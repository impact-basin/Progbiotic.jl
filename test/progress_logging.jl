using Progbiotic
using Test
using Logging

"""A message type shaped like ProgressLogging.Progress, so the protocol can be
exercised without taking a dependency on ProgressLogging itself."""
struct FakeProgressRecord
    fraction :: Union{Float64, Nothing}
    name     :: String
    done     :: Bool
    id       :: Int
end

@testset "progress_logging.jl" begin
    @testset "log lines are drawn beneath the bar" begin
        bar = Progress(10; desc = "logs", io = IOBuffer(), tty = true, vanish = 30.0,
                       start = false)
        push_log!(bar, Logging.Info, "line one")
        push_log!(bar, Logging.Warn, "line two")
        push_log!(bar, :debug, "line three", key = 7)

        block = render_block(bar)
        @test length(block) == 4                 # the bar, then three log lines
        @test occursin("logs", block[1])
        @test occursin("line one", block[2])
        @test occursin("line two", block[3])
        @test occursin("line three", block[4])
        @test occursin("key=7", block[4])        # keyword arguments are kept
        @test occursin("\e[36m", block[2])       # cyan for @info
        @test occursin("\e[33m", block[3])       # yellow for @warn
        @test occursin("\e[34m", block[4])       # blue for @debug
        @test length(active_logs(bar)) == 3
        # and they are drawn by the tree renderer too, under the same bar
        @test occursin("line one", render_tree(bar))
    end

    @testset "records expire after the vanish timeout" begin
        bar = Progress(10; desc = "expiring", io = IOBuffer(), tty = true, vanish = 0.15,
                       start = false)
        push_log!(bar, Logging.Info, "short lived")
        @test length(active_logs(bar)) == 1
        @test Progbiotic.has_active_logs(bar)
        sleep(0.35)
        @test isempty(active_logs(bar))
        @test !Progbiotic.has_active_logs(bar)
        # the record is gone from the drawn block too, leaving only the bar
        @test length(render_block(bar)) == 1

        # vanish = false keeps everything: nothing ever expires
        forever = Progress(10; desc = "permanent", io = IOBuffer(), tty = true,
                           vanish = false, start = false)
        push_log!(forever, Logging.Info, "still here")
        sleep(0.2)
        @test length(active_logs(forever)) == 1
    end

    @testset "log_file keeps records permanently" begin
        directory = mktempdir()
        path = joinpath(directory, "train.log")
        bar = Progress(100; desc = "sink", io = IOBuffer(), tty = true, vanish = 0.1,
                       log_file = path, start = false)
        push_log!(bar, Logging.Info, "checkpoint at epoch 25")
        push_log!(bar, Logging.Warn, "diverging loss")
        push_log!(bar, Logging.Error, "aborting")
        sleep(0.3)
        # gone from the screen ...
        @test isempty(active_logs(bar))
        # ... but permanent on disk, in plain text
        finish!(bar; wait = true)
        contents = read(path, String)
        @test occursin("[INFO] checkpoint at epoch 25", contents)
        @test occursin("[WARN] diverging loss", contents)
        @test occursin("[ERROR] aborting", contents)
        @test !occursin("\e[", contents)
        @test length(split(strip(contents), '\n')) == 3

        # the sink belongs to the tree, not to the node that asked for it: a child's
        # records reach the same file
        tree_path = joinpath(directory, "tree.log")
        root = Progress(10; desc = "tree", io = IOBuffer(), tty = true, vanish = 0.2,
                        log_file = tree_path, start = false)
        kid = child(root, 4; desc = "kid")
        @test kid.root.sink === root.root.sink
        push_log!(kid, Logging.Info, "from the child")
        finish!(root; wait = true)
        @test occursin("[INFO] from the child", read(tree_path, String))

        # an IO sink is used as given and never closed by us
        stream = IOBuffer()
        streamed = Progress(10; desc = "stream sink", io = IOBuffer(), tty = true,
                            vanish = 0.0, log_file = stream, start = false)
        push_log!(streamed, Logging.Info, "to the stream")
        finish!(streamed; wait = true)
        @test occursin("[INFO] to the stream", String(take!(stream)))
        @test isopen(stream)
    end

    @testset "@progress writes its log_file" begin
        path = joinpath(mktempdir(), "macro.log")
        @progress "Ingesting records" total = 4 vanish = 0.0 log_file = path io = IOBuffer() for i in 1:4
            i % 2 == 0 && @info "checkpoint at record " * string(i)
            i == 3 && @warn "malformed record " * string(i)
        end
        contents = read(path, String)
        @test occursin("[INFO] checkpoint at record 2", contents)
        @test occursin("[WARN] malformed record 3", contents)
        @test occursin("[INFO] checkpoint at record 4", contents)
        @test !occursin("\e[", contents)
    end

    @testset "non-interactive output is flat and ANSI-free" begin
        @test Progress(10; io = IOBuffer(), start = false).opts.tty == false
        @test Progress(10; io = IOBuffer(), tty = true, start = false).opts.tty == true

        buffer = IOBuffer()
        bar = Progress(100; desc = "ci job", io = buffer, tty = false, vanish = 0.0,
                       flat_step = 10, threaded = false)
        for _ in 1:100
            next!(bar)
        end
        finish!(bar; wait = true)
        output = String(take!(buffer))
        @test !occursin("\e[", output)
        @test occursin("[INFO] ci job", output)
        @test occursin("100% (100/100)", output)
        @test !occursin("█", output)             # no bar glyph in a log file

        # the flat line carries the rate, the ETA and the postfix
        flat = Progress(200; desc = "flat", io = IOBuffer(), tty = false, start = false)
        now = time()
        flat.state.current[] = 100
        flat.state.start = now - 10.0            # ten seconds of work, exactly
        flat.state.last_update = now
        set_postfix!(flat; loss = 0.25)
        line = render_flat_line(flat)
        @test occursin("[INFO] flat 50% (100/200)", line)
        @test occursin("10.0 it/s", line)
        @test occursin("ETA: 10 s", line)
        @test occursin("[loss=0.25]", line)

        withenv("CI" => "true") do
            @test Progbiotic._ci_environment()
        end
        withenv("CI" => "") do
            @test !Progbiotic._ci_environment()
        end
    end

    @testset "log capture scopes" begin
        bar = Progress(10; desc = "scope", io = IOBuffer(), tty = true, vanish = 30.0,
                       start = false)
        Progbiotic._with_progress_logging(bar) do
            @info "captured inside the scope"
            set_postfix!(; loss = 0.5)
        end
        entries = active_logs(bar)
        @test length(entries) == 1
        @test entries[1].message == "captured inside the scope"
        @test entries[1].level == Logging.Info
        @test occursin("loss=0.5", render_frame(bar))
        # the scope is unwound on exit: no bar stays installed in this task
        @test current_bar() === nothing
    end

    @testset "capture filtering and pass-through" begin
        bar = Progress(10; desc = "filtered", io = IOBuffer(), tty = true, vanish = 30.0,
                       start = false)
        Progbiotic._with_progress_logging(bar; capture = [:warn, :error]) do
            @info "goes to the ordinary logger"
            @warn "captured"
        end
        entries = active_logs(bar)
        @test length(entries) == 1
        @test entries[1].level == Logging.Warn

        silent = Progress(10; desc = "off", io = IOBuffer(), tty = true, vanish = 30.0,
                          start = false)
        Progbiotic._with_progress_logging(silent; capture = false) do
            @info "not captured"
        end
        @test isempty(active_logs(silent))
    end

    @testset "thread-safe capture" begin
        bar = Progress(1000; desc = "threaded logs", io = IOBuffer(), tty = true,
                       vanish = 300.0, start = false)
        Progbiotic._with_progress_logging(bar) do
            Base.Threads.@threads for i in 1:200
                @info "threaded " * string(i)
            end
        end
        entries = active_logs(bar)
        @test length(entries) == 200
        @test length(unique(entry.message for entry in entries)) == 200
    end

    @testset "capture is scoped, never global" begin
        # a bare handle installs nothing process-wide: loading this package must not
        # patch Logging.global_logger, so a record emitted here stays ordinary
        bar = Progress(10; desc = "bare", io = IOBuffer(), tty = false, vanish = 60.0,
                       start = false)
        @info "not captured by a bare handle"
        @warn "also not captured"
        @test isempty(active_logs(bar))
        finish!(bar; wait = true)

        # an explicit scope is what captures
        scoped = Progress(10; desc = "scoped", io = IOBuffer(), tty = false, vanish = 60.0,
                          start = false)
        Progbiotic._with_progress_logging(scoped) do
            @info "captured by the scope"
            @warn "also captured"
        end
        entries = active_logs(scoped)
        @test length(entries) == 2
        @test entries[1].level == Logging.Info
        @test entries[2].level == Logging.Warn
        @test occursin("also captured", join(render_block(scoped), "\n"))
        finish!(scoped; wait = true)
    end

    @testset "a bare prog loop does not intercept logs" begin
        wrapped = prog(1:4; desc = "bare iterator", io = IOBuffer(), tty = false,
                       vanish = 60.0)
        for x in wrapped
            x == 2 && @info "from the loop body"
        end
        @test isempty(active_logs(wrapped.bar))
        finish!(wrapped; wait = true)

        # wrap the same loop in an explicit scope and it is captured
        scoped = prog(1:4; desc = "scoped iterator", io = IOBuffer(), tty = false,
                      vanish = 60.0)
        Progbiotic._with_progress_logging(scoped.bar) do
            for x in scoped
                x == 2 && @info "captured from the loop body"
            end
        end
        @test occursin("captured from the loop body", join(render_block(scoped.bar), "\n"))
        finish!(scoped; wait = true)
    end

    @testset "ProgressLogging records drive the bar" begin
        bar = Progress(10; desc = "pl", io = IOBuffer(), tty = true, vanish = 30.0,
                       start = false)
        logger = ProgbioticLogger(bar)
        Logging.with_logger(logger) do
            @info "pl" progress = 0.5
        end
        @test pbdone(bar) == 5
        @test occursin("progress=0.5", render_frame(bar))
        # a progress record is state, not history: it produces no log line
        @test isempty(active_logs(bar))

        # the older underscore-prefixed spelling is understood too
        Logging.with_logger(logger) do
            @info "pl" _progress = 1.0
        end
        @test pbdone(bar) == 10

        # the ProgressLogging message shape (a struct carrying fraction/name/done)
        named = Progress(10; desc = "", io = IOBuffer(), tty = true, vanish = 30.0,
                         start = false)
        Logging.with_logger(ProgbioticLogger(named)) do
            @logmsg Logging.LogLevel(-1) FakeProgressRecord(0.3, "from progress log", false, 1)
        end
        @test pbdone(named) == 3
        @test named.state.desc[] == "from progress log"
        @test occursin("from progress log", render_frame(named))

        done = Progress(10; desc = "finishing", io = IOBuffer(), tty = true, vanish = 30.0,
                        start = false)
        Logging.with_logger(ProgbioticLogger(done)) do
            @logmsg Logging.LogLevel(-1) FakeProgressRecord(nothing, "finishing", true, 2)
        end
        @test pbdone(done) == 10
    end
end
