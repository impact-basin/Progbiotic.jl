module TerminalFixture

using Test
using Libdl
using Progbiotic

# libvterm 0.3 ABI; older parser callback tables have a different layout
const lib = let
    found = C_NULL
    for name in ("libvterm.so.0", "libvterm.so", "libvterm.0.dylib", "libvterm.dylib", "vterm.dll")
        handle = Libdl.dlopen_e(name)
        handle == C_NULL && continue
        if Libdl.dlsym_e(handle, :vterm_build) != C_NULL
            found = handle
            break
        end
        Libdl.dlclose(handle)
    end
    found
end

sym(name) = Libdl.dlsym(lib, name)

struct Pos
    row::Cint
    col::Cint
end

struct Rect
    top::Cint
    bottom::Cint
    left::Cint
    right::Cint
end

struct Glyph
    chars::Ptr{UInt32}
    width::Cint
    flags::Cuint
end

# the string-fragment bitfields occupy one unsigned int after the pointer
struct Fragment
    text::Ptr{UInt8}
    flags::Cuint
end

mutable struct Trace
    glyphs::Vector{NTuple{3,Int}}
    forbidden::Vector{Symbol}
    text::IOBuffer
    osc::IOBuffer
    link::Bool
end

Trace() = Trace(NTuple{3,Int}[], Symbol[], IOBuffer(), IOBuffer(), false)
trace(user) = unsafe_pointer_to_objref(user)::Trace

function putglyph(info::Ptr{Glyph}, pos::Pos, user::Ptr{Cvoid})::Cint
    push!(trace(user).glyphs, (pos.row, pos.col, unsafe_load(info).width))
    return 1
end

function text(bytes::Ptr{UInt8}, len::Csize_t, user::Ptr{Cvoid})::Cint
    # libvterm supplies the remaining input, not an already-delimited text token
    n = 0
    while n < len
        byte = unsafe_load(bytes, n + 1)
        (byte < 0x20 || byte == 0x7f) && break
        n += 1
    end
    write(trace(user).text, unsafe_wrap(Vector{UInt8}, bytes, n))
    return Cint(n)
end

function control(::Cuchar, user::Ptr{Cvoid})::Cint
    push!(trace(user).forbidden, :control)
    return 1
end

function escape(::Ptr{UInt8}, ::Csize_t, user::Ptr{Cvoid})::Cint
    push!(trace(user).forbidden, :escape)
    return 1
end

function csi(leader::Ptr{UInt8}, ::Ptr{Clong}, ::Cint, intermed::Ptr{UInt8},
             command::Cchar, user::Ptr{Cvoid})::Cint
    plain = (leader == C_NULL || unsafe_load(leader) == 0) &&
            (intermed == C_NULL || unsafe_load(intermed) == 0)
    command == Int('m') && plain || push!(trace(user).forbidden, :csi)
    return 1
end

function osc(command::Cint, fragment::Fragment, user::Ptr{Cvoid})::Cint
    log = trace(user)
    if fragment.flags & 0x40000000 != 0
        truncate(log.osc, 0)
        seekstart(log.osc)
    end
    len = Int(fragment.flags & 0x3fffffff)
    write(log.osc, unsafe_wrap(Vector{UInt8}, fragment.text, len))
    if fragment.flags & 0x80000000 != 0
        parts = split(String(take!(log.osc)), ';'; limit = 2)
        if command == 8 && length(parts) == 2
            log.link = !isempty(parts[2])
        else
            push!(log.forbidden, :osc)
        end
    end
    return 1
end

function dcs(::Ptr{UInt8}, ::Csize_t, ::Fragment, user::Ptr{Cvoid})::Cint
    push!(trace(user).forbidden, :dcs)
    return 1
end

function stringcontrol(::Fragment, user::Ptr{Cvoid})::Cint
    push!(trace(user).forbidden, :string)
    return 1
end

const state_callbacks = Ref(ntuple(12) do i
    i == 1 ? @cfunction(putglyph, Cint, (Ptr{Glyph}, Pos, Ptr{Cvoid})) : C_NULL
end)

