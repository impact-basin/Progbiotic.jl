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
        @test occursin("0 units", line)               # indeterminate mode

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
end