using Progbiotic
using Progbiotic: render_column
using Test

# A throwaway bar: no terminal, nothing lingering, so a test can never leave a
# render task behind or scribble on the suite's output.
sink() = IOBuffer()

@testset "node.jl" begin
    @testset "Tag pads to a width when asked" begin
        s = BarState(100; desc = "Short")
        s.current[] = 42
        s.last_update = s.start + 1.0

        @test render_column(Tag("{desc}"), s) == "Short"
        @test render_column(Tag("{desc}"; width = 14), s) == "Short         "
        @test length(render_column(Tag("{desc}"; width = 14), s)) == 14

        # a label longer than its column is not truncated
        long = BarState(1; desc = "a very long description indeed")
        @test render_column(Tag("{desc}"; width = 4), long) == "a very long description indeed"

        # width still applies to interpolated templates
        @test render_column(Tag("{n}/{total}"; width = 10), s) == "42/100    "
        @test render_column(Tag(; width = 6), s) == "Short "
    end

    @testset "theme_layout carries the width into the label column" begin
        unpadded = theme_layout(AMBER)
        padded   = theme_layout(AMBER; desc_width = 20)

        @test any(c -> c isa Tag && c.width == 0, unpadded)
        @test any(c -> c isa Tag && c.width == 20, padded)
        @test length(unpadded) == length(padded)

        # the rest of the layout is the same either way
        @test typeof(unpadded[3]) == typeof(padded[3])
    end

    @testset "supporting types start empty" begin
        @test isempty(Progbiotic.LogBuf().entries)
        @test Progbiotic.LogBuf().sink === nothing

        p = Progbiotic.Paint()
        @test (p.count, p.flat_pct, p.rows) == (0, -1, 0)

        r = Progbiotic.RootState()
        @test r.task === nothing
        @test !r.running[]
        @test r.rows == 0
    end
end
