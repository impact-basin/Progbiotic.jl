using Progbiotic
using Test

@testset "progressbar.jl" begin
    @testset "duration_str formatting" begin
        @test duration_str(1) == "1 s"
        @test duration_str(10) == "10 s"
        @test duration_str(100) == "1m 40 s"
        @test duration_str(1000) == "16m 40 s"
        @test duration_str(10000) == "2h 46m 40 s"
        @test duration_str(100000) == "1d 3h 46m 40 s"
        @test duration_str(1000000) == "11d 13h 46m 40 s"
        @test duration_str(0.5; show_ms=true) == "500.0ms"
        @test duration_str(0.0005; show_ms=true) == "500.0µs"
        @test duration_str(Inf) == "∞"
        @test duration_str(NaN) == "N/A"
    end

    @testset "a standalone bar renders through its theme" begin
        p = Progress(nothing; desc = "foobar", io = sink(), tty = false, start = false)
        line = render_frame(p)
        @test occursin("foobar", line)
        @test occursin("1 unit", line)               # indeterminate mode

        p2 = Progress(4; desc = "foobar", theme = OCEAN, io = sink(), tty = false,
                      start = false)
        @test pbtotal(p2) == 4
        line2 = plain(render_frame(p2))
        @test occursin("0%", line2)                  # determinate mode
        @test occursin("(0/4)", line2)

        # the standalone form is the same line, with no tree and no terminal around it
        # (the colors cycle with the spinner, so compare what the eye sees)
        q = Progress(4; desc = "foobar", io = sink(), tty = false, start = false)
        @test plain(render_frame(q)) == plain(render_line(q))
    end

    @testset "prog runs a block per item" begin
        results  = Int[]
        returned = prog(1:10; desc = "squaring", io = sink(), vanish = 0.0) do x
            push!(results, x^2)
        end
        @test returned === nothing
        @test results == [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]

        doubled = [x * 2 for x in prog(1:10; io = sink(), vanish = 0.0)]
        @test doubled == collect(2:2:20)
    end

    @testset "iteration over a wrapped collection" begin
        p = prog(1:50; desc = "Downloading", io = sink(), vanish = 0.0)
        n = 0
        for i in p
            n += i
        end
        @test n == sum(1:50)
        @test pbdone(p) == 50
        @test isfinished(p)
        @test p.bar.theme === AMBER          # prog takes its look from the default theme

        files = ["data1.csv", "data2.csv", "data3.csv", "data4.csv"]
        seen  = String[]
        for file in prog(files; desc = "Parsing files", io = sink(), vanish = 0.0)
            push!(seen, file)
        end
        @test seen == files
    end

    @testset "comprehensions" begin
        squares = [x^2 for x in prog(1:10; desc = "Squaring", io = sink(), vanish = 0.0)]
        @test squares == [x^2 for x in 1:10]

        matrix = reshape(1:9, 3, 3)
        m = [x^2 for x in prog(matrix; desc = "Squaring matrix elements!", io = sink(),
                              vanish = 0.0)]
        @test m == [x^2 for x in matrix]
    end

    @testset "threaded iteration over a wrapped collection" begin
        p    = prog(1:100; desc = "Threaded", io = sink(), vanish = 0.0)
        seen = zeros(Int, 100)
        Base.Threads.@threads for i in p
            seen[i] = i
        end
        @test seen == collect(1:100)
        @test pbdone(p) == 100
        finish!(p)
    end

    @testset "Theme mix-and-match copy constructor" begin
        t = Theme(AMBER; spinner=EMERALD.spinner)
        @test t.palette == AMBER.palette
        @test t.spinner == EMERALD.spinner
        @test t.barunits == AMBER.barunits
        @test t.empty == AMBER.empty
        u = Theme(OCEAN; barunits=['░', '█'], empty='·')
        @test u.palette == OCEAN.palette
        @test u.barunits == ['░', '█']
        @test u.empty == '·'
        v = Theme(AMBER; caps="[]", head='>')
        @test v.caps == ('[', ']')
        @test v.head == '>'
        @test AMBER.caps == (' ', ' ')        # built-in themes default to no caps
        @test AMBER.head === nothing
    end

    @testset "bar endcaps and head marker" begin
        # caps + head from a theme, on a bar that asked for its own width
        p = Progress(10; desc = "caps", width = 10, io = sink(), tty = false, start = false,
                     theme = Theme(AMBER; caps = "[]", head = ">"))
        next!(p, 6)                            # 60%
        vis = plain(render_frame(p))
        @test startswith(vis, "◉ ") || occursin("] ", vis)  # spinner present
        # the bar is framed and tipped: "█████>░░░░" with "[]" caps
        m = match(r"\[.*\]", vis)
        @test m !== nothing
        @test occursin(">", m.match)           # head at the tip

        # no head on a completed bar
        update!(p, 10)
        vis2 = plain(render_frame(p))
        @test occursin("]", vis2)
        @test !occursin(">", vis2)
    end

    @testset "bar endcaps and head marker via @progress" begin
        captured = Ref{Any}(nothing)
        @progress "outer" io = sink() vanish = 0.0 for i in 1:2
            @progress (ctx => ("x", caps = "()", head = "▸")) for j in 1:2
                captured[] = ctx
            end
        end

        # the bound context *is* the node, so its theme is the one the level asked for
        @test captured[].theme.caps == ('(', ')')
        @test captured[].theme.head == '▸'
    end

    @testset "amber-family themes" begin
        for T in (HONEY, EMBER, TANGERINE, COPPER, MARIGOLD, SUNSET, AMBER_GLOW)
            @test !isempty(T.palette)
            @test !isempty(T.barunits)
            @test !isempty(T.spinner)
        end
    end

    @testset "REPL show summaries" begin
        p = Progress(10; desc = "Downloading", io = sink(), tty = false, start = false)
        next!(p, 3)
        s = sprint(show, p)
        @test occursin("Progress", s)
        @test occursin("Downloading", s)
        @test occursin("3/10", s)

        q = Progress(nothing; desc = "Watching", io = sink(), tty = false, start = false)
        @test occursin("Watching", sprint(show, q))
        @test occursin("indeterminate", sprint(show, q))
        @test !occursin("/", sprint(show, q))

        # a node's summary counts its own children, not the whole tree
        root = Progress(nothing; desc = "Pipeline", io = sink(), tty = false, start = false)
        child(root, 2; desc = "child one")
        child(root, 3; desc = "child two")
        s2 = sprint(show, root)
        @test occursin("Pipeline", s2)
        @test occursin("2 children", s2)
    end

    @testset "per-bar style overrides" begin
        # the glyph keywords belong to child(...), which restyles a copy of the theme
        root = Progress(nothing; title = "styles", io = sink(), tty = false, start = false)
        j = child(root, 3; desc = "y", spinner = "◐◑", barunits = "▒█", empty = " ",
                  width = 24)
        @test j.theme.spinner == ['◐', '◑']
        @test j.theme.barunits == ['▒', '█']
        @test j.theme.empty == ' '
        @test j.opts.width == 24
        next!(j, 2)                            # 2/3: the bar shows filled glyphs
        @test occursin("█", plain(render_frame(j)))

        # a standalone node takes its look from the theme it was handed
        p = Progress(3; theme = Theme(AMBER; spinner = collect("⠋⠙")), io = sink(),
                     tty = false, start = false)
        @test p.theme.spinner == ['⠋', '⠙']
        @test p.opts.width == 0                # nothing overrides the measured width

        # no overrides -> the default theme, unchanged
        q = Progress(nothing; io = sink(), tty = false, start = false)
        @test q.theme === AMBER
    end
end
