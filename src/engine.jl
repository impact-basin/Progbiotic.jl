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

    lines = keep && term_height > 0 ? _gutter_lines(root, term_height, term_width) : String[]
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
to step through, so it emits a heartbeat once a second instead, and a settled node always
gets its last line from the forced pass, which is how an error reaches a flat log.
"""
function _should_emit_flat(node::Progress, percentage::Int, force::Bool, now_sec::Float64)
    paint    = node.paint
    previous = paint.flat_pct

    # the forced pass writes the final state, which earns a line only if it is not the one
    # already written: a determinate node climbs to 100, and an indeterminate one stops
    # reading "elapsed" and starts reading "done in"
    force && return previous < 100 && !paint.flat_done
    # last_flat is stamped only when a line is actually written, so it is what tells a
    # node that has never announced itself from one that is indeterminate and sitting at
    # -1 for the whole run
    paint.last_flat == 0.0 && return true
    percentage < 0 &&
        return !_settled(node) && (now_sec - paint.last_flat) >= 1.0
    percentage >= previous + node.opts.flat_step && return true
    return _settled(node) && percentage >= 100 && previous < 100
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
        percentage = flat_percentage(node)
        _should_emit_flat(node, percentage, force, now_sec) || continue
        node.paint.flat_pct  = percentage
        node.paint.last_flat = now_sec
        node.paint.flat_done = _settled(node)
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

"""Draw one frame, in whichever mode the tree is in."""
function render_tick!(root::Progress; force::Bool = false)
    _refresh_timing!(root)
    return root.opts.tty ? _draw_tty!(root) : _draw_flat!(root; force = force)
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
    state = root.root
    state.task === nothing || return state.task
    state.running[] = true
    state.task = threaded ? Threads.@spawn(_render_loop(root)) : (@async _render_loop(root))
    return state.task
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
    timeout = haserror(node.state) ? node.opts.error_vanish : node.opts.vanish
    (_settled(node) && isinf(timeout)) || return false
    return all(child -> _all_forever(child, now_sec), children(node))
end

"""
    _render_loop(root)

The frame-rate-limited render loop. It ticks at most 1 / dt times a second and hands the
terminal back as soon as there is nothing left that could change.
"""
function _render_loop(root::Progress)
    drew_final = false
    try
        while root.root.running[]
            if root.opts.tty
                # the gutter is ours to redraw, and redrawing it is what erases a node
                # whose vanish timeout has run out
                render_tick!(root)
            elseif _all_complete(root, time())
                # a flat log is append-only, so the finished tree writes exactly one
                # final line and then stops
                if !drew_final
                    render_tick!(root; force = true)
                    drew_final = true
                end
            else
                render_tick!(root)
                drew_final = false
            end
            _at_rest(root) && break
            sleep(root.opts.dt)
        end
    catch err
        # rendering must never take the user's computation down with it, and it must not
        # write through the user's logger, so failures go straight to stderr.
        try
            print(stderr, "Progbiotic: render task stopped: ", sprint(showerror, err), "\n")
        catch
        end
    finally
        try
            # A flat log is append-only and this is its last chance to write the final
            # state. Two ways out miss it otherwise: the tree coming to rest during a draw,
            # which breaks the loop before the forced pass at the top can run again, and a
            # scope ending while the loop is asleep -- with dt at 50ms and a shorter scope,
            # the task never wakes up again and the nodes registered after its last tick
            # would never be written at all.
            root.opts.tty || drew_final || render_tick!(root; force = true)
        catch
        end
        try
            _release_gutter!(root)
        catch
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

Mark a node complete: clamp its counter to its total, stamp the finish time, draw the
final frame, and let the render task linger for the vanish timeout before erasing it.

A node that has already registered an error is not clamped: its counter stays where the
work stopped, and the frame drawn is the error frame. `fail!` and `finish!` are the two
sides of the same teardown.

`wait` blocks until the render task has handed the terminal back. It defaults to true for
non-interactive output, where teardown is immediate and callers reasonably expect the
final line to already be in the buffer, and to false for a terminal, where waiting would
block for the whole vanish timeout for no reason.
"""
function finish!(node::Progress; wait::Bool = !node.opts.tty)
    top  = root_of(node)
    task = top.root.task

    if isfinished(node.state)
        wait && task !== nothing && _wait_quietly(task)
        return nothing
    end

    state = node.state
    # an errored node keeps the counter where it stopped; only a successful finish clamps
    if !haserror(state)
        total = state.total
        total !== nothing && (state.current[] = total)
    end
    state.last_update = time()
    state.finish[] == 0 && (state.finish[] = time())
    # completed_at is deliberately left alone: the renderer stamps it on the tick that
    # first sees the node settled, and that same tick is the one that draws it. Stamping
    # here would mean a node with vanish = 0.0 was already gone before its final frame.

    # the final frame is drawn here rather than left to the task, so it lands whatever the
    # node's vanish timeout is: with vanish = 0.0 the task could already consider the tree
    # gone by the time it next woke up. A second draw is harmless -- the flat renderer
    # dedupes on the percentage it last announced, and the gutter is ours to redraw.
    render_tick!(top; force = true)

    wait && task !== nothing && _wait_quietly(task)
    return _release_empty_gutter!(top)
end

# hand the gutter back when it is still reserved but has nothing left to show.
#
# the final frame above can redraw a gutter the render task had already released: a node
# with vanish = 0.0 is erased on the very tick that notices it finished, and if that tick
# won the race there is nothing running afterwards to erase the frame drawn here. This is
# the reconciliation, and it is a no-op in the ordinary case where the tree is still there.
function _release_empty_gutter!(root::Progress)
    (root.root.rows == 0 || !root.opts.tty) && return nothing
    isempty(_gutter_lines(root, displaysize(root.io)...)) || return nothing
    return _release_gutter!(root)
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
    state.running[] = false
    task  = state.task
    state.task = nothing

    if task === nothing
        _release_gutter!(top)
    else
        _wait_quietly(task)
    end
    return nothing
end

function _wait_quietly(task::Task)
    try
        Base.wait(task)
    catch
    end
    return nothing
end
