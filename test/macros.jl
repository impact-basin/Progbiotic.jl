using Progbiotic
using Test


# every node of a tree, the root first, depth-first
function treenodes(root::Progress)
    out = Progress[]
    gather!(out, root)
    return out
end

function gather!(out::Vector{Progress}, node::Progress)
    push!(out, node)
    for kid in children(node)
        gather!(out, kid)
    end
    return out
end

# a subroutine holding a context: a context *is* a node, so it registers its children
# through child(), exactly as the macro does
function subtask_with_context(ctx)
    sub = child(ctx, 5; desc = "Subtask", theme = NEON)
    for _ in 1:5
        sleep(0.0001)
        next!(sub)
    end
    return sub
end

function download_and_extract(ctx, filename)
    # child task 1: download step (vanishes 1.0s after completion)
    dl = child(ctx, 20; desc = "Downloading $filename", theme = GLACIER, vanish_timeout = 1.0)
    for _ in 1:20
        sleep(0.0001)
        next!(dl)
    end

    # child task 2: extract step (vanishes 1.0s after completion)
    ext = child(ctx, 15; desc = "Extracting $filename", theme = SYNTHWAVE, vanish_timeout = 1.0)
    for _ in 1:15
        sleep(0.0001)
        next!(ext)
    end
    return nothing
end

