mutable struct ProgBar
    title       :: String
    lock        :: ReentrantLock
    jobs        :: Dict{ProgJob, Union{ProgJob, Nothing}}
    children    :: Dict{Union{ProgJob, Nothing}, Vector{ProgJob}}
    order       :: Vector{ProgJob}
    completed_at    :: Dict{ProgJob, Float64}
    vanish_timeouts :: Dict{ProgJob, Union{Float64, Nothing}}
    default_timeout :: Union{Float64, Nothing}
    style       :: Symbol
    dt          :: Float64
    last_render :: Float64
    io          :: IO
    active      :: Bool

    function ProgBar(
        title::String = "";
        vanish_timeout::Union{Float64, Nothing} = nothing, # e.g. 1.0 or nothing
        style::Symbol = :round,
        dt::Float64 = 0.05,
        io::IO = stdout
    )
        new(
            title,
            ReentrantLock(),
            Dict{ProgJob, Union{ProgJob, Nothing}}(),
            Dict{Union{ProgJob, Nothing}, Vector{ProgJob}}(),
            ProgJob[],
            Dict{ProgJob, Float64}(),
            Dict{ProgJob, Union{Float64, Nothing}}(),
            vanish_timeout,
            style,
            dt,
            0.0,
            io,
            false
        )
    end
end

"""
    add_job!(pbar::ProgBar, iter_or_desc; parent=nothing, desc="", total=nothing, theme=AMBER) -> ProgJob

Adds a job (or sub-job if `parent` is specified) to the `ProgBar` hierarchy.
"""
function add_job!(
    pbar::ProgBar,
    iter_or_desc;
    parent::Union{ProgJob, Nothing} = nothing,
    desc::String = "",
    total::Union{Int, Nothing} = nothing,
    theme::Theme = AMBER,

    vanish::Bool = (pbar.default_timeout !== nothing),
    vanish_timeout::Union{Float64, Nothing} = (vanish ? (pbar.default_timeout !==
  nothing ? pbar.default_timeout : 1.0) : nothing),
    dt::Float64 = pbar.dt,
    io::IO = pbar.io
)
    # Default child theme to parent theme if not explicitly changed
    actual_theme = (theme === AMBER && parent !== nothing) ? parent.theme : theme

    job = if iter_or_desc isa AbstractString
        ProgJob(iter_or_desc; total=total, theme=actual_theme, dt=dt, io=io)
    else
        ProgJob(iter_or_desc, actual_theme; desc=desc, total=total, dt=dt, io=io)
    end

    @lock pbar.lock begin
        pbar.jobs[job] = parent
        ch = get!(pbar.children, parent, ProgJob[])
        push!(ch, job)
        push!(pbar.order, job)
        pbar.vanish_timeouts[job] = vanish_timeout
    end

    if pbar.active
        print_progbar_in_gutter(pbar; force=true)
    end
    return job
end

function get_children(pbar::ProgBar, parent::Union{ProgJob, Nothing})
    @lock pbar.lock begin
        return copy(get(pbar.children, parent, ProgJob[]))
    end
end


function is_job_visible(pbar::ProgBar, job::ProgJob, now_sec::Float64)
    # 1. If any children are still visible, this parent must stay visible
    children = get_children(pbar, job)
    any_child_visible = any(c -> is_job_visible(pbar, c, now_sec), children)
    any_child_visible && return true

    # 2. If no vanish timeout is set, it stays visible forever
    timeout = get(pbar.vanish_timeouts, job, nothing)
    timeout === nothing && return true

    # 3. Check completion timestamp
    comp_time = get(pbar.completed_at, job, nothing)
    if comp_time === nothing
        @lock job.lock begin
            if job.total !== nothing && job.state >= job.total
                pbar.completed_at[job] = now_sec
            end
        end
        return true
    end

    # 4. Check if within timeout window
    return (now_sec - comp_time) < timeout
end

function get_visible_children(pbar::ProgBar, parent::Union{ProgJob, Nothing},
now_sec::Float64)
    all_children = get_children(pbar, parent)
    return filter(j -> is_job_visible(pbar, j, now_sec), all_children)
end

"""
    render_progbar_tree(pbar::ProgBar; bar_width=25) -> String

Renders the full job hierarchy as a formatted tree string.
"""
function render_progbar_tree(pbar::ProgBar; bar_width::Int = 40)
    syms = get(TREE_STRS, pbar.style) do
        TREE_STRS[:round]
    end
    buf = IOBuffer()
    now_sec = time()

    top_jobs = get_visible_children(pbar, nothing, now_sec)

    if !isempty(pbar.title)
        # Titled tree: The title serves as the root header, top-level jobs branch under it
        println(buf, _ANSI_BOLD, pbar.title, _ANSI_RESET)
        _render_job_nodes(buf, pbar, top_jobs, "", syms, bar_width, now_sec)
    elseif length(top_jobs) == 1
        # Untitled single root job: Display the root job flush (no hanging branch prefix)
        root_job = top_jobs[1]
        job_rendered = show_progjob_with_theme(root_job, root_job.theme; bar_width = bar_width)
        println(buf, job_rendered)

        # Children branch directly from the root
        children = get_visible_children(pbar, root_job, now_sec)
        if !isempty(children)
            _render_job_nodes(buf, pbar, children, "", syms, bar_width, now_sec)
        end
    else
        # Untitled multiple top-level jobs: Display with standard branch prefixes
        _render_job_nodes(buf, pbar, top_jobs, "", syms, bar_width, now_sec)
    end

    return String(take!(buf))
