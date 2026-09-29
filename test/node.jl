using Progbiotic
using Progbiotic: render_column
using Test


@testset "node.jl" begin
    @testset "Tag pads to a width when asked" begin
        s = BarState(100; desc = "Short")
        s.current[] = 42
        s.last_update = s.start + 1.0

        @test render_column(Tag("{desc}"), s) == "Short"
        @test render_column(Tag("{desc}"; width = 14), s) == "Short         "
        @test length(render_column(Tag("{desc}"; width = 14), s)) == 14

        # a label longer than its column is not truncated
        long = BarState(1; desc = "a very long description indeed")
        @test render_column(Tag("{desc}"; width = 4), long) == "a very long description indeed"

        # width still applies to interpolated templates
        @test render_column(Tag("{n}/{total}"; width = 10), s) == "42/100    "
        @test render_column(Tag(; width = 6), s) == "Short "
    end

    @testset "theme_layout carries the width into the label column" begin
        unpadded = theme_layout(AMBER)
        padded   = theme_layout(AMBER; desc_width = 20)

        @test any(c -> c isa Tag && c.width == 0, unpadded)
        @test any(c -> c isa Tag && c.width == 20, padded)
        @test length(unpadded) == length(padded)

        # the rest of the layout is the same either way
        @test typeof(unpadded[3]) == typeof(padded[3])

        # the bar width is a parameter too, so the engine can measure one for a tree
        @test theme_layout(AMBER)[3].width == 30
        @test theme_layout(AMBER; width = 12)[3].width == 12
    end

    @testset "supporting types start empty" begin
        @test isempty(Progbiotic.LogBuf().entries)

        p = Progbiotic.Paint()
        @test (p.count, p.flat_pct, p.last_flat, p.completed_at) == (0, -1, 0.0, 0.0)

        r = Progbiotic.RootState()
        @test r.task === nothing
        @test !r.running[]
        @test r.rows == 0
        @test r.title == ""
        @test r.final_depth == 0
        @test r.style == :round
        @test r.child_vanish == 1.0
        @test r.sink === nothing
        @test r.dest === nothing
    end

    @testset "a node starts empty and knows its tree" begin
        root = Progbiotic.Progress(nothing; desc = "root", io = IOBuffer(), tty = false,
                                   vanish = 0.0)
        @test isempty(children(root))
        @test root.parent === nothing
        @test root.kind === :bar
        @test root_of(root) === root
        @test node_depth(root) == 0
        @test root.state.desc[] == "root"

        kid = child(root, 5; desc = "kid")
        @test length(children(root)) == 1
        @test children(root)[1] === kid
        @test kid.parent === root
        @test root_of(kid) === root
        @test node_depth(kid) == 1
        @test kid.root === root.root
        @test kid.io === root.io

        # children() hands back a copy, so a caller cannot corrupt the tree with it
        copy_of_children = children(root)
        push!(copy_of_children, root)
        @test length(children(root)) == 1
    end

    @testset "a child inherits what it is not given" begin
        root = Progbiotic.Progress(nothing; theme = OCEAN, io = IOBuffer(), tty = false,
                                   vanish = 0.5, child_vanish = 0.25)
        @test child(root, 1).theme === OCEAN
        @test child(root, 1; theme = NEON).theme === NEON
        @test child(root, 1).opts.vanish == 0.25          # the tree default
        @test child(root, 1; vanish = 2.0).opts.vanish == 2.0
        @test child(root, 1; vanish = false).opts.vanish == Inf
        @test child(root, 1).opts.dt == root.opts.dt
        @test child(root, 1).opts.tty == root.opts.tty
    end

    @testset "kinds are validated" begin
        @test_throws ProgbioticError Progbiotic.Progress(1; io = IOBuffer(), kind = :nope)
        root = Progbiotic.Progress(1; io = IOBuffer(), tty = false, vanish = 0.0)
        milestone = child(root, nothing; desc = "step", kind = :milestone)
        @test Progbiotic.ismilestone(milestone)
        @test !Progbiotic.iscontainer(milestone)
        @test !Progbiotic.ismilestone(root)
        @test_throws ProgbioticError child(root, 1; kind = :nope)
    end

    @testset "an indeterminate node is one unit of work" begin
        root = Progbiotic.Progress(nothing; desc = "milestone", io = IOBuffer(),
                                   tty = false, vanish = 0.0)
        @test !Progbiotic._completed(root)
        finish!(root; wait = true)
        @test Progbiotic._completed(root)
        @test isfinished(root)
    end

    @testset "vanish resolves the same way everywhere" begin
        @test Progbiotic._resolve_vanish(nothing) == Inf
        @test Progbiotic._resolve_vanish(false) == Inf
        @test Progbiotic._resolve_vanish(true) == 1.0
        @test Progbiotic._resolve_vanish(2) == 2.0
        @test Progbiotic._resolve_vanish(0.0) == 0.0
        @test_throws ProgbioticError Progbiotic._resolve_vanish(-1)
        @test_throws ProgbioticError Progbiotic._resolve_vanish("soon")
    end

    @testset "show names the bar and its shape" begin
        root = Progbiotic.Progress(10; desc = "handle", io = IOBuffer(), tty = false,
                                   vanish = 0.0, start = false)
        text = sprint(show, root)
        @test occursin("Progress", text)
        @test occursin("handle", text)
        @test occursin("0/10", text)
        @test occursin("running", text)

        child(root, 5; desc = "kid")
        @test occursin("1 children", sprint(show, root))
    end
end
