# bar will be rendered as:
# [blinker] [desc] [progress] [eta] 

mutable struct ProgJob{I}
    lock        :: ReentrantLock
    desc        :: String
    state       :: Int
    total       :: Union{Int, Nothing}
    start       :: Float64
    iter        :: I
    theme       :: Theme
    dt          :: Float64
    last_render :: Float64
    io          :: IO

    # Standalone job (no iterator wrapped)                                           
    function ProgJob(                                                                
        desc::String = "";                                                           
        total::Union{Int, Nothing} = nothing,                                        
        theme::Theme = AMBER,                                                        
        dt::Float64 = 0.05,                                                          
        io::IO = stdout                                                              
    )                                                                                
        new{Nothing}(                                                                
            ReentrantLock(), desc, 0, total, time(),                                 
            nothing, theme, dt, 0.0, io                                              
        )                                                                            
    end                                                                              
                                                                                     
    # Iterator-wrapping job: ProgJob(iter, [theme]; desc="...", dt=0.05, io=stdout)  
    function ProgJob(                                                                
        iter::I,                                                                     
        theme::Theme = AMBER;                                                        
        desc::String = "",                                                           
        total::Union{Int, Nothing} = nothing,                                        
        dt::Float64 = 0.05,                                                          
        io::IO = stdout                                                              
    ) where I                                                                        
        tot = total !== nothing ? total : try length(iter) catch; nothing end        
        new{I}(                                                                      
            ReentrantLock(), desc, 0, tot, time(),                                   
            iter, theme, dt, 0.0, io                                                 
        )                                                                            
    end                                                                              
end

function Base.iterate(job::ProgJob)                                                                  
    job.iter === nothing && throw(ArgumentError("This ProgJob does not wrap an iterable."))          
                                                                                                     
    # Reset progress timing and state                                                                
    job.state = 0                                                                                    
    job.start = time()                                                                               
    job.last_render = 0.0                                                                            
                                                                                                     
    # Initial draw (0% or starting spinner)                                                          
    print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))                                 
    flush(job.io)                                                                                    
                                                                                                     
    next = iterate(job.iter)                                                                         
    if next === nothing                                                                              
        # Empty collection: finish immediately                                                       
        print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme), "\n")                       
        flush(job.io)                                                                                
        return nothing                                                                               
    end                                                                                              
                                                                                                     
    item, iter_state = next                                                                          
    job.state = 1                                                                                    
    return (item, iter_state)                                                                        
end                                                                                                  
                                                                                                     
# Subsequent iteration steps                                                                         
function Base.iterate(job::ProgJob, iter_state)                                                      
    next = iterate(job.iter, iter_state)                                                             
                                                                                                     
    if next === nothing                                                                              
        # Reached the end: print final 100% frame and a newline                                      
        print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme), "\n")                       
        flush(job.io)                                                                                
        return nothing                                                                               
    end                                                                                              
                                                                                                     
    item, next_iter_state = next                                                                     
    job.state += 1                                                                                   
                                                                                                     
    # Throttled redraw to maintain high performance in tight loops                                   
    now_sec = time()                                                                                 
    if (now_sec - job.last_render >= job.dt) || (job.total !== nothing && job.state == job.total)    
        print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))                             
        flush(job.io)                                                                                
        job.last_render = now_sec                                                                    
    end                                                                                              
                                                                                                     
    return (item, next_iter_state)                                                                   
end                                                                                                  
                                                                                                     
# Forward iterator traits so ProgJob behaves transparently like the underlying collection            
Base.length(job::ProgJob) = job.total !== nothing ? job.total : length(job.iter)                     
Base.eltype(::Type{ProgJob{I}}) where I = eltype(I)                                                  
Base.size(job::ProgJob{I}) where I = job.total !== nothing ? (job.total,) : size(job.iter)                                                  
Base.IteratorSize(::Type{ProgJob{I}}) where I = Base.IteratorSize(I)                                 
Base.IteratorEltype(::Type{ProgJob{I}}) where I = Base.IteratorEltype(I)                             

