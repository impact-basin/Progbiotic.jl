# the render engine: TTY detection, the gutter, the frame-rate limiter and the
# background render task.
#
# the contract this file upholds is simple: *the computational loop never touches the
# terminal*. Advancing a bar is an atomic add; drawing happens on a separate Task that
# wakes at most fps times a second, reads the atomics, and writes one buffer under a
# lock. A for loop over 10^7 items therefore pays for a handful of atomic adds per item
# and nothing else.
#
# two output modes share that machinery:
#
#   * interactive (a terminal): the tree is kept in a gutter reserved at the bottom of
#     the screen, behind a scroll region, so the user's own output scrolls above it
#     instead of being overwritten by the next frame;
#   * non-interactive (a pipe, a redirected file, CI): flat, append-only lines with no
#     escape sequences at all, emitted once per flat_step percent per node.

# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------

const _CSI = "\e["

"""Position the cursor at a row and column, one-based."""
_at(row::Int, col::Int = 1) = string(_CSI, row, ";", col, "H")

# ---------------------------------------------------------------------------
# terminal detection
# ---------------------------------------------------------------------------

"""
    _is_tty(io) -> Bool

Whether the stream is an interactive terminal, i.e. whether ANSI cursor control is safe.

Julia's Base has no isatty; the idiomatic test is whether the stream is a Base.TTY (an
IOContext is unwrapped first). Redirecting stdout to a file or a pipe -- or running under
CI, where CI=true is conventionally exported -- turns this off, and the engine then
emits flat, ANSI-free lines instead.
"""
_is_tty(io::IO) = _is_tty_impl(_unwrap_io(io))

_unwrap_io(io::IOContext) = _unwrap_io(io.io)
_unwrap_io(io::IO) = io

# only a real terminal (and a non-CI environment) can be drawn to in place.
function _is_tty_impl(io)
    io isa Base.TTY || return false
    return !_ci_environment()
end

"""True when the CI environment variable marks a non-interactive build."""
function _ci_environment()
    value = lowercase(strip(get(ENV, "CI", "")))
    return value == "true" || value == "1" || value == "yes"
end

# ---------------------------------------------------------------------------
# timing
# ---------------------------------------------------------------------------

"""
    _refresh_timing!(node)

Stamp each node's last-advance time, but only for the nodes whose counter actually moved
since the previous tick.

This is what lets rate and ETA freeze while a bar waits on a nested job without costing
anything in the hot loop: advancing a bar stays a single atomic add, and the timestamp is
refreshed from the render tick, which already runs at fps.
"""
function _refresh_timing!(node::Progress)
    state = node.state
    count = pbdone(state)
    if count != node.paint.count
        node.paint.count = count
        state.last_update = time()
    end
    isfinished(state) && state.finish[] == 0 && _finish_state!(state; clamp = false)
    for kid in children(node)
        _refresh_timing!(kid)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# the gutter
# ---------------------------------------------------------------------------

"""
    _gutter_lines(root, term_height, term_width) -> Vector{String}

The lines the tree is about to occupy, clipped to the terminal and capped so the gutter
can never leave the scroll region without a row to spare.

A tree whose root has errored is drawn uncollapsed. An uncaught exception is the one time
the whole live tree is worth reproducing, so the failing node's position is visible
instead of hidden beneath the root's completion. A caught failure contributes a frozen
record above the live tree instead, and the oldest records are shed first when the block
does not fit.
"""
function _gutter_lines(root::Progress, term_height::Int, term_width::Int)
    # an escaped error reproduces the live tree; a caught one keeps its frozen records
    escaped = haserror(root.state)
    records = FailureRecord[]
    if !escaped
        records = @lock root.root.lock copy(root.root.failures)
    end
    text = render_tree(root; collapse = !escaped, width = term_width, records = records)
    isempty(text) && return String[]
    lines = split(chomp(text), '\n')
    cap = term_height - 1
    if length(lines) > cap
        # records sit above the live tree, and the live tree is the part that has to stay;
        # when the block does not fit, the oldest records fall off the top
        lines = isempty(records) ? lines[1:cap] : lines[(length(lines) - cap + 1):end]
    end
    return String[lines...]
end

# the gutter is written under the lock every other terminal write takes, so a concurrent
# println from the user can never land in the middle of an escape sequence.
function _write_gutter!(root::Progress, buffer::IOBuffer)
    state = root.root
    @lock state.lock begin
        write(root.io, take!(buffer))
        flush(root.io)
    end
    state.last_draw = time()
    return true
end

