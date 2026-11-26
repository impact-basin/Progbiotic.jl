using Progbiotic
using Test

"""A column that counts how many times the engine asked it to render."""
mutable struct CountingColumn <: AbstractColumn
    frames :: Base.RefValue{Int}
end
CountingColumn() = CountingColumn(Ref(0))
Progbiotic.render_column(column::CountingColumn, ::BarState) = (column.frames[] += 1; "tick")

struct RenderGate <: AbstractColumn
    first :: Threads.Atomic{Bool}
    calls :: Channel{Task}
    gate  :: Channel{Nothing}
end
RenderGate() = RenderGate(Threads.Atomic{Bool}(true), Channel{Task}(64), Channel{Nothing}(1))

function Progbiotic.render_column(col::RenderGate, ::BarState)
    put!(col.calls, current_task())
    Threads.atomic_xchg!(col.first, false) && take!(col.gate)
    return "tick"
end

struct FailingColumn <: AbstractColumn
    fail :: Threads.Atomic{Bool}
end
Progbiotic.render_column(col::FailingColumn, ::BarState) = col.fail[] ? error("render failed") : "tick"

struct SelfStoppingColumn <: AbstractColumn
    root    :: Base.RefValue{Any}
    enabled :: Threads.Atomic{Bool}
    calls   :: Threads.Atomic{Int}
    finish  :: Bool
end

function Progbiotic.render_column(col::SelfStoppingColumn, ::BarState)
    Threads.atomic_add!(col.calls, 1)
    if col.enabled[]
        col.finish ? finish!(col.root[]; wait = false) : Progbiotic.stop_render!(col.root[])
    end
    yield()
    return "tick"
end

"""Bare accumulation loop, the baseline the wrapped loop is compared against."""
function plain_loop(n::Int)
    acc = 0
    for i in 1:n
        acc += i
    end
    return acc
end

"""Same loop, with a progress bar advanced every iteration."""
function wrapped_loop(bar, n::Int)
    acc = 0
    for i in 1:n
        next!(bar)
        acc += i
    end
    return acc
end

