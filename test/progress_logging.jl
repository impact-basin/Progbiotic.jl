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
        bar = ProgressContext(10; desc = "logs", io = IOBuffer(), tty = true, vanish = 30.0)
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
    end

    @testset "records expire after the vanish timeout" begin
        bar = ProgressContext(10; desc = "expiring", io = IOBuffer(), tty = true,
                              vanish = 0.15)
        push_log!(bar, Logging.Info, "short lived")
        @test length(active_logs(bar)) == 1
        @test Progbiotic.has_active_logs(bar)
        sleep(0.35)
        @test isempty(active_logs(bar))
        @test !Progbiotic.has_active_logs(bar)
        # the record is gone from the drawn block too, leaving only the bar
        @test length(render_block(bar)) == 1

        # vanish = false keeps everything: nothing ever expires
        forever = ProgressContext(10; desc = "permanent", io = IOBuffer(), tty = true,
                                  vanish = false)
        push_log!(forever, Logging.Info, "still here")
        sleep(0.2)
        @test length(active_logs(forever)) == 1
    end

    @testset "log_file keeps records permanently" begin
        directory = mktempdir()
        path = joinpath(directory, "train.log")
        bar = ProgressContext(100; desc = "sink", io = IOBuffer(), tty = true,
                              vanish = 0.1, log_file = path)
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

        # an IO sink is used as given and never closed by us
        stream = IOBuffer()
        streamed = ProgressContext(10; desc = "stream sink", io = IOBuffer(),
                                   tty = true, vanish = 0.0, log_file = stream)
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
        @test ProgressContext(10; io = IOBuffer()).tty == false
        @test ProgressContext(10; io = IOBuffer(), tty = true).tty == true

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
        state = ProgressContext(200; desc = "flat", io = IOBuffer(), tty = false)
        state.state.current[] = 100
        state.state.start = time() - 10.0
        state.state.last_update = time()
        set_postfix!(state; loss = 0.25)
        line = render_flat_line(state)
        @test occursin("[INFO] flat 50% (100/200)", line)
        @test occursin("10.0 it/s", line)
        @test occursin("ETA 00:00:10", line)
        @test occursin("[loss=0.25]", line)

        withenv("CI" => "true") do
            @test Progbiotic._ci_environment()
        end
        withenv("CI" => "") do
            @test !Progbiotic._ci_environment()
        end
    end

    @testset "log capture scopes" begin
        bar = ProgressContext(10; desc = "scope", io = IOBuffer(), tty = true, vanish = 30.0)
        with_progress_logging(bar) do
            @info "captured inside the scope"
            set_postfix!(; loss = 0.5)
        end
        entries = active_logs(bar)
        @test length(entries) == 1
        @test entries[1].message == "captured inside the scope"
        @test entries[1].level == Logging.Info
        @test occursin("loss=0.5", render_column(Postfix(), bar.state))
        # the target is restored once the scope exits
        @test current_progress_target() === nothing
    end

    @testset "capture filtering and pass-through" begin
        bar = ProgressContext(10; desc = "filtered", io = IOBuffer(), tty = true, vanish = 30.0)
        with_progress_logging(bar; capture = [:warn, :error]) do
            @info "goes to the ordinary logger"
            @warn "captured"
        end
        entries = active_logs(bar)
        @test length(entries) == 1
        @test entries[1].level == Logging.Warn

        silent = ProgressContext(10; desc = "off", io = IOBuffer(), tty = true, vanish = 30.0)
        with_progress_logging(silent; capture = false) do
            @info "not captured"
        end
        @test isempty(active_logs(silent))
    end

    @testset "thread-safe capture" begin
        bar = ProgressContext(1000; desc = "threaded logs", io = IOBuffer(), tty = true,
                              vanish = 300.0)
        with_progress_logging(bar) do
            Base.Threads.@threads for i in 1:200
                @info "threaded " * string(i)
            end
        end
        entries = active_logs(bar)
        @test length(entries) == 200
        @test length(unique(entry.message for entry in entries)) == 200
    end

    @testset "global capture reaches a bare handle" begin
        @test log_capture_enabled()
        bar = Progress(10; desc = "global", io = IOBuffer(), tty = false, vanish = 60.0)
        @info "captured by the active bar"
        @warn "also captured"
        entries = active_logs(bar.ctx)
        @test length(entries) == 2
        @test occursin("captured by the active bar", entries[1].message)
        @test entries[1].level == Logging.Info
        @test entries[2].level == Logging.Warn
        @test occursin("also captured", join(render_block(bar.ctx), "\n"))
        finish!(bar; wait = true)

        # with no bar running, records are ordinary again and nothing is buffered
        @test current_active_context() === nothing

        # the layer can be switched off and back on
        @test disable_log_capture!()
        @test !log_capture_enabled()
        @test !disable_log_capture!()
        @test enable_log_capture!()
        @test log_capture_enabled()
    end

    @testset "bare prog loops intercept logs" begin
        wrapped = prog(1:4; desc = "global iterator", io = IOBuffer(), tty = false,
                       vanish = 60.0)
        for x in wrapped
            x == 2 && @info "from the loop body"
        end
        @test occursin("from the loop body", join(render_block(wrapped.ctx), "\n"))
    end

    @testset "ProgressLogging records drive the bar" begin
        bar = ProgressContext(10; desc = "pl", io = IOBuffer(), tty = true, vanish = 30.0)
        logger = ProgbioticLogger(bar)
        Logging.with_logger(logger) do
            @info "pl" progress = 0.5
        end
        @test bar.state.current[] == 5
        @test occursin("progress=0.5", render_column(Postfix(), bar.state))
        # a progress record is state, not history: it produces no log line
        @test isempty(active_logs(bar))

        # the older underscore-prefixed spelling is understood too
        Logging.with_logger(logger) do
            @info "pl" _progress = 1.0
        end
        @test bar.state.current[] == 10

        # the ProgressLogging message shape (a struct carrying fraction/name/done)
        named = ProgressContext(10; desc = "", io = IOBuffer(), tty = true, vanish = 30.0)
        Logging.with_logger(ProgbioticLogger(named)) do
            @logmsg Logging.LogLevel(-1) FakeProgressRecord(0.3, "from progress log", false, 1)
        end
        @test named.state.current[] == 3
        @test named.state.desc[] == "from progress log"
        @test occursin("from progress log", render_frame(named))

        done = ProgressContext(10; desc = "finishing", io = IOBuffer(), tty = true, vanish = 30.0)
        Logging.with_logger(ProgbioticLogger(done)) do
            @logmsg Logging.LogLevel(-1) FakeProgressRecord(nothing, "finishing", true, 2)
        end
        @test done.state.current[] == 10
    end
end