"""
    _draw_tty!(root) -> Bool

Draw the tree into the gutter reserved at the bottom of the screen, behind a scroll
region.

Room is made by scrolling rather than by clearing: a new row is claimed by printing a
newline at the bottom of the region the tree already sits in, which pushes the user's own
output up into the scrollback instead of overwriting it with a bar that is about to
appear there. Rows are only cleared once the tree has stopped needing them, since nothing
else can want them back.
"""
function _draw_tty!(root::Progress)
    io = root.io
    term_height, term_width = displaysize(io)
    (term_height > 0 && term_width > 0) || return false

    state    = root.root
    previous = state.rows
    lines    = _gutter_lines(root, term_height, term_width)
    rows     = length(lines)
    buffer   = IOBuffer()

    if rows == 0
        # nothing visible: hand the screen back, clearing the rows the tree was using and
        # parking the cursor where they were, so later output starts there
        if previous > 0
            print(buffer, _at(term_height - previous + 1), "\e[J", "\e[r",
                  _at(term_height - previous + 1))
            state.rows = 0
        end
        return _write_gutter!(root, buffer)
    end

    if rows > previous
        bottom = previous == 0 ? term_height : term_height - previous
        print(buffer, _at(bottom), repeat("\n", rows - previous))
    end

    scroll_bottom = max(1, term_height - rows)
    print(buffer, "\e[1;", scroll_bottom, "r")
    # clear from the top of whichever gutter was taller, so a shrinking tree leaves no
    # stale rows behind it
    print(buffer, _at(term_height - max(previous, rows) + 1), "\e[J")
    print(buffer, _at(scroll_bottom + 1), join(lines, "\n"))
    print(buffer, _at(scroll_bottom))

    state.rows = rows
    return _write_gutter!(root, buffer)
end

"""
    _release_gutter!(root; keep = true)

Give the reserved rows back.

With `keep` the tree is drawn one last time and left on screen as ordinary text, with the
cursor on a fresh line below it, so a finished run stays readable in the scrollback.
Without it the rows are cleared, which is what a tree that has vanished wants.
"""
function _release_gutter!(root::Progress; keep::Bool = true)
    state    = root.root
    previous = state.rows
    previous == 0 && return nothing

    io = root.io
    term_height, term_width = displaysize(io)
    buffer = IOBuffer()

    lines = try
        keep && term_height > 0 ? _gutter_lines(root, term_height, term_width) : String[]
    catch
        String[]
    end
    if isempty(lines)
        # the tree has gone, or was never wanted: clear the rows it was using and park
        # where they were, so later output starts there
        print(buffer, _at(term_height - previous + 1), "\e[J", "\e[r",
              _at(term_height - previous + 1))
    else
        # leave the tree behind as ordinary text and start a fresh line under it
        print(buffer, _at(max(1, term_height - length(lines) + 1)), join(lines, "\n"))
        print(buffer, "\e[r", _at(term_height), "\n")
    end

    state.rows = 0
    return _write_gutter!(root, buffer)
end

# ---------------------------------------------------------------------------
# flat output
# ---------------------------------------------------------------------------

"""
    _should_emit_flat(node, percentage, force, now_sec) -> Bool

Whether a node has earned another line of the non-interactive format: the first one, then
one per flat_step percent, then the final 100%. An indeterminate node has no percentage
to step through, so it emits a heartbeat once a second instead. A settled node always gets
its last line, which is how an error reaches a flat log.
"""
function _should_emit_flat(node::Progress, percentage::Int, force::Bool, now_sec::Float64,
                           settled::Bool = _settled(node), status::Symbol = pbstatus(node))
    paint    = node.paint
    previous = paint.flat_pct
    status !== :running && status !== paint.flat_status && return true

    # the forced pass writes the final state, which earns a line only if it is not the one
    # already written: a determinate node climbs to 100, and an indeterminate one stops
    # reading "elapsed" and starts reading "done in"
    (force || settled) && return previous < 100 && !paint.flat_done
    # last_flat is stamped only when a line is actually written, so it is what tells a
    # node that has never announced itself from one that is indeterminate and sitting at
    # -1 for the whole run
    paint.last_flat == 0.0 && return true
    percentage < 0 && return (now_sec - paint.last_flat) >= 1.0
    return percentage >= previous + node.opts.flat_step
end

