using Progbiotic
using Test

@testset "Progbiotic.jl" begin
    @testset "ProgJob standalone" begin
        job = ProgJob("Test standalone"; total=10, theme=AMBER)
        @test job.total == 10
        @test job.state == 0
        update!(job)
        @test job.state == 1
    end

    @testset "ProgBar tree hierarchy" begin
        pbar = ProgBar("Root Pipeline"; vanish_timeout=1.0)
        @test pbar.title == "Root Pipeline"
        @test pbar.default_timeout == 1.0

        j1 = add_job!(pbar, 1:5; desc="Parent Job", theme=OCEAN)
        @test length(pbar) == 1
        @test length(get_children(pbar, nothing)) == 1

        j2 = add_job!(pbar, 1:10; parent=j1, desc="Child Job", theme=CYBERPUNK)
        @test length(pbar) == 2
        @test length(get_children(pbar, j1)) == 1

        update!(pbar, j2, 10)
        @test j2.state == 10
        @test haskey(pbar.completed_at, j2)
    end

    @testset "ProgContext forwarding" begin
        pbar = ProgBar("Context Test")
        parent_job = add_job!(pbar, "Main Task"; total=5)
        ctx = ProgContext(pbar, parent_job)

        child_job = add_job!(ctx, 1:4; desc="Subtask")
        @test pbar.jobs[child_job] === parent_job
    end

    @testset "Tree formatting (no hanging root)" begin
        pbar = ProgBar()
        root = add_job!(pbar, "Root Task"; total=10)
        child = add_job!(pbar, "Child Task"; parent=root, total=5)
        
        rendered = render_progbar_tree(pbar)
        lines = split(rendered, '\n'; keepempty=false)
        @test length(lines) == 2
        @test !startswith(lines[1], "╰─")
        @test !startswith(lines[1], "├─")
        @test startswith(lines[2], "╰─")
    end

    @testset "@progress macro basic execution" begin
        counter = 0
        @progress "Simple Loop" for i in 1:5
            counter += 1
        end
        @test counter == 5
    end

    @testset "@progress macro nested with context" begin
        counter = 0
        sub_counter = 0
        @progress ("Outer Loop", OCEAN) for i in 1:2
            counter += 1
            @progress (ctx => ("Inner Loop $i", GLACIER)) for j in 1:3
                sub_counter += 1
            end
        end
        @test counter == 2
        @test sub_counter == 6
    end

    include("threads.jl")
    include("macros.jl")
    include("progtree.jl")
    include("progressbar.jl")
    include("tree.jl")
end

