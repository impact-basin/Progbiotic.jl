using Progbiotic
using Test
using Logging

# The real thing: Progbiotic does not depend on ProgressLogging, but it speaks its
# protocol, so a ProgressLogging job drives a Progbiotic bar.
import ProgressLogging

@testset "ProgressLogging.jl interoperability" begin
    @testset "a real ProgressLogging job drives a bar" begin
        bar = Progress(10; desc = "pl", io = IOBuffer(), tty = true, vanish = 60.0,
                       start = false)
        Logging.with_logger(ProgbioticLogger(bar)) do
            ProgressLogging.@withprogress name = "pl" begin
                for i in 1:10
                    ProgressLogging.@logprogress i / 10
                end
            end
        end
        @test pbdone(bar) == 10
        @test occursin("progress=", render_frame(bar))
        # progress records are state, not history
        @test isempty(active_logs(bar))
    end

    @testset "@logprogress with a name" begin
        bar = Progress(4; desc = "", io = IOBuffer(), tty = true, vanish = 60.0,
                       start = false)
        Logging.with_logger(ProgbioticLogger(bar)) do
            ProgressLogging.@withprogress name = "named job" begin
                for i in 1:4
                    ProgressLogging.@logprogress i / 4
                end
            end
        end
        @test pbdone(bar) == 4
        @test bar.state.desc[] == "named job"
        @test occursin("named job", render_frame(bar))
    end

    @testset "plain progress keyword records" begin
        bar = Progress(8; desc = "kwargs", io = IOBuffer(), tty = true, vanish = 60.0,
                       start = false)
        Logging.with_logger(ProgbioticLogger(bar)) do
            @info "kwargs" progress = 0.25
        end
        @test pbdone(bar) == 2

        # indeterminate progress leaves the counter alone but is still consumed
        before = pbdone(bar)
        Logging.with_logger(ProgbioticLogger(bar)) do
            @info "kwargs" progress = nothing
        end
        @test pbdone(bar) == before
        @test isempty(active_logs(bar))

        # "done" completes the bar
        Logging.with_logger(ProgbioticLogger(bar)) do
            @info "kwargs" progress = "done"
        end
        @test pbdone(bar) == 8
    end
end