"""
    _draw_flat!(root; force = false) -> Bool

Non-interactive output for a whole tree: append a flat line for every node that has
crossed another flat_step percent, plus one per node when forced, which is how the final
100% lines are written.
"""
function _draw_flat!(root::Progress; force::Bool = false)
    now_sec = time()
    symbols = get(TREE_STRS, root.root.style, TREE_STRS[:round])
    buffer  = IOBuffer()
    wrote   = false

    for row in _tree_rows(root, symbols, false, now_sec)
        node = row.node
        percentage = flat_percentage(row.state)
        settled = _settled(row.state)
        status = pbstatus(row.state)
        _should_emit_flat(node, percentage, force, now_sec, settled, status) || continue
        node.paint.flat_pct  = percentage
        node.paint.last_flat = now_sec
        node.paint.flat_done = settled
        node.paint.flat_status = status
        print(buffer, render_flat_line(node, row.depth, row.state), "\n")
        wrote = true
    end

    wrote || return false
    state = root.root
    @lock state.lock begin
        write(root.io, take!(buffer))
        flush(root.io)
    end
    state.last_draw = now_sec
    return true
end

"""Draw one frame and acknowledge requests sampled before it started."""
function render_tick!(root::Progress; force::Bool = false)
    state = root.root
    request = @lock state.lock state.requested
    try
        _refresh_timing!(root)
        return root.opts.tty ? _draw_tty!(root) : _draw_flat!(root; force = force)
    finally
        @lock state.lock begin
            state.drawn = request
            notify(state.frame; all = true)
        end
    end
end

# ---------------------------------------------------------------------------
# the background render task
# ---------------------------------------------------------------------------

"""
    start_render!(root; threaded = root.opts.threaded) -> Task

Start the one task that owns the terminal for a whole tree.

threaded = false keeps it on the current thread as an async task: it runs whenever the
computational loop yields, which is exactly when terminal I/O is free, and it costs
nothing at all while a tight loop is running. threaded = true uses Threads.@spawn so the
bar keeps animating even during a long, never-yielding computation; it is worth it only
when such a loop is expected.

A node never starts a task of its own. Children share the root's, which is a property of
the RootState they all hold rather than a convention someone has to remember.
"""
function start_render!(root::Progress; threaded::Bool = root.opts.threaded)
    root = root_of(root)
    state = root.root
    @lock state.lock begin
        state.task === nothing || return state.task
        reset(state.wake)
        state.running[] = true
        state.task = threaded ? Threads.@spawn(_render_loop(root)) : (@async _render_loop(root))
        return state.task
    end
end

"""
    _at_rest(root) -> Bool

Whether the render task can hand the terminal back.

A flat tree is done as soon as every visible node has finished, since there is nothing to
redraw. A gutter is done when it has released itself, or when everything still on screen
has finished and none of it will ever time out: nothing left can change, so the tree is
left where it is. A node still counting down a finite vanish timeout keeps the loop
alive, because erasing it is the loop's job.
"""
function _at_rest(root::Progress)
    now_sec = time()
    root.opts.tty || return _all_complete(root, now_sec)
    root.root.rows == 0 && return true
    return _all_complete(root, now_sec) && _all_forever(root, now_sec)
end

# every visible node, this one and its whole subtree, has settled
function _all_complete(node::Progress, now_sec::Float64)
    _visible(node, now_sec) || return true
    _settled(node) || return false
    return all(child -> _all_complete(child, now_sec), children(node))
end

# no visible node is waiting out a finite vanish timeout
function _all_forever(node::Progress, now_sec::Float64)
    _visible(node, now_sec) || return true
    _settled(node) || return false

    kids = children(node)
    all(child -> _all_forever(child, now_sec), kids) || return false

    timeout = haserror(node.state) ? node.opts.error_vanish : node.opts.vanish
    return isinf(timeout) ||
           (node.parent !== nothing && node_depth(node) <= node.root.final_depth) ||
           any(child -> _visible(child, now_sec), kids)
end

"""
    _render_loop(root)

The render loop ticks every dt seconds, or sooner for an explicit flush, and hands the
terminal back as soon as there is nothing left that could change.
"""
function _render_loop(root::Progress)
    state = root.root
    timer = nothing
    try
        dt = max(root.opts.dt, 0.001)
        timer = Timer(_ -> notify(state.wake), dt; interval = dt)
        while state.running[]
            render_tick!(root)
            _at_rest(root) && break
            wait(state.wake)
        end
    catch err
        # rendering must never take the user's computation down with it, and it must not
        # write through the user's logger, so failures go straight to stderr.
        try
            print(stderr, "Progbiotic: render task stopped: ", sprint(showerror, err), "\n")
        catch
        end
    finally
        timer === nothing || close(timer)
        # requests arriving during the final draw must be flushed before ownership ends
        while true
            try
                render_tick!(root; force = true)
            catch
            end
            try
                _release_gutter!(root)
            catch
            end
            @lock state.lock begin
                state.drawn < state.requested && continue
                state.running[] = false
                state.task = nothing
                notify(state.frame; all = true)
                break
            end
        end
    end
    return nothing
end

