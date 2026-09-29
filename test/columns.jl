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

    @testset "Tag pads and bolds only when asked" begin
        state = aged_state(desc = "Short")

        # an unstyled column emits no escape sequences at all, so a custom layout is
        # plain text until it asks otherwise
        @test render_column(Tag("{desc}"), state) == "Short"
        @test !occursin('\e', render_column(Tag("{desc}"), state))

        @test render_column(Tag("{desc}"; width = 8), state) == "Short   "
        bolded = render_column(Tag("{desc}"; bold = true), state)
        @test strip_ansi(bolded) == "Short"
        @test occursin("\e[1m", bolded)
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

        # a pad is what stops the field jittering as it crosses nine percent to ten
        @test render_column(Percent(0, pad = 3), aged_state(total = 200, current = 8)) == "  4%"
        @test render_column(Percent(0, pad = 3), aged_state(total = 200, current = 90)) == " 45%"
        @test length(render_column(Percent(0, pad = 3), aged_state(total = 200, current = 90))) == 3 + 1
    end

    @testset "Count" begin
        # the completed count is padded to the width of the total, so the field does
        # not shuffle as it climbs
        @test render_column(Count(), aged_state(total = 10, current = 4)) == "( 4/10)"
        @test render_column(Count(), aged_state(total = 100, current = 4)) == "(  4/100)"
        @test render_column(Count(), aged_state(total = 10, current = 10)) == "(10/10)"

        # an indeterminate bar stands for one piece of work, and says so
        @test render_column(Count(), aged_state(total = nothing)) == "1 unit"
    end

    @testset "Rate" begin
        # 100 items in 10 seconds is ten items a second, bracketed and padded so the
        # times to the right of it line up down a tree
        @test render_column(Rate(), aged_state(total = 200, current = 100)) == "[10.0 it/s ]"
        @test render_column(Rate(unit = "rows/s"),
                            aged_state(total = 2000, current = 25000)) == "[2.5k rows/s]"
        @test render_column(Rate(unit = "cells/s"),
                            aged_state(total = 2000, current = 25000000)) == "[2.5M cells/s]"
        # below one item per second the column inverts, which is far easier to read
        @test render_column(Rate(), aged_state(total = 200, current = 5)) == "[2.0 s/it  ]"
        @test render_column(Rate(pad = 0), aged_state(total = 200, current = 5)) == "[2.0 s/it]"
        # a rate of zero is nothing to report
        @test render_column(Rate(), aged_state(total = 200, current = 0)) == ""
    end

    @testset "Eta is the time column" begin
        # running: an estimate extrapolated from the average rate so far
        @test render_column(Eta(), aged_state(total = 200, current = 100)) == "ETA: 10 s"
        @test startswith(render_column(Eta(), aged_state(total = 100, current = 1)), "ETA: ")

        # finished: no countdown is left, so it reports what the work took
        @test startswith(render_column(Eta(), aged_state(total = 200, current = 200)), "done in")

        # indeterminate: there is no end to count down to, so it reports elapsed time
        @test startswith(render_column(Eta(), aged_state(total = nothing)), "(elapsed:")

        # nothing to extrapolate from yet
        @test render_column(Eta(), aged_state(total = 200, current = 0)) == "ETA: N/A"

        # a long estimate reads as days and hours rather than an hours field running
        # past 24
        slow = render_column(Eta(), aged_state(total = 100000, current = 1, elapsed = 100.0))
        @test startswith(slow, "ETA: ") && occursin("h", slow)
    end

    @testset "Postfix and set_postfix!" begin
        bar = Progress(100; desc = "metrics", io = IOBuffer(), tty = true,
                       vanish = 0.0, start = false)
        @test render_column(Postfix(), bar.state) == ""

        set_postfix!(bar; loss = 0.041, lr = 1e-4)
        text = render_column(Postfix(), bar.state)
        @test text == "[loss=0.041, lr=0.0001]"
        # insertion order is preserved, not dictionary order
        @test startswith(text, "[loss=")
        @test occursin("loss=0.041, lr=0.0001", text)

        # values are overwritten, not appended
        set_postfix!(bar; loss = 0.9)
        @test render_column(Postfix(), bar.state) == "[loss=0.9, lr=0.0001]"

        # a custom separator
        @test occursin("; ", render_column(Postfix("; "), bar.state))

        # a bare set_postfix! outside any scope is a mistake, not a silent no-op
        @test_throws ProgbioticError set_postfix!(; epoch = 3)

        # inside a scope it reaches that scope's bar
        live = Progress(10; desc = "live", io = IOBuffer(), tty = false, vanish = 0.0)
        with_progress_logging(live) do
            set_postfix!(; epoch = 3)
        end
        @test occursin("epoch=3", render_column(Postfix(), live.state))
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

        bar = Progress(200; desc = "composed", io = IOBuffer(), tty = true,
                       vanish = 0.0, start = false)
        bar.state.current[] = 100
        bar.state.start = time() - 10.0
        bar.state.last_update = time()
        set_postfix!(bar; loss = 0.25)

        frame = strip_ansi(render_frame(bar))
        @test occursin("composed", frame)
        @test occursin(" 50%", frame)          # the theme's Percent is digits = 0, pad = 3
        @test occursin("(100/200)", frame)
        @test occursin("[10.0 it/s ]", frame)
        # the elapsed is a hair past ten seconds by the time it is read, so the exact
        # rendering depends on whether duration_str's millisecond branch trips
        @test occursin("ETA: 10", frame)
        @test occursin("[loss=0.25]", frame)

        # empty columns are dropped, and the join is a single space
        sparse = (Tag("{desc}"), Percent(), Postfix())
        bar2 = Progress(10; desc = "sparse", layout = sparse, io = IOBuffer(),
                        tty = true, vanish = 0.0, start = false)
        @test render_frame(bar2) == "sparse 0.0%"
    end

    @testset "the layout from the feature tour" begin
        my_layout = (
            Spinner(:dots),
            Tag("{desc}"),
            Bar(fill = '█', empty = '░', width = 30),
            Percent(),
            Rate(unit = "it/s"),
            Eta(),
            Postfix(),
        )
        bar = Progress(100; layout = my_layout, desc = "Custom Pipeline",
                       io = IOBuffer(), tty = true, vanish = 0.0, start = false)
        bar.state.start = time() - 1.0
        bar.state.last_update = time()
        for _ in 1:45
            next!(bar)
        end
        set_postfix!(bar; accuracy = "45.0%")

        frame = strip_ansi(render_frame(bar))
        @test occursin("Custom Pipeline", frame)
        @test occursin("45.0%", frame)
        @test occursin("accuracy=45.0%", frame)
        @test occursin("45.0 it/s", frame)
        @test occursin('█', frame)
        @test occursin('░', frame)
        @test length(bar.layout) == 7
    end
end
