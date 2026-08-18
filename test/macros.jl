using Progbiotic
using Test

# Subroutine receiving the bound context
function subtask_with_pbar_context(ctx)
    sub = add_job!(ctx, 1:5; desc="Subtask", theme=NEON)
    for _ in 1:5
        sleep(0.0001)
        update!(ctx, sub)
    end
    return sub
end

function download_and_extract(ctx, filename)
    # Child task 1: Download step (vanishes 1.0s after completion)
    dl = add_job!(ctx, "Downloading $filename"; total=20, theme=GLACIER, vanish_timeout=1.0)
    for _ in 1:20
        sleep(0.0001)
        update!(ctx, dl)
    end

    # Child task 2: Extract step (vanishes 1.0s after completion)
    ext = add_job!(ctx, "Extracting $filename"; total=15, theme=SYNTHWAVE, vanish_timeout=1.0)
    for _ in 1:15
        sleep(0.0001)
        update!(ctx, ext)
    end
end

@testset "macros.jl" begin
    @testset "simple loop" begin
        counter = 0
        @progress "Working on i" for i = 1:10
            counter += 1
        end
        @test counter == 10
    end

    @testset "nested loops with themes and context binding" begin
        inner_count = 0
        ctx_ok = Ref(true)
        pbar_ref = Ref{Any}(nothing)
        @progress ("Working on i", AMBER) for i = 1:3
            @progress (pbar => NEON) for k = 1:4
                ctx_ok[] &= pbar.parent !== nothing && pbar.pbar isa ProgBar
                pbar_ref[] = pbar.pbar
                inner_count += 1
                subtask_with_pbar_context(pbar)
            end
        end
        @test ctx_ok[]
        @test inner_count == 12

        pbar = pbar_ref[]
        @test length(pbar) == 16          # root + 3 inner jobs + 12 subtasks
        root = get_children(pbar, nothing)[1]
        inner_jobs = get_children(pbar, root)
        @test length(inner_jobs) == 3     # one job per outer iteration
        @test all(length(get_children(pbar, j)) == 4 for j in inner_jobs)
        @test all(j.state == j.total for j in pbar)
        @test all(haskey(pbar.completed_at, j) for j in pbar)
    end

    @testset "three-level deep progress tree" begin
        depth3_count = 0
        ctx_ok = Ref(true)
        pbar_ref = Ref{Any}(nothing)
        @progress ("Outer Pipeline", OCEAN) for i = 1:3
            @progress (stage => ("Stage $i", CYBERPUNK)) for j = 1:5
                ctx_ok[] &= stage.parent !== nothing
                pbar_ref[] = stage.pbar
                @progress "Micro-batch" for k = 1:10
                    depth3_count += 1
                end
            end
        end
        @test ctx_ok[]
        @test depth3_count == 150

        pbar = pbar_ref[]
        @test length(pbar) == 19          # root + 3 stages + 15 micro-batches
        root = get_children(pbar, nothing)[1]
        stages = get_children(pbar, root)
        @test length(stages) == 3
        @test all(length(get_children(pbar, s)) == 5 for s in stages)
        @test all(j.state == j.total for j in pbar)
    end

    @testset "vanish_timeout on nested jobs" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("Timed Epochs", vanish_timeout=1.0)) for i = 1:2
            pbar_ref[] = ctx.pbar
            @progress ("Batches $i", vanish_timeout=1.0) for j = 1:5
            end
        end
        pbar = pbar_ref[]
        @test length(pbar) == 3
        root = get_children(pbar, nothing)[1]
        children = get_children(pbar, root)
        @test length(children) == 2
        @test all(pbar.vanish_timeouts[c] == 1.0 for c in children)
        # Completed child jobs are no longer visible after their vanish window
        @test all(!Progbiotic.is_job_visible(pbar, c, time() + 10.0) for c in children)
    end

    @testset "global default vanish_timeout" begin
        pbar = ProgBar("Batch Processing"; vanish_timeout=1.0)
        parent_job = add_job!(pbar, "Overall Progress"; total=3, theme=OCEAN, vanish=false)
        worker_job = nothing
        for i in 1:3
            worker_job = add_job!(pbar, "Worker Task #$i"; parent=parent_job, total=25, theme=CYBERPUNK)
            for step in 1:25
                update!(pbar, worker_job, step)
            end
            update!(pbar, parent_job, i)
        end
        @test length(pbar) == 4
        @test pbar.vanish_timeouts[parent_job] === nothing     # vanish=false
        @test pbar.vanish_timeouts[worker_job] == 1.0          # inherited default
        @test all(j.state == j.total for j in pbar)
    end

    @testset "context forwarding to subroutines" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("Asset Pipeline", AMBER)) for asset in 1:3
            pbar_ref[] = ctx.pbar
            download_and_extract(ctx, "asset-$asset")
        end
        pbar = pbar_ref[]
        @test length(pbar) == 7           # root + 3 x (download + extract)
        @test all(j.state == j.total for j in pbar)
        root = get_children(pbar, nothing)[1]
        @test all(pbar.vanish_timeouts[c] == 1.0 for c in get_children(pbar, root))
    end

    @testset "title and theme keyword form" begin
        total = 0
        @progress title="Model Training Pipeline" theme=OCEAN "Epochs" for epoch in 1:3
            @progress ("Epoch $epoch Batches", CYBERPUNK) for batch in 1:20
                total += 1
            end
        end
        @test total == 60
    end

    @testset "nested jobs with vanish_timeout" begin
        total = 0
        @progress "Long job!" for i in 1:30
            @progress "Short job $(i)!" vanish_timeout=2.0 for j in 1:10
                total += 1
            end
        end
        @test total == 300
    end
end