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

# A node with no children is a standalone bar. Its vanish timeout is how long the bar
# *and the records it holds* stay on screen, where nothing means forever. Nothing
# renders it (start = false), so a test can ask the renderer for a frame whenever it
# likes.
log_node(; vanish = nothing, desc = "job", title = "") =
    Progress(3; desc = desc, title = title, vanish = vanish, io = IOBuffer(), start = false)

@testset "test_logging.jl" begin
    @testset "captures @info, @warn, @debug and @error" begin
        node = log_node()
        Logging.with_logger(ProgbioticLogger(node)) do
            @info "informational" answer = 42
            @warn "careful"
            @debug "verbose"
            @error "broken"
        end
        entries = active_logs(node)
        @test length(entries) == 4
        @test [e.level for e in entries] ==
              [Logging.Info, Logging.Warn, Logging.Debug, Logging.Error]
        @test occursin("informational", entries[1].message)
        @test occursin("answer=42", entries[1].message)   # keyword args are kept
        @test entries[1].vanish == Inf                    # no vanish timeout: kept
        @test all(e -> e.created_at <= time(), entries)

        # the records are the node's own - its buffer holds them - while the permanent
        # sink they would be mirrored to belongs to the tree, which is the node here
        @test length(node.logs.entries) == 4
        @test Progbiotic.has_active_logs(node)
        @test node.root.sink === nothing
        @test current_bar() === nothing                   # nothing is left installed
    end

    @testset "capture filtering and pass-through" begin
        node = log_node()
        sink = SinkLogger()
        Logging.with_logger(ProgbioticLogger(node; capture = [:warn, :error], parent = sink)) do
            @info "handled by the parent logger"
            @warn "intercepted"
        end
        entries = active_logs(node)
        @test length(entries) == 1
        @test entries[1].level == Logging.Warn
        @test occursin("intercepted", entries[1].message)
        @test sink.records == [(Logging.Info, "handled by the parent logger")]

        # capture = false: nothing is intercepted
        node2 = log_node()
        sink2 = SinkLogger()
        Logging.with_logger(ProgbioticLogger(node2; capture = false, parent = sink2)) do
            @info "not captured"
            @error "also not captured"
        end
        @test isempty(active_logs(node2))
        @test [r[1] for r in sink2.records] == [Logging.Info, Logging.Error]

        # a LogLevel captures that level and above
        node3 = log_node()
        sink3 = SinkLogger()
        Logging.with_logger(ProgbioticLogger(node3; capture = Logging.Warn, parent = sink3)) do
            @info "below"
            @warn "at"
            @error "above"
        end
        @test [e.level for e in active_logs(node3)] == [Logging.Warn, Logging.Error]
        @test [r[1] for r in sink3.records] == [Logging.Info]
    end

    @testset "a scoped capture installs the logger and the current bar" begin
        node = log_node()
        Logging.with_logger(Logging.NullLogger()) do
            with_progress_logging(node; capture = [:warn]) do
                @test current_bar() === node            # a bare set_postfix! would find it
                @info "not captured"
                @warn "captured"
            end
        end
        @test [e.level for e in active_logs(node)] == [Logging.Warn]
        @test current_bar() === nothing                 # and the scope is unwound again
    end

    @testset "entries expire after the scope's vanish timeout" begin
        node = log_node(vanish = 0.2)
        push_log!(node, Logging.Info, "short lived")
        @test length(active_logs(node)) == 1
        @test active_logs(node)[1].vanish == 0.2
        sleep(0.35)
        @test isempty(active_logs(node))
        # pruned, not merely filtered: the node's buffer itself is emptied
        @test isempty(node.logs.entries)
        @test !Progbiotic.has_active_logs(node)

        # expiry is measured against the time it is asked about, so a test can age an
        # entry without sleeping: push_log! hands back the entry it stored
        timed = log_node(vanish = 0.2)
        entry = push_log!(timed, Logging.Info, "measured")
        @test [e.message for e in active_logs(timed, entry.created_at + 0.1)] == ["measured"]
        @test isempty(active_logs(timed, entry.created_at + 0.3))
        @test !Progbiotic.has_active_logs(timed, entry.created_at + 0.3)

        # without a vanish timeout the entry is kept indefinitely
        kept = log_node()
        push_log!(kept, :info, "kept")                     # symbol levels work too
        sleep(0.35)
        @test length(active_logs(kept)) == 1
        @test active_logs(kept)[1].vanish == Inf

        # prune_logs! drops everything that has expired
        pruned = log_node(vanish = 0.1)
        push_log!(pruned, Logging.Warn, "gone soon")
        sleep(0.25)
        prune_logs!(pruned)
        @test isempty(active_logs(pruned))
        @test isempty(pruned.logs.entries)
    end

    @testset "log lines render under their bar" begin
        # a generous timeout here: building a node and drawing the first tree costs more
        # than a tight window would allow, and expiry is checked by aging explicitly below
        node = log_node(vanish = 30.0, title = "log tests")
        push_log!(node, Logging.Info, "rendered info")
        rendered = render_tree(node)
        @test occursin("rendered info", rendered)
        @test occursin("INFO", rendered)
        @test occursin("\e[36m", rendered)                # cyan for @info
        @test count(l -> occursin("INFO", l), split(chomp(rendered), '\n')) == 1

        push_log!(node, Logging.Warn, "rendered warn")
        warn_rendered = render_tree(node)
        @test occursin("rendered warn", warn_rendered)
        @test occursin("\e[33m", warn_rendered)           # yellow for @warn
        # both lines sit under the bar (title + bar + 2 logs)
        @test length(split(chomp(warn_rendered), '\n')) == 4

        # the tree is drawn as of a time it is handed, so an entry can be aged out
        # without waiting for it
        aged = log_node(vanish = 1.0)
        entry = push_log!(aged, Logging.Info, "aged out")
        @test occursin("aged out", render_tree(aged; now_sec = entry.created_at + 0.5))
        @test !occursin("aged out", render_tree(aged; now_sec = entry.created_at + 1.5))
        @test isempty(aged.logs.entries)        # pruned by the render, not just hidden

        # multi-line messages are flattened to a single gutter row
        ml = log_node(vanish = 30.0)
        push_log!(ml, Logging.Info, "first line\nsecond line")
        ml_rendered = render_tree(ml)
        @test occursin("first line second line", ml_rendered)
        @test length(split(chomp(ml_rendered), '\n')) == 2    # bar + 1 log
    end

    @testset "a bar with live logs stays visible" begin
        node = log_node(vanish = 0.4)
        update!(node, 3)                                    # the bar completes
        t0 = time()
        render_tree(node; now_sec = t0)                     # the tick stamps completion
        sleep(0.3)
        entry = push_log!(node, Logging.Info, "lingering")  # outlives the bar's window
        # the bar's own window is over at t0 + 0.4, the record's runs to t0 + 0.7: the
        # live record is what keeps the bar on screen
        live = render_tree(node; now_sec = t0 + 0.5)
        @test occursin("job", live)
        @test occursin("lingering", live)
        # once the record has expired too, the standalone bar goes with it
        @test render_tree(node; now_sec = t0 + 0.8) == ""
        @test isempty(active_logs(node, t0 + 0.8))
        @test entry.vanish == 0.4
    end

    @testset "@progress intercepts the standard logging macros" begin
        node = nothing
        @progress node "Ingesting" total = 5 vanish = 3.0 io = IOBuffer() for i in 1:5
            i == 2 && @info "checkpoint at record $i"
            i == 4 && @warn "malformed record $i"
        end
        entries = active_logs(node)
        @test [e.level for e in entries] == [Logging.Info, Logging.Warn]
        @test entries[1].message == "checkpoint at record 2"
        @test entries[2].message == "malformed record 4"
        @test all(e -> e.vanish == 3.0, entries)    # from the vanish = 3.0 option
    end

    @testset "@progress capture option" begin
        Logging.with_logger(Logging.NullLogger()) do
            node = nothing
            @progress node "Filtered" capture = [:error] vanish = 1.0 io = IOBuffer() for i in 1:3
                @info "goes to the surrounding logger"
                i == 1 && @error "captured"
            end
            entries = active_logs(node)
            @test length(entries) == 1
            @test entries[1].level == Logging.Error

            alias = nothing
            @progress alias "Alias" capture_logs = [:warn] io = IOBuffer() for i in 1:2
                i == 2 && @warn "alias captured"
            end
            @test [e.message for e in active_logs(alias)] == ["alias captured"]

            off = nothing
            @progress off "Off" capture = false io = IOBuffer() for i in 1:3
                @info "not captured"
            end
            @test isempty(active_logs(off))
        end
    end

    @testset "nested scopes capture into the innermost node" begin
        outer = nothing
        inner = nothing
        @progress outer "Outer" vanish = 5.0 io = IOBuffer() for i in 1:2
            @info "outer $i"
            @progress inner "Inner" vanish = 0.5 for j in 1:3
                @info "inner $i.$j"
            end
        end
        outer_entries = active_logs(outer)
        @test [e.message for e in outer_entries] == ["outer 1", "outer 2"]
        @test all(e -> e.vanish == 5.0, outer_entries)
        @test all(e -> !startswith(e.message, "inner"), outer_entries)

        # the inner level rebinds its name every iteration, so this is the last one
        inner_entries = active_logs(inner)
        @test [e.message for e in inner_entries] == ["inner 2.1", "inner 2.2", "inner 2.3"]
        @test all(e -> e.vanish == 0.5, inner_entries)
        @test inner.parent === outer                # one tree: a child holds its parent
        @test Progbiotic.root_of(inner) === outer
    end

    @testset "block-form scopes capture logs" begin
        blk = nothing
        @progress blk "Block" vanish = 2.0 io = IOBuffer() begin
            @info "inside the block"
        end
        @test [e.message for e in active_logs(blk)] == ["inside the block"]
        @test active_logs(blk)[1].vanish == 2.0
    end

    @testset "with=ctx subroutines capture into the active node" begin
        function log_subtask(subctx, n)
            @progress with = subctx "subtask" vanish = 1.0 for k in 1:n
                k == 1 && @info "from the subroutine"
            end
        end
        node = nothing
        @progress node "Outer" io = IOBuffer() for i in 1:2
            log_subtask(node, 2)
        end
        @test isempty(active_logs(node))            # the outer bar owns no logs

        subtasks = children(node)
        @test length(subtasks) == 2
        @test all(sub -> sub.parent === node, subtasks)
        entries = reduce(vcat, (active_logs(sub) for sub in subtasks))
        @test length(entries) == 2
        @test all(e -> occursin("from the subroutine", e.message), entries)
        @test all(e -> e.vanish == 1.0, entries)
    end

    @testset "thread-safe capture under Threads.@threads" begin
        n = 200
        node = nothing
        @progress node "Threaded" io = IOBuffer() Base.Threads.@threads for i in 1:n
            @info "threaded $i"
        end
        entries = active_logs(node)
        @test length(entries) == n
        @test length(unique(e.message for e in entries)) == n
    end
end
