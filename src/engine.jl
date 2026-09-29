# The render engine: TTY detection, the background render task, the frame-rate
# limiter and the ANSI terminal controls.
#
# The contract this file exists to uphold is simple: *the computational loop never
# touches the terminal*.  Advancing a bar is an atomic add; drawing happens on a
# separate Task that wakes at most fps times a second, reads the atomics, and writes
# one buffer under a lock.  A for loop over 10^7 items therefore pays for a handful
# of atomic adds per item and nothing else.
#
# Two output modes share that machinery:
#
#   * interactive (a terminal): a live bar redrawn in place with ANSI cursor
#     control, with transient log lines drawn underneath and erased when they
#     expire;
#   * non-interactive (a pipe, a redirected file, CI): flat, append-only lines with
#     no escape sequences at all, emitted once per flat_step percent.

# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------

const _CSI = "\e["
const _ANSI_RESET = "\e[0m"

"""Move the cursor up n rows (no-op for n <= 0)."""
_cursor_up(n::Int) = n > 0 ? string(_CSI, n, "A") : ""

"""Move the cursor down n rows (no-op for n <= 0)."""
_cursor_down(n::Int) = n > 0 ? string(_CSI, n, "B") : ""

"""Erase from the cursor to the end of the line."""
const _ERASE_LINE = "\e[K"

# Colours for intercepted log lines, by level.
const _LOG_LEVEL_COLORS = Dict{Logging.LogLevel, String}(
    Logging.Debug => "\e[34m",   # blue
    Logging.Info  => "\e[36m",   # cyan
    Logging.Warn  => "\e[33m",   # yellow
    Logging.Error => "\e[31m",   # red
)

_log_color(level::Logging.LogLevel) =
    get(_LOG_LEVEL_COLORS, level, _LOG_LEVEL_COLORS[Logging.Info])

const _LOG_LEVEL_NAMES = Dict{Logging.LogLevel, String}(
    Logging.Debug => "DEBUG",
    Logging.Info  => "INFO",
    Logging.Warn  => "WARN",
    Logging.Error => "ERROR",
)

_log_level_name(level::Logging.LogLevel) = get(_LOG_LEVEL_NAMES, level, uppercase(string(level)))

"""
    format_plain_log_line(entry::LogEntry) -> String

A log record as one plain, ANSI-free line, e.g.

    [INFO] checkpoint at record 25

This is the format used both for the persistent log_file sink and for every
intercepted record in non-interactive mode: a CI log is a file, and a file should
not contain cursor control sequences.
"""
function format_plain_log_line(entry::LogEntry)
    return string("[", _log_level_name(entry.level), "] ", entry.message)
end

"""
    format_log_line(entry::LogEntry) -> String

A log record as a colour-coded line for the interactive display.  The coloured bar
glyph marks the line as progress output rather than user output.
"""
function format_log_line(entry::LogEntry)
    return string(_log_color(entry.level), "▏ ", entry.message, _ANSI_RESET)
end

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

"""
    render_frame(ctx::ProgressContext) -> String

Render the bar itself: every column in the layout, joined with single spaces, with
empty columns dropped.  This is the single line the whole design is built around,
and it is pure: it reads the atomics and returns a string, touching no I/O.
"""
function render_frame(ctx::ProgressContext)
    parts = String[]
    for column in ctx.layout
        text = render_column(column, ctx.state)
        isempty(text) || push!(parts, text)
    end
    return join(parts, " ")
end

"""The currently active (non-expired) log entries, oldest first."""
rendered_logs(ctx::ProgressContext, now_sec::Float64 = time()) = active_logs(ctx, now_sec)

"""
    render_block(ctx::ProgressContext) -> Vector{String}

The complete frame to draw: the bar line followed by one line per live log record.
"""
function render_block(ctx::ProgressContext, now_sec::Float64 = time())
    lines = String[render_frame(ctx)]
    for entry in rendered_logs(ctx, now_sec)
        push!(lines, format_log_line(entry))
    end
    return lines
end

"""
    render_flat_line(ctx::ProgressContext) -> String

One line of the non-interactive format, e.g.

    [INFO] Parsing Records 25% (250/1000) 412.5 it/s ETA 00:00:01 [loss=0.041]

Spinners and bars are dropped: they carry no information in a log file, and the
whole point of this mode is output you can grep.
"""
function render_flat_line(ctx::ProgressContext)
    state = ctx.state
    label = isempty(state.desc[]) ? "Progress" : state.desc[]
    done = state.current[]
    total = state.total

    head = if total === nothing
        string("[INFO] ", label, " ", done, " (indeterminate)")
    else
        done = clamp(done, 0, total)
        pct = total > 0 ? floor(Int, 100 * done / total) : 100
        string("[INFO] ", label, " ", pct, "% (", done, "/", total, ")")
    end

    extras = String[]
    for column in ctx.layout
        # The description and the percentage are already in the head, and a spinner
        # or a bar would only add noise.
        (column isa TextColumn || column isa SpinnerColumn ||
         column isa BarColumn || column isa PercentageColumn) && continue
        text = render_column(column, state)
        isempty(text) || push!(extras, text)
    end
    postfix = postfix_text(state)
    isempty(postfix) || push!(extras, string("[", postfix, "]"))

    isempty(extras) && return head
    return string(head, " ", join(extras, " "))