const parser_callbacks = Ref((
    @cfunction(text, Cint, (Ptr{UInt8}, Csize_t, Ptr{Cvoid})),
    @cfunction(control, Cint, (Cuchar, Ptr{Cvoid})),
    @cfunction(escape, Cint, (Ptr{UInt8}, Csize_t, Ptr{Cvoid})),
    @cfunction(csi, Cint, (Ptr{UInt8}, Ptr{Clong}, Cint, Ptr{UInt8}, Cchar, Ptr{Cvoid})),
    @cfunction(osc, Cint, (Cint, Fragment, Ptr{Cvoid})),
    @cfunction(dcs, Cint, (Ptr{UInt8}, Csize_t, Fragment, Ptr{Cvoid})),
    @cfunction(stringcontrol, Cint, (Fragment, Ptr{Cvoid})),
    @cfunction(stringcontrol, Cint, (Fragment, Ptr{Cvoid})),
    @cfunction(stringcontrol, Cint, (Fragment, Ptr{Cvoid})),
    C_NULL,
))

function terminal(f, height, width)
    vt = ccall(sym(:vterm_new), Ptr{Cvoid}, (Cint, Cint), height, width)
    vt == C_NULL && error("libvterm allocation failed")
    try
        ccall(sym(:vterm_set_utf8), Cvoid, (Ptr{Cvoid}, Cint), vt, 1)
        return f(vt)
    finally
        ccall(sym(:vterm_free), Cvoid, (Ptr{Cvoid},), vt)
    end
end

function feed(vt, s)
    n = ccall(sym(:vterm_input_write), Csize_t,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), vt, s, sizeof(s))
    n == sizeof(s) || error("libvterm consumed only $n bytes")
    return nothing
end

function pen(state)
    return map(1:12) do attr
        # VTermValue is a union; bool/int/colour all fit in its first four bytes
        value = zeros(UInt8, 16)
        ccall(sym(:vterm_state_get_penattr), Cint,
              (Ptr{Cvoid}, Cint, Ptr{UInt8}), state, attr, value)
        Tuple(value[1:4])
    end
end

function geometry(s, width)
    log = Trace()
    GC.@preserve log begin
        terminal(256, width) do vt
            state = ccall(sym(:vterm_obtain_state), Ptr{Cvoid}, (Ptr{Cvoid},), vt)
            ccall(sym(:vterm_state_set_callbacks), Cvoid,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                  state, state_callbacks, pointer_from_objref(log))
            ccall(sym(:vterm_state_reset), Cvoid, (Ptr{Cvoid}, Cint), state, 1)
            initial = pen(state)
            feed(vt, s)
            fits = all(log.glyphs) do (row, col, cells)
                row == 0 && 0 <= col && col + cells <= width
            end
            return (; fits, closed = pen(state) == initial, glyphs = copy(log.glyphs))
        end
    end
end

function parsed(s)
    log = Trace()
    GC.@preserve log begin
        terminal(4, 80) do vt
            ccall(sym(:vterm_parser_set_callbacks), Cvoid,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                  vt, parser_callbacks, pointer_from_objref(log))
            ccall(sym(:vterm_parser_set_emit_nul), Cvoid, (Ptr{Cvoid}, Bool), vt, true)
            feed(vt, s)
            linked = log.link
            visible = String(take!(log.text))
            # a plain trailer must reach text, even after a truncated control string
            marker = "TRAILERq7"
            feed(vt, marker)
            trailer = String(take!(log.text))
            clean = isvalid(visible) && all(c -> !iscntrl(c) && c != '\u2028' && c != '\u2029', visible)
            return (; forbidden = copy(log.forbidden), linked, clean,
                    ground = trailer == marker)
        end
    end
end

function screenrows(screen, height, width)
    return map(0:(height - 1)) do row
        bytes = Vector{UInt8}(undef, 32 * width + 1)
        n = ccall(sym(:vterm_screen_get_text), Csize_t,
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Rect), screen, bytes, length(bytes),
                  Rect(row, row + 1, 0, width))
        String(bytes[1:n])
    end
end

# a cooked PTY applies OPOST/ONLCR before the emulator receives these bytes
transport(s) = replace(s, "\n" => "\r\n")

struct Literal <: AbstractColumn
    text::String
end

Progbiotic.render_column(col::Literal, ::BarState) = col.text

