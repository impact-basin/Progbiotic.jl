"""
    ProgBar([title=""]; vanish_timeout=nothing, final_depth=0, style=:round, dt=0.05, io=stdout)

Mutable container for a tree of [`ProgJob`](@ref)s, rendered as a live gutter at
the bottom of the terminal.

# keyword arguments
- `vanish_timeout`: default time (seconds) a completed child bar stays on screen
  before disappearing; `nothing` (the default) keeps completed bars forever.
- `final_depth`: how many levels of children remain visible once a job completes
  (0 keeps only the job itself, 1 also its direct children, ...). Children within
  the retained depth ignore their vanish timeout.
- `style`: tree-drawing style (`:round` or `:square`).
- `dt`: minimum seconds between gutter redraws (throttle).
- `io`: output stream (defaults to `stdout`).
- `log_file`: a path or `IO` every intercepted log record is appended to,
  permanently and in plain text, even after it has vanished from the screen.
- `background`: draw from a background task (the default) so the computational
  loop never blocks on terminal I/O.

When `io` is not a terminal the gutter is replaced by flat, ANSI-free lines.

Log records intercepted inside `@progress` scopes are buffered per job in
`pbar.logs` (a [`ProgLogStore`](@ref)) and drawn under the bar they belong to.

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
    logs              :: ProgLogStore
    log_file          :: Union{String, IO, Nothing}
    log_sink          :: Union{IO, Nothing}
    sink_lock         :: ReentrantLock
    background        :: Bool
    interactive       :: Bool
    flat_step         :: Int
    flat_states       :: Dict{ProgJob, Int}
    running           :: Threads.Atomic{Bool}
    task              :: Union{Task, Nothing}

    function ProgBar(title::String = "";
                     vanish_timeout::Union{Float64, Nothing} = nothing, # e.g. 1.0 or nothing
                     final_depth::Int = 0, # how many levels of children to keep once a job completes
                     style::Symbol = :round,
                     dt::Float64 = 0.05,
                     io::IO = stdout,
                     log_file = nothing,   # path or IO: permanent plain-text log sink
                     background::Bool = true, # render from a background task
                     flat_step::Int = 10)     # percent between flat lines when not a TTY
        sink, destination = _open_log_sink(log_file)
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
            false,
            ProgLogStore(),
            destination,
            sink,
            ReentrantLock(),
            background,
            true,
            flat_step,
            Dict{ProgJob, Int}(),
            Threads.Atomic{Bool}(false),
            nothing)
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
    # default child theme to parent theme if not explicitly changed
    actual_theme = (theme === AMBER && parent !== nothing) ? parent.theme : theme
    actual_theme = _apply_style(actual_theme, spinner, barunits, empty, caps, head)

    # resolve the vanish timeout for this job:
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

    # sequential-subtask pattern: registering any new job under `parent` completes
    # that parent's previously pending statement subtasks, so only one subtask
    # shows as active at a time.
    _complete_statement_jobs!(pbar, parent)

    _request_gutter_refresh(pbar; force = true)
    return job
end

# true once a job is done: a determinate job is done at its total; an indeterminate
# job (e.g. a milestone subtask) is done once its finish timestamp is recorded.
function _job_finished(job::ProgJob)
    @lock job.lock begin
        if job.total !== nothing
            return job.state >= job.total
        end
        return job.finish ≈ 0.0 ? false : true
    end
end

# marks `job` as a milestone container: its total is the number of milestone
# subtasks it contains, and its state tracks how many of them have completed.
function _mark_container!(pbar::ProgBar, job::ProgJob)
    @lock pbar.lock begin
        pbar.container_jobs[job] = nothing
    end
    return nothing
end

# sets a container's state to the number of completed milestone subtasks.
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

# completes all pending (registered but not yet finished) statement subtasks under
# `parent`. Statement subtasks are created by `@progress "desc"` (no loop/block body).
# if `parent` is a milestone container, its state is advanced to the number of
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


# distance of `job` from the top of the tree (roots are at depth 0).
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

    # 2. A job holding live log lines stays visible until they expire, so an
    #    intercepted log is never cut short by its bar vanishing first.
    has_active_logs(pbar, job, now_sec) && return true

    # 3. Jobs within the configured final depth are retained regardless of their
    #    vanish timeout: `final_depth=N` promises to keep N levels of children.
    _job_depth(pbar, job) <= pbar.final_depth && return true

    # 4. If no vanish timeout is set, it stays visible forever
    timeout = get(pbar.vanish_timeouts, job, nothing)
    timeout === nothing && return true

    # 5. Check completion timestamp
    comp_time = get(pbar.completed_at, job, nothing)
    if comp_time === nothing
        @lock job.lock begin
            if job.total !== nothing && job.state >= job.total
                pbar.completed_at[job] = now_sec
            end
        end
        return true
    end

    # 6. Check if within timeout window
    return (now_sec - comp_time) < timeout
end

function get_visible_children(pbar::ProgBar, parent::Union{ProgJob, Nothing},
                              now_sec::Float64)
    all_children = get_children(pbar, parent)
    return filter(j -> is_job_visible(pbar, j, now_sec), all_children)
end

# collects every currently visible job in the tree (depth-first), used to size the
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
    # drop expired log lines before measuring the tree: the gutter's height (and so
    # the area it clears) must match the lines that are actually drawn.
    prune_logs!(pbar, now_sec)

    top_jobs = get_visible_children(pbar, nothing, now_sec)

    # fixed description column: pad every row to the longest visible description
    # (with a sensible minimum) so the bar column lines up across rows.
    visible = _visible_job_list(pbar, nothing, now_sec)
    max_desc = isempty(visible) ? 0 : maximum(length(j.desc) for j in visible)
    desc_width = max(14, max_desc)

    if !isempty(pbar.title)
        # titled tree: The title serves as the root header, top-level jobs branch under it
        println(buf, _ANSI_BOLD, pbar.title, _ANSI_RESET)
        _render_job_nodes(buf, pbar, top_jobs, "", syms, bar_width, now_sec, desc_width;
                          collapse_completed = collapse_completed, final_depth = final_depth)
    elseif length(top_jobs) == 1
        # untitled single root job: Display the root job flush (no hanging branch prefix)
        root_job = top_jobs[1]
        job_rendered = show_progjob_with_theme(root_job, root_job.theme; bar_width = bar_width, desc_width = desc_width)
        println(buf, job_rendered)
        _render_job_logs(buf, pbar, root_job, "", syms, now_sec)

        # children branch directly from the root (kept unless the root is done and
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
        # untitled multiple top-level jobs: Display with standard branch prefixes
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

        # intercepted log lines are drawn directly beneath the bar they belong to.
        _render_job_logs(io, pbar, job, prefix * extension, syms, now_sec)

        # in collapse mode a finished job hides its subtree, keeping only
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

        # size the bar so the whole line (blinker + desc + bar + pct + rate + eta)
        # fits `term_width` columns instead of wrapping.
        bar_width = clamp(term_width - 60, 10, 40)
        tree_str = render_progbar_tree(pbar; bar_width = bar_width,
                                       collapse_completed = true,
                                       final_depth = pbar.final_depth)

        if isempty(tree_str)
            # nothing visible: release the whole screen
            print(io, "\e[r")
            print(io, "\e[", term_height, ";1H")
            flush(io)
            pbar.last_render = now_sec
            pbar.last_gutter_start = term_height + 1
            return
        end

        # truncate every line to the terminal width so the tree never wraps; this
        # keeps `tree_height` equal to the number of rows the tree really occupies.
        lines = split(chomp(tree_str), '\n')
        lines = map(l -> _truncate_ansi(l, term_width), lines)
        tree_height = length(lines)

        # never let the tree overflow the screen: keep the top of the tree only.
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
    _request_gutter_refresh(pbar)
end



"""
    with_tree_gutter(f::Function, pbar::ProgBar; io=stdout)

