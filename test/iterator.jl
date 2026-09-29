using Progbiotic
using Test


@testset "iterator.jl" begin
    @testset "prog over a range infers its total" begin
        it = prog(1:100; desc = "range", io = sink(), vanish = 0.0)
        @test it.bar.state.total == 100
        @test length(it) == 100
        @test eltype(it) == Int
        @test collect(prog(1:5; io = sink(), vanish = 0.0)) == collect(1:5)
        finish!(it)
    end

    @testset "prog over arrays, matrices and generators" begin
        data = ["a", "b", "c", "d"]
        seen = String[]
        for item in prog(data; desc = "files", io = sink(), vanish = 0.0)
            push!(seen, item)
        end
        @test seen == data

        matrix = reshape(1:9, 3, 3)
        squares = [x^2 for x in prog(matrix; desc = "matrix", io = sink(), vanish = 0.0)]
        @test squares == [x^2 for x in matrix]

        generator = (i * 2 for i in 1:10)
        it = prog(generator; io = sink(), vanish = 0.0)
        @test it.bar.state.total == 10
        @test sum(it) == sum(2:2:20)
    end

    @testset "unbounded and size-unknown sources go indeterminate" begin
        channel = Channel{Int}(16) do ch
            for i in 1:25
                put!(ch, i)
            end
        end
        it = prog(channel; desc = "stream", io = sink(), vanish = 0.0)
        @test it.bar.state.total === nothing
        @test Base.IteratorSize(typeof(it)) isa Base.SizeUnknown
        total = 0
        for item in it
            total += item
        end
        @test total == sum(1:25)

        filtered = prog(Iterators.filter(iseven, 1:20); io = sink(), vanish = 0.0)
        @test filtered.bar.state.total === nothing
        @test sum(filtered) == sum(2:2:20)
    end

    @testset "total and layout can be overridden" begin
        forced = prog(1:10; total = 500, io = sink(), vanish = 0.0)
        @test forced.bar.state.total == 500
        finish!(forced)

        indeterminate = prog(1:10; total = nothing, io = sink(), vanish = 0.0)
        @test indeterminate.bar.state.total === nothing
        finish!(indeterminate)

        custom = prog(1:3; layout = (Tag("{n}/{total}"),), io = sink(), vanish = 0.0)
        @test length(custom.bar.layout) == 1
        finish!(custom)
    end

    @testset "progress advances exactly once per item" begin
        it = prog(1:37; io = sink(), vanish = 0.0)
        for _ in it
        end
        @test it.bar.state.current[] == 37
        @test Progbiotic.isfinished(it.bar.state)
    end

    @testset "the do-block form runs the whole loop" begin
        collected = Int[]
        prog(1:6; desc = "block", io = sink(), vanish = 0.0) do x
            push!(collected, x)
        end
        @test collected == collect(1:6)
    end

    @testset "wrapped collections behave like the collection" begin
        it = prog(1:6; io = sink(), vanish = 0.0)
        @test size(it) == (6,)
        @test axes(it) == (Base.OneTo(6),)
        @test firstindex(it) == 1
        @test lastindex(it) == 6
        @test keys(it) == 1:6
        @test collect(eachindex(it)) == collect(1:6)
        @test it[3] == 3
        finish!(it)
    end

    @testset "@threads over a wrapped collection" begin
        wrapped = prog(1:200; desc = "threaded", io = sink(), vanish = 0.0)
        seen = zeros(Int, 200)
        Base.Threads.@threads for i in wrapped
            seen[i] = i
        end
        @test seen == collect(1:200)
        # Threads.@threads reads indexable collections with getindex, which has to
        # advance the bar just like iterate does
        @test wrapped.bar.state.current[] == 200
        finish!(wrapped)
    end

    @testset "a wrapped collection's bar is what a bare set_postfix! finds" begin
        it = prog(1:4; desc = "scoped", io = sink(), vanish = 0.0)
        Progbiotic._with_scope(it.bar) do
            for _ in it
                set_postfix!(pass = "one")
            end
        end
        @test pbdone(it) == 4
        @test occursin("pass=one", Progbiotic.postfix_text(it.bar.state))
        finish!(it)
    end

    @testset "show" begin
        it = prog(1:4; desc = "shown", io = sink(), vanish = 0.0)
        text = sprint(show, it)
        @test occursin("ProgbioticIterator", text)
        @test occursin("0/4", text)
        finish!(it)
    end
end
