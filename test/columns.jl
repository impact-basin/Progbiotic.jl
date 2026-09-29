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
        @test SpinnerColumn() isa AbstractColumn
        @test BarColumn() isa AbstractColumn
        @test PercentageColumn() isa AbstractColumn
        @test RateColumn() isa AbstractColumn
        @test ETAColumn() isa AbstractColumn
        @test PostfixColumn() isa AbstractColumn
        @test TextColumn() isa AbstractColumn

        @test render_column(TestFixedColumn(), aged_state()) == "fixed"
        @test render_column(TestFixedColumn(), aged_state()) isa String
    end

    @testset "SpinnerColumn" begin
        state = aged_state()
        spinner = SpinnerColumn(:dots)
        @test spinner.style == :dots
        @test length(spinner.frames) == 10
        @test render_column(spinner, state) in spinner.frames

        line = SpinnerColumn(:line)
        @test line.frames == ["-", "\\", "|", "/"]
        @test render_column(line, state) in line.frames

        @test render_column(SpinnerColumn(:clock), state) in SpinnerColumn(:clock).frames
        @test_throws ErrorException SpinnerColumn(:nope)
    end

    @testset "TextColumn templates" begin
        state = aged_state(total = 200, desc = "Training", current = 50)
        @test render_column(TextColumn("{desc}"), state) == "Training"
        @test render_column(TextColumn("{n}/{total}"), state) == "50/200"
        @test render_column(TextColumn("{pct}%"), state) == "25.0%"
        @test render_column(TextColumn("elapsed {elapsed}"), state) == "elapsed 00:00:10"
        @test render_column(TextColumn("no placeholders"), state) == "no placeholders"
        @test render_column(TextColumn("{unknown}"), state) == "{unknown}"

        indeterminate = aged_state(total = nothing, desc = "watching")
        @test render_column(TextColumn("{desc}"), indeterminate) == "watching"
        @test render_column(TextColumn("{total}"), indeterminate) == ""
    end

    @testset "BarColumn" begin
        half = aged_state(total = 200, current = 100)
        bar = render_column(BarColumn(fill = '#', empty = '-', width = 10), half)
        @test bar == "#####-----"
        @test length(render_column(BarColumn(fill = '#', empty = '-', width = 10),
                                   aged_state(total = 4, current = 0))) == 10
        @test render_column(BarColumn(fill = '#', empty = '-', width = 10),
                            aged_state(total = 4, current = 4)) == "##########"

        # the default glyphs are the documented ones
        default_bar = render_column(BarColumn(), half)
        @test length(default_bar) == 30
        @test count(==('█'), default_bar) == 15
        @test count(==('░'), default_bar) == 15

        # keyword and positional construction agree
        @test BarColumn('#', '-', 10).width == 10
        @test BarColumn(fill = '#', empty = '-', width = 10).fill == '#'
        @test BarColumn().width == 30

        # an indeterminate bar shows a moving block of the full track width
        marquee = render_column(BarColumn(fill = '#', empty = '-', width = 20),
                                aged_state(total = nothing))
        @test length(marquee) == 20
        @test occursin('#', marquee)
        @test count(==('#'), marquee) == 5
    end

    @testset "PercentageColumn" begin
        @test render_column(PercentageColumn(), aged_state(total = 200, current = 90)) == "45.0%"
        @test render_column(PercentageColumn(0), aged_state(total = 3, current = 1)) == "33%"
        @test render_column(PercentageColumn(3), aged_state(total = 3, current = 1)) == "33.333%"
        @test render_column(PercentageColumn(), aged_state(total = nothing)) == ""
    end

    @testset "RateColumn" begin
        # 100 items in 10 seconds is ten items a second
        @test render_column(RateColumn(), aged_state(total = 200, current = 100)) == "10.0 it/s"
        @test render_column(RateColumn(unit = "rows/s"),
                            aged_state(total = 2000, current = 25000)) == "2.5k rows/s"
        @test render_column(RateColumn(unit = "cells/s"),
                            aged_state(total = 2000, current = 25000000)) == "2.5M cells/s"
        # below one item per second the column inverts, which is far easier to read
        @test render_column(RateColumn(), aged_state(total = 200, current = 5)) == "2.0 s/it"
        @test render_column(RateColumn(), aged_state(total = 200, current = 0)) == ""
    end

    @testset "ETAColumn" begin
        @test render_column(ETAColumn(), aged_state(total = 200, current = 100)) == "ETA 00:00:10"
        @test occursin(r"^ETA \d{2}:\d{2}:\d{2}$",
                       render_column(ETAColumn(), aged_state(total = 100, current = 1)))
        @test render_column(ETAColumn(), aged_state(total = 200, current = 200)) == "ETA 00:00:00"
        @test render_column(ETAColumn(), aged_state(total = nothing)) == ""
        @test render_column(ETAColumn(), aged_state(total = 200, current = 0)) == ""

        # more than a day of remaining work still fits the format
        slow = render_column(ETAColumn(), aged_state(total = 100000, current = 1, elapsed = 100.0))
        @test occursin(r"^ETA \d+:\d{2}:\d{2}$", slow)
    end

    @testset "PostfixColumn and set_postfix!" begin
        handle = Progress(100; desc = "metrics", io = IOBuffer(), tty = true,
                          vanish = 0.0, start = false)
        state = handle.ctx.state
        @test render_column(PostfixColumn(), state) == ""

        set_postfix!(handle; loss = 0.041, lr = 1e-4)
        text = render_column(PostfixColumn(), state)
        @test text == "[loss=0.041, lr=0.0001]"
        # insertion order is preserved, not dictionary order
        @test startswith(text, "[loss=")
        @test occursin("loss=0.041, lr=0.0001", text)

        # values are overwritten, not appended
        set_postfix!(handle; loss = 0.9)
        @test render_column(PostfixColumn(), state) == "[loss=0.9, lr=0.0001]"

        # a custom separator
        @test occursin("; ", render_column(PostfixColumn("; "), state))

        # a bare set_postfix! reaches the innermost live bar
        live = Progress(10; desc = "live", io = IOBuffer(), tty = false, vanish = 0.0)
        set_postfix!(; epoch = 3)
        @test occursin("epoch=3", render_column(PostfixColumn(), live.ctx.state))
        finish!(live; wait = true)
    end

    @testset "default_layout and composition" begin
        layout = default_layout()
        @test layout isa Vector{AbstractColumn}
        @test any(c -> c isa SpinnerColumn, layout)
        @test any(c -> c isa BarColumn, layout)
        @test any(c -> c isa PercentageColumn, layout)
        @test any(c -> c isa RateColumn, layout)
        @test any(c -> c isa ETAColumn, layout)
        @test any(c -> c isa PostfixColumn, layout)

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
        layout2 = [TextColumn("{desc}"), PercentageColumn(), PostfixColumn()]
        handle2 = Progress(10; desc = "sparse", layout = layout2, io = IOBuffer(),
                           tty = true, vanish = 0.0, start = false)
        @test render_frame(handle2.ctx) == "sparse 0.0%"
    end

    @testset "the layout from the feature tour" begin
        my_layout = [
            SpinnerColumn(:dots),
            TextColumn("{desc}"),
            BarColumn(fill = '█', empty = '░', width = 30),
            PercentageColumn(),
            RateColumn(unit = "it/s"),
            ETAColumn(),
            PostfixColumn(),
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
