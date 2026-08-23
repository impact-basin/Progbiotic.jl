"""
    ProgBar([title=""]; vanish_timeout=nothing, final_depth=0, style=:round, dt=0.05, io=stdout)

Mutable container for a tree of [`ProgJob`](@ref)s, rendered as a live gutter at
the bottom of the terminal.

# Keyword arguments
- `vanish_timeout`: default time (seconds) a completed child bar stays on screen
  before disappearing; `nothing` (the default) keeps completed bars forever.
- `final_depth`: how many levels of children remain visible once a job completes
  (0 keeps only the job itself, 1 also its direct children, ...). Children within
  the retained depth ignore their vanish timeout.
- `style`: tree-drawing style (`:round` or `:square`).
- `dt`: minimum seconds between gutter redraws (throttle).
- `io`: output stream (defaults to `stdout`).

Use [`add_job!`](@ref) to build the tree, [`update!`](@ref) to advance jobs, and
[`with_tree_gutter`](@ref) to pin the tree to the terminal while work runs.
"""
mutable struct ProgBar
    title             :: String
    lock              :: ReentrantLock
    jobs              :: Dict{ProgJob, Union{ProgJob, Nothing}}
    children          :: Dict{Union{ProgJob, Nothing}, Vector{ProgJob}}
    order             :: Vector{ProgJob}
    completed_at      :: Dict{ProgJob, Float64}
    vanish_timeouts   :: Dict{ProgJob, Union{Float64, Nothing}}
    statement_jobs    :: Dict{ProgJob, Nothing}
    container_jobs    :: Dict{ProgJob, Nothing}
    default_timeout   :: Union{Float64, Nothing}
    final_depth       :: Int
    style             :: Symbol
    dt                :: Float64
    last_render       :: Float64
    last_gutter_start :: Int
    io                :: IO
    active            :: Bool

    function ProgBar(title::String = "";
                     vanish_timeout::Union{Float64, Nothing} = nothing, # e.g. 1.0 or nothing
                     final_depth::Int = 0, # how many levels of children to keep once a job completes
                     style::Symbol = :round,
                     dt::Float64 = 0.05,
                     io::IO = stdout)
        new(title,
            ReentrantLock(),
            Dict{ProgJob, Union{ProgJob, Nothing}}(),
            Dict{Union{ProgJob, Nothing}, Vector{ProgJob}}(),
            ProgJob[],
            Dict{ProgJob, Float64}(),
            Dict{ProgJob, Union{Float64, Nothing}}(),
            Dict{ProgJob, Nothing}(),
            Dict{ProgJob, Nothing}(),
            vanish_timeout,
            final_depth,
            style,
            dt,
            0.0,
            typemax(Int),
            io,
            false)
    end
end

"""
    add_job!(pbar::ProgBar, iter_or_desc; parent=nothing, desc="", total=nothing, theme=AMBER) -> ProgJob

Adds a job (or sub-job if `parent` is specified) to the `ProgBar` hierarchy.
`spinner`/`barunits`/`empty`/`caps`/`head` override the theme's glyphs for this job
(as strings or Char vectors); `width` overrides the bar width.
"""
function add_job!(pbar::ProgBar, iter_or_desc;
                  parent::Union{ProgJob, Nothing} = nothing,
                  desc::String = "",
                  total::Union{Int, Nothing} = nothing,
                  theme::Theme = AMBER,
                  spinner = nothing, barunits = nothing, empty = nothing,
                  caps = nothing, head = nothing,
                  width::Union{Nothing, Int} = nothing,
                  vanish::Union{Bool, Nothing} = nothing,
                  vanish_timeout::Union{Float64, Nothing} = nothing,
                  dt::Float64 = pbar.dt,
                  io::IO = pbar.io)
    # Default child theme to parent theme if not explicitly changed
    actual_theme = (theme === AMBER && parent !== nothing) ? parent.theme : theme
    actual_theme = _apply_style(actual_theme, spinner, barunits, empty, caps, head)

    # Resolve the vanish timeout for this job:
    #   * an explicit `vanish_timeout` always wins;
    #   * `vanish=false` keeps the bar on screen forever;
    #   * `vanish=true` falls back to the pbar default (or 1.0);
    #   * otherwise, non-root jobs inherit `pbar.default_timeout` so completed
    #     sub-bars disappear a moment after finishing, while root jobs (the ones
    #     that anchor the tree) stay visible for the whole session.
    timeout = if vanish_timeout !== nothing
        vanish_timeout
    elseif vanish === false
        nothing
    elseif vanish === true
        pbar.default_timeout !== nothing ? pbar.default_timeout : 1.0
    elseif parent !== nothing && pbar.default_timeout !== nothing
        pbar.default_timeout
    else
        nothing
    end

    job = if iter_or_desc isa AbstractString
        ProgJob(iter_or_desc; total=total, theme=actual_theme, width=width, dt=dt, io=io)
    else
        ProgJob(iter_or_desc, actual_theme; desc=desc, total=total, width=width, dt=dt, io=io)
    end

    @lock pbar.lock begin
        pbar.jobs[job] = parent
        ch = get!(pbar.children, parent, ProgJob[])
        push!(ch, job)
        push!(pbar.order, job)
        pbar.vanish_timeouts[job] = timeout
    end

    # Sequential-subtask pattern: registering any new job under `parent` completes
    # that parent's previously pending statement subtasks, so only one subtask
    # shows as active at a time.
    _complete_statement_jobs!(pbar, parent)

    if pbar.active
        print_progbar_in_gutter(pbar; force=true)
    end
    return job