end

"""
    flat_percentage(ctx::ProgressContext) -> Int

The bar's integer completion percentage, or -1 for an indeterminate bar.
"""
function flat_percentage(ctx::ProgressContext)
    state = ctx.state
    total = state.total
    total === nothing && return -1
    total <= 0 && return 100
    return clamp(floor(Int, 100 * state.current[] / total), 0, 100)
end

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

"""
    _draw_tty!(ctx) -> Bool

Redraw the bar (and its live logs) in place.  Returns whether anything was written.

The cursor is assumed to sit on the row *after* the block that is currently drawn,
and ctx.rendered_lines records how many rows that block occupied, so the block can
be overwritten exactly.  A shrinking block clears its own leftovers, and the whole
frame is assembled in an IOBuffer and written with a single write, so a concurrent
println from another task can never land in the middle of an escape sequence.
"""
function _draw_tty!(ctx::ProgressContext)
    now_sec = time()
    prune_logs!(ctx, now_sec)
    lines = render_block(ctx, now_sec)
    previous = ctx.rendered_lines

    buffer = IOBuffer()
    previous > 0 && print(buffer, _cursor_up(previous))
    print(buffer, "\r")
    for line in lines
        print(buffer, _ERASE_LINE, line, "\n")
    end
    # Erase rows left over from a taller previous frame.
    extra = previous - length(lines)
    for _ in 1:max(0, extra)
        print(buffer, _ERASE_LINE, "\n")
    end
    extra > 0 && print(buffer, _cursor_up(extra))

    @lock ctx.write_lock begin
        write(ctx.io, take!(buffer))
        flush(ctx.io)
        ctx.rendered_lines = length(lines)
    end
    ctx.last_render = now_sec
    return true
end

"""
    _erase_tty!(ctx)

Erase the drawn block and leave the cursor exactly where the block started, so the
terminal looks as though the bar was never there.  This is what the vanish timeout
does when it runs out.
"""
function _erase_tty!(ctx::ProgressContext)
    @lock ctx.write_lock begin
        rows = ctx.rendered_lines
        if rows > 0
            buffer = IOBuffer()
            print(buffer, _cursor_up(rows))
            for _ in 1:rows
                print(buffer, _ERASE_LINE, "\n")
            end
            print(buffer, _cursor_up(rows))
            write(ctx.io, take!(buffer))
            flush(ctx.io)
            ctx.rendered_lines = 0
        end
    end
    return nothing
end

"""
    _draw_flat!(ctx; force = false) -> Bool

Non-interactive output: append a flat line when the bar has crossed another
flat_step percent, or when forced (which is how the final 100% line is written).

Intercepted log records are written out once, in the same plain format used for the
log_file sink, and then dropped: in a file there is nothing to redraw them over.
Determinate bars emit at most 100 / flat_step lines, so a long loop does not flood
a CI log.
"""
function _draw_flat!(ctx::ProgressContext; force::Bool = false)
    now_sec = time()
    wrote = false
    # The decision and the write share one lock: with a threaded renderer, the
    # task and a finalising finish!() could otherwise both decide to emit.
    @lock ctx.write_lock begin
        buffer = IOBuffer()
        for entry in pending_logs!(ctx, now_sec)
            print(buffer, format_plain_log_line(entry), "\n")
            wrote = true
        end
        percentage = flat_percentage(ctx)
        if _should_emit_flat(ctx, percentage, force)
            print(buffer, render_flat_line(ctx), "\n")
            ctx.last_flat_pct = percentage
            wrote = true
        end
        if wrote
            write(ctx.io, take!(buffer))
            flush(ctx.io)
        end
    end
    ctx.last_render = now_sec
    return wrote
end

# Flat-mode throttling.  Indeterminate bars have no percentage to step through, so
# they emit a heartbeat once a second instead.
function _should_emit_flat(ctx::ProgressContext, percentage::Int, force::Bool)
    force && return ctx.last_flat_pct < 100
    percentage < 0 && return (time() - ctx.last_render) >= 1.0
    ctx.last_flat_pct < 0 && return true             # always announce a new bar
    percentage >= ctx.last_flat_pct + ctx.flat_step && return true
    return ctx.finished[] && percentage >= 100 && ctx.last_flat_pct < 100
end

"""
    _refresh_timing!(ctx)

Stamp the last-advance time, but only when the counter actually moved since the
previous tick.

This is what lets rate and ETA freeze while a bar waits on a nested job without
costing anything in the hot loop: advancing a bar stays a single atomic add, and
the timestamp is refreshed from the render tick, which already runs at 20 Hz.
"""
function _refresh_timing!(ctx::ProgressContext)
    state = ctx.state
    count = state.current[]
    if count != ctx.last_count
        ctx.last_count = count
        state.last_update = time()
    end
    return nothing
end

