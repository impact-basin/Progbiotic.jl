using Progbiotic
using Test

# shared by the files below. A throwaway bar writes nowhere and never leaves a render
# task chewing on the suite's output, and plain() drops the colours from a line for the
# assertions that do not care about them.
sink() = IOBuffer()
plain(text) = replace(text, r"\e\[[0-9;]*m" => "")

@testset "Progbiotic.jl" begin
    @testset "a node with no children is a standalone bar" begin
        bar = Progress(10; desc = "Test standalone", theme = AMBER, io = IOBuffer(),
                       tty = false, vanish = 0.0)
        @test pbtotal(bar) == 10
        @test pbdone(bar) == 0
        @test isempty(children(bar))
        @test bar.parent === nothing
        next!(bar)
        @test pbdone(bar) == 1
        finish!(bar; wait = true)
    end

    @testset "child hangs a node under another" begin
        root = Progress(5; desc = "Root Pipeline", io = IOBuffer(), tty = false,
                        vanish = 0.0, child_vanish = 0.0)
        @test root.root.title == ""
        @test root.opts.vanish == 0.0

        j1 = child(root, 5; desc = "Parent Job", theme = OCEAN)
        @test length(children(root)) == 1
        @test root_of(j1) === root
        @test node_depth(j1) == 1

        j2 = child(j1, 10; desc = "Child Job", theme = CYBERPUNK)
        @test length(children(j1)) == 1
        @test node_depth(j2) == 2

        update!(j2, 10)
        @test pbdone(j2) == 10
        @test Progbiotic._completed(j2)

        # finish!(root; wait = true) waits for the render task, and the task lives as long
        # as the tree does, so a root's children are finished before it
        finish!(j2; wait = false)
        finish!(j1; wait = false)
        finish!(root; wait = true)
    end

    @testset "a node is its own context" begin
        root = Progress(nothing; desc = "Context Test", io = IOBuffer(), tty = false,
                        vanish = 0.0)
        parent = child(root, 5; desc = "Main Task")
        sub = child(parent, 4; desc = "Subtask")

        # there is no separate handle to reach through any more: the node the caller
        # holds *is* the bar it advances
        @test sub.parent === parent
        @test root_of(sub) === root
        @test length(children(parent)) == 1

        finish!(sub; wait = false)
        finish!(parent; wait = false)
        finish!(root; wait = true)
    end

    @testset "Tree formatting (no hanging root)" begin
        root = Progress(nothing; desc = "Root Task", io = IOBuffer(), tty = false,
                        vanish = nothing, child_vanish = 0.0)
        kid = child(root, 5; desc = "Child Task")

        lines = split(render_tree(root), '\n'; keepempty = false)
        @test length(lines) == 2
        @test !startswith(lines[1], "╰─")
        @test !startswith(lines[1], "├─")
        @test startswith(lines[2], "╰─")

        finish!(kid; wait = false)
        finish!(root; wait = true)
    end

    @testset "@progress macro basic execution" begin
        counter = 0
        @progress "Simple Loop" for i in 1:5
            counter += 1
        end
        @test counter == 5
    end

    @testset "@progress macro nested with context" begin
        counter = 0
        sub_counter = 0
        @progress ("Outer Loop", OCEAN) for i in 1:2
            counter += 1
            @progress (ctx => ("Inner Loop " * string(i), GLACIER)) for j in 1:3
                sub_counter += 1
            end
        end
        @test counter == 2
        @test sub_counter == 6
    end

    include("bar.jl")
    include("error.jl")
    include("quality.jl")
    include("node.jl")
    include("iterator.jl")
    include("columns.jl")
    include("imperative.jl")
    include("threads.jl")
    include("macros.jl")
    include("progtree.jl")
    include("progressbar.jl")
    include("features.jl")
end
