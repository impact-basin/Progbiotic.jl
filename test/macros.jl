using ProgBiotic

# Subroutine receiving the bound context
function subtask_with_pbar_context(ctx)
    sub = add_job!(ctx, 1:5; desc="Subtask", theme=NEON)
    for _ in 1:5
        sleep(0.01)
        update!(ctx, sub)
    end
end

# 1. Simple loop
@progress "Working on i" for i = 1:10
    sleep(0.02)
end

# 2. Nested with theme and context binding
@progress ("Working on i", AMBER) for i = 1:5
    @progress GLACIER for j = 1:5
        sleep(0.01)
    end
    @progress (pbar => NEON) for k = 1:10
        sleep(0.02)
        subtask_with_pbar_context(pbar) # passes context to subroutine
    end
end

# 3. 3-level deep nested progress tree
@progress ("Outer Pipeline", OCEAN) for i = 1:3
    @progress (stage => ("Stage $i", CYBERPUNK)) for j = 1:5
        @progress "Micro-batch" for k = 1:10
            sleep(0.005)
        end
    end
end


@progress ("Training Pipeline", OCEAN) for epoch in 1:3
    # Inner batch progress bar vanishes 1.0 second after completion
    @progress ("Epoch $epoch Batches", CYBERPUNK, vanish_timeout=1.0) for batch in 1:20
        sleep(0.05)
    end

    # Intermediate logs scroll cleanly above the tree
    println(">> Epoch $epoch completed. Starting next epoch...")
    sleep(1.2) # Pausing slightly demonstrates the inner bar disappearing
end


function download_and_extract(ctx, filename)
    # Child task 1: Download step (vanishes 1.0s after completion)
    dl = add_job!(ctx, "Downloading $filename"; total=20, theme=GLACIER, vanish_timeout=1.0)
    for _ in 1:20
        sleep(0.02)
        update!(ctx, dl)
    end

    # Child task 2: Extract step (vanishes 1.0s after completion)
    ext = add_job!(ctx, "Extracting $filename"; total=15, theme=SYNTHWAVE, vanish_timeout=1.0)
    for _ in 1:15
        sleep(0.02)
        update!(ctx, ext)
    end
end

@progress (ctx => ("Asset Pipeline", AMBER)) for asset in ["models.tar.gz", "textures.zip", "audio.pak"]
    download_and_extract(ctx, asset)
    sleep(1.2) # Gutter shrinks back to just the parent bar between assets
end


@progress ("ETL Pipeline", OCEAN) for dataset_id in 1:2
    # Tier 2: Dataset phase stays visible
    @progress ("Dataset #$dataset_id", GLACIER) for chunk_id in 1:3
        # Tier 3: Individual chunk transforms vanish 1.0s after completion
        @progress ("Chunk $chunk_id Transform", NEON, vanish_timeout=1.0) for step in 1:10
            sleep(0.01)
        end
        sleep(1.1)
    end
end


# Set a global default timeout of 1.0s for all completed child jobs
pbar = ProgBar("Batch Processing"; vanish_timeout=1.0)

with_tree_gutter(pbar) do
    # Main parent job: marked vanish=false so it never disappears
    parent_job = add_job!(pbar, "Overall Progress"; total=3, theme=OCEAN, vanish=false)

    for i in 1:3
        # Child job: inherits the 1.0s default vanish timeout
        worker_job = add_job!(pbar, "Worker Task #$i"; parent=parent_job, total=25, theme=CYBERPUNK)
        
        for step in 1:25
            sleep(0.02)
            update!(pbar, worker_job, step)
        end
        
        update!(pbar, parent_job, i)
        sleep(1.2) # Worker task disappears from the tree gutter
    end
end


# Outer loop is the root of the tree (rendered flush at column 0)
@progress "Data Ingestion Pipeline" for phase in 1:2
    @progress "Reading files" for file in 1:5
        sleep(0.02)
    end
end


# Provides an explicit header title for the whole tree
@progress title="Model Training Pipeline" theme=OCEAN "Epochs" for epoch in 1:3
    @progress ("Epoch $epoch Batches", CYBERPUNK) for batch in 1:20
        sleep(0.01)
    end
end


@progress "Downloading weights" for i in 1:100
    sleep(0.01)
end
