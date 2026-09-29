using Progbiotic
using Test

@testset "bar.jl" begin
    @testset "a fresh bar knows nothing yet" begin
        s = BarState(10; desc = "fresh")
        @test pbdone(s) == 0
        @test pbtotal(s) == 10
        @test pbfraction(s) == 0.0
        @test pbrate(s) == 0.0          # no elapsed time to divide by
        @test pbeta(s) === nothing      # nothing to extrapolate from yet
        @test !isfinished(s)
        @test s.desc[] == "fresh"
    end

    @testset "indeterminate bars report no fraction and no eta" begin
        s = BarState()
        @test pbtotal(s) === nothing
        @test pbfraction(s) === nothing
        @test pbeta(s) === nothing
        @test !isfinished(s)
    end

    @testset "a zero total is complete, not a division by zero" begin
        s = BarState(0)
        @test pbfraction(s) == 1.0
        @test pbeta(s) === nothing
    end

    @testset "fraction saturates and eta extrapolates" begin
        s = BarState(10)
        s.current[] = 5
        s.last_update = s.start + 1.0           # one second of work
        @test pbfraction(s) == 0.5
        @test pbrate(s) == 5.0
        @test pbeta(s) ≈ 1.0                    # five left at five per second

        s.current[] = 20                        # overshoot stays clamped
        @test pbfraction(s) == 1.0
        @test pbeta(s) == 0.0                   # done: nothing left to wait for
    end

    @testset "timing freezes at completion and tracks wall clock before it" begin
        s = BarState(10)
        s.last_update = s.start + 2.0
        @test pbelapsed(s) == 2.0               # work time, up to the last advance

        s.finish[] = s.start + 3.0
        @test isfinished(s)
        sleep(0.02)
        @test pbruntime(s) == 3.0               # frozen, not still counting
        @test pbelapsed(s) == 3.0               # completion beats last_update
    end

    @testset "postfix keeps insertion order and holds one entry per key" begin
        s = BarState(10)
        Progbiotic._merge_postfix!(s; loss = 0.5, lr = 1e-4)
        @test Progbiotic.postfix_text(s) == "loss=0.5, lr=0.0001"

        Progbiotic._merge_postfix!(s; loss = 0.25)         # overwritten in place, order kept
        @test Progbiotic.postfix_text(s) == "loss=0.25, lr=0.0001"
        @test length(s.postfix[]) == 2

        Progbiotic._merge_postfix!(s; epoch = 3)           # new keys append
        @test Progbiotic.postfix_text(s) == "loss=0.25, lr=0.0001, epoch=3"
        @test Progbiotic.postfix_text(s; separator = " ") == "loss=0.25 lr=0.0001 epoch=3"
    end

    @testset "postfix renders values at set time" begin
        s = BarState(10)
        Progbiotic._merge_postfix!(s; x = 1)

        # the stored entry is text, so the render tick never calls show on a
        # user value; mutating the source afterwards cannot change the display
        @test s.postfix[] == [:x => "1"]
        @test Progbiotic.postfix_text(s) == "x=1"
    end

    @testset "an empty postfix renders nothing" begin
        @test Progbiotic.postfix_text(BarState(10)) == ""
    end

    @testset "description is only filled when empty" begin
        s = BarState(10; desc = "given")
        Progbiotic._set_description!(s, "other")
        @test s.desc[] == "given"

        s2 = BarState(10)
        Progbiotic._set_description!(s2, "filled")
        @test s2.desc[] == "filled"
    end

    @testset "readers forward through a handle" begin
        bar = Progress(10; io = IOBuffer(), vanish = 0.0)
        @test pbtotal(bar) == 10
        @test pbdone(bar) == 0
        @test pbfraction(bar) == 0.0
        @test !isfinished(bar)
        next!(bar, 4)
        @test pbdone(bar) == 4
        finish!(bar; wait = true)
        @test isfinished(bar)
        @test pbfraction(bar) == 1.0
    end
end
