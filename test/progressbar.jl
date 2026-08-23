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

    @testset "show_progjob_with_theme rendering" begin
        p = ProgJob("foobar")
        line = show_progjob_with_theme(p, AMBER)
        @test occursin("foobar", line)
        @test occursin("1 unit", line)               # indeterminate mode

        p2 = ProgJob(1:4)
        @test p2.total == 4
        line2 = show_progjob_with_theme(p2, OCEAN)
        @test occursin("0% (0/4)", line2)             # determinate mode
    end

    @testset "with_job" begin
        results = with_job(1:10) do x
            x^2
        end
        @test results == [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]

        doubled = with_job(1:10) do x
            x * 2
        end
        @test doubled == collect(2:2:20)
    end

    @testset "ProgJob iteration" begin
        p = ProgJob(1:50; desc="Downloading")
        n = 0
        for i in p
            n += i
        end
        @test n == sum(1:50)
        @test p.state == 50

        files = ["data1.csv", "data2.csv", "data3.csv", "data4.csv"]
        seen = String[]
        for file in ProgJob(files, OCEAN; desc="Parsing files")
            push!(seen, file)
        end
        @test seen == files
    end

    @testset "comprehensions" begin
        squares = [x^2 for x in ProgJob(1:10, GLACIER; desc="Squaring")]
        @test squares == [x^2 for x in 1:10]

        m = [x^2 for x in ProgJob(reshape(1:9, 3, 3), GLACIER; desc="Squaring matrix elements!")]
        @test m == [x^2 for x in reshape(1:9, 3, 3)]
    end

    @testset "threaded iteration over ProgJob" begin
        p = ProgJob(1:100, AMBER; desc="Threaded")
        seen = zeros(Int, 100)
        Base.Threads.@threads for i in p
            seen[i] = i
        end
        @test seen == collect(1:100)
        @test p.state == 100
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
        # caps + head from a theme
        p = ProgJob(1:10; caps="[]", head=">", width=10)
        update!(p, 6)                          # 60%
        line = show_progjob_with_theme(p, p.theme)
        strip_ansi(s) = replace(s, r"\e\[[0-9;]*m" => "")
        vis = strip_ansi(line)
        @test startswith(vis, "◉ ") || occursin("] ", vis)  # spinner present
        # the bar is framed and tipped: "██████>" with "[]" caps
        m = match(r"\[.*\]", vis)
        @test m !== nothing
        @test occursin(">", m.match)           # head at the tip
        @test !occursin(">", replace(m.match, ">" => "")) || true

        # no head on a completed bar
        update!(p, 10)
        vis2 = strip_ansi(show_progjob_with_theme(p, p.theme))
        @test occursin("]", vis2)
        @test !occursin(">", vis2)
    end

    @testset "bar endcaps and head marker via @progress" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("x", caps="()", head="▸")) for i in 1:2
            pbar_ref[] = ctx.pbar
        end
        root = get_children(pbar_ref[], nothing)[1]
        @test root.theme.caps == ('(', ')')
        @test root.theme.head == '▸'
    end

    @testset "amber-family themes" begin
        for T in (HONEY, EMBER, TANGERINE, COPPER, MARIGOLD, SUNSET, AMBER_GLOW)
            @test !isempty(T.palette)
            @test !isempty(T.barunits)
            @test !isempty(T.spinner)
        end
    end

    @testset "REPL show summaries" begin
        p = ProgJob(1:10; desc="Downloading")
        update!(p, 3)
        s = sprint(show, p)
        @test occursin("ProgJob", s)
        @test occursin("Downloading", s)
        @test occursin("3/10", s)

        q = ProgJob("Watching")                    # indeterminate
        @test occursin("Watching", sprint(show, q))
        @test !occursin("/", sprint(show, q))

        pbar = ProgBar("Pipeline")
        root = add_job!(pbar, "root"; total=2)
        add_job!(pbar, "child"; parent=root, total=3)
        s2 = sprint(show, pbar)
        @test occursin("ProgBar", s2)
        @test occursin("Pipeline", s2)
        @test occursin("2 jobs", s2)
        @test occursin("1 root", s2)
    end

    @testset "per-bar style overrides" begin
        # via add_job!
        pbar = ProgBar()
        j = add_job!(pbar, 1:3; desc="y", spinner="◐◑", barunits="▒█", empty=" ", width=24)
        @test j.theme.spinner == ['◐', '◑']
        @test j.theme.barunits == ['▒', '█']
        @test j.bar_width == 24
        update!(pbar, j, 2)                      # 2/3: the bar shows filled glyphs
        line = show_progjob_with_theme(j, j.theme)
        @test occursin("█", line)

        # via the standalone ProgJob constructor
        p = ProgJob(1:3; spinner="⠋⠙")
        @test p.theme.spinner == ['⠋', '⠙']
        @test p.bar_width === nothing          # no width override by default

        # no overrides -> theme unchanged
        q = ProgJob("plain")
        @test q.theme === AMBER
    end
end
