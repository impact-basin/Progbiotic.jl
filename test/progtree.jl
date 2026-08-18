using Progbiotic
using Test

@testset "progtree.jl" begin
    @testset "tree construction and updates" begin
        pbar = ProgBar("Data Pipeline & Model Training"; style=:round)
        @test pbar.title == "Data Pipeline & Model Training"
        @test pbar.style == :round

        download_task = add_job!(pbar, "Download Phase"; total=2, theme=OCEAN)
        file1 = add_job!(pbar, "dataset_train.csv"; parent=download_task, total=50, theme=GLACIER)
        for _ in 1:50
            update!(pbar, file1)
        end
        update!(pbar, download_task)
        @test file1.state == 50
        @test download_task.state == 1

        file2 = add_job!(pbar, "dataset_test.csv"; parent=download_task, total=30, theme=GLACIER)
        for _ in 1:30
            update!(pbar, file2)
        end
        update!(pbar, download_task)
        @test file2.state == 30
        @test download_task.state == 2

        train_task = add_job!(pbar, "Training Epochs"; total=3, theme=CYBERPUNK)
        batch_tasks = ProgJob[]
        for epoch in 1:3
            batch_task = add_job!(pbar, "Epoch $epoch Batches"; parent=train_task, total=25, theme=SYNTHWAVE)
            push!(batch_tasks, batch_task)
            for b in 1:25
                update!(pbar, batch_task, b)
            end
            update!(pbar, train_task, epoch)
        end

        @test batch_tasks[end].state == 25
        @test train_task.state == 3

        @test length(pbar) == 7
        @test get_children(pbar, nothing) == [download_task, train_task]
        @test get_children(pbar, download_task) == [file1, file2]
        @test get_children(pbar, train_task) == batch_tasks
        @test all(j.state == j.total for j in pbar)
        @test all(haskey(pbar.completed_at, j) for j in pbar)
    end

    @testset "rendering the tree" begin
        pbar = ProgBar("Data Pipeline"; style=:round)
        root = add_job!(pbar, "Download Phase"; total=2, theme=OCEAN)
        for f in ("dataset_train.csv", "dataset_test.csv")
            job = add_job!(pbar, f; parent=root, total=5, theme=GLACIER)
            for _ in 1:5
                update!(pbar, job)
            end
            update!(pbar, root)
        end

        rendered = render_progbar_tree(pbar)
        lines = split(rendered, '\n'; keepempty=false)
        @test length(lines) == 4            # title + root + 2 children
        @test occursin("Data Pipeline", rendered)
        @test occursin("dataset_train.csv", rendered)
        @test occursin("dataset_test.csv", rendered)
        @test occursin("100%", rendered)
        @test occursin("╰─", rendered)      # round terminator glyph

        cube = ProgBar("Square Tree"; style=:square)
        croot = add_job!(cube, "Root"; total=1)
        update!(cube, croot, 1)
        square_tree = render_progbar_tree(cube)
        @test occursin("└─", square_tree)   # square terminator glyph on real nodes
        @test !occursin("╰─", square_tree)
    end

    @testset "tree gutter smoke" begin
        pbar = ProgBar("Gutter Test")
        root = add_job!(pbar, "Root"; total=2)
        with_tree_gutter(pbar) do
            update!(pbar, root, 1)
            update!(pbar, root, 2)
        end
        @test root.state == 2
    end
end