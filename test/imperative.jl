using Progbiotic
using Test

"""A column that counts how many times the engine asked it to render."""
mutable struct CountingColumn <: AbstractColumn
    frames :: Base.RefValue{Int}
end
CountingColumn() = CountingColumn(Ref(0))
Progbiotic.render_column(column::CountingColumn, ::ProgressState) = (column.frames[] += 1; "tick")

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
        @test progress_total(bar) == 50
        @test progress_current(bar) == 0
        text = sprint(show, bar)
        @test occursin("Progress", text)
        @test occursin("handle", text)
        @test occursin("0/50", text)
        @test occursin("running", text)
    end

    @testset "next!, update! and finish!" begin
        bar = Progress(10; io = IOBuffer(), vanish = 0.0, start = false)
        next!(bar)
        @test progress_current(bar) == 1
        next!(bar, 4)
        @test progress_current(bar) == 5
        update!(bar, 8)
        @test progress_current(bar) == 8
        # absolute updates are clamped to the total
        update!(bar, 999)
        @test progress_current(bar) == 10
        finish!(bar; wait = true)
        @test progress_finished(bar.ctx.state)
        @test occursin("finished", sprint(show, bar))
        # finishing twice is harmless
        finish!(bar; wait = true)
        @test progress_current(bar) == 10
    end

    @testset "indeterminate handles" begin
        bar = Progress(nothing; desc = "watching", io = IOBuffer(), tty = true,
                       vanish = 0.0, start = false)
        @test progress_total(bar) === nothing
        next!(bar)
        frame = render_frame(bar.ctx)
        @test occursin("watching", frame)
        @test !occursin("%", frame)
        update!(bar, 7)
        @test progress_current(bar) == 7
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
        @test progress_finished(bar.ctx.state)

        seen = 0
        other = withprogress(3; io = IOBuffer(), vanish = 0.0) do p
            for _ in 1:3
                next!(p)
                seen += 1
            end
        end
        @test seen == 3
        @test progress_current(other) == 3
    end

    @testset "thread-safe advance under Threads.@threads" begin
        n = 20_000
        bar = Progress(n; desc = "parallel", io = IOBuffer(), vanish = 0.0)
        Base.Threads.@threads for _ in 1:n
            next!(bar)
        end
        # A lost update would show up here: the counter is a Threads.Atomic.
        @test progress_current(bar) == n
        finish!(bar; wait = true)
        @test progress_current(bar) == n

        # postfix metrics written from every worker stay intact
        bar2 = Progress(n; desc = "parallel metrics", io = IOBuffer(), vanish = 0.0)
        Base.Threads.@threads for i in 1:n
            next!(bar2)
            i % 1000 == 0 && set_postfix!(bar2; thread = Base.Threads.threadid())
        end
        finish!(bar2; wait = true)
        @test progress_current(bar2) == n
        @test haskey(bar2.ctx.state.postfix[], :thread)
    end

    @testset "the render task is frame-rate limited" begin
        counter = CountingColumn()
        bar = Progress(10_000; layout = [counter], io = IOBuffer(), tty = true,
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

    @testset "tty drawing and vanishing" begin
        buffer = IOBuffer()
        bar = Progress(10; desc = "tty", io = buffer, tty = true, fps = 100.0, vanish = 0.0)
        for _ in 1:10
            next!(bar)
        end
        finish!(bar; wait = true)
        output = String(take!(buffer))
        @test occursin("\e[", output)
        @test occursin("100.0%", output)
        # vanish = 0.0 erases the finished block again
        @test bar.ctx.rendered_lines == 0

        kept = Progress(10; desc = "kept", io = IOBuffer(), tty = true,
                        fps = 100.0, vanish = false)
        for _ in 1:10
            next!(kept)
        end
        finish!(kept; wait = true)
        # vanish = false means the finished bar stays on screen
        @test kept.ctx.rendered_lines > 0
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
        @test progress_current(bar) == n

        per_iteration_ns = (wrapped - base) / n
        @info "atomic advance overhead" plain_ms = base / 1e6 wrapped_ms = wrapped / 1e6 per_iteration_ns
        # One lock-free atomic add and one call.  The bound is deliberately loose:
        # this is a guard against accidentally reintroducing locks or I/O into the
        # hot path, not a benchmark.
        @test per_iteration_ns < 100.0
    end
end