Executes `f()` while maintaining the dynamic tree gutter at the bottom.
Restores the terminal scroll margin upon completion.
"""
function with_tree_gutter(f::Function, pbar::ProgBar; io::IO = pbar.io)
    pbar.active = true
    pbar.io = io
    pbar.interactive = _is_tty(io)
    pbar.last_gutter_start = typemax(Int)
    term_height, _ = displaysize(io)

    if !pbar.interactive
        # non-interactive: nothing to reserve and nothing to redraw, so every
        # update is an append-only flat line with no escape sequences at all.
        _start_gutter_task!(pbar)
        try
            return f()
        finally
            stop_gutter!(pbar)
            pbar.active = false
            _print_flat_tree!(pbar; force = true)
        end
    end

    print_progbar_in_gutter(pbar; force = true)
    _start_gutter_task!(pbar)
    try
        return f()
    finally
        stop_gutter!(pbar)
        pbar.active = false
        print_progbar_in_gutter(pbar; force = true)
        # reset scroll region and move cursor to the end
        print(io, "\e[r")
        print(io, "\e[", term_height, ";1H\n")
        flush(io)
    end
end

"""
    _request_gutter_refresh(pbar; force = false)

Ask for the gutter to be redrawn.

With background rendering on - the default - this is a no-op: the render task owns
the terminal, and the computational loop must never block on it.  Turn background
rendering off and the refresh happens inline, throttled by the bar's own dt, which
is what the original synchronous renderer did.
"""
function _request_gutter_refresh(pbar::ProgBar; force::Bool = false)
    pbar.active || return nothing
    pbar.background && return nothing
    return pbar.interactive ? print_progbar_in_gutter(pbar; force = force) :
                              _print_flat_tree!(pbar; force = force)
end

"""Start the background gutter render task, unless background rendering is off."""
function _start_gutter_task!(pbar::ProgBar)
    pbar.background || return nothing
    pbar.running[] = true
    # flat output is append-only, so it is safe to write it from another thread and
    # it keeps updating during a long, never-yielding loop.  Cursor control is not:
    # an async task can only redraw when the computational loop yields, which is
    # also exactly when interleaving with the user's own output is impossible.
    pbar.task = (!pbar.interactive && Threads.nthreads() > 1) ?
        Threads.@spawn(_gutter_loop(pbar)) : (@async _gutter_loop(pbar))
    return nothing
end

"""
    _gutter_loop(pbar)

