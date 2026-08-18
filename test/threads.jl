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
            ok[] &= ctx.parent !== nothing
            sleep(0.0002)
        end
        @test ok[]
    end

    @testset "other macro-wrapped loops" begin
        results = zeros(Int, 20)
        @progress "Sync/async" Base.@sync Base.@async for i in 1:20
            results[i] = i * 3
        end
        @test results == collect(3:3:60)

        simd = zeros(Int, 10)
        @progress "Simd" Base.@simd for i in 1:10
            simd[i] = i * 2
        end
        @test simd == collect(2:2:20)
    end
end