function checkline(line, width)
    cells = geometry(line, width)
    tokens = parsed(line)
    @test cells.fits
    @test cells.closed
    @test isempty(tokens.forbidden)
    @test !tokens.linked
    @test tokens.clean
    @test tokens.ground
end

function gutter(height, width; keep = false)
    terminal(height, width) do vt
        screen = ccall(sym(:vterm_obtain_screen), Ptr{Cvoid}, (Ptr{Cvoid},), vt)
        ccall(sym(:vterm_screen_reset), Cvoid, (Ptr{Cvoid}, Cint), screen, 1)
        buf = IOBuffer()
        io = IOContext(buf, :displaysize => (height, width))
        root = Progress(10; io, tty = true, start = false, layout = (Literal("R"),))
        child(root, 10; layout = (Literal("C"),))

        @test Progbiotic._draw_tty!(root)
        feed(vt, transport(String(take!(buf))))
        @test root.root.rows == 2
        @test screenrows(screen, height, width)[end-1:end] == ["R", "╰─ C"]

        if !keep
            child(root, 10; layout = (Literal("D"),))
            @test Progbiotic._draw_tty!(root)
            feed(vt, transport(String(take!(buf))))
            @test root.root.rows == 3
            @test screenrows(screen, height, width)[end-2:end] == ["R", "├─ C", "╰─ D"]

            feed(vt, transport(repeat("u\n", 2height)))
            @test screenrows(screen, height, width)[end-2:end] == ["R", "├─ C", "╰─ D"]

            # explicit state completion avoids starting a background renderer
            Progbiotic._finish_state!(root.state)
            @test Progbiotic._draw_tty!(root)
            feed(vt, transport(String(take!(buf))))
            @test root.root.rows == 1
            @test screenrows(screen, height, width)[end-2:end] == ["", "", "R"]
        end

        Progbiotic._release_gutter!(root; keep)
        feed(vt, transport(String(take!(buf))))
        @test root.root.rows == 0
        if keep
            @test screenrows(screen, height, width)[end-2:end] == ["R", "╰─ C", ""]
        else
            @test screenrows(screen, height, width)[end] == ""
        end

        feed(vt, transport(repeat("z\n", height + 1)))
        @test screenrows(screen, height, width) == [fill("z", height - 1); ""]
        @test root.root.task === nothing
    end
end

# a narrow failed tree still fits the gutter it claims, and keeps its status visible
function statusgutter(height, width)
    terminal(height, width) do vt
        screen = ccall(sym(:vterm_obtain_screen), Ptr{Cvoid}, (Ptr{Cvoid},), vt)
        ccall(sym(:vterm_screen_reset), Cvoid, (Ptr{Cvoid}, Cint), screen, 1)
        buf = IOBuffer()
        io = IOContext(buf, :displaysize => (height, width))
        root = Progress(10; io, tty = true, start = false, desc = repeat("root ", 20))
        kid = child(root, 10; desc = repeat("界", 20))
        fail!(kid, ErrorException("bad"))
        Progbiotic._finish_state!(root.state)

        @test Progbiotic._draw_tty!(root)
        feed(vt, transport(String(take!(buf))))
        rows = root.root.rows
        @test 2 <= rows <= height - 1
        shown = screenrows(screen, height, width)
        bottom = shown[end-rows+1:end]
        @test any(row -> occursin("ERROR", row) || occursin("!", row), bottom)
        @test width < 8 ? all(!isempty, bottom) :
              any(row -> occursin("root", row) || occursin("界", row), bottom)

        feed(vt, transport(repeat("u\n", height)))
        @test screenrows(screen, height, width)[end-rows+1:end] == bottom

        Progbiotic._release_gutter!(root)
        feed(vt, transport(String(take!(buf))))
        @test root.root.rows == 0
    end
end