# 1. Forward Indexing & Array Bounds Interfaces
Base.firstindex(job::ProgJob) = firstindex(job.iter)
Base.lastindex(job::ProgJob)  = lastindex(job.iter)
Base.eachindex(job::ProgJob)  = eachindex(job.iter)
Base.axes(job::ProgJob)       = axes(job.iter)
Base.keys(job::ProgJob)       = keys(job.iter)

# 2. Thread-safe getindex: updates progress and renders throttled output
function Base.getindex(job::ProgJob, idx...)
    # Retrieve item from underlying collection
    val = getindex(job.iter, idx...)

    # Thread-safe state update & terminal rendering
    @lock job.lock begin
        if job.state == 0
            job.start = time()
            job.last_render = 0.0
            # Optional: Initial 0% draw
            print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))
            flush(job.io)
        end

        job.state += 1

        now_sec = time()
        is_final = (job.total !== nothing && job.state == job.total)
        
        # Render if throttled interval elapsed OR if all items are completed
        if is_final || (now_sec - job.last_render >= job.dt)
            if is_final
                # Print 100% completed bar with final newline
                print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme), "\n")
            else
                print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))
            end
            flush(job.io)
            job.last_render = now_sec
        end
    end

    return val
end

function _ansi_fg(c::Color)
    rgb = RGB(c)
    r = round(Int, Colors.red(rgb) * 255)
    g = round(Int, Colors.green(rgb) * 255)
    b = round(Int, Colors.blue(rgb) * 255)
    return "\e[38;2;$(r);$(g);$(b)m"
end

const _ANSI_RESET = "\e[0m"
const _ANSI_DIM   = "\e[2m"
const _ANSI_BOLD  = "\e[1m"


"""
    render_bar(prog::Float64, t::Theme; width::Int = 40) -> String

Renders a high-resolution progress bar using fractional `barunits` stipple levels.
"""
function _render_bar(prog::Float64, t::Theme; width::Int = 40)
    p = clamp(prog, 0.0, 1.0)
    k = length(t.barunits)
    
    # Sub-character stipple resolution
    total_subunits = round(Int, p * width * k)
    full_chars = div(total_subunits, k)
    rem_subunits = rem(total_subunits, k)

    fg_color = isempty(t.palette) ? "" : _ansi_fg(t.palette[1])
    dim_color = isempty(t.palette) ? _ANSI_DIM : _ansi_fg(t.palette[end])

    # Filled portion
    bar_full = repeat(string(t.barunits[end]), full_chars)
    bar_partial = rem_subunits > 0 ? string(t.barunits[rem_subunits]) : ""
    
    # Empty portion
    empty_count = width - full_chars - (rem_subunits > 0 ? 1 : 0)
    bar_empty = repeat(string(t.empty), max(0, empty_count))

    return string(
        fg_color, bar_full, bar_partial, 
        dim_color, bar_empty, _ANSI_RESET
    )
end