"""Stamp completion without clamping failed counters; report whether a final frame is due."""
function _finish_state!(state::BarState; clamp::Bool = true)
    @lock state.lock begin
        if state.status === :succeeded
            total = state.total
            clamp && total !== nothing && state.current[] != total || return false
            state.current[] = total
            return true
        end
        state.status !== :running && state.finish[] > 0 && return false
        if state.status === :running
            total = state.total
            clamp && total !== nothing && (state.current[] = total)
            state.status = :succeeded
        end
        state.finish[] == 0 && (state.finish[] = time())
    end
    return true
end

function _cancel_state!(state::BarState)
    @lock state.lock begin
        pbstatus(state) === :running || return false
        state.status = :cancelled
        state.finish[] = time()
    end
    return true
end

function _cancel_descendants!(node::Progress)
    changed = false
    for kid in children(node)
        changed |= _cancel_descendants!(kid)
        changed |= _cancel_state!(kid.state)
    end
    return changed
end

function _request_frame!(node::Progress)
    @lock node.root.lock begin
        node.root.requested += 1
        notify(node.root.wake)
    end
    return nothing
end

"""
    cancel!(bar; wait = !bar.opts.tty)

End reporting without filling the counter, retaining partial progress. Unfinished child
bars are cancelled too. This does not stop Julia tasks: callers must stop their work
cooperatively and must not continue advancing terminal handles. Cancellation is terminal;
`finish!` does not turn it into success.
"""
function cancel!(node::Progress; wait::Bool = !node.opts.tty)
    changed = _cancel_descendants!(node)
    changed |= _cancel_state!(node.state)
    changed && _request_frame!(node)
    _finish!(node; wait, clamp = false)
    return node
end

# scope cleanup must not replace an exception already unwinding through user code
function _close_scope!(node::Progress; completed::Bool)
    try
        if completed && pbstatus(node) === :running
            _complete_statement_jobs!(node)
            _finish_state!(node.state; clamp = iscontainer(node))
        elseif !completed
            _cancel_state!(node.state)
        end
        _cancel_descendants!(node)
    catch
    finally
        if node.parent === nothing
            _clear_failure!(node)
            try
                stop_render!(node)
            catch
            end
        end
    end
    return nothing
end

"""
    root_of(node) -> Progress

The node at the top of a tree. The render task and the gutter belong to it, and a child
reaches it by walking up.
"""
function root_of(node::Progress)
    while node.parent !== nothing
        node = node.parent
    end
    return node
end

"""
    finish!(node::Progress; wait = !node.opts.tty)

Mark a node complete: clamp its counter to its total and stamp the finish time. The
render task draws its final frame and handles the vanish timeout.

A node that has already registered an error is not clamped: its counter stays where the
work stopped, and the frame drawn is the error frame. `fail!` and `finish!` are the two
sides of the same teardown.

For a root, `wait` blocks until the render task has handed the terminal back. For a child,
it requests and waits for a frame containing its completion, without waiting for its
parent to finish.
It defaults to true for non-interactive output and false for a terminal. With no renderer
(`start = false`), children only update state; finishing the root flushes the tree.
"""
function finish!(node::Progress; wait::Bool = !node.opts.tty)
    return _finish!(node; wait, clamp = true)
end

function _finish!(node::Progress; wait::Bool, clamp::Bool)
    if node.parent !== nothing && !wait
        _finish_state!(node.state; clamp)
        return nothing
    end

    top = root_of(node)
    root = top.root
    task = @lock root.lock begin
        fresh = _finish_state!(node.state; clamp)
        if node === top
            fresh && (root.requested += 1)
            if fresh || root.requested > root.drawn
                start_render!(top)
                notify(root.wake)
            end
        elseif root.task !== nothing && current_task() !== root.task
            root.requested += 1
            request = root.requested
            notify(root.wake)
            while root.task !== nothing && root.drawn < request
                Base.wait(root.frame)
            end
        end
        root.task
    end
    node === top && wait && task !== nothing && task !== current_task() && _wait_quietly(task)
    node === top && _clear_failure!(node)
    return nothing
end

"""
    stop_render!(node)

Ask the render task to stop and wait for it to hand the terminal back, leaving the tree on
screen as ordinary text. Unlike finish! this does not wait out the vanish timeout: it is
the "tear down now" path, used when a scope ends or a bar is abandoned.
"""
function stop_render!(node::Progress)
    top   = root_of(node)
    state = top.root
    task = @lock state.lock begin
        current_task() === state.task || (state.requested += 1)
        task = start_render!(top)
        state.running[] = false
        notify(state.wake)
        task
    end
    task === current_task() || _wait_quietly(task)
    return nothing
end

function _wait_quietly(task::Task)
    try
        Base.wait(task)
    catch
    end
    return nothing
end
