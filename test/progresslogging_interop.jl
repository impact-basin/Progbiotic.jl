using Progbiotic
using Test
using Logging

# The real thing: Progbiotic does not depend on ProgressLogging, but it speaks its
# protocol, so a ProgressLogging job drives a Progbiotic bar.
import ProgressLogging

@testset "ProgressLogging.jl interoperability" begin
    @testset "a real ProgressLogging job drives a bar" begin
        bar = ProgressContext(10; desc = "pl", io = IOBuffer(), tty = true, vanish = 60.0)
        Logging.with_logger(ProgbioticLogger(bar)) do
            ProgressLogging.@withprogress name = "pl" begin
                for i in 1:10
                    ProgressLogging.@logprogress i / 10
                end
            end
        end
        @test bar.state.current[] == 10
        @test occursin("progress=", render_column(Postfix(), bar.state))
        # progress records are state, not history
        @test isempty(active_logs(bar))
    end

    @testset "@logprogress with a name" begin
        bar = ProgressContext(4; desc = "", io = IOBuffer(), tty = true, vanish = 60.0)
        Logging.with_logger(ProgbioticLogger(bar)) do
            ProgressLogging.@withprogress name = "named job" begin
                for i in 1:4
                    ProgressLogging.@logprogress i / 4
                end
            end
        end
        @test bar.state.current[] == 4
        @test bar.state.desc[] == "named job"
    end

    @testset "plain progress keyword records" begin
        bar = ProgressContext(8; desc = "kwargs", io = IOBuffer(), tty = true, vanish = 60.0)
        Logging.with_logger(ProgbioticLogger(bar)) do
            @info "kwargs" progress = 0.25
        end
        @test bar.state.current[] == 2

        # indeterminate progress leaves the counter alone but is still consumed
        before = bar.state.current[]
        Logging.with_logger(ProgbioticLogger(bar)) do
            @info "kwargs" progress = nothing
        end
        @test bar.state.current[] == before
        @test isempty(active_logs(bar))

        # "done" completes the bar
        Logging.with_logger(ProgbioticLogger(bar)) do
            @info "kwargs" progress = "done"
        end
        @test bar.state.current[] == 8
    end
end
