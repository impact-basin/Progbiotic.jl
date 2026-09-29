using Progbiotic
using Test

# the README's feature tour, exercised end to end. every bar draws into a throwaway
# buffer, so the tour never scribbles on the suite's output.

@testset "features.jl" begin
    # 1. zero-boilerplate iterator interface
    @testset "inferred length and unbounded streams" begin
        wrapped = prog(1:1000; desc = "Parsing Records", vanish = 2.0, io = IOBuffer())
        @test pbtotal(wrapped) == 1000        # the length is inferred from the collection

        seen = 0
        for record in wrapped
            seen += 1
        end
        @test seen == 1000
        @test pbdone(wrapped) == 1000

        # an unbounded source has no length to infer, so it gets a spinner instead of a
        # percentage that would be a lie
        data_stream = Channel(ch -> foreach(i -> put!(ch, i), 1:500))
        streamed    = prog(data_stream; desc = "Streaming Input", io = IOBuffer())
        @test pbtotal(streamed) === nothing

        items = 0
        for item in streamed
            items += 1
        end
        @test items == 500
    end

    # 2. dynamic postfix metrics
    @testset "postfix metrics" begin
        bar = Ref{Any}(nothing)

        @progress "Model Training" total=100 vanish=3.0 io=IOBuffer() for epoch in 1:100
            bar[] = current_bar()
            loss  = 1.0 / epoch
            acc   = 0.5 + (epoch / 200)

            # update inline key-value indicators on the active progress line
            set_postfix!(loss = round(loss, digits = 4), accuracy = "$(round(acc * 100, digits = 1))%")
        end

        line = plain(render_frame(bar[]))
        @test occursin("loss=", line)             # the metrics are state on the bar's line
        @test occursin("accuracy=", line)
    end

    # 3. modular column layouts
    @testset "custom column layout" begin
        my_layout = (
            Spinner(:dots),
            Tag("{desc}"),
            Bar(; fill = '█', empty = '░', width = 36),
            Percent(),
            Count(),
            Rate(unit = "it/s"),
            Eta(),
            Postfix(),
        )

        p = Progress(100; layout = my_layout, desc = "Custom Pipeline", vanish = 0.0,
                     io = IOBuffer(), tty = false, start = false)
        for i in 1:100
            next!(p)
        end
        finish!(p)

        line = plain(render_frame(p))
        @test occursin("Custom Pipeline", line)
        @test count(==('█'), line) == 36          # the layout's own bar width is used verbatim
        @test any(frame -> occursin(frame, line), Spinner(:dots).frames)
        @test !occursin("◉", line)                # the AMBER theme's spinner is not in this layout
    end

    # 4. a thread-safe imperative handle
    @testset "thread-safe handle" begin
        p = Progress(10_000; desc = "Parallel Processing", vanish = 1.0,
                     io = IOBuffer(), tty = false, start = false)

        Progbiotic._with_scope(p) do
            Threads.@threads for i in 1:10_000
                # one atomic add, with no lock contention and no lost update
                next!(p)
            end
        end
        finish!(p)

        @test pbdone(p) == 10_000
    end
end
