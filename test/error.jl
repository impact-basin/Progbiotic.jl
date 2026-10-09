using Progbiotic
using Test

@testset "error.jl" begin
    @testset "a throwing Progress(f, n) body registers an error, not a completion" begin
        seen = Ref{Any}(nothing)
        caught = try
            Progress(10; desc = "training", io = sink(), tty = false, vanish = 0.0) do p
                seen[] = p
                next!(p); next!(p)
                error("boom")
            end
            nothing
        catch e
            e
        end

        @test caught isa ErrorException
        bar = seen[]
        @test haserror(bar)
        @test !isfinished(bar)
        @test pbdone(bar) == 2                    # not clamped to the total
        @test pberror(bar) isa ErrorInfo
        @test pberror(bar).type === ErrorException
        @test pberror(bar).msg == "boom"
        @test pbfraction(bar) == 0.2              # the fraction survives

        line = plain(render_line(bar))
        @test occursin("ERROR: ErrorException", line)
        @test !occursin("done in", line)
    end

    @testset "an exception in @progress marks every level it unwinds through" begin
        outer = Ref{Any}(nothing)
        inner = Ref{Any}(nothing)
        caught = try
            @progress (o => "outer") io = sink() for i in 1:3
                outer[] = o
                @progress (n => "inner") for j in 1:3
                    inner[] = n
                    j == 2 && error("deep")
                end
            end
            nothing
        catch e
            e
        end

        @test caught isa ErrorException
        @test haserror(outer[])
        @test haserror(inner[])
        @test !isfinished(outer[])
        @test pbdone(inner[]) == 1   # @progress advances after each body, so j == 2 never counted
        @test occursin("ERROR: ErrorException", plain(render_line(inner[])))
    end

    @testset "a throwing prog(f, iter) body registers an error" begin
        seen = Ref{Any}(nothing)
        caught = try
            prog(1:10; desc = "iterate", io = sink(), tty = false) do x
                seen[] = current_bar()
                x == 3 && error("pow")
            end
            nothing
        catch e
            e
        end

        @test caught isa ErrorException
        bar = seen[]
        @test haserror(bar)
        @test !isfinished(bar)
        @test pbdone(bar) == 3
    end

    @testset "a throw in a block marks its in-flight milestone too" begin
        root = Ref{Any}(nothing)
        caught = try
            @progress (c => "pipeline") io = sink() begin
                root[] = c
                @progress "job 1"
                error("block boom")
            end
            nothing
        catch e
            e
        end

        @test caught isa ErrorException
        @test haserror(root[])
        kids = children(root[])
        @test length(kids) == 1
        @test haserror(kids[1])
        @test !isfinished(kids[1])
    end

    @testset "fail! marks a hand-driven bar and finish! does not clamp it" begin
        bar = Progress(10; desc = "manual", io = sink(), tty = false, vanish = 0.0)
        next!(bar)
        fail!(bar, DomainError(1.0, "nope"))

        @test haserror(bar)
        @test !isfinished(bar)
        @test pbdone(bar) == 1
        @test pberror(bar).type === DomainError
        @test occursin("ERROR: DomainError", plain(render_line(bar)))

        finish!(bar; wait = true)
        @test pbdone(bar) == 1                    # the counter stays where the work stopped
        @test haserror(bar)
        @test !isfinished(bar)
    end

    @testset "the first error wins, and a bare type is accepted" begin
        bar = Progress(10; io = sink(), tty = false, vanish = 0.0)
        fail!(bar, ErrorException("first"))
        fail!(bar, DomainError(1.0, "second"))
        @test pberror(bar).type === ErrorException

        typed = Progress(10; io = sink(), tty = false, vanish = 0.0)
        fail!(typed, DomainError)
        @test pberror(typed).type === DomainError
        finish!(bar; wait = true)
        finish!(typed; wait = true)
    end

    @testset "fail! reaches a wrapped iterator's bar" begin
        it = prog(1:10; io = sink(), vanish = 0.0)
        fail!(it, ErrorException("wrapped"))
        @test haserror(it)
        @test haserror(it.bar)
        finish!(it)
    end

    @testset "a snapshot carries the error and does not move with it" begin
        s = BarState(10)
        snap = Progbiotic._snapshot(s)
        @test !haserror(snap)
        @test pberror(snap) === nothing

        fail!(s, ErrorException("later"))
        @test !haserror(snap)
        @test haserror(s)
        @test pberror(s).type === ErrorException
    end

    @testset "the error look: dead spinner, red bar, error time" begin
        s = BarState(10; desc = "x")
        s.current[] = 5
        fail!(s, ErrorException("boom"))

        @test render_column(Spinner(:dots), s) == string(Progbiotic._ERROR_FG, "!", Progbiotic._ANSI_RESET)
        @test render_column(Eta(), s) == "ERROR: ErrorException"
        @test pbfraction(s) == 0.5                 # the fraction is untouched
        @test occursin(Progbiotic._ERROR_FG, render_column(Bar(; width = 10), s))

        plain_fill = plain(render_column(Bar(; width = 10), s))
        @test count(==('█'), plain_fill) == 5   # half of ten, still filled
    end

    @testset "errored bars persist unless ev says otherwise" begin
        now = time()

        persists = Progress(10; io = sink(), tty = false, vanish = 0.1)
        @test persists.opts.error_vanish == Inf
        fail!(persists, ErrorException("x"))
        @test Progbiotic._visible(persists, now + 1000.0)

        own = Progress(10; io = sink(), tty = false, vanish = 0.1, error_vanish = true)
        @test own.opts.error_vanish == 0.1
        fail!(own, ErrorException("x"))
        own.paint.completed_at = now
        @test Progbiotic._visible(own, now + 0.05)
        @test !Progbiotic._visible(own, now + 0.2)

        timed = Progress(10; io = sink(), tty = false, vanish = 5.0, error_vanish = 0.1)
        @test timed.opts.error_vanish == 0.1

        Progbiotic.stop_render!(persists)
        Progbiotic.stop_render!(own)
        Progbiotic.stop_render!(timed)
    end

    @testset "@progress ev is inherited by nested levels" begin
        kid = Ref{Any}(nothing)
        try
            @progress "outer" io = sink() ev = 0.5 for i in 1:2
                @progress (c => "inner") for j in 1:2
                    kid[] = c
                    error("x")
                end
            end
        catch
        end
        @test kid[].opts.error_vanish == 0.5
    end

    @testset "an errored tree comes to rest instead of spinning" begin
        bar = Progress(10; io = sink(), tty = false, vanish = 0.0)
        next!(bar, 3)
        fail!(bar, ErrorException("stop"))
        @test Progbiotic._all_complete(bar, time())
        @test Progbiotic._at_rest(bar)
        finish!(bar; wait = true)
    end

    @testset "a flat run writes the error line" begin
        io = IOBuffer()
        try
            @progress "flat" io = io for i in 1:10
                i == 4 && error("flat boom")
            end
        catch
        end
        text = plain(String(take!(io)))
        @test occursin("ERROR: ErrorException", text)
    end

    @testset "show says errored" begin
        bar = Progress(10; io = sink(), tty = false, vanish = 0.0)
        fail!(bar, ErrorException("x"))
        @test occursin("errored", sprint(show, bar))
        finish!(bar; wait = true)
    end

    @testset "ErrorInfo reads as its type" begin
        @test sprint(show, ErrorInfo(DomainError, "m")) == "ErrorInfo(DomainError)"
    end

    @testset "an uncaught error reproduces the live tree" begin
        innermost = Ref{Any}(nothing)
        try
            @progress (r => "root") io = sink() for i in 1:2
                @progress (a => "alpha $i") for j in 1:2
                    @progress (b => "beta $i-$j") for k in 1:2
                        innermost[] = b
                        k == 1 && error("boom")
                    end
                end
            end
        catch
        end

        root = Progbiotic.root_of(innermost[])
        @test haserror(root)

        rows = Progbiotic._gutter_lines(root, 24, 80)
        @test length(rows) == 3                   # root, alpha, beta, not just the root
        @test any(row -> occursin("beta", plain(row)), rows)

        # a healthy completed tree still collapses to its root
        stable = Progress(1; desc = "stable", io = sink(), tty = false, vanish = Inf,
                          child_vanish = Inf, start = false)
        kid = child(stable, 1; desc = "kid")
        update!(kid, 1)
        update!(stable, 1)
        @test length(Progbiotic._gutter_lines(stable, 24, 80)) == 1
        Progbiotic.stop_render!(stable)
    end

    @testset "a caught failure leaves a frozen red record" begin
        root = Ref{Any}(nothing)
        @progress (o => "outer") io = sink() for i in 1:10
            root[] = o
            try
                @progress "inner" for j in 1:10
                    (i == 5 && j == 5) && error("Bad!")
                    (i == 8 && j == 8) && throw(DomainError(1.0, "bad"))
                end
            catch
                continue
            end
        end

        # the live root completed; the failures live in its records
        @test !haserror(root[])
        @test Progbiotic._completed(root[])

        records = @lock root[].root.lock copy(root[].root.failures)
        @test length(records) == 2
        @test records[1].err isa ErrorException
        @test records[2].err isa DomainError
        @test length(records[1].rows) == 2             # outer, then inner

        outer1 = records[1].rows[1][2]
        outer2 = records[2].rows[1][2]
        @test pbdone(outer1) == 4                      # frozen at the first failure
        @test pbdone(outer2) == 6                      # and at the second
        @test outer1.tainted                           # ancestors draw red
        @test !haserror(outer1)                        # but are not themselves errored

        lines = Progbiotic._gutter_lines(root[], 40, 100)
        @test length(lines) == 5                       # 2 records x 2 rows, plus the live root

        # the tainted outer is red and keeps its time; the failed inner carries the error
        @test occursin(Progbiotic._ERROR_FG, lines[1])
        @test !occursin("ERROR:", plain(lines[1]))
        @test occursin("ERROR: ErrorException", plain(lines[2]))
        @test occursin(Progbiotic._ERROR_FG, lines[3])
        @test occursin("ERROR: DomainError", plain(lines[4]))

        # the live root finished, so it is not red
        @test !occursin(Progbiotic._ERROR_FG, lines[5])
        @test occursin("done in", plain(lines[5]))
    end

    @testset "records fall off the top before the live tree does" begin
        root = Ref{Any}(nothing)
        @progress (o => "outer") io = sink() for i in 1:5
            root[] = o
            try
                @progress "inner" for j in 1:2
                    error("x")
                end
            catch
            end
        end

        # five 2-row records plus the live root, crammed into a 4-row terminal
        lines = Progbiotic._gutter_lines(root[], 4, 100)
        @test length(lines) == 3
        @test occursin("outer", plain(lines[end]))     # the live tree survives the clip
        @test occursin("done in", plain(lines[end]))
    end

    @testset "an uncaught error records one chain, not one per level" begin
        innermost = Ref{Any}(nothing)
        try
            @progress (r => "root") io = sink() for i in 1:2
                @progress (a => "alpha") for j in 1:2
                    @progress (b => "beta") for k in 1:2
                        innermost[] = b
                        error("boom")
                    end
                end
            end
        catch
        end

        root = Progbiotic.root_of(innermost[])
        @test haserror(root)
        @test length(root.root.failures) == 1          # deduped by the exception object

        # an escaped error reproduces the live tree, not the records
        lines = Progbiotic._gutter_lines(root, 40, 100)
        @test length(lines) == 3
        @test all(line -> occursin("ERROR: ErrorException", plain(line)), lines)
    end
end