end

function _render_job_nodes(
    io::IO,
    pbar::ProgBar,
    jobs::Vector{ProgJob},
    prefix::String,
    syms::Dict{Symbol, String},
    bar_width::Int,
    now_sec::Float64
)
    n = length(jobs)
    for (i, job) in enumerate(jobs)
        is_last = (i == n)
        branch = is_last ? syms[:term] : syms[:leaf]
        extension = is_last ? syms[:nada] : syms[:line]

        job_rendered = show_progjob_with_theme(job, job.theme; bar_width = bar_width)
        println(io, prefix, branch, job_rendered)

        children = get_visible_children(pbar, job, now_sec)
        if !isempty(children)
            _render_job_nodes(io, pbar, children, prefix * extension, syms, bar_width, now_sec)
        end
    end
end

"""
    print_progbar_in_gutter(pbar::ProgBar; force=false)

Renders the tree of progress bars dynamically into the bottom terminal gutter.
"""
function print_progbar_in_gutter(pbar::ProgBar; io::IO = pbar.io, force::Bool = false)
    now_sec = time()
    if !force && (now_sec - pbar.last_render < pbar.dt)
        return
    end

    @lock pbar.lock begin
        tree_str = render_progbar_tree(pbar)
        tree_height = count(==('\n'), tree_str)

        term_height, term_width = displaysize(io)
        scroll_bottom = max(1, term_height - tree_height)
        gutter_start = scroll_bottom + 1

        # 1. Update scrolling region to leave room for the gutter
        print(io, "\e[1;", scroll_bottom, "r")

        # 2. Position cursor in gutter and draw tree
        print(io, "\e[", gutter_start, ";1H")
        print(io, "\e[J")
        print(io, tree_str)

        # 3. Restore cursor position to the active scroll area
        print(io, "\e[", scroll_bottom, ";1H")
        flush(io)

        pbar.last_render = now_sec
    end
end

"""
    update!(pbar::ProgBar, job::ProgJob, [new_state])

Updates a specific job's progress in the tree and refreshes the gutter display.
"""
function update!(pbar::ProgBar, job::ProgJob, new::Union{Int, Nothing} = nothing)
    @lock job.lock begin
        if isnothing(new)
            job.state += 1
        else
            job.state = new
        end
        # Record completion timestamp on first completion
        if job.total !== nothing && job.state >= job.total && !haskey(pbar.
completed_at, job)
            pbar.completed_at[job] = time()
        end
    end
    print_progbar_in_gutter(pbar)
end



"""
    with_tree_gutter(f::Function, pbar::ProgBar; io=stdout)

Executes `f()` while maintaining the dynamic tree gutter at the bottom.
Restores the terminal scroll margin upon completion.
"""
function with_tree_gutter(f::Function, pbar::ProgBar; io::IO = pbar.io)
    pbar.active = true
    pbar.io = io
    print_progbar_in_gutter(pbar; force=true)

    term_height, _ = displaysize(io)
    try
        f()
    finally
        pbar.active = false
        print_progbar_in_gutter(pbar; force=true)
        # Reset scroll region and move cursor to the end
        print(io, "\e[r")
        print(io, "\e[", term_height, ";1H\n")
        flush(io)
    end
end

# Base container & iterator interfaces for ProgBar
Base.length(pbar::ProgBar) = length(pbar.order)
Base.iterate(pbar::ProgBar, state=1) = state > length(pbar.order) ? nothing : (pbar.order[state], state + 1)
Base.eltype(::Type{ProgBar}) = ProgJob
Base.keys(pbar::ProgBar) = keys(pbar.jobs)
Base.firstindex(pbar::ProgBar) = 1
Base.lastindex(pbar::ProgBar) = length(pbar.order)
Base.getindex(pbar::ProgBar, i::Int) = pbar.order[i]

"""
    ProgContext(pbar::ProgBar, parent::Union{ProgJob, Nothing})

Hierarchical context handle for passing a progress bar and its active parent node to subroutines.
"""
struct ProgContext
    pbar   :: ProgBar
    parent :: Union{ProgJob, Nothing}
end

# Forward helper methods so subroutines can interact directly with the context
add_job!(ctx::ProgContext, iter_or_desc; parent=ctx.parent, kwargs...) =
    add_job!(ctx.pbar, iter_or_desc; parent=parent, kwargs...)

update!(ctx::ProgContext, args...) = update!(ctx.pbar, args...)
print_progbar_in_gutter(ctx::ProgContext; kwargs...) = print_progbar_in_gutter(ctx.pbar; kwargs...)