end

# True once a job is done: a determinate job is done at its total; an indeterminate
# job (e.g. a milestone subtask) is done once its finish timestamp is recorded.
function _job_finished(job::ProgJob)
    @lock job.lock begin
        if job.total !== nothing
            return job.state >= job.total
        end
        return job.finish ≈ 0.0 ? false : true
    end
end

# Marks `job` as a milestone container: its total is the number of milestone
# subtasks it contains, and its state tracks how many of them have completed.
function _mark_container!(pbar::ProgBar, job::ProgJob)
    @lock pbar.lock begin
        pbar.container_jobs[job] = nothing
    end
    return nothing
end

# Sets a container's state to the number of completed milestone subtasks.
function _refresh_container_state!(pbar::ProgBar, parent::ProgJob)
    @lock parent.lock begin
        if parent.total !== nothing
            completed = count(c -> haskey(pbar.statement_jobs, c) && _job_finished(c),
                              get_children(pbar, parent))
            parent.state = completed
            parent.last_update = time()
        end
    end
    return nothing
end

# Completes all pending (registered but not yet finished) statement subtasks under
# `parent`. Statement subtasks are created by `@progress "desc"` (no loop/block body).
# If `parent` is a milestone container, its state is advanced to the number of
# completed milestones.
function _complete_statement_jobs!(pbar::ProgBar, parent::Union{ProgJob, Nothing})
    to_complete = @lock pbar.lock begin
        [c for c in get_children(pbar, parent)
         if haskey(pbar.statement_jobs, c) && !_job_finished(c)]
    end
    for c in to_complete
        now = time()
        @lock c.lock begin
            c.finish = now
        end
        @lock pbar.lock begin
            if !haskey(pbar.completed_at, c)
                pbar.completed_at[c] = now
            end
        end
    end
    if !isempty(to_complete) && parent !== nothing && haskey(pbar.container_jobs, parent)
        _refresh_container_state!(pbar, parent)
    end
    return nothing
end

"""
    _statement_job(pbar::ProgBar, parent; desc="", theme=AMBER, vanish=..., vanish_timeout=...) -> ProgJob

Registers a named subtask — the `@progress "desc"` statement form with no loop or
block body — as a child of `parent`. Subtasks have no total of their own: they are
milestones, shown with a spinner and elapsed time, and are "finished" when the
next job registers under the same parent (see `add_job!`) or when the enclosing
progress scope exits (their `finish` timestamp is then recorded).
"""
function _statement_job(pbar::ProgBar, parent::Union{ProgJob, Nothing};
                        desc::String = "", theme::Theme = AMBER,
                        spinner = nothing, barunits = nothing, empty = nothing,
                        caps = nothing, head = nothing,
                        width::Union{Nothing, Int} = nothing,
                        vanish::Union{Bool, Nothing} = nothing,
                        vanish_timeout::Union{Float64, Nothing} = nothing)
    job = add_job!(pbar, desc; parent=parent, theme=theme,
                   spinner=spinner, barunits=barunits, empty=empty,
                   caps=caps, head=head, width=width,
                   vanish=vanish, vanish_timeout=vanish_timeout)
    @lock pbar.lock begin
        pbar.statement_jobs[job] = nothing
    end
    return job
end

"""
    get_children(pbar::ProgBar, parent) -> Vector{ProgJob}

Returns a copy of the direct children of `parent`, or the top-level jobs when
`parent` is `nothing`.
"""
function get_children(pbar::ProgBar, parent::Union{ProgJob, Nothing})
    @lock pbar.lock begin
        return copy(get(pbar.children, parent, ProgJob[]))
    end
end


# Distance of `job` from the top of the tree (roots are at depth 0).
function _job_depth(pbar::ProgBar, job::ProgJob)
    d = 0
    cur = job
    while true
        parent = get(pbar.jobs, cur, nothing)
        parent === nothing && return d
        cur = parent
        d += 1
    end