@testset "imperative.jl" begin
    @testset "Progress constructor and show" begin
        bar = Progress(50; desc = "handle", io = IOBuffer(), vanish = 0.0, start = false)
        @test bar isa Progress
        @test pbtotal(bar) == 50
        @test pbdone(bar) == 0
        text = sprint(show, bar)
        @test occursin("Progress", text)
        @test occursin("handle", text)
        @test occursin("0/50", text)
        @test occursin("running", text)
    end

    @testset "next!, update! and finish!" begin
        bar = Progress(10; io = IOBuffer(), vanish = 0.0, start = false)
        next!(bar)
        @test pbdone(bar) == 1
        next!(bar, 4)
        @test pbdone(bar) == 5
        update!(bar, 8)
        @test pbdone(bar) == 8
        # absolute updates are clamped to the total
        update!(bar, 999)
        @test pbdone(bar) == 10
        finish!(bar; wait = true)
        @test isfinished(bar.state)
        @test occursin("finished", sprint(show, bar))
        # finishing twice is harmless
        finish!(bar; wait = true)
        @test pbdone(bar) == 10
    end

    @testset "indeterminate handles" begin
        bar = Progress(nothing; desc = "watching", io = IOBuffer(), tty = true,
                       vanish = 0.0, start = false)
        @test pbtotal(bar) === nothing
        next!(bar)
        frame = render_frame(bar)
        @test occursin("watching", frame)
        @test !occursin("%", frame)
        update!(bar, 7)
        @test pbdone(bar) == 7
    end

    @testset "do-block and withprogress forms" begin
        collected = Int[]
        bar = Progress(5; desc = "block", io = IOBuffer(), vanish = 0.0) do p
            for i in 1:5
                next!(p)
                push!(collected, i)
            end
        end
        @test collected == collect(1:5)
        @test isfinished(bar.state)

        seen = 0
        other = withprogress(3; io = IOBuffer(), vanish = 0.0) do p
            for _ in 1:3
                next!(p)
                seen += 1
            end
        end
        @test seen == 3
        @test pbdone(other) == 3
    end

    @testset "thread-safe advance under Threads.@threads" begin
        n = 20_000
        bar = Progress(n; desc = "parallel", io = IOBuffer(), vanish = 0.0)
        Base.Threads.@threads for _ in 1:n
            next!(bar)
        end
        # A lost update would show up here: the counter is a Threads.Atomic.
        @test pbdone(bar) == n
        finish!(bar; wait = true)
        @test pbdone(bar) == n

        # postfix metrics written from every worker stay intact
        bar2 = Progress(n; desc = "parallel metrics", io = IOBuffer(), vanish = 0.0)
        Base.Threads.@threads for i in 1:n
            next!(bar2)
            i % 1000 == 0 && set_postfix!(bar2; thread = Base.Threads.threadid())
        end
        finish!(bar2; wait = true)
        @test pbdone(bar2) == n
        @test occursin("thread=", Progbiotic.postfix_text(bar2.state))
        # one entry for the key, overwritten each time, not one per call
        @test length(bar2.state.postfix[]) == 1
    end

    @testset "the render task is frame-rate limited" begin
        counter = CountingColumn()
        bar = Progress(10_000; layout = (counter,), io = IOBuffer(), tty = true,
                       fps = 20.0, vanish = 0.0)
        started = time()
        while time() - started < 0.25
            next!(bar)
            sleep(0.001)
        end
        finish!(bar; wait = true)
        elapsed = time() - started
        # At 20 fps a quarter of a second can hold at most a handful of frames, no
        # matter how often the bar is advanced.
        @test counter.frames[] <= ceil(Int, elapsed * 20.0) + 3
        @test counter.frames[] >= 2
    end

    @testset "a flat line carries no escapes and one postfix" begin
        bar = Progress(10; desc = "flat", io = IOBuffer(), tty = false, vanish = 0.0,
                       start = false)
        next!(bar, 3)
        set_postfix!(bar; loss = 0.041)

        line = render_flat_line(bar)
        @test !occursin('\e', line)
        @test startswith(line, "flat 30% (3/10)")
        @test length(findall("[loss=0.041]", line)) == 1
    end

    @testset "the forced flat pass does not repeat a line" begin
        node = Progress(nothing; desc = "milestone", io = IOBuffer(), tty = false,
                        vanish = 0.0, start = false)
        now = time()

        # announced while it was still running
        @test Progbiotic._should_emit_flat(node, -1, false, now)
        node.paint.flat_pct  = -1
        node.paint.last_flat = now
        node.paint.flat_done = false

        # the final pass has something new to say: it has finished since
        node.state.finish[] = time()
        @test Progbiotic._should_emit_flat(node, -1, true, now)

        # and once that line is on the log, it does not say it again. Without this the
        # forced pass wrote an identical line for every indeterminate node.
        node.paint.flat_done = true
        node.paint.flat_status = :succeeded
        @test !Progbiotic._should_emit_flat(node, -1, true, now)

        # a node that has never been announced still gets its one line
        fresh = Progress(nothing; desc = "fresh", io = IOBuffer(), tty = false,
                         vanish = 0.0, start = false)
        @test Progbiotic._should_emit_flat(fresh, -1, true, now)
    end

    @testset "the gutter is drawn, then erased or left behind" begin
        buffer = IOBuffer()
        bar = Progress(10; desc = "tty", io = buffer, tty = true, fps = 100.0, vanish = 0.0)
        for _ in 1:10
            next!(bar)
        end
        finish!(bar; wait = true)
        output = String(take!(buffer))

        @test occursin("\e[", output)                  # stored in a scroll region
        @test occursin("\e[1;", output) && occursin("r", output)
        @test occursin("100%", output)
        # vanish = 0.0 erases it again: the last time the gutter was cleared, nothing was
        # drawn back over it, so the bar is gone from the screen
        @test !occursin('◉', last(split(output, "\e[J")))
        @test bar.root.rows == 0

        kept = IOBuffer()
        other = Progress(10; desc = "kept", io = kept, tty = true, fps = 100.0,
                         vanish = false)
        for _ in 1:10
            next!(other)
        end
        finish!(other; wait = true)
        left = String(take!(kept))
        # vanish = false hands the terminal back with the finished tree still on it, as
        # ordinary text with the cursor on a fresh line below
        @test occursin('◉', last(split(left, "\e[J")))
        @test endswith(left, "\n")
    end

    @testset "child completion never enters the renderer" begin
        for threaded in (false, true)
            col = RenderGate()
            root = Progress(2; layout = (col,), io = IOBuffer(), tty = true,
                            vanish = false, threaded, start = false)
            kid = child(root, 1)
            owner = Progbiotic.start_render!(root)
            try
                @test timedwait(() -> isready(col.calls), 5.0) == :ok
                @test take!(col.calls) === owner
                finisher = Threads.@spawn finish!(kid; wait = false)
                @test timedwait(() -> istaskdone(finisher), 5.0) == :ok
                @test kid.paint.completed_at == 0.0
                @test !isready(col.calls)
            finally
                finish!(root; wait = false)
                put!(col.gate, nothing)
                wait(owner)
            end
            while isready(col.calls)
                @test take!(col.calls) === owner
            end
            @test root.root.task === nothing
            @test root.root.drawn == root.root.requested
        end
    end

    @testset "waiting for a child waits for its frame, not its parent" begin
        io = IOBuffer()
        root = Progress(2; io, tty = false, threaded = false, vanish = false)
        kid = child(root; desc = "child")
        finisher = @async finish!(kid)
        try
            @test timedwait(() -> istaskdone(finisher), 5.0) == :ok
            @test !isfinished(root)
            @test kid.paint.flat_done
        finally
            finish!(root)
            wait(finisher)
        end
        lines = split(String(take!(io)), '\n')
        @test count(line -> occursin("child ", line) && occursin("done in", line), lines) == 1
    end

    @testset "waiting for a child wakes a slow renderer" begin
        root = Progress(2; io = IOBuffer(), tty = false, threaded = false, fps = 0.01)
        @test timedwait(() -> root.paint.last_flat > 0, 5.0) == :ok
        kid = child(root, 1)
        finisher = @async finish!(kid; wait = true)
        try
            @test timedwait(() -> istaskdone(finisher), 5.0) == :ok
            @test kid.paint.flat_done
            @test !isfinished(root)
        finally
            finish!(root)
            wait(finisher)
        end
    end

    @testset "root completion and its flush request are published together" begin
        io = IOBuffer()
        root = Progress(2; io, tty = false, threaded = false, start = false)
        entered = Channel{Nothing}(1)
        lock(root.root.lock)
        finisher = Threads.@spawn begin
            put!(entered, nothing)
            finish!(root; wait = false)
        end
        try
            take!(entered)
            @test timedwait(() -> isfinished(root), 0.1) == :timed_out
        finally
            unlock(root.root.lock)
        end
        finish!(root; wait = true)
        wait(finisher)
        @test occursin("100%", String(take!(io)))
    end

    @testset "a frame already in progress cannot acknowledge a later completion" begin
        col = RenderGate()
        root = Progress(2; layout = (col,), io = IOBuffer(), tty = true,
                        vanish = false, threaded = false, start = false)
        kid = child(root, 1)
        owner = Progbiotic.start_render!(root)
        @test timedwait(() -> isready(col.calls), 5.0) == :ok
        take!(col.calls)
        finisher = @async finish!(kid; wait = true)
        try
            @test timedwait(() -> root.root.requested > 0, 5.0) == :ok
            @test !istaskdone(finisher)
            put!(col.gate, nothing)
            @test timedwait(() -> istaskdone(finisher), 5.0) == :ok
            @test !isfinished(root)
        finally
            isready(col.gate) || put!(col.gate, nothing)
            finish!(root; wait = true)
            wait(finisher)
        end
        @test istaskdone(owner)
    end

    @testset "shutdown flushes a tree that never had a tick" begin
        io = IOBuffer()
        root = Progress(nothing; desc = "root", kind = :container, io,
                        tty = false, threaded = false, start = false)
        child(root; desc = "first", kind = :milestone)
        child(root; desc = "second", kind = :milestone)
        Progbiotic._complete_statement_jobs!(root)
        Progbiotic.stop_render!(root)
        text = String(take!(io))
        @test count("root ", text) == 1
        @test count("first ", text) == 1
        @test count("second ", text) == 1
        @test root.root.task === nothing
    end

    @testset "shutdown includes requests arriving during its final draw" begin
        col = RenderGate()
        root = Progress(2; layout = (col,), io = IOBuffer(), tty = true,
                        vanish = false, threaded = false, start = false)
        stopper = @async Progbiotic.stop_render!(root)
        @test timedwait(() -> isready(col.calls), 5.0) == :ok
        owner = take!(col.calls)
        finisher = @async finish!(root; wait = true)
        try
            @test timedwait(() -> root.root.requested == 2, 5.0) == :ok
            @test root.root.drawn == 0
            @test !istaskdone(finisher)
        finally
            put!(col.gate, nothing)
        end
        @test timedwait(() -> istaskdone(stopper) && istaskdone(finisher), 5.0) == :ok
        @test root.root.drawn == root.root.requested
        @test root.root.task === nothing
        while isready(col.calls)
            @test take!(col.calls) === owner
        end
    end

    @testset "a flat error is flushed once without advancing" begin
        io = IOBuffer()
        root = Progress(10; io, tty = false, start = false)
        next!(root, 3)
        Progbiotic.render_tick!(root)
        fail!(root, ErrorException("stopped"))
        finish!(root)
        finish!(root)
        Progbiotic.stop_render!(root)
        text = String(take!(io))
        @test count("ERROR: ErrorException", text) == 1
        @test pbdone(root) == 3
    end

    @testset "a failed final draw still releases the gutter" begin
        col = FailingColumn(Threads.Atomic{Bool}(false))
        io = IOBuffer()
        root = Progress(2; layout = (col,), io, tty = true, threaded = false,
                        fps = 0.01, vanish = false)
        @test timedwait(() -> root.root.rows > 0, 5.0) == :ok
        take!(io)
        col.fail[] = true
        Progbiotic.stop_render!(root)
        @test root.root.rows == 0
        @test root.root.task === nothing
        @test occursin("\e[r", String(take!(io)))
    end

    @testset "a stale flat snapshot cannot swallow a later failure" begin
        col = RenderGate()
        io = IOBuffer()
        root = Progress(2; layout = (col,), io, tty = false, threaded = false,
                        start = false)
        kid = child(root, 10; desc = "child")
        owner = Progbiotic.start_render!(root)
        @test timedwait(() -> isready(col.calls), 5.0) == :ok
        take!(col.calls)
        try
            fail!(kid, ErrorException("late failure"))
        finally
            put!(col.gate, nothing)
            Progbiotic.stop_render!(root)
        end
        @test istaskdone(owner)
        @test count("ERROR: ErrorException", String(take!(io))) == 1
    end

    @testset "retirement follows effective permanence" begin
        function settled_tree(vanish, child_vanish; depth = 0)
            root = Progress(1; io = IOBuffer(), tty = true, start = false,
                            vanish, final_depth = depth)
            kid = child(root, 1; vanish = child_vanish)
            Progbiotic._finish_state!(kid.state)
            Progbiotic._finish_state!(root.state)
            return root, kid
        end

        root, kid = settled_tree(0.0, Inf)
        @test Progbiotic._all_forever(root, 100.0)
        @test root.paint.completed_at == 0.0

        root, kid = settled_tree(0.0, 0.0; depth = 1)
        @test Progbiotic._all_forever(root, 100.0)
        @test Progbiotic._visible(kid, 1000.0)

        root, kid = settled_tree(Inf, 2.0)
        @test !Progbiotic._all_forever(root, 100.0)
        @test kid.paint.completed_at == 100.0
        @test !Progbiotic._all_forever(root, 101.0)
        @test Progbiotic._all_forever(root, 102.0)
        @test !Progbiotic._visible(kid, 102.0)

        root, kid = settled_tree(3.0, 2.0)
        @test !Progbiotic._all_forever(root, 100.0)
        @test root.paint.completed_at == 0.0
        @test !Progbiotic._all_forever(root, 102.0)
        @test root.paint.completed_at == 102.0
        @test Progbiotic._visible(root, 104.0)
        @test !Progbiotic._visible(root, 105.0)
        @test Progbiotic._all_forever(root, 105.0)

        root, kid = settled_tree(0.0, 0.0; depth = 1)
        grandkid = child(kid, 1; vanish = 2.0)
        Progbiotic._finish_state!(grandkid.state)
        @test !Progbiotic._all_forever(root, 100.0)
        @test Progbiotic._all_forever(root, 102.0)
        @test !Progbiotic._visible(grandkid, 102.0)
        @test Progbiotic._visible(kid, 102.0)

        root = Progress(1; io = IOBuffer(), tty = true, start = false, vanish = Inf)
        kid = child(root, 1; vanish = Inf)
        Progbiotic._finish_state!(root.state)
        @test !Progbiotic._all_forever(root, 100.0)

        for timeout in (2.0, Inf)
            root = Progress(1; io = IOBuffer(), tty = true, start = false, vanish = Inf)
            kid = child(root, 10; vanish = Inf, error_vanish = timeout)
            Progbiotic._finish_state!(root.state)
            fail!(kid, ErrorException("child failed"))
            @test Progbiotic._all_forever(root, 100.0) == isinf(timeout)
            @test Progbiotic._all_forever(root, 102.0)
            @test Progbiotic._visible(kid, 102.0) == isinf(timeout)
        end
    end

    @testset "retained descendants release renderer ownership" begin
        for threaded in (false, true), (vanish, child_vanish, depth) in
                ((0.0, Inf, 0), (0.0, 0.0, 1), (Inf, 0.0, 0))
            root = Progress(1; io = IOBuffer(), tty = true, start = false,
                            threaded, vanish, final_depth = depth)
            kid = child(root, 1; vanish = child_vanish)
            Progbiotic._finish_state!(kid.state)
            finisher = @async finish!(root; wait = true)
            try
                @test timedwait(() -> istaskdone(finisher), 5.0) == :ok
                @test root.root.task === nothing
                @test root.root.rows == 0
                @test root.root.drawn == root.root.requested
                @test Progbiotic._visible(kid, time()) == (depth == 1 || isinf(child_vanish))
            finally
                Progbiotic.stop_render!(root)
                wait(finisher)
            end
        end
    end

    @testset "renderer teardown callbacks do not request endless final frames" begin
        for threaded in (false, true), finish in (false, true), tty in (false, true)
            col = SelfStoppingColumn(Ref{Any}(nothing), Threads.Atomic{Bool}(true),
                                     Threads.Atomic{Int}(0), finish)
            root = Progress(10; layout = (col,), io = IOBuffer(), tty,
                            start = false, threaded, vanish = Inf)
            col.root[] = root
            owner = Progbiotic.start_render!(root)
            try
                @test timedwait(() -> istaskdone(owner), 5.0) == :ok
                @test col.calls[] > 0
                @test root.root.requested == (finish ? 1 : 0)
                @test root.root.drawn == root.root.requested
                @test root.root.task === nothing
                @test root.root.rows == 0
            finally
                col.enabled[] = false
                Progbiotic.stop_render!(root)
                wait(owner)
            end
        end
    end

    @testset "atomic advance keeps a fine-grained loop cheap" begin
        n = 10_000_000
        base = time_ns()
        plain = plain_loop(n)
        base = time_ns() - base

        bar = Progress(n; desc = "bench", io = devnull, tty = false, fps = 1.0, vanish = 0.0)
        wrapped = time_ns()
        total = wrapped_loop(bar, n)
        wrapped = time_ns() - wrapped
        finish!(bar; wait = true)

        @test total == plain
        @test pbdone(bar) == n

        per_iteration_ns = (wrapped - base) / n
        @info "atomic advance overhead" plain_ms = base / 1e6 wrapped_ms = wrapped / 1e6 per_iteration_ns
        # One lock-free atomic add and one call.  The bound is deliberately loose:
        # this is a guard against accidentally reintroducing locks or I/O into the
        # hot path, not a benchmark.
        @test per_iteration_ns < 100.0
    end
end
