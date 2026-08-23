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

    @testset "begin/end block progress" begin
        counter = 0
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => "Block root") begin
            pbar_ref[] = ctx.pbar
            @progress "Inner A" for j in 1:3
                counter += 1
            end
            @progress "Inner B" for j in 1:4
                counter += 1
            end
        end
        @test counter == 7
        pbar = pbar_ref[]
        @test length(pbar) == 3               # block root + 2 inner loops
        root = get_children(pbar, nothing)[1]
        @test root.desc == "Block root"
        @test root.total == 1 && root.state == 1
        @test all(j.state == j.total for j in pbar)
    end

    @testset "nested begin/end block inside a loop" begin
        counter = 0
        @progress "Outer" for i in 1:3
            @progress "Phase" begin
                counter += 1
            end
        end
        @test counter == 3
    end

    @testset "final_depth option" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("Outer", final_depth=1)) for i in 1:2
            pbar_ref[] = ctx.pbar
            @progress "Inner" for j in 1:2
            end
        end
        @test pbar_ref[].final_depth == 1
    end

    @testset "short form options" begin
        # d=1 -> final_depth=1
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("Short", d=1)) for i in 1:2
            pbar_ref[] = ctx.pbar
            @progress "Inner" for j in 1:2
            end
        end
        @test pbar_ref[].final_depth == 1

        # v=1.2 -> vanish_timeout=1.2 (Float64), inherited by nested levels
        pbar_ref2 = Ref{Any}(nothing)
        @progress (ctx => ("Short2", v=1.2)) for i in 1:2
            pbar_ref2[] = ctx.pbar
            @progress "Inner" for j in 1:2
            end
        end
        pbar2 = pbar_ref2[]
        root2 = get_children(pbar2, nothing)[1]
        @test pbar2.vanish_timeouts[root2] === 1.2
        @test all(pbar2.vanish_timeouts[c] === 1.2 for c in get_children(pbar2, root2))

        # v=false -> vanish=false: nothing vanishes anywhere
        pbar_ref3 = Ref{Any}(nothing)
        @progress (ctx => ("Short3", v=false)) for i in 1:2
            pbar_ref3[] = ctx.pbar
            @progress "Inner" for j in 1:2
            end
        end
        pbar3 = pbar_ref3[]
        root3 = get_children(pbar3, nothing)[1]
        @test pbar3.vanish_timeouts[root3] === nothing
        @test all(pbar3.vanish_timeouts[c] === nothing for c in get_children(pbar3, root3))

        # t=OCEAN -> theme=OCEAN
        pbar_ref4 = Ref{Any}(nothing)
        @progress (ctx => ("Short4", t=OCEAN)) for i in 1:2
            pbar_ref4[] = ctx.pbar
        end
        root4 = get_children(pbar_ref4[], nothing)[1]
        @test root4.theme === OCEAN

        # the old `threads=true` option is gone: wrap loops with Threads.@threads
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @progress "Bad" threads=true for i in 1:2 end
        end)

        # vanish_timeout=1 (integer) is normalised to 1.0 (Float64)
        pbar_ref5 = Ref{Any}(nothing)
        @progress (ctx => ("Short5", v=1)) for i in 1:2
            pbar_ref5[] = ctx.pbar
        end
        @test pbar_ref5[].vanish_timeouts[get_children(pbar_ref5[], nothing)[1]] === 1.0

        # ambiguous `v` value is rejected at expansion time
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @progress "Bad" v=nothing for i in 1:2 end
        end)
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @progress "Bad" d=1.5 for i in 1:2 end
        end)
    end

    @testset "statement subtasks (bare @progress, no body)" begin
        counter = 0
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("foo", d=1)) begin
            pbar_ref[] = ctx.pbar
            @progress "job 1"
            counter += 1
            @progress "job 2"
            counter += 1
            @progress "job 3"
            counter += 1
        end
        @test counter == 3
        pbar = pbar_ref[]
        @test length(pbar) == 4                     # foo + 3 subtasks
        root = get_children(pbar, nothing)[1]
        children = get_children(pbar, root)
        @test [c.desc for c in children] == ["job 1", "job 2", "job 3"]
        # milestones have no total of their own
        @test all(c.total === nothing for c in children)
        # each subtask finishes when the next one starts (or when the scope ends)
        @test all(Progbiotic._job_finished(c) for c in children)
        # the block's total is the number of milestones; state tracks completions
        @test root.total == 3
        @test root.state == 3
        @test pbar.final_depth == 1

        # retained by final_depth (d=1) so the collapsed final render keeps them
        s = render_progbar_tree(pbar; collapse_completed=true, final_depth=1)
        @test occursin("foo", s)
        @test occursin("job 1", s) && occursin("job 2", s) && occursin("job 3", s)
    end

    @testset "statement subtasks complete sequentially" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => "foo") begin
            pbar_ref[] = ctx.pbar
            @progress "job 1"
            @progress "job 2"
            @progress "job 3"
        end
        pbar = pbar_ref[]
        root = get_children(pbar, nothing)[1]
        children = get_children(pbar, root)
        @test all(Progbiotic._job_finished(c) for c in children)
    end

    @testset "statement subtasks complete one-at-a-time" begin
        pbar = ProgBar()
        root = add_job!(pbar, "foo"; total=1)
        j1 = Progbiotic._statement_job(pbar, root; desc="job 1")
        @test !Progbiotic._job_finished(j1)          # active while its work runs
        j2 = Progbiotic._statement_job(pbar, root; desc="job 2")
        @test Progbiotic._job_finished(j1)           # finished when the next starts
        @test !Progbiotic._job_finished(j2)
        j3 = Progbiotic._statement_job(pbar, root; desc="job 3")
        @test Progbiotic._job_finished(j2)
        @test !Progbiotic._job_finished(j3)
        Progbiotic._complete_statement_jobs!(pbar, root)  # scope exit
        @test Progbiotic._job_finished(j3)
    end

    @testset "statement subtask inside a loop" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => "outer") for i in 1:2
            pbar_ref[] = ctx.pbar
            @progress "step"
        end
        pbar = pbar_ref[]
        root = get_children(pbar, nothing)[1]
        children = get_children(pbar, root)
        @test length(children) == 2
        # the second step completes the first; the scope exit completes the last
        @test all(Progbiotic._job_finished(c) for c in children)
    end

    @testset "statement subtask options and context binding" begin
        pbar_ref = Ref{Any}(nothing)
        ctx_ok = Ref(false)
        @progress (ctx => "parent") begin
            pbar_ref[] = ctx.pbar
            @progress "job" t=OCEAN v=2.0
            @progress (subctx => "job2")
            ctx_ok[] = subctx.parent !== nothing && subctx.pbar === ctx.pbar
        end
        pbar = pbar_ref[]
        root = get_children(pbar, nothing)[1]
        children = get_children(pbar, root)
        @test children[1].theme === OCEAN
        @test pbar.vanish_timeouts[children[1]] === 2.0
        @test ctx_ok[]
    end

    @testset "bare symbol binds a context (shorthand for ctx => ...)" begin
        pbar_ref = Ref{Any}(nothing)
        @progress ctx "outer..." for i in 1:2
            pbar_ref[] = ctx.pbar
        end
        pbar = pbar_ref[]
        @test length(pbar) == 1
        @test get_children(pbar, nothing)[1].desc == "outer..."
    end

    @testset "subroutine context threading (with=)" begin
        pbar_ref = Ref{Any}(nothing)
        ctx_in_inner = Ref{Any}(nothing)
        ctx_after_sub = Ref{Any}(nothing)
        ctx_after_inner = Ref{Any}(nothing)
        ctx_in_working = Ref{Any}(nothing)

        function subtask(ctx, i)
            @progress with=ctx "working..." for k in 1:i
                ctx_in_working[] = ctx
            end
        end

        @progress ctx "outer..." for i in 1:2
            @progress "inner" for j in 1:2
                pbar_ref[] = ctx.pbar
                ctx_in_inner[] = ctx
                subtask(ctx, i)
                ctx_after_sub[] = ctx
            end
            ctx_after_inner[] = ctx
        end

        pbar = pbar_ref[]
        root = get_children(pbar, nothing)[1]
        inners = get_children(pbar, root)
        @test root.desc == "outer..."
        @test all(c.desc == "inner" for c in inners)
        workings = reduce(vcat, get_children(pbar, c) for c in inners)
        @test length(workings) == 4          # sum_i (2 inners * i) = 2 + 4
        @test all(w.desc == "working..." for w in workings)
        @test all(w.state == w.total for w in workings)

        # contexts track the innermost job, scoped
        @test ctx_in_inner[].parent.desc == "inner"
        @test ctx_after_sub[].parent.desc == "inner"       # restored after subtask
        @test ctx_after_inner[].parent.desc == "outer..."  # restored after inner loop
        @test ctx_in_working[].parent.desc == "working..." # rebound inside with= body
        @test ctx_in_working[].pbar === pbar
    end

    @testset "with= statement form and sibling placement" begin
        pbar_ref = Ref{Any}(nothing)
        function steps(ctx)
            @progress with=ctx "step 1"
            @progress with=ctx "step 2"
        end
        @progress (ctx => "pipeline") begin
            pbar_ref[] = ctx.pbar
            steps(ctx)
        end
        pbar = pbar_ref[]
        root = get_children(pbar, nothing)[1]
        @test [c.desc for c in get_children(pbar, root)] == ["step 1", "step 2"]
        @test all(Progbiotic._job_finished(c) for c in get_children(pbar, root))
    end

    @testset "with= rejects a non-context at runtime" begin
        err = try
            let x = 42
                @progress with=x "nope" for k in 1:2
                end
            end
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("with=", sprint(showerror, err))
    end

    @testset "BUG1: final_depth retains children without v=false" begin
        # depth-1 children are kept even after the vanish window elapses
        pbar = ProgBar(""; final_depth=1, vanish_timeout=0.1)
        root = add_job!(pbar, "root"; total=1)
        child = add_job!(pbar, "child"; parent=root, total=1)
        update!(pbar, child, 1)
        update!(pbar, root, 1)
        @test Progbiotic.is_job_visible(pbar, child, time() + 10.0)

        # without final_depth, the same child vanishes
        pbar0 = ProgBar(""; final_depth=0, vanish_timeout=0.1)
        r0 = add_job!(pbar0, "root"; total=1)
        c0 = add_job!(pbar0, "child"; parent=r0, total=1)
        update!(pbar0, c0, 1)
        @test !Progbiotic.is_job_visible(pbar0, c0, time() + 10.0)

        # end-to-end: d=1 alone shows the children in the collapsed final render
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("foo", d=1)) begin
            pbar_ref[] = ctx.pbar
            @progress "bar" for j in 1:5
            end
            @progress "baz" for k in 1:5
            end
        end
        sleep(0.7)   # let the default vanish window (0.5s) elapse
        s = render_progbar_tree(pbar_ref[]; collapse_completed=true, final_depth=1)
        @test occursin("foo", s)
        @test occursin("bar", s) && occursin("baz", s)
    end

    @testset "BUG2: ETA/rate freeze while a job is idle" begin
        p = ProgJob("t"; total=10)
        now = time()
        @lock p.lock begin
            p.start = now - 10.0      # started 10 s ago
            p.state = 5               # 5/10 done
            p.last_update = now - 2.0 # last activity was 8 s after start
        end
        barpart(s) = s[findfirst(c -> c in ('█', '░', '▒', '▓', '▏'), s):end]
        l1 = show_progjob_with_theme(p, AMBER)
        sleep(0.3)                    # idle: nothing updates the job
        l2 = show_progjob_with_theme(p, AMBER)
        # the bar/rate/ETA portion is identical because it is measured to the last
        # update, not to "now" (only the spinner changes between renders)
        @test barpart(l1) == barpart(l2)
        # rate = 5/8 it/s -> "1.6 s/it"; ETA = (1-0.5)*(8s/0.5) = 8 s
        @test occursin("1.6 s/it", l1)
        @test occursin("ETA: 8 s", l1)
    end

    @testset "REQUEST1: total-less jobs show no rate/ETA, but report elapsed" begin
        p = ProgJob("task")            # no total
        line = show_progjob_with_theme(p, AMBER)
        @test !occursin("it/s", line)
        @test !occursin("s/it", line)
        @test !occursin("ETA", line)
        @test occursin("elapsed", line)

        # a finished indeterminate job reports its (frozen) duration
        @lock p.lock begin
            p.finish = time()
        end
        line2 = show_progjob_with_theme(p, AMBER)
        @test !occursin("ETA", line2)
        @test occursin("done in", line2)
    end

    @testset "REQUEST2: block total = milestone count, progress = completed milestones" begin
        pbar_ref = Ref{Any}(nothing)
        states = Int[]
        @progress (ctx => "foo") begin
            pbar_ref[] = ctx.pbar
            @progress "job 1"
            push!(states, ctx.parent.state)   # 0/3 while job 1 runs
            @progress "job 2"
            push!(states, ctx.parent.state)   # 1/3
            @progress "job 3"
            push!(states, ctx.parent.state)   # 2/3
        end
        pbar = pbar_ref[]
        root = get_children(pbar, nothing)[1]
        @test states == [0, 1, 2]
        @test root.total == 3
        @test root.state == 3                 # 3/3 once the scope ends
        @test all(Progbiotic._job_finished(c) for c in get_children(pbar, root))
    end

    @testset "per-bar style overrides via @progress" begin
        pbar_ref = Ref{Any}(nothing)
        @progress (ctx => ("x", spinner="✶✷", barunits="░█", empty="░", width=30)) for i in 1:2
            pbar_ref[] = ctx.pbar
        end
        root = get_children(pbar_ref[], nothing)[1]
        @test root.theme.spinner == ['✶', '✷']
        @test root.theme.barunits == ['░', '█']
        @test root.theme.empty == '░'
        @test root.bar_width == 30
        line = show_progjob_with_theme(root, root.theme)
        @test occursin("█", line)             # bar drawn with the override glyphs
    end
end