end

function is_job_visible(pbar::ProgBar, job::ProgJob, now_sec::Float64)
    # 1. If any children are still visible, this parent must stay visible
    children = get_children(pbar, job)
    any_child_visible = any(c -> is_job_visible(pbar, c, now_sec), children)
    any_child_visible && return true

    # 2. Jobs within the configured final depth are retained regardless of their
    #    vanish timeout: `final_depth=N` promises to keep N levels of children.
    _job_depth(pbar, job) <= pbar.final_depth && return true

    # 3. If no vanish timeout is set, it stays visible forever
    timeout = get(pbar.vanish_timeouts, job, nothing)
    timeout === nothing && return true

    # 4. Check completion timestamp
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

# Collects every currently visible job in the tree (depth-first), used to size the
# description column so bars line up across all rows.
function _visible_job_list(pbar::ProgBar, parent::Union{ProgJob, Nothing}, now_sec::Float64)
    jobs = ProgJob[]
    for j in get_visible_children(pbar, parent, now_sec)
        push!(jobs, j)
        append!(jobs, _visible_job_list(pbar, j, now_sec))
    end
    return jobs
end

"""
    render_progbar_tree(pbar::ProgBar; bar_width=40, collapse_completed=false, final_depth=0) -> String

Renders the full job hierarchy as a formatted tree string.

All rows share a fixed-width description column (sized to the longest visible
description) so the bars, rates, and ETAs line up vertically. When
`collapse_completed=true` (used by the live gutter), finished jobs hide their
subtree beyond `final_depth` levels: `final_depth=0` keeps only the job itself,
`final_depth=1` also keeps its direct children, and so on.
"""
function render_progbar_tree(pbar::ProgBar; bar_width::Int = 40, collapse_completed::Bool = false,
                             final_depth::Int = pbar.final_depth)
    syms = get(TREE_STRS, pbar.style) do
        TREE_STRS[:round]
    end
    buf = IOBuffer()
    now_sec = time()

    top_jobs = get_visible_children(pbar, nothing, now_sec)

    # Fixed description column: pad every row to the longest visible description
    # (with a sensible minimum) so the bar column lines up across rows.
    visible = _visible_job_list(pbar, nothing, now_sec)
    max_desc = isempty(visible) ? 0 : maximum(length(j.desc) for j in visible)
    desc_width = max(14, max_desc)

    if !isempty(pbar.title)
        # Titled tree: The title serves as the root header, top-level jobs branch under it
        println(buf, _ANSI_BOLD, pbar.title, _ANSI_RESET)
        _render_job_nodes(buf, pbar, top_jobs, "", syms, bar_width, now_sec, desc_width;
                          collapse_completed = collapse_completed, final_depth = final_depth)
    elseif length(top_jobs) == 1
        # Untitled single root job: Display the root job flush (no hanging branch prefix)
        root_job = top_jobs[1]
        job_rendered = show_progjob_with_theme(root_job, root_job.theme; bar_width = bar_width, desc_width = desc_width)
        println(buf, job_rendered)

        # Children branch directly from the root (kept unless the root is done and
        # the requested final depth has been reached)
        root_done = collapse_completed && root_job.total !== nothing && root_job.state >= root_job.total
        if !root_done || final_depth > 0
            children = get_visible_children(pbar, root_job, now_sec)
            if !isempty(children)
                _render_job_nodes(buf, pbar, children, "", syms, bar_width, now_sec, desc_width; depth = 1,
                                  collapse_completed = collapse_completed, final_depth = final_depth)
            end
        end
    else
        # Untitled multiple top-level jobs: Display with standard branch prefixes
        _render_job_nodes(buf, pbar, top_jobs, "", syms, bar_width, now_sec, desc_width;
                          collapse_completed = collapse_completed, final_depth = final_depth)
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
    now_sec::Float64,
    desc_width::Int = 14;
    depth::Int = 0,
    collapse_completed::Bool = false,
    final_depth::Int = 0
)
    n = length(jobs)
    for (i, job) in enumerate(jobs)
        is_last = (i == n)
        branch = is_last ? syms[:term] : syms[:leaf]
        extension = is_last ? syms[:nada] : syms[:line]

        job_rendered = show_progjob_with_theme(job, job.theme; bar_width = bar_width, desc_width = desc_width)
        println(io, prefix, branch, job_rendered)

        # In collapse mode a finished job hides its subtree, keeping only
        # `final_depth` levels of children below the top of the tree.
        job_done = collapse_completed && job.total !== nothing && job.state >= job.total
        if !(job_done && depth >= final_depth)
            children = get_visible_children(pbar, job, now_sec)
            if !isempty(children)
                _render_job_nodes(io, pbar, children, prefix * extension, syms, bar_width, now_sec, desc_width;
                                  depth = depth + 1,
                                  collapse_completed = collapse_completed,
                                  final_depth = final_depth)
            end
        end
    end
