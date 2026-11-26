using Progbiotic
using Test

@testset "threads.jl" begin
    @testset "Base.Threads.@threads-wrapped @progress" begin
        results = zeros(Int, 100)
        @progress "Threaded count" Base.Threads.@threads for i in 1:100
            results[i] = i
        end
        @test results == collect(1:100)
    end

    @testset "@threads with extra scheduler argument" begin
        results = zeros(Int, 60)
        @progress "Threaded (static)" Base.Threads.@threads :static for i in 1:60
            results[i] = i
        end
        @test results == collect(1:60)
    end

    @testset "nested @progress inside threaded loop" begin
        counts = zeros(Int, 36)
        @progress "Long job!" Base.Threads.@threads for i in 1:36
            @progress "Short job $(i)!" vanish_timeout=2.0 for j in 1:10
                counts[i] += 1
            end
        end
        @test counts == fill(10, 36)
    end

    @testset "bound context usable inside threaded loop" begin
        ok = Ref(true)
        @progress (ctx => "Bound threaded") Base.Threads.@threads for i in 1:50
            ok[] &= ctx isa Progress && pbtotal(ctx) == 50
            sleep(0.0002)
        end
        @test ok[]
    end

    @testset "threaded bodies have an active bar" begin
        prior = current_bar()
        active = Vector{Any}(undef, 6)
        expected = Vector{Any}(undef, 6)
        @progress ctx "thread metrics" io=IOBuffer() Base.Threads.@threads for i in 1:6
            active[i] = current_bar()
            expected[i] = ctx
            set_postfix!(iteration = i)
        end
        @test all(active[i] === expected[i] for i in eachindex(active))
        @test all(node -> node isa Progress, active)
        @test occursin("iteration=", Progbiotic.postfix_text(expected[1].state))
        @test current_bar() === prior
    end

    @testset "concurrent branches have lexical contexts" begin
        if Base.Threads.nthreads() > 1
            ready = Base.Threads.Atomic{Int}(0)
            active = Vector{Any}(undef, 2)
            contexts = Vector{Any}(undef, 2)
            forwarded = Vector{Any}(undef, 2)
            restored = Vector{Any}(undef, 2)
            roots = Vector{Any}(undef, 2)

            @progress ctx "branches" io=IOBuffer() Base.Threads.@threads :static for i in 1:2
                roots[i] = ctx
                @progress "branch $i" begin
                    Base.Threads.atomic_add!(ready, 1)
                    while ready[] < 2
                        yield()
                    end
                    contexts[i] = ctx
                    active[i] = current_bar()
                    # neither branch may restore ctx until both have read it
                    Base.Threads.atomic_add!(ready, 1)
                    while ready[] < 4
                        yield()
                    end
                    @progress with=ctx "forwarded $i" for j in 1:1
                        forwarded[i] = current_bar()
                    end
                    restored[i] = ctx
                end
                roots[i] = ctx
            end

            @test active[1] !== active[2]
            @test all(contexts[i] === active[i] for i in 1:2)
            @test all(forwarded[i].parent === active[i] for i in 1:2)
            @test all(restored[i] === active[i] for i in 1:2)
            @test roots[1] === roots[2]
            @test all(active[i].parent === roots[i] for i in 1:2)
        end
    end

    @testset "explicit branch bindings do not overwrite captured variables" begin
        if Base.Threads.nthreads() > 1
            sub = :outside
            ready = Base.Threads.Atomic{Int}(0)
            active = Vector{Any}(undef, 2)
            contexts = Vector{Any}(undef, 2)
            @progress "explicit branches" io=IOBuffer() Base.Threads.@threads :static for i in 1:2
                @progress sub "branch $i" begin
                    Base.Threads.atomic_add!(ready, 1)
                    while ready[] < 2
                        yield()
                    end
                    contexts[i] = sub
                    active[i] = current_bar()
                    Base.Threads.atomic_add!(ready, 1)
                    while ready[] < 4
                        yield()
                    end
                end
            end
            @test sub === :outside
            @test active[1] !== active[2]
            @test all(contexts[i] === active[i] for i in 1:2)
        end
    end

    @testset "other macro-wrapped loops" begin
        results = zeros(Int, 20)
        @progress "Sync/async" Base.@sync Base.@async for i in 1:20
            results[i] = i * 3
        end
        @test results == collect(3:3:60)

        prior = current_bar()
        active = Vector{Any}(undef, 3)
        @progress ctx "async metrics" io=IOBuffer() Base.@sync Base.@async for i in 1:3
            active[i] = (ctx, current_bar())
            set_postfix!(iteration = i)
        end
        @test all(pair -> pair[1] === pair[2], active)
        @test current_bar() === prior

        simd = zeros(Int, 10)
        @progress "Simd" Base.@simd for i in 1:10
            simd[i] = i * 2
        end
        @test simd == collect(2:2:20)
    end
end
