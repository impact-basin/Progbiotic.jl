using Progbiotic
using Progbiotic: render_tick!, _draw_tty!, _gutter_lines, _release_gutter!
using Test

# every node at or below one, depth first
function walk(node)
    found = Any[node]
    for kid in children(node)
        append!(found, walk(kid))
    end
    return found
end

@testset "progtree.jl" begin
    @testset "tree construction and updates" begin
        root = Progress(nothing; title = "Data Pipeline & Model Training", style = :round,
                        io = sink(), tty = false, start = false)
        @test root.root.title == "Data Pipeline & Model Training"
        @test root.root.style == :round

        download = child(root, 2; desc = "Download Phase", theme = OCEAN)
        file1    = child(download, 50; desc = "dataset_train.csv", theme = GLACIER)
        for _ in 1:50
            next!(file1)
        end
        next!(download)

        @test pbdone(file1) == 50
        @test pbdone(download) == 1
        @test download.theme === OCEAN
        @test file1.theme === GLACIER

        file2 = child(download, 30; desc = "dataset_test.csv", theme = GLACIER)
        for _ in 1:30
            next!(file2)
        end
        next!(download)

        @test pbdone(file2) == 30
        @test pbdone(download) == 2

        train   = child(root, 3; desc = "Training Epochs", theme = CYBERPUNK)
        batches = Progress[]
        for epoch in 1:3
            batch = child(train, 25; desc = "Epoch $epoch Batches", theme = SYNTHWAVE)
            push!(batches, batch)
            for b in 1:25
                update!(batch, b)
            end
            update!(train, epoch)
        end

        @test pbdone(batches[end]) == 25
        @test pbdone(train) == 3

        # the titled root holds seven descendants, and each level is reachable from its
        # parent: there is no separate job registry to look them up in
        @test length(walk(root)) == 8
        @test children(root) == [download, train]
        @test children(download) == [file1, file2]
        @test children(train) == batches
        @test node_depth(download) == 1
        @test node_depth(batches[end]) == 2

        # every node that has a total reaches it; the title-only root has none to reach
        @test all(n -> Progbiotic._completed(n), walk(root)[2:end])

        # drawing is what notices completion, which is what starts a vanish timer
        render_tick!(root)
        @test file1.paint.completed_at > 0
    end

    @testset "rendering the tree" begin
        root = Progress(2; desc = "Download Phase", title = "Data Pipeline", theme = OCEAN,
                        io = sink(), tty = false, start = false)
        for f in ("dataset_train.csv", "dataset_test.csv")
            kid = child(root, 5; desc = f, theme = GLACIER)
            for _ in 1:5
                next!(kid)
            end
            next!(root)
        end

        rendered = render_tree(root; collapse = false)
        lines    = plain.(split(rendered, '\n'; keepempty = false))
        @test length(lines) == 4            # title + the root bar + 2 children
        @test occursin("Data Pipeline", rendered)
        @test occursin("dataset_train.csv", rendered)
        @test occursin("dataset_test.csv", rendered)
        @test occursin("100%", rendered)
        @test occursin("╰─", rendered)      # round terminator glyph

        # the root branches under the title, and its children branch under the root
        @test lines[1] == "Data Pipeline"
        @test startswith(lines[2], "╰─ ")
        @test startswith(lines[3], "├─ ")
        @test startswith(lines[4], "╰─ ")

        # collapse, the default, drops the subtree of a finished node at final_depth 0
        @test length(split(render_tree(root), '\n'; keepempty = false)) == 2

        cube = Progress(1; desc = "Root", style = :square, io = sink(), tty = false,
                        start = false)
        ckid = child(cube, 1; desc = "kid")
        next!(ckid, 1)
        next!(cube, 1)

        square_tree = plain(render_tree(cube; collapse = false))
        @test occursin("└─", square_tree)   # square terminator glyph on real nodes
        @test !occursin("╰─", square_tree)
    end

    @testset "tree gutter smoke" begin
        io   = sink()
        root = Progress(2; desc = "Gutter Test", io = io, tty = true, start = false)
        kid  = child(root, 2; desc = "kid")
        next!(kid, 1)

        @test _draw_tty!(root)
        @test root.root.rows == 2                       # both rows were claimed

        lines = _gutter_lines(root, 24, 80)
        @test length(lines) == 2
        @test occursin("Gutter Test", plain(lines[1]))
        @test occursin("50%", plain(lines[2]))          # the child's own progress
        @test startswith(plain(lines[2]), "╰─ ")
        @test occursin("\e[1;22r", String(take!(io)))   # a scroll region above the gutter

        next!(kid, 1)
        next!(root, 2)

        @test _draw_tty!(root)
        @test root.root.rows == 1                       # a finished root collapses its child
        @test occursin("100%", plain(_gutter_lines(root, 24, 80)[1]))

        _release_gutter!(root)
        @test root.root.rows == 0
        @test pbdone(root) == 2
    end

    @testset "final_depth collapse" begin
        root = Progress(2; desc = "Stage", title = "Pipeline", final_depth = 1,
                        io = sink(), tty = false, start = false)
        @test root.root.final_depth == 1

        for f in ("a.csv", "b.csv")
            kid = child(root, 3; desc = f)
            for _ in 1:3
                next!(kid)
            end
            next!(root)
        end

        # depth 0: the title and the finished root alone
        root.root.final_depth = 0
        d0 = render_tree(root)
        @test length(split(d0, '\n'; keepempty = false)) == 2
        @test occursin("Stage", d0)
        @test !occursin("a.csv", d0)

        # depth 1, what the tree itself asked for: title + root + direct children
        root.root.final_depth = 1
        d1 = render_tree(root)
        @test length(split(d1, '\n'; keepempty = false)) == 4
        @test occursin("a.csv", d1)

        # depth 2: the same tree, with no grandchildren to retain
        root.root.final_depth = 2
        d2 = render_tree(root)
        @test length(split(d2, '\n'; keepempty = false)) == 4
        @test occursin("b.csv", d2)
    end
end