end

"""
    _truncate_ansi(s::AbstractString, width::Int) -> String

Truncates `s` to at most `width` visible columns, treating ANSI escape sequences as
zero-width. Only CSI sequences (`\\e[ ... final-byte`) are recognised as zero-width;
anything else counts as one visible column. If truncation happened, the result ends
with a reset so no colour bleeds into following terminal content.
"""
function _truncate_ansi(s::AbstractString, width::Int)
    n = 0
    i = firstindex(s)
    last = lastindex(s)
    buf = IOBuffer()
    while i <= last && n < width
        c = s[i]
        if c == '\e' && i < last && s[nextind(s, i)] == '['
            # CSI sequence: copy `\e[` plus everything up to and including the
            # final byte (in '@'..'~'), which has zero visible width.
            j = nextind(s, i)  # position of '['
            while j <= last
                j = nextind(s, j)
                j > last && break
                b = s[j]
                if '@' <= b <= '~'
                    break
                end
            end
            if j <= last
                write(buf, SubString(s, i, j))
                i = nextind(s, j)
            else
                break  # unterminated escape: drop the rest of the line
            end
        else
            write(buf, c)
            n += 1
            i = nextind(s, i)
        end
    end
    out = String(take!(buf))
    return n >= width ? out * _ANSI_RESET : out
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
        term_height, term_width = displaysize(io)
        if term_height <= 0 || term_width <= 0
            return
        end

        # Size the bar so the whole line (blinker + desc + bar + pct + rate + eta)
        # fits `term_width` columns instead of wrapping.
        bar_width = clamp(term_width - 60, 10, 40)
        tree_str = render_progbar_tree(pbar; bar_width = bar_width,
                                       collapse_completed = true,
                                       final_depth = pbar.final_depth)

        if isempty(tree_str)
            # Nothing visible: release the whole screen
            print(io, "\e[r")
            print(io, "\e[", term_height, ";1H")
            flush(io)
            pbar.last_render = now_sec
            pbar.last_gutter_start = term_height + 1
            return
        end

        # Truncate every line to the terminal width so the tree never wraps; this
        # keeps `tree_height` equal to the number of rows the tree really occupies.
        lines = split(chomp(tree_str), '\n')
        lines = map(l -> _truncate_ansi(l, term_width), lines)
        tree_height = length(lines)

        # Never let the tree overflow the screen: keep the top of the tree only.
        if tree_height > term_height - 1
            tree_height = term_height - 1
            resize!(lines, tree_height)
        end

        scroll_bottom = max(1, term_height - tree_height)
        gutter_start = scroll_bottom + 1

        # 1. Clear the whole gutter area (old rows AND new rows) so a shrinking
        #    tree never leaves stale bars behind on the display.
        clear_from = min(pbar.last_gutter_start, gutter_start)
        print(io, "\e[", clear_from, ";1H")
        print(io, "\e[J")

        # 2. Update scrolling region to leave room for the gutter
        print(io, "\e[1;", scroll_bottom, "r")

        # 3. Position cursor in gutter and draw tree (no trailing newline, so the
        #    cursor never lands past the bottom row and never triggers a scroll)
        print(io, "\e[", gutter_start, ";1H")
        print(io, join(lines, "\n"))

        # 4. Restore cursor position to the active scroll area
        print(io, "\e[", scroll_bottom, ";1H")
        flush(io)

        pbar.last_render = now_sec
        pbar.last_gutter_start = gutter_start
    end
end

"""
    update!(pbar::ProgBar, job::ProgJob, [new_state])

Updates a specific job's progress in the tree and refreshes the gutter display.
"""
function update!(pbar::ProgBar, job::ProgJob, new::Union{Int, Nothing} = nothing)
    completed = _advance!(job, new)
    completed && @lock pbar.lock begin
        if !haskey(pbar.completed_at, job)
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
    pbar.last_gutter_start = typemax(Int)
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

# Compact REPL summary, e.g. `ProgBar("Pipeline", 7 jobs, 2 roots)`.
function Base.show(io::IO, pbar::ProgBar)
    n = length(pbar)
    roots = length(get_children(pbar, nothing))
    print(io, "ProgBar(")
    isempty(pbar.title) || print(io, repr(pbar.title), ", ")
    print(io, n, " job", n == 1 ? "" : "s", ", ", roots, " root", roots == 1 ? "" : "s", ")")
end

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
