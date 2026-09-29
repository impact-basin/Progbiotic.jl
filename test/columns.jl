using Progbiotic
using Test

strip_ansi(text) = replace(text, r"\e\[[0-9;]*m" => "")

"""A bar with a fixed amount of work already done and a fixed 10s of elapsed time."""
function aged_state(; total = 200, desc = "job", current = 0, elapsed = 10.0)
    state = BarState(total; desc = desc)
    state.current[] = current
    state.start = time() - elapsed
    state.last_update = time()
    return state
end

"""A user-defined column, proving the documented extension point works."""
struct TestFixedColumn <: AbstractColumn end
Progbiotic.render_column(::TestFixedColumn, state::BarState) = "fixed"

@testset "columns.jl" begin
    @testset "AbstractColumn interface" begin
        @test Spinner() isa AbstractColumn
        @test Bar() isa AbstractColumn
        @test Percent() isa AbstractColumn
        @test Rate() isa AbstractColumn
        @test Eta() isa AbstractColumn
        @test Postfix() isa AbstractColumn
        @test Tag() isa AbstractColumn

        @test render_column(TestFixedColumn(), aged_state()) == "fixed"
        @test render_column(TestFixedColumn(), aged_state()) isa String
    end

    @testset "Spinner" begin
        state = aged_state()
        spinner = Spinner(:dots)
        @test isempty(spinner.palette)   # unstyled unless a theme supplies one
        @test length(spinner.frames) == 10
        @test render_column(spinner, state) in spinner.frames

        line = Spinner(:line)
        @test line.frames == ["-", "\\", "|", "/"]
        @test render_column(line, state) in line.frames

        @test render_column(Spinner(:clock), state) in Spinner(:clock).frames
        @test_throws ProgbioticError Spinner(:nope)
    end

    @testset "Tag templates" begin
        state = aged_state(total = 200, desc = "Training", current = 50)
        @test render_column(Tag("{desc}"), state) == "Training"
        @test render_column(Tag("{n}/{total}"), state) == "50/200"
        @test render_column(Tag("{pct}%"), state) == "25.0%"
        @test render_column(Tag("elapsed {elapsed}"), state) == "elapsed 00:00:10"
        @test render_column(Tag("no placeholders"), state) == "no placeholders"
        @test render_column(Tag("{unknown}"), state) == "{unknown}"

        indeterminate = aged_state(total = nothing, desc = "watching")
        @test render_column(Tag("{desc}"), indeterminate) == "watching"
        @test render_column(Tag("{total}"), indeterminate) == ""
    end

    @testset "Bar" begin
        half = aged_state(total = 200, current = 100)
        plain = Bar(fill = '#', empty = '-', width = 10)

        # an unstyled bar is plain text: no palette means no escape sequences, so
        # a bar drawn into a pipe or a file carries no terminal control at all
        bar = render_column(plain, half)
        @test bar == " #####----- "           # the flanking spaces are the default caps
        @test !occursin('\e', bar)

        @test render_column(plain, aged_state(total = 4, current = 0)) == " ---------- "
        @test render_column(plain, aged_state(total = 4, current = 4)) == " ########## "

        # the default glyphs are the documented ones
        default_bar = render_column(Bar(), half)
        @test count(==('█'), default_bar) == 15
        @test count(==('░'), default_bar) == 15

        # keyword and positional construction agree
        @test Bar('#', '-', 10).width == 10
        @test Bar(fill = '#', empty = '-', width = 10).units == ['#']
        @test Bar().width == 30

        # a themed bar carries a palette, and so is coloured and reset
        themed = render_column(Bar(AMBER.barunits, AMBER.empty, AMBER.palette,
                                   AMBER.caps, AMBER.head; width = 10), half)
        @test occursin("\e[38;2;", themed)
        @test occursin("\e[0m", themed)
        @test occursin("█", strip_ansi(themed))

        # an indeterminate bar sweeps a block of the full track
        marquee = strip_ansi(render_column(Bar(fill = '#', empty = '-', width = 20),
                                           aged_state(total = nothing)))
        @test length(marquee) == 22           # 20 + the two caps
        @test count(==('#'), marquee) == 5
    end

    @testset "Percent" begin
        @test render_column(Percent(), aged_state(total = 200, current = 90)) == "45.0%"
        @test render_column(Percent(0), aged_state(total = 3, current = 1)) == "33%"
        @test render_column(Percent(3), aged_state(total = 3, current = 1)) == "33.333%"
        @test render_column(Percent(), aged_state(total = nothing)) == ""
    end

    @testset "Rate" begin
        # 100 items in 10 seconds is ten items a second
        @test render_column(Rate(), aged_state(total = 200, current = 100)) == "10.0 it/s"
        @test render_column(Rate(unit = "rows/s"),
                            aged_state(total = 2000, current = 25000)) == "2.5k rows/s"
        @test render_column(Rate(unit = "cells/s"),
                            aged_state(total = 2000, current = 25000000)) == "2.5M cells/s"
        # below one item per second the column inverts, which is far easier to read
        @test render_column(Rate(), aged_state(total = 200, current = 5)) == "2.0 s/it"
        @test render_column(Rate(), aged_state(total = 200, current = 0)) == ""
    end

    @testset "Eta" begin
        @test render_column(Eta(), aged_state(total = 200, current = 100)) == "ETA 00:00:10"
        @test occursin(r"^ETA \d{2}:\d{2}:\d{2}$",
                       render_column(Eta(), aged_state(total = 100, current = 1)))
        @test render_column(Eta(), aged_state(total = 200, current = 200)) == "ETA 00:00:00"
        @test render_column(Eta(), aged_state(total = nothing)) == ""
        @test render_column(Eta(), aged_state(total = 200, current = 0)) == ""

        # more than a day of remaining work still fits the format
        slow = render_column(Eta(), aged_state(total = 100000, current = 1, elapsed = 100.0))
        @test occursin(r"^ETA \d+:\d{2}:\d{2}$", slow)
    end

    @testset "Postfix and set_postfix!" begin
        handle = Progress(100; desc = "metrics", io = IOBuffer(), tty = true,
                          vanish = 0.0, start = false)
        state = handle.ctx.state
        @test render_column(Postfix(), state) == ""

        set_postfix!(handle; loss = 0.041, lr = 1e-4)
        text = render_column(Postfix(), state)
        @test text == "[loss=0.041, lr=0.0001]"
        # insertion order is preserved, not dictionary order
        @test startswith(text, "[loss=")
        @test occursin("loss=0.041, lr=0.0001", text)

        # values are overwritten, not appended
        set_postfix!(handle; loss = 0.9)
        @test render_column(Postfix(), state) == "[loss=0.9, lr=0.0001]"

        # a custom separator
        @test occursin("; ", render_column(Postfix("; "), state))

        # a bare set_postfix! outside any scope is a mistake, not a silent no-op
        @test_throws ProgbioticError set_postfix!(; epoch = 3)

        # inside a scope it reaches that scope's bar
        live = Progress(10; desc = "live", io = IOBuffer(), tty = false, vanish = 0.0)
        with_progress_logging(live) do
            set_postfix!(; epoch = 3)
        end
        @test occursin("epoch=3", render_column(Postfix(), live.ctx.state))
        finish!(live; wait = true)
        finish!(live; wait = true)
    end

    @testset "default_layout and composition" begin
        layout = default_layout()
        @test layout isa Tuple
        @test any(c -> c isa Spinner, layout)
        @test any(c -> c isa Bar, layout)
        @test any(c -> c isa Percent, layout)
        @test any(c -> c isa Count, layout)
        @test any(c -> c isa Rate, layout)
        @test any(c -> c isa Eta, layout)
        @test any(c -> c isa Postfix, layout)

        handle = Progress(200; desc = "composed", io = IOBuffer(), tty = true,
                          vanish = 0.0, start = false)
        handle.ctx.state.current[] = 100
        handle.ctx.state.start = time() - 10.0
        handle.ctx.state.last_update = time()
        set_postfix!(handle; loss = 0.25)

        frame = strip_ansi(render_frame(handle.ctx))
        @test startswith(frame, "composed") || occursin("composed", frame)
        @test occursin("50.0%", frame)
        @test occursin("10.0 it/s", frame)
        @test occursin("ETA 00:00:10", frame)
        @test occursin("[loss=0.25]", frame)

        # empty columns are dropped, and the join is a single space
        layout2 = [Tag("{desc}"), Percent(), Postfix()]
        handle2 = Progress(10; desc = "sparse", layout = layout2, io = IOBuffer(),
                           tty = true, vanish = 0.0, start = false)
        @test render_frame(handle2.ctx) == "sparse 0.0%"
    end

    @testset "the layout from the feature tour" begin
        my_layout = [
            Spinner(:dots),
            Tag("{desc}"),
            Bar(fill = '█', empty = '░', width = 30),
            Percent(),
            Rate(unit = "it/s"),
            Eta(),
            Postfix(),
        ]
        handle = Progress(100; layout = my_layout, desc = "Custom Pipeline",
                          io = IOBuffer(), tty = true, vanish = 0.0, start = false)
        handle.ctx.state.start = time() - 1.0
        handle.ctx.state.last_update = time()
        for _ in 1:45
            next!(handle)
        end
        set_postfix!(handle; accuracy = "45.0%")
        frame = strip_ansi(render_frame(handle.ctx))
        @test occursin("Custom Pipeline", frame)
        @test occursin("45.0%", frame)
        @test occursin("accuracy=45.0%", frame)
        @test occursin("45.0 it/s", frame)
        @test occursin('█', frame)
        @test occursin('░', frame)
        @test length(handle.ctx.layout) == 7
    end
end