"""Draw one frame, in whichever mode the context is in."""
function render_tick!(ctx::ProgressContext; force::Bool = false)
    _refresh_timing!(ctx)
    return ctx.tty ? _draw_tty!(ctx) : _draw_flat!(ctx; force = force)
end

# ---------------------------------------------------------------------------
# The background render task
# ---------------------------------------------------------------------------

"""
    start_render_task!(ctx; threaded = false) -> Task

Start the task that owns every write to the bar's output stream.

threaded = false (the default) keeps it on the current thread as an async task: it
runs whenever the loop yields, which is exactly when terminal I/O is free, and it
costs nothing at all while a tight loop is running.  threaded = true uses
Threads.@spawn so the bar keeps animating even during a long, never-yielding
computation; it is worth it only when such a loop is expected.
"""
function start_render_task!(ctx::ProgressContext; threaded::Bool = false)
    ctx.task === nothing || return ctx.task
    ctx.running[] = true
    _register_active!(ctx)
    ctx.task = threaded ? Threads.@spawn(_render_loop(ctx)) : (@async _render_loop(ctx))
    return ctx.task
end

"""
    _render_loop(ctx)

The frame-rate-limited render loop.  It ticks at most 1 / ctx.dt times a second,
and once the bar is finished it keeps drawing for another vanish seconds so the
completed bar is readable, then erases it.
"""
function _render_loop(ctx::ProgressContext)
    drew_final = false
    try
        while ctx.running[]
            if ctx.finished[]
                # A finished bar never changes, so it is drawn once more and then
                # left alone: redrawing it while it lingers would only scribble
                # over whatever the caller printed in the meantime.
                if !drew_final
                    render_tick!(ctx; force = true)
                    drew_final = true
                end
            else
                render_tick!(ctx)
            end
            if ctx.finished[]
                # Flat output is append-only: there is nothing to linger for.
                ctx.tty || break
                # vanish = Inf means keep the finished bar on screen forever.
                isinf(ctx.vanish) && break
                (time() - ctx.state.finish[]) >= ctx.vanish && break
            end
            sleep(ctx.dt)
        end
    catch err
        # Rendering must never take the user's computation down with it, and it must
        # not log through the user's logger (which may be capturing into this very
        # context), so failures go straight to stderr.
        try
            print(stderr, "Progbiotic: render task stopped: ", sprint(showerror, err), "\n")
        catch
        end
    finally
        try
            _finalize_render!(ctx)
        catch
        end
        try
            _close_log_sink!(ctx)
        catch
        end
        _unregister_active!(ctx)
    end
    return nothing
end

"""
    _finalize_render!(ctx)

Hand the terminal back.  A finished bar whose vanish timeout has elapsed is erased;
anything else is left on screen, with the cursor already parked on the row below
the block.
"""
function _finalize_render!(ctx::ProgressContext)
    ctx.tty || return nothing
    ctx.finished[] || return nothing
    isinf(ctx.vanish) && return nothing
    return _erase_tty!(ctx)
end

"""
    stop_render_task!(ctx; wait = true)

Ask the render task to stop and, by default, wait for it to finish its cleanup.
Unlike finish! this does not wait for the vanish timeout: it is the "tear down now"
path, used when a bar is abandoned rather than completed.
"""
function stop_render_task!(ctx::ProgressContext; wait::Bool = true)
    ctx.running[] = false
    task = ctx.task
    (task !== nothing && wait) && _wait_quietly(task)
    _unregister_active!(ctx)
    return nothing
end

"""
    finish!(ctx::ProgressContext; wait = !ctx.tty)

Mark the bar complete: clamp the counter to the total, stamp the finish time, draw
the final 100% frame synchronously, and let the render task linger for vanish
seconds before erasing it.

wait blocks until the render task has torn itself down.  It defaults to true for
non-interactive output, where teardown is immediate and callers reasonably expect
the final line to already be in the buffer, and to false for a terminal, where
waiting would block for the whole vanish timeout for no reason.
"""
function finish!(ctx::ProgressContext; wait::Bool = !ctx.tty)
    if ctx.finished[]
        (wait && ctx.task !== nothing) && _wait_quietly(ctx.task)
        ctx.task === nothing && _close_log_sink!(ctx)
        _unregister_active!(ctx)
        return nothing
    end
    state = ctx.state
    state.total !== nothing && (state.current[] = state.total)
    state.last_update = time()
    state.finish[] == 0 && (state.finish[] = time())
    ctx.finished[] = true

    task = ctx.task
    if task === nothing
        # Nothing is rendering this bar, so the final frame has to be drawn here.
        ctx.tty ? _draw_tty!(ctx) : _draw_flat!(ctx; force = true)
        _close_log_sink!(ctx)
    elseif wait
        # The render task owns the terminal.  It draws the final frame, honours the
        # vanish timeout and erases the block, all in one place, so finish! and the
        # task can never both draw - or erase - the same block.
        _wait_quietly(task)
    end
    _unregister_active!(ctx)
    return nothing
end

function _wait_quietly(task::Task)
    try
        Base.wait(task)
    catch
    end
    return nothing
end