The tree renderer's background loop.  It is an async task, so it only runs when
the computational loop yields - which is exactly when terminal I/O is free - and it
costs nothing at all while a tight loop is running.
"""
function _gutter_loop(pbar::ProgBar)
    while pbar.running[]
        try
            if pbar.interactive
                print_progbar_in_gutter(pbar)
            else
                _print_flat_tree!(pbar)
            end
        catch
            # A rendering failure must never take the user's computation down.
        end
        sleep(pbar.dt)
    end
    return nothing
end

"""Stop the background gutter render task and wait for it to finish."""
function stop_gutter!(pbar::ProgBar)
    pbar.running[] = false
    task = pbar.task
    pbar.task = nothing
    task === nothing && return nothing
    try
        Base.wait(task)
    catch
    end
    return nothing
end

"""Every visible job, paired with its depth in the tree (depth-first)."""
function _flat_job_list!(out::Vector{Tuple{ProgJob, Int}}, pbar::ProgBar, parent,
                         depth::Int, now_sec::Float64)
    for job in get_visible_children(pbar, parent, now_sec)
        push!(out, (job, depth))
        _flat_job_list!(out, pbar, job, depth + 1, now_sec)
    end
    return out
end

"""One job as a plain, ANSI-free line, e.g. "[INFO] Training 40% (4/10)"."""
function _flat_job_line(job::ProgJob, depth::Int)
    job_state, total, desc = @lock job.lock (job.state, job.total, job.desc)
    isempty(desc) && (desc = "Progress")
    indent = repeat("  ", depth)
    if total === nothing
        return string("[INFO] ", indent, desc, " ", max(job_state, 1), " (indeterminate)")
    end
    done = clamp(job_state, 0, total)
    percentage = total > 0 ? floor(Int, 100 * done / total) : 100
    return string("[INFO] ", indent, desc, " ", percentage, "% (", done, "/", total, ")")
end

"""
    _pending_tree_logs!(pbar) -> Vector{LogEntry}

