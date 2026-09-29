using Progbiotic

# Standard loop with a 2.0-second vanish timeout for both progress bar and transient logs
@progress "Ingesting Records" total=100 vanish=2.0 for i in 1:100
    if i % 25 == 0
        @info "Checkpoint reached at record $i" # Appears below progress bar, vanishes after 2.0s
    elseif i == 87
        @warn "Malformed schema at record $i, applying fallback" # Vanishes after 2.0s
    end
    # ... processing payload ...
end

# When nesting progress scopes, @info, @debug, and @warn calls route to the innermost active progress context.
# Logs inherit the vanish timeout of that specific inner scope.
@progress "Batch Run" total=5 vanish=10.0 for batch in 1:5
    @info "Starting batch $batch" # Attached to outer context (10.0s TTL)

    @progress "Processing Items" total=50 vanish=1.5 for item in 1:50
        if item == 13
            @debug "Cache miss for item $item" # Attached to inner context (1.5s TTL)
        end
        # ... item work ...
    end
    # Inner progress bar completes and vanishes after 1.5s along with its remaining logs
end

# Users can explicitly configure or disable log plumbing on a per-context basis while preserving
# standard Julia log levels (Logging.LogLevel):

# Capture only warnings and errors into the progress UI, letting @info bypass to standard logger
@progress "Reindexing" total=1000 capture=[:warn, :error] vanish=3.0 for id in 1:1000
    @info "Processing $id" # Handled normally by root logger (not captured in UI)
    if id == 404
        @warn "Entity $id missing" # Intercepted and rendered under UI bar for 3.0s
    end
end