"""
    show_progjob_with_theme(p::ProgJob, t::Theme; bar_width::Int = 40) -> String

Renders the progress job line according to the format:
    `[blinker] [desc] [progress] [eta]`
"""
function show_progjob_with_theme(p::ProgJob, t::Theme; bar_width::Int = 40)
    # Thread-safe snapshot of job state
    desc, state, total, start_time = lock(p.lock) do
        (p.desc, p.state, p.total, p.start)
    end

    now_sec = time()
    elapsed = max(0.0, now_sec - start_time)

    # 1. [Blinker / Spinner] - Cycles through spinner glyphs and palette colors
    spinner_char = isempty(t.spinner) ? '◉' : t.spinner[mod(floor(Int, now_sec * 8), length(t.spinner)) + 1]
    spinner_color = isempty(t.palette) ? "" : _ansi_fg(t.palette[mod(floor(Int, now_sec * 4), length(t.palette)) + 1])
    blinker_str = string(spinner_color, spinner_char, _ANSI_RESET)

    # 2. [Desc]
    desc_str = isempty(desc) ? "" : string(_ANSI_BOLD, desc, _ANSI_RESET, " ")

    # 3. [Progress] & 4. [ETA]
    if total === nothing
        # Indeterminate mode (no total known)
        prog_str = string(_ANSI_DIM, "$state units", _ANSI_RESET)
        eta_str = string(_ANSI_DIM, "(elapsed: ", duration_str(elapsed), ")", _ANSI_RESET)
    else
        # Determinate mode
        prog = total > 0 ? (state / total) : 1.0
        pct = round(Int, prog * 100)
        bar = _render_bar(prog, t; width = bar_width)
        prog_str = "$bar $(lpad(pct, 3))% ($state/$total)"

        if prog >= 1.0
            eta_str = string(_ANSI_DIM, "done in ", duration_str(elapsed), _ANSI_RESET)
        elseif prog > 0.0
            eta_sec = (1.0 - prog) * (elapsed / prog)
            eta_str = string(_ANSI_DIM, "ETA: ", duration_str(eta_sec), _ANSI_RESET)
        else
            eta_str = string(_ANSI_DIM, "ETA: N/A", _ANSI_RESET)
        end
    end

    # Return full rendered line: [blinker] [desc] [progress] [eta]
    return "$blinker_str $desc_str$prog_str $eta_str"
end

function update!(job :: ProgJob, new :: Union{Int, Nothing} = nothing)
    @lock job.lock begin
        if isnothing(new)
            job.state += 1
        else
            job.state = new
        end
    end
end

"""
    with_job(f::Function, iter, pbar::Union{ProgJob, Theme} = AMBER; desc = "", dt = 0.05, io = stdout)

Iterates over `iter`, executing `f(item)` on each element while rendering an animated progress bar.
Returns the collected results of `f(item)` for each element.

# Arguments
- `f::Function`: Callback function executed for each item.
- `iter`: Any iterable collection or generator.
- `pbar`: Either an existing `ProgJob` or a `Theme` (defaults to `AMBER`).
- `desc::String`: Description label for the job.
- `dt::Float64`: Minimum time interval (in seconds) between terminal redraws to prevent I/O bottlenecks.
- `io::IO`: Output stream (defaults to `stdout`).
"""
function with_job(
    f::Function,
    iter,
    pbar::Union{ProgJob, Theme} = AMBER;
    desc::String = "",
    theme::Theme = (pbar isa Theme ? pbar : AMBER),
    dt::Float64 = 0.05,
    io::IO = stdout
)
    # 1. Infer total length if available
    total = try
        length(iter)
    catch
        nothing
    end

    # 2. Initialize or configure the ProgJob
    job = if pbar isa ProgJob
        @lock pbar.lock begin
            if isnothing(pbar.total) && !isnothing(total)
                pbar.total = total
            end
            if !isempty(desc) && isempty(pbar.desc)
                pbar.desc = desc
            end
        end
        pbar
    else
        j = ProgJob(desc)
        j.total = total
        j
    end

    # 3. Pre-allocate results if size is known
    results = total !== nothing ? Vector{Any}(undef, total) : Any[]
    last_render = 0.0

    # Initial draw
    print(io, "\r\e[K", show_progjob_with_theme(job, theme))
    flush(io)

    try
        for (i, item) in enumerate(iter)
            # Execute user payload
            res = f(item)
            if total !== nothing
                results[i] = res
            else
                push!(results, res)
            end

            # Update job state
            update!(job, i)

            # Throttled render (and always render on the final iteration)
            now_sec = time()
            if (now_sec - last_render >= dt) || (total !== nothing && i == total)
                print(io, "\r\e[K", show_progjob_with_theme(job, theme))
                flush(io)
                last_render = now_sec
            end
        end
    finally
        # Final render to ensure 100% status is displayed, followed by a newline
        print(io, "\r\e[K", show_progjob_with_theme(job, theme), "\n")
        flush(io)
    end

    return results
end