Mark and return every buffered tree log record the flat renderer has not written
yet, oldest first.  Entries are marked rather than removed: a scope's captured
records stay inspectable through active_logs even though they have already been
streamed out.
"""
function _pending_tree_logs!(pbar::ProgBar)
    store = pbar.logs
    pending = LogEntry[]
    @lock store.lock begin
        for buffer in values(store.buffers)
            for entry in buffer
                entry.printed && continue
                entry.printed = true
                push!(pending, entry)
            end
        end
    end
    sort!(pending, by = entry -> entry.created_at)
    return pending
end

"""
    _print_flat_tree!(pbar; force = false)

Non-interactive rendering for the tree engine: flat, append-only lines and not a
single escape sequence, so a CI log stays readable and greppable.

A bar emits a line when it crosses another flat_step percent, plus one when it
first appears and one when it completes.  Intercepted log records are written out
once, in the same plain format the log_file sink uses.
"""
function _print_flat_tree!(pbar::ProgBar; force::Bool = false)
    now_sec = time()
    buffer = IOBuffer()
    wrote = false

    for entry in _pending_tree_logs!(pbar)
        print(buffer, format_plain_log_line(entry), "\n")
        wrote = true
    end

    for (job, depth) in _flat_job_list!(Tuple{ProgJob, Int}[], pbar, nothing, 0, now_sec)
        job_state, total = @lock job.lock (job.state, job.total)
        percentage = total === nothing ? -1 :
                     (total > 0 ? floor(Int, 100 * clamp(job_state, 0, total) / total) : 100)
        previous = get(pbar.flat_states, job, nothing)
        emit = if previous === nothing
            true
        elseif percentage < 0
            force && previous < 0
        elseif force
            previous < percentage || (percentage >= 100 && previous < 100)
        else
            percentage >= previous + pbar.flat_step ||
                (percentage >= 100 && previous < 100)
        end
        emit || continue
        pbar.flat_states[job] = percentage
        print(buffer, _flat_job_line(job, depth), "\n")
        wrote = true
    end

    wrote || return false
    @lock pbar.lock begin
        write(pbar.io, take!(buffer))
        flush(pbar.io)
    end
    pbar.last_render = now_sec
    return true
end

# Base container & iterator interfaces for ProgBar
Base.length(pbar::ProgBar) = length(pbar.order)
Base.iterate(pbar::ProgBar, state=1) = state > length(pbar.order) ? nothing : (pbar.order[state], state + 1)
Base.eltype(::Type{ProgBar}) = ProgJob
Base.keys(pbar::ProgBar) = keys(pbar.jobs)
Base.firstindex(pbar::ProgBar) = 1
Base.lastindex(pbar::ProgBar) = length(pbar.order)
Base.getindex(pbar::ProgBar, i::Int) = pbar.order[i]

# compact REPL summary, e.g. `ProgBar("Pipeline", 7 jobs, 2 roots)`.
function Base.show(io::IO, pbar::ProgBar)
    n = length(pbar)
    roots = length(get_children(pbar, nothing))
    print(io, "ProgBar(")
    isempty(pbar.title) || print(io, repr(pbar.title), ", ")
    print(io, n, " job", n == 1 ? "" : "s", ", ", roots, " root", roots == 1 ? "" : "s", ")")
end

# `ProgContext` — the hierarchical context handle, including the log buffer used
# to capture `@info`/`@warn`/... records — is defined in `src/context.jl`.
