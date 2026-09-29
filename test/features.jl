using Progbiotic
using Logging

# ==============================================================================
# 1. Zero-Boilerplate Iterator & Unbounded Spinner Interface
# ==============================================================================

# Inferred length from collection
for record in prog(1:1000; desc="Parsing Records", vanish=2.0)
    # Automatically tracks step progress and infers total=1000
end

# Unbounded stream / channel (automatically displays a spinner)
data_stream = Channel(ch -> foreach(i -> put!(ch, i), 1:500))

for item in prog(data_stream; desc="Streaming Input")
    # Spinner rotates until channel closes
end

# ==============================================================================
# 2. Dynamic Postfix Metrics & Dynamic Logging Sinks
# ==============================================================================

# Real-time state metrics without creating log line clutter
@progress "Model Training" total=100 vanish=3.0 log_file="train.log" for epoch in 1:100
    loss = 1.0 / epoch
    acc = 0.5 + (epoch / 200)
    
    # Update inline key-value indicators on the active progress line
    set_postfix!(loss=round(loss, digits=4), accuracy="$(round(acc*100, digits=1))%")
    
    if epoch % 25 == 0
        # Transients show in terminal under bar for 3.0s, but permanently append to train.log
        @info "Checkpoint saved at epoch $epoch"
    end
end

# ==============================================================================
# 3. Modular Column Layouts & Persistent Sinks
# ==============================================================================

# Define a custom visual pipeline
my_layout = [
    SpinnerColumn(:dots),
    TextColumn("{desc}"),
    BarColumn(fill='█', empty='░', width=30),
    PercentageColumn(),
    RateColumn(unit="it/s"),
    ETAColumn(),
    PostfixColumn()
]

p = Progress(100; layout=my_layout, desc="Custom Pipeline", vanish=0.0)
for i in 1:100
    sleep(0.01)
    next!(p)
end
finish!(p)

# ==============================================================================
# 4. Multi-threaded Parallel Execution & Imperative Handles
# ==============================================================================

# Thread-safe atomic counter updates inside Threads.@threads
p_parallel = Progress(10_000; desc="Parallel Processing", vanish=1.0)

Threads.@threads for i in 1:10_000
    # Thread-safe increment with zero lock contention
    next!(p_parallel)
    
    if i == 5000
        # Safe concurrent log interception
        @warn "Halfway mark reached on thread $(Threads.threadid())"
    end
end
finish!(p_parallel)