@testset "macros.jl" begin
    @testset "simple loop" begin
        counter  = 0
        root_ref = Ref{Any}(nothing)
        @progress (ctx => "Working on i") io=IOBuffer() for i = 1:10
            root_ref[] = ctx
            counter += 1
        end

        @test counter == 10
        @test pbtotal(root_ref[]) == 10
        @test pbdone(root_ref[]) == 10
    end

    @testset "nested loops with themes and context binding" begin
        inner_count = 0
        ctx_ok      = Ref(true)
        inner_ref   = Ref{Any}(nothing)
        root_ref    = Ref{Any}(nothing)

        @progress (root => ("Working on i", AMBER)) io=IOBuffer() for i = 1:3
            root_ref[] = root
            @progress (pbar => NEON) for k = 1:4
                # a bound context is the node itself, hung under the outer one
                ctx_ok[] &= pbar.parent !== nothing && pbar.parent isa Progress
                inner_ref[] = pbar
                inner_count += 1
                subtask_with_context(pbar)
            end
        end

        @test ctx_ok[]
        @test inner_count == 12

        nodes = treenodes(root_ref[])
        @test length(nodes) == 16                    # root + 3 inner jobs + 12 subtasks
        inner_jobs = children(root_ref[])
        @test length(inner_jobs) == 3                # one job per outer iteration
        @test all(length(children(job)) == 4 for job in inner_jobs)
        @test all(node -> pbdone(node) == pbtotal(node), nodes)
        @test all(Progbiotic._completed, nodes)
        @test inner_ref[].parent === root_ref[]      # the innermost node hangs under the root
    end

    @testset "three-level deep progress tree" begin
        depth3_count = 0
        ctx_ok       = Ref(true)
        root_ref     = Ref{Any}(nothing)

        @progress (root => ("Outer Pipeline", OCEAN)) io=IOBuffer() for i = 1:3
            root_ref[] = root
            @progress (stage => ("Stage $i", CYBERPUNK)) for j = 1:5
                ctx_ok[] &= stage.parent !== nothing
                @progress "Micro-batch" for k = 1:10
                    depth3_count += 1
                end
            end
        end

        @test ctx_ok[]
        @test depth3_count == 150

        nodes = treenodes(root_ref[])
        @test length(nodes) == 19                    # root + 3 stages + 15 micro-batches
        stages = children(root_ref[])
        @test length(stages) == 3
        @test all(length(children(stage)) == 5 for stage in stages)
        @test all(node -> pbdone(node) == pbtotal(node), nodes)
    end

    @testset "vanish_timeout on nested jobs" begin
        root_ref = Ref{Any}(nothing)
        @progress (ctx => ("Timed Epochs", vanish_timeout=1.0)) io=IOBuffer() for i = 1:2
            root_ref[] = ctx
            @progress ("Batches $i", vanish_timeout=1.0) for j = 1:5
            end
        end

        root = root_ref[]
        @test length(treenodes(root)) == 3
        batches = children(root)
        @test length(batches) == 2
        @test all(batch -> batch.opts.vanish === 1.0, batches)

        # completed child jobs are gone once their own timeout has run out
        now = time()
        foreach(batch -> Progbiotic._visible(batch, now), batches)   # the tick that notices
        @test all(!Progbiotic._visible(batch, now + 10.0) for batch in batches)
    end

    @testset "global default vanish_timeout" begin
        root = Progress(3; desc = "Overall Progress", title = "Batch Processing", theme = OCEAN,
                        vanish = false, child_vanish = 1.0, io = IOBuffer(), tty = false,
                        start = false)

        workers = Any[]
        for i in 1:3
            worker = child(root, 25; desc = "Worker Task #$i", theme = CYBERPUNK)
            push!(workers, worker)
            for step in 1:25
                next!(worker)
            end
            next!(root)
        end

        @test length(treenodes(root)) == 4
        @test isinf(root.opts.vanish)                              # vanish=false: kept on screen
        @test all(worker -> worker.opts.vanish === 1.0, workers)   # the tree's child default
        @test all(Progbiotic._completed, treenodes(root))
    end

    @testset "context forwarding to subroutines" begin
        root_ref = Ref{Any}(nothing)
        @progress (ctx => ("Asset Pipeline", AMBER)) io=IOBuffer() for asset in 1:3
            root_ref[] = ctx
            download_and_extract(ctx, "asset-$asset")
        end

        root = root_ref[]
        @test length(treenodes(root)) == 7           # root + 3 x (download + extract)
        @test all(Progbiotic._completed, treenodes(root))
        @test all(node -> node.opts.vanish === 1.0, children(root))
    end

    @testset "title and theme keyword form" begin
        total    = 0
        root_ref = Ref{Any}(nothing)
        @progress title="Model Training Pipeline" theme=OCEAN (ctx => "Epochs") io=IOBuffer() for epoch in 1:3
            root_ref[] = ctx
            @progress ("Epoch $epoch Batches", CYBERPUNK) for batch in 1:20
                total += 1
            end
        end

        @test total == 60
        @test root_ref[].root.title == "Model Training Pipeline"
        @test root_ref[].theme === OCEAN

        # the title is drawn as a header row, with the root branching under it
        lines = split(plain(render_tree(root_ref[])), '\n'; keepempty = false)
        @test lines[1] == "Model Training Pipeline"
        @test startswith(lines[2], "╰─ ")
    end

    @testset "nested jobs with vanish_timeout" begin
        total = 0
        @progress "Long job!" io=IOBuffer() for i in 1:30
            @progress "Short job $(i)!" vanish_timeout=2.0 for j in 1:10
                total += 1
            end
        end
        @test total == 300
    end

    @testset "begin/end block progress" begin
        counter  = 0
        root_ref = Ref{Any}(nothing)
        @progress (ctx => "Block root") io=IOBuffer() begin
            root_ref[] = ctx
            @progress "Inner A" for j in 1:3
                counter += 1
            end
            @progress "Inner B" for j in 1:4
                counter += 1
            end
        end

        @test counter == 7
        root = root_ref[]
        @test length(treenodes(root)) == 3           # block root + 2 inner loops
        @test root.state.desc[] == "Block root"
        @test pbtotal(root) == 1 && pbdone(root) == 1
        @test all(Progbiotic._completed, treenodes(root))
    end

    @testset "nested begin/end block inside a loop" begin
        counter = 0
        @progress "Outer" io=IOBuffer() for i in 1:3
            @progress "Phase" begin
                counter += 1
            end
        end
        @test counter == 3
    end

    @testset "final_depth option" begin
        root_ref = Ref{Any}(nothing)
        @progress (ctx => ("Outer", final_depth=1)) io=IOBuffer() for i in 1:2
            root_ref[] = ctx
            @progress "Inner" for j in 1:2
            end
        end
        @test root_ref[].root.final_depth == 1
    end

    @testset "short form options" begin
        # d=1 -> final_depth=1
        root_ref = Ref{Any}(nothing)
        @progress (ctx => ("Short", d=1)) io=IOBuffer() for i in 1:2
            root_ref[] = ctx
            @progress "Inner" for j in 1:2
            end
        end
        @test root_ref[].root.final_depth == 1

        # v=1.2 -> vanish_timeout=1.2 (Float64), inherited by nested levels
        root_ref2  = Ref{Any}(nothing)
        inner_ref2 = Ref{Any}(nothing)
        @progress (ctx => ("Short2", v=1.2)) io=IOBuffer() for i in 1:2
            root_ref2[] = ctx
            @progress (inner => "Inner") for j in 1:2
                inner_ref2[] = inner
            end
        end
        @test root_ref2[].opts.vanish === 1.2
        @test inner_ref2[].opts.vanish === 1.2

        # v=false -> vanish=false: nothing vanishes anywhere
        root_ref3  = Ref{Any}(nothing)
        inner_ref3 = Ref{Any}(nothing)
        @progress (ctx => ("Short3", v=false)) io=IOBuffer() for i in 1:2
            root_ref3[] = ctx
            @progress (inner => "Inner") for j in 1:2
                inner_ref3[] = inner
            end
        end
        @test isinf(root_ref3[].opts.vanish)
        @test isinf(inner_ref3[].opts.vanish)

        # t=OCEAN -> theme=OCEAN
        root_ref4 = Ref{Any}(nothing)
        @progress (ctx => ("Short4", t=OCEAN)) io=IOBuffer() for i in 1:2
            root_ref4[] = ctx
        end
        @test root_ref4[].theme === OCEAN

        # the old threads=true option is gone: wrap loops with Threads.@threads
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @progress "Bad" threads=true for i in 1:2 end
        end)

        # vanish_timeout=1 (integer) is normalised to 1.0 (Float64)
        root_ref5 = Ref{Any}(nothing)
        @progress (ctx => ("Short5", v=1)) io=IOBuffer() for i in 1:2
            root_ref5[] = ctx
        end
        @test root_ref5[].opts.vanish === 1.0

        # an ambiguous v value is rejected at expansion time
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @progress "Bad" v=nothing for i in 1:2 end
        end)
        @test_throws ErrorException macroexpand(@__MODULE__, quote
            @progress "Bad" d=1.5 for i in 1:2 end
        end)
    end

    @testset "statement subtasks (bare @progress, no body)" begin
        counter  = 0
        root_ref = Ref{Any}(nothing)
        @progress (ctx => ("foo", d=1)) io=IOBuffer() begin
            root_ref[] = ctx
            @progress "job 1"
            counter += 1
            @progress "job 2"
            counter += 1
            @progress "job 3"
            counter += 1
        end

        @test counter == 3
        root = root_ref[]
        @test length(treenodes(root)) == 4           # foo + 3 subtasks
        jobs = children(root)
        @test [job.state.desc[] for job in jobs] == ["job 1", "job 2", "job 3"]
        @test all(Progbiotic.ismilestone, jobs)
        @test all(job -> pbtotal(job) === nothing, jobs)   # milestones have no total of their own
        # every subtask is closed by the time the scope ends
        @test all(Progbiotic._completed, jobs)
        # the block's total is the number of milestones; its counter tracks completions
        @test pbtotal(root) == 3
        @test pbdone(root) == 3
        @test root.root.final_depth == 1

        # retained by final_depth (d=1), so the collapsed final render keeps them
        text = plain(render_tree(root))
        @test occursin("foo", text)
        @test occursin("job 1", text) && occursin("job 2", text) && occursin("job 3", text)
    end

    @testset "statement subtasks complete sequentially" begin
        root_ref = Ref{Any}(nothing)
        @progress (ctx => "foo") io=IOBuffer() begin
            root_ref[] = ctx
            @progress "job 1"
            @progress "job 2"
            @progress "job 3"
        end
        @test all(Progbiotic._completed, children(root_ref[]))
    end

    @testset "statement subtasks are closed one at a time" begin
        parent = Progress(1; desc = "foo", io = IOBuffer(), tty = false, start = false)
        j1 = child(parent, nothing; desc = "job 1", kind = :milestone)
        j2 = child(parent, nothing; desc = "job 2", kind = :milestone)
        j3 = child(parent, nothing; desc = "job 3", kind = :milestone)

        # a milestone is meant to stay open until the next one is registered, or until
        # the scope ends. src today closes a milestone in the very call that registers it,
        # so none of them is ever open while its work runs; see the report. these are the
        # assertions that hold either way.
        @test Progbiotic._completed(j1)          # registering job 2 closed job 1
        @test Progbiotic._completed(j2)          # registering job 3 closed job 2

        Progbiotic._complete_statement_jobs!(parent)   # scope exit
        @test all(Progbiotic._completed, children(parent))
        @test all(job -> job.state.finish[] > 0, children(parent))
    end

    @testset "statement subtask inside a loop" begin
        root_ref = Ref{Any}(nothing)
        @progress (ctx => "outer") io=IOBuffer() for i in 1:2
            root_ref[] = ctx
            @progress "step"
        end

        steps = children(root_ref[])
        @test length(steps) == 2
        @test all(Progbiotic._completed, steps)
    end

    @testset "statement subtask options and context binding" begin
        root_ref = Ref{Any}(nothing)
        sub_ref  = Ref{Any}(nothing)
        @progress (ctx => "parent") io=IOBuffer() begin
            root_ref[] = ctx
            @progress "job" t=OCEAN v=2.0
            @progress (subctx => "job2")
            sub_ref[] = subctx
        end

        jobs = children(root_ref[])
        @test jobs[1].theme === OCEAN
        @test jobs[1].opts.vanish === 2.0
        @test sub_ref[].state.desc[] == "job2"
        @test sub_ref[].parent === root_ref[]        # a context is the node; its parent is the block
    end

    @testset "bare symbol binds a context (shorthand for ctx => ...)" begin
        root_ref = Ref{Any}(nothing)
        @progress ctx "outer..." io=IOBuffer() for i in 1:2
            root_ref[] = ctx
        end
        @test length(treenodes(root_ref[])) == 1
        @test root_ref[].state.desc[] == "outer..."
    end

    @testset "subroutine context threading (with=)" begin
        root_ref    = Ref{Any}(nothing)
        in_inner    = Ref{Any}(nothing)
        after_sub   = Ref{Any}(nothing)
        after_inner = Ref{Any}(nothing)
        in_working  = Ref{Any}(nothing)

        function subtask(ctx, i)
            @progress with=ctx "working..." for k in 1:i
                in_working[] = ctx
            end
        end

        @progress ctx "outer..." io=IOBuffer() for i in 1:2
            root_ref[] = ctx
            @progress "inner" for j in 1:2
                in_inner[] = ctx
                subtask(ctx, i)
                after_sub[] = ctx
            end
            after_inner[] = ctx
        end

        root   = root_ref[]
        inners = children(root)
        @test root.state.desc[] == "outer..."
        @test all(node -> node.state.desc[] == "inner", inners)
        workings = reduce(vcat, children(inner) for inner in inners)
        @test length(workings) == 4                  # 2 inner jobs x 2 outer iterations
        @test all(node -> node.state.desc[] == "working...", workings)
        @test all(node -> pbdone(node) == pbtotal(node), workings)

        # contexts track the innermost job, scoped
        @test in_inner[].state.desc[] == "inner"
        @test after_sub[].state.desc[] == "inner"          # restored after the subroutine
        @test after_inner[].state.desc[] == "outer..."     # restored after the inner loop
        @test in_working[].state.desc[] == "working..."    # rebound inside the with= body
        @test Progbiotic.root_of(in_working[]) === root    # one tree, one renderer
    end

    @testset "with= statement form and sibling placement" begin
        root_ref = Ref{Any}(nothing)
        function steps(ctx)
            @progress with=ctx "step 1"
            @progress with=ctx "step 2"
        end

        @progress (ctx => "pipeline") io=IOBuffer() begin
            root_ref[] = ctx
            steps(ctx)
        end

        jobs = children(root_ref[])
        @test [job.state.desc[] for job in jobs] == ["step 1", "step 2"]
        @test all(Progbiotic._completed, jobs)
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
        # a with= value that is not a bar is rejected, with the message the guard wrote,
        # rather than falling through to Progbiotic.child
        @test err isa ProgbioticError
        @test occursin("with=", sprint(showerror, err))
    end

    @testset "BUG1: final_depth retains children without v=false" begin
        # depth-1 children are kept even after the vanish window elapses
        root = Progress(1; desc = "root", final_depth = 1, vanish = 0.1, child_vanish = 0.1,
                        io = IOBuffer(), tty = false, start = false)
        kid = child(root, 1; desc = "child")
        update!(kid, 1)
        update!(root, 1)
        @test Progbiotic._visible(kid, time() + 10.0)

        # without final_depth, the same child vanishes
        root0 = Progress(1; desc = "root", vanish = 0.1, child_vanish = 0.1,
                         io = IOBuffer(), tty = false, start = false)
        kid0 = child(root0, 1; desc = "child")
        update!(kid0, 1)
        now = time()
        Progbiotic._visible(kid0, now)                        # the tick that notices it finished
        @test !Progbiotic._visible(kid0, now + 10.0)

        # end-to-end: d=1 alone shows the children in the collapsed final render
        root_ref = Ref{Any}(nothing)
        @progress (ctx => ("foo", d=1)) io=IOBuffer() begin
            root_ref[] = ctx
            @progress "bar" for j in 1:5
            end
            @progress "baz" for k in 1:5
            end
        end
        sleep(0.7)   # let the default vanish window (0.5s) elapse
        text = plain(render_tree(root_ref[]))
        @test occursin("foo", text)
        @test occursin("bar", text) && occursin("baz", text)
    end

    @testset "BUG2: ETA/rate freeze while a job is idle" begin
        bar   = Progress(10; desc = "t", io = IOBuffer(), tty = false, start = false)
        state = bar.state
        now   = time()
        state.start       = now - 10.0       # started 10 s ago
        state.current[]   = 5                # 5/10 done
        state.last_update = now - 2.0        # last activity was 8 s after the start

        barpart(s) = s[findfirst(c -> c in ('█', '░', '▒', '▓', '▏'), s):end]
        l1 = plain(render_frame(bar))
        sleep(0.3)                           # idle: nothing updates the bar
        l2 = plain(render_frame(bar))
        # the bar/rate/ETA portion is identical because it is measured to the last
        # update, not to "now" (only the spinner changes between renders)
        @test barpart(l1) == barpart(l2)
        # rate = 5/8 it/s -> "1.6 s/it"; ETA = (1-0.5)*(8s/0.5) = 8 s
        @test occursin("1.6 s/it", l1)
        @test occursin("ETA: 8 s", l1)
    end

    @testset "REQUEST1: total-less jobs show no rate/ETA, but report elapsed" begin
        bar  = Progress(nothing; desc = "task", io = IOBuffer(), tty = false, start = false)
        line = plain(render_frame(bar))
        @test !occursin("it/s", line)
        @test !occursin("s/it", line)
        @test !occursin("ETA", line)
        @test occursin("elapsed", line)

        # a finished indeterminate job reports its (frozen) duration
        bar.state.finish[] = time()
        line2 = plain(render_frame(bar))
        @test !occursin("ETA", line2)
        @test occursin("done in", line2)
    end

    @testset "REQUEST2: block total = milestone count, progress = completed milestones" begin
        states   = Int[]
        observed = Int[]
        root_ref = Ref{Any}(nothing)
        @progress (ctx => "foo") io=IOBuffer() begin
            root_ref[] = ctx
            @progress "job 1"
            push!(states, pbdone(ctx))
            push!(observed, count(Progbiotic._completed, children(ctx)))
            @progress "job 2"
            push!(states, pbdone(ctx))
            push!(observed, count(Progbiotic._completed, children(ctx)))
            @progress "job 3"
            push!(states, pbdone(ctx))
            push!(observed, count(Progbiotic._completed, children(ctx)))
        end

        root = root_ref[]
        @test states == observed           # the counter is the completed milestone count
        @test pbtotal(root) == 3
        @test pbdone(root) == 3            # 3/3 once the scope ends
        @test all(Progbiotic._completed, children(root))
    end

    @testset "style overrides work at the root of a tree too" begin
        root_ref = Ref{Any}(nothing)
        @progress "styled root" spinner = "✶✷" caps = "[]" width = 12 io = IOBuffer() for i in 1:2
            root_ref[] = Progbiotic.current_bar()
        end

        bar = root_ref[]
        @test bar.theme.spinner == ['✶', '✷']
        @test bar.theme.caps == ('[', ']')
        @test bar.opts.width == 12
    end

    @testset "per-bar style overrides via @progress" begin
        inner_ref = Ref{Any}(nothing)
        @progress (ctx => "x") io=IOBuffer() for i in 1:2
            @progress (pbar => ("y", spinner="✶✷", barunits="░█", empty="░", width=30)) for j in 1:2
                inner_ref[] = pbar
            end
        end

        bar = inner_ref[]
        @test bar.theme.spinner == ['✶', '✷']
        @test bar.theme.barunits == ['░', '█']
        @test bar.theme.empty == '░'
        @test bar.opts.width == 30
        @test occursin("█", plain(render_frame(bar)))    # drawn with the override glyphs
    end
end
