using Progbiotic
using Test
using Logging

# A minimal logger that records everything handed to it, used to check that log
# levels a progress scope does not capture still reach the surrounding logger.
mutable struct SinkLogger <: Logging.AbstractLogger
    records :: Vector{Tuple{Logging.LogLevel, String}}
end

SinkLogger() = SinkLogger(Tuple{Logging.LogLevel, String}[])

Logging.min_enabled_level(::SinkLogger) = Logging.BelowMinLevel
Logging.shouldlog(::SinkLogger, level, _module, group, id) = true
Logging.catch_exceptions(::SinkLogger) = true
Logging.handle_message(sink::SinkLogger, level, message, _module, group, id, file, line;
                       kwargs...) = (push!(sink.records, (level, string(message))); nothing)

# Builds a context around a single job. `vanish_timeout` mirrors the `vanish`
# option of a `@progress` scope: `nothing` means the bar (and its logs) never vanish.
function log_ctx(; vanish_timeout = nothing, desc = "job")
    pbar = ProgBar("log tests")
    job = add_job!(pbar, desc; total = 3, vanish_timeout = vanish_timeout)
    return ProgContext(pbar, job)
end

@testset "test_logging.jl" begin
    @testset "captures @info, @warn, @debug and @error" begin
        ctx = log_ctx()
        Logging.with_logger(ProgbioticLogger(ctx)) do
            @info "informational" answer = 42
            @warn "careful"
            @debug "verbose"
            @error "broken"
        end
        entries = active_logs(ctx)
        @test length(entries) == 4
        @test [e.level for e in entries] ==
              [Logging.Info, Logging.Warn, Logging.Debug, Logging.Error]
        @test occursin("informational", entries[1].message)
        @test occursin("answer=42", entries[1].message)   # keyword args are kept
        @test entries[1].vanish_timeout == Inf            # no vanish timeout: kept
        @test all(e -> e.created_at <= time(), entries)
        # the context exposes the buffer of the job it belongs to
        @test ctx.log_buffer === ctx.pbar.logs.buffers[ctx.parent]
        @test ctx.log_lock === ctx.pbar.logs.lock
        @test current_prog_context() === nothing
    end

    @testset "capture filtering and pass-through" begin
        ctx = log_ctx()
        sink = SinkLogger()
        Logging.with_logger(ProgbioticLogger(ctx; capture = [:warn, :error], parent = sink)) do
            @info "handled by the parent logger"
            @warn "intercepted"
        end
        entries = active_logs(ctx)
        @test length(entries) == 1
        @test entries[1].level == Logging.Warn
        @test occursin("intercepted", entries[1].message)
        @test sink.records == [(Logging.Info, "handled by the parent logger")]

        # capture = false: nothing is intercepted
        ctx2 = log_ctx()
        sink2 = SinkLogger()
        Logging.with_logger(ProgbioticLogger(ctx2; capture = false, parent = sink2)) do
            @info "not captured"
            @error "also not captured"
        end
        @test isempty(active_logs(ctx2))
        @test [r[1] for r in sink2.records] == [Logging.Info, Logging.Error]

        # a LogLevel captures that level and above
        ctx3 = log_ctx()
        sink3 = SinkLogger()
        Logging.with_logger(ProgbioticLogger(ctx3; capture = Logging.Warn, parent = sink3)) do
            @info "below"
            @warn "at"
            @error "above"
        end
        @test [e.level for e in active_logs(ctx3)] == [Logging.Warn, Logging.Error]
        @test [r[1] for r in sink3.records] == [Logging.Info]
    end

    @testset "entries expire after the scope's vanish timeout" begin
        ctx = log_ctx(vanish_timeout = 0.2)
        push_log!(ctx, Logging.Info, "short lived")
        @test length(active_logs(ctx)) == 1
        @test active_logs(ctx)[1].vanish_timeout == 0.2
        sleep(0.35)
        @test isempty(active_logs(ctx))
        # pruned, not merely filtered: the buffer itself is emptied
        @test isempty(get(ctx.pbar.logs.buffers, ctx.parent, ProgressLogEntry[]))
        @test !Progbiotic.has_active_logs(ctx.pbar, ctx.parent)

        # without a vanish timeout the entry is kept indefinitely
        ctx2 = log_ctx()
        push_log!(ctx2, :info, "kept")                     # symbol levels work too
        sleep(0.35)
        @test length(active_logs(ctx2)) == 1
        @test active_logs(ctx2)[1].vanish_timeout == Inf

        # prune_logs! drops everything that has expired
        ctx3 = log_ctx(vanish_timeout = 0.1)
        push_log!(ctx3, Logging.Warn, "gone soon")
        sleep(0.25)
        prune_logs!(ctx3)
        @test isempty(active_logs(ctx3))
        @test all(isempty, values(ctx3.pbar.logs.buffers))
    end

    @testset "log lines render under their bar" begin
        ctx = log_ctx(vanish_timeout = 0.25)
        push_log!(ctx, Logging.Info, "rendered info")
        rendered = render_progbar_tree(ctx.pbar)
        @test occursin("rendered info", rendered)
        @test occursin("INFO", rendered)
        @test occursin("\e[36m", rendered)                # cyan for @info
        @test count(l -> occursin("INFO", l), split(chomp(rendered), '\n')) == 1

        push_log!(ctx, Logging.Warn, "rendered warn")
        warn_rendered = render_progbar_tree(ctx.pbar)
        @test occursin("rendered warn", warn_rendered)
        @test occursin("\e[33m", warn_rendered)           # yellow for @warn
        # both lines sit under the bar (title + bar + 2 logs)
        @test length(split(chomp(warn_rendered), '\n')) == 4

        sleep(0.4)
        expired = render_progbar_tree(ctx.pbar)
        @test !occursin("rendered info", expired)
        @test !occursin("rendered warn", expired)

        # multi-line messages are flattened to a single gutter row
        ml = log_ctx()
        push_log!(ml, Logging.Info, "first line\nsecond line")
        ml_rendered = render_progbar_tree(ml.pbar)
        @test occursin("first line second line", ml_rendered)
        @test length(split(chomp(ml_rendered), '\n')) == 3   # title + bar + 1 log
    end

    @testset "a bar with live logs stays visible" begin
        ctx = log_ctx(vanish_timeout = 0.4)
        update!(ctx.pbar, ctx.parent, 3)                    # the bar completes
        sleep(0.3)
        push_log!(ctx, Logging.Info, "lingering")           # outlives the bar's window
        sleep(0.3)
        @test occursin("lingering", render_progbar_tree(ctx.pbar))
        sleep(0.5)
        @test !occursin("lingering", render_progbar_tree(ctx.pbar))
    end

    @testset "@progress intercepts the standard logging macros" begin
        ctx = nothing
        @progress ctx "Ingesting" total=5 vanish=3.0 for i in 1:5
            i == 2 && @info "checkpoint at record $i"
            i == 4 && @warn "malformed record $i"
        end
        entries = active_logs(ctx)
        @test [e.level for e in entries] == [Logging.Info, Logging.Warn]
        @test entries[1].message == "checkpoint at record 2"
        @test entries[2].message == "malformed record 4"
        @test all(e -> e.vanish_timeout == 3.0, entries)    # from `vanish=3.0`
    end

    @testset "@progress capture option" begin
        Logging.with_logger(Logging.NullLogger()) do
            ctx = nothing
            @progress ctx "Filtered" capture=[:error] vanish=1.0 for i in 1:3
                @info "goes to the surrounding logger"
                i == 1 && @error "captured"
            end
            entries = active_logs(ctx)
            @test length(entries) == 1
            @test entries[1].level == Logging.Error

            alias = nothing
            @progress alias "Alias" capture_logs=[:warn] for i in 1:2
                i == 2 && @warn "alias captured"
            end
            @test [e.message for e in active_logs(alias)] == ["alias captured"]

            off = nothing
            @progress off "Off" capture=false for i in 1:3
                @info "not captured"
            end
            @test isempty(active_logs(off))
        end
    end

    @testset "nested scopes capture into the innermost context" begin
        outer = nothing
        inner = nothing
        @progress outer "Outer" vanish=5.0 for i in 1:2
            @info "outer $i"
            @progress inner "Inner" vanish=0.5 for j in 1:3
                @info "inner $i.$j"
            end
        end
        outer_entries = active_logs(outer)
        @test [e.message for e in outer_entries] == ["outer 1", "outer 2"]
        @test all(e -> e.vanish_timeout == 5.0, outer_entries)
        @test all(e -> !startswith(e.message, "inner"), outer_entries)

        inner_ctx = ProgContext(outer.pbar, inner.parent)
        inner_entries = active_logs(inner_ctx)
        @test [e.message for e in inner_entries] == ["inner 2.1", "inner 2.2", "inner 2.3"]
        @test all(e -> e.vanish_timeout == 0.5, inner_entries)
        @test inner_ctx.pbar === outer.pbar
    end

    @testset "block-form scopes capture logs" begin
        blk = nothing
        @progress blk "Block" vanish=2.0 begin
            @info "inside the block"
        end
        @test [e.message for e in active_logs(blk)] == ["inside the block"]
        @test active_logs(blk)[1].vanish_timeout == 2.0
    end

    @testset "with=ctx subroutines capture into the active job" begin
        function log_subtask(subctx, n)
            @progress with=subctx "subtask" vanish=1.0 for k in 1:n
                k == 1 && @info "from the subroutine"
            end
        end
        ctx = nothing
        @progress ctx "Outer" for i in 1:2
            log_subtask(ctx, 2)
        end
        @test isempty(active_logs(ctx))               # the outer bar owns no logs
        subtask_ctxs = [ProgContext(ctx.pbar, c) for c in get_children(ctx.pbar, ctx.parent)]
        @test length(subtask_ctxs) == 2
        entries = reduce(vcat, (active_logs(sub) for sub in subtask_ctxs))
        @test length(entries) == 2
        @test all(e -> occursin("from the subroutine", e.message), entries)
        @test all(e -> e.vanish_timeout == 1.0, entries)
    end

    @testset "thread-safe capture under Threads.@threads" begin
        n = 200
        ctx = nothing
        @progress ctx "Threaded" Base.Threads.@threads for i in 1:n
            @info "threaded $i"
        end
        entries = active_logs(ctx)
        @test length(entries) == n
        @test length(unique(e.message for e in entries)) == n
    end
end