@testset "independent terminal" begin
    if lib == C_NULL
        @info "libvterm 0.3 ABI unavailable; skipping independent terminal fixture"
        @test_skip lib != C_NULL
    else
        @info "independent terminal backend" library = Libdl.dlpath(lib) abi = "libvterm 0.3"
        try
            @testset "oracle checks" begin
                @test !geometry("AB\e[H", 1).fits
                @test !geometry("界", 1).fits
                @test geometry("界", 2).fits
                @test geometry("e\u0301e\u0301", 2).fits
                @test geometry("界", 2).glyphs == [(0, 0, 2)]
                @test geometry("e\u0301e\u0301", 2).glyphs == [(0, 0, 1), (0, 1, 1)]
                @test geometry("\e[31mAB\e[0m", 2).glyphs == [(0, 0, 1), (0, 1, 1)]
                @test !geometry("\e[31mX", 2).closed
                @test geometry("\e[1;3;4;31;44mX\e[0m", 2).closed
                @test isempty(parsed("\e[31mX\e[0m").forbidden)
                @test parsed("\e]8;;https://example.org\e\\X").linked
                @test !parsed("\e]8;;https://example.org\e\\X\e]8;;\e\\").linked
                @test !parsed("\e]0;unfinished").ground
                @test !parsed("TRAILERq7\e]0;unfinished").ground
                @test !parsed("\e[").ground
                for command in ("\e[2J", "\e[?25l", "\n", "\0", "\e7",
                                "\e]0;title\a", "\ePqdata\e\\", "\e_data\e\\")
                    @test !isempty(parsed(command).forbidden)
                end
                @test !parsed("\u009b2J").clean
            end

            # libvterm 0.3 does not compose modern ZWJ emoji into a two-cell cluster;
            # exact emoji/grapheme policy belongs in the portable text unit tests
            labels = (
                ascii = repeat("alpha", 10),
                cjk = repeat("界", 25),
                combining = repeat("e\u0301", 45),
                sgr = "\e[1;3;4;31;44m" * repeat("界e\u0301", 20) * "\e[0m",
                link = "\e]8;id=fixture;https://example.org\e\\" * repeat("界e\u0301", 20),
                controls = "A\nB\rC\tD\vE\fF\u2028G\u2029H\e[2J\e[H" *
                           "\e]0;bad\a\ePqbad\e\\\u009b2J\u009d0;bad\u009c" * repeat("界", 20),
            )
            @testset "$name $kind width=$width" for (name, label) in pairs(labels),
                                                     kind in (:title, :label, :column), width in 1:40
                layout = kind == :column ? (Literal(label),) : (Tag(),)
                root = Progress(10; io = IOBuffer(), tty = true, start = false, layout,
                                title = kind == :title ? label : "",
                                desc = kind == :label ? label : "root")
                child(root, 10; desc = "kid", layout = (Literal("child"),))
                for line in split(render_tree(root; width), '\n'; keepempty = true)
                    checkline(line, width)
                end
                @test root.root.task === nothing
            end

            @testset "fragment boundaries" begin
                link = "\e]8;;https://example.org\e\\"
                root = Progress(1; io = IOBuffer(), start = false,
                                layout = (Literal("\e[31mA"), Literal(link * "B"), Literal("C")))
                line = render_line(root)
                @test occursin("A\e[0m ", line)
                @test occursin("B\e]8;;\e\\ C", line)
                checkline(line, 10)
            end

            @testset "narrow status rows width=$width" for width in 1:40
                for (status, action, wide, narrow, minimum) in (
                    (:failed, p -> fail!(p, ErrorException("bad")), "ERROR", "!", 5),
                    (:cancelled, p -> Progbiotic._cancel_state!(p.state), "cancelled", "-", 9),
                    (:interrupted, p -> fail!(p, InterruptException()), "interrupted", "!", 11),
                )
                    p = Progress(10; io = IOBuffer(), tty = true, start = false,
                                 desc = repeat("界", 30))
                    action(p)
                    marker = width >= minimum ? wide : narrow
                    for line in split(render_tree(p; width), '\n')
                        checkline(line, width)
                        @test occursin(marker, Progbiotic._plain_text(line))
                    end
                end
            end

            @testset "gutter height=$height width=$width keep=$keep" for height in (4, 8),
                                                                         width in (8, 20), keep in (false, true)
                gutter(height, width; keep)
            end

            @testset "narrow failing gutter height=$height width=$width" for height in (4, 8),
                                                                              width in (5, 8, 20)
                statusgutter(height, width)
            end
        finally
            Libdl.dlclose(lib)
        end
    end
end

end
