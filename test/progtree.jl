using ProgBiotic

pbar = ProgBar("Data Pipeline & Model Training"; style=:round)

with_tree_gutter(pbar) do
    # 1. Top-level Task: Download Phase
    download_task = add_job!(pbar, "Download Phase"; total=2, theme=OCEAN)
    
    file1 = add_job!(pbar, "dataset_train.csv"; parent=download_task, total=50, theme=GLACIER)
    for _ in 1:50
        sleep(0.01)
        update!(pbar, file1)
    end
    update!(pbar, download_task)
    
    file2 = add_job!(pbar, "dataset_test.csv"; parent=download_task, total=30, theme=GLACIER)
    for _ in 1:30
        sleep(0.01)
        update!(pbar, file2)
    end
    update!(pbar, download_task)
    
    println("Dataset downloads complete! Proceeding to training...")

    # 2. Top-level Task: Training Epochs
    train_task = add_job!(pbar, "Training Epochs"; total=3, theme=CYBERPUNK)
    
    for epoch in 1:3
        # Sub-job: Batches per epoch
        batch_task = add_job!(pbar, "Epoch $epoch Batches"; parent=train_task, total=25, theme=SYNTHWAVE)
        for b in 1:25
            sleep(0.015)
            update!(pbar, batch_task, b)
        end
        
        println(">> [Epoch $epoch/3] Finished with Loss = $(round(0.45 / epoch, digits=3))")
        update!(pbar, train_task, epoch)
    end
end
