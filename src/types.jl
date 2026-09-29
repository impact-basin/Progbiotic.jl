# Core value types shared by the whole package.
#
# This file defines the vocabulary the rest of the refactor is built on:
#
#   * AbstractColumn   - the pluggable rendering interface (src/columns.jl);
#   * LogEntry         - one intercepted log record (src/logger.jl);
#   * BarState         - the atomic progress counters (src/bar.jl);
#   * ProgressContext  - a state bound to a layout, a stream and a render task.
#
# Nothing here performs I/O; src/engine.jl owns every terminal interaction.
#
# Note the deliberate distinction from the older tree renderer:
#
#   * ProgContext     (src/context.jl) is a *handle* into a ProgBar tree, and is
#                     what the @progress macro binds;
#   * ProgressContext (this file) is the single-bar, column-layout context used
#                     by prog(...) and Progress(...).

# ---------------------------------------------------------------------------
# Columns
# ---------------------------------------------------------------------------

"""
    AbstractColumn

Supertype of every progress-bar column.

A column is a small, stateless value that knows how to turn a BarState into one
string. Columns are composed into a Vector{AbstractColumn} (a *layout*) and
joined with single spaces by the renderer, so a layout reads left-to-right like the
bar it draws:

    layout = (Spinner(:dots), Tag("{desc}"), Bar(),
              Percent(), Count(), Rate("it/s"), Eta(), Postfix())

Implementations must define

    render_column(col::MyColumn, state::BarState) -> String

Columns must be cheap to render (the engine calls them up to 20 times a second) and
must never block: they only read the atomic progress state.
"""
abstract type AbstractColumn end

"""
    render_column(col::AbstractColumn, state::BarState) -> String

Render one column of a progress line.  This is the extension point for custom
columns: subtype AbstractColumn and add a method.

Returning an empty string is allowed and means "this column contributes nothing
right now"; the engine drops empty columns along with the whitespace around them.
"""
function render_column end

# ---------------------------------------------------------------------------
# Render context
# ---------------------------------------------------------------------------

"""
    ProgressContext(total = nothing; desc = "", layout = default_layout(),
                    io = stdout, vanish = 1.0, fps = 20.0, flat_step = 10,
                    tty = nothing, log_file = nothing) -> ProgressContext

Everything needed to *draw* one progress bar: the atomic BarState, the column
layout, the output stream, the intercepted-log buffer and the background render
task.

# Keyword arguments
- desc:      the bar's description (see Tag's "{desc}" template).
- layout:    a Vector{AbstractColumn}; defaults to default_layout().
- io:        output stream (defaults to stdout).
- vanish:    seconds a finished bar (and the log lines under it) stays on screen
             before being erased; false keeps it forever, 0.0 erases it at once.
- fps:       render cap in frames per second (default 20, i.e. a 50 ms tick).
- flat_step: in non-interactive mode, emit a flat log line every this many percent.
- tty:       force interactive (true) or flat (false) mode; by default this is
             detected from the stream and the CI environment variable.
- log_file:  a path or IO every intercepted log record is *permanently* appended
             to, in plain text, even after it has vanished from the screen.

A context is already thread-safe: advancing it only touches atomics, log appends
take the log lock, and every terminal write happens under the write lock.
"""
mutable struct ProgressContext
    # Atomic counters and timing.
    state          :: BarState
    # Columns, joined with single spaces.
    layout         :: Vector{AbstractColumn}
    # Where the bar is drawn.
    io             :: IO
    # Whether the stream is an interactive terminal (ANSI) or a flat log stream.
    tty            :: Bool
    # Seconds a finished bar stays on screen; Inf means forever.
    vanish         :: Float64
    # Seconds between render ticks (1 / fps).
    dt             :: Float64
    # Non-interactive mode: emit a line every this many percent.
    flat_step      :: Int
    # Intercepted, not-yet-expired log records.
    logs           :: Vector{LogEntry}
    # Guards the log buffer.
    log_lock       :: ReentrantLock
    # Persistent sink destination: a path, an IO, or nothing.
    log_file       :: Union{String, IO, Nothing}
    # Opened sink stream, or nothing.
    log_sink       :: Union{IO, Nothing}
    # Guards the sink.
    sink_lock      :: ReentrantLock
    # Guards *all* writes to the output stream.
    write_lock     :: ReentrantLock
    # The background render task, once started.
    task           :: Union{Task, Nothing}
    # Set to false to ask the render task to stop.
    running        :: Threads.Atomic{Bool}
    # Set once the bar has been finished.
    finished       :: Threads.Atomic{Bool}
    # Number of terminal rows the last drawn frame occupied.
    rendered_lines :: Int
    # Last percentage emitted in flat mode (throttles CI output).
    last_flat_pct  :: Int
    # Counter value observed at the previous tick; see _refresh_timing!.
    last_count     :: Int
    # time() of the last frame actually drawn.
    last_render    :: Float64
end

"""
    _resolve_vanish(vanish) -> Float64

Normalise the vanish option: false and nothing mean "keep on screen forever" (Inf),
true means the 1.0 second default, and a number is the timeout in seconds, where
0.0 erases immediately.
"""
function _resolve_vanish(vanish)
    vanish === nothing && return Inf
    vanish === false && return Inf
    vanish === true && return 1.0
    vanish isa Real ||
        throw(ProgbioticError("vanish must be a Bool or a number of seconds; got ",
                              repr(vanish)))
    v = float(vanish)
    v < 0 && throw(ProgbioticError("vanish must be >= 0; got ", v))
    return v
end

"""
    _is_tty(io) -> Bool

Whether the stream is an interactive terminal, i.e. whether ANSI cursor control is
safe.

Julia's Base has no isatty; the idiomatic test is whether the stream is a Base.TTY
(an IOContext is unwrapped first).  Redirecting stdout to a file or a pipe - or
running under CI, where CI=true is conventionally exported - turns this off, and
the engine then emits flat, ANSI-free log lines instead.
"""
_is_tty(io::IO) = _is_tty_impl(_unwrap_io(io))

_unwrap_io(io::IOContext) = _unwrap_io(io.io)
_unwrap_io(io::IO) = io

# Only a real terminal (and a non-CI environment) can be drawn to in place.
function _is_tty_impl(io)
    io isa Base.TTY || return false
    return !_ci_environment()
end

"""True when the CI environment variable marks a non-interactive build."""
function _ci_environment()
    value = lowercase(strip(get(ENV, "CI", "")))
    return value == "true" || value == "1" || value == "yes"
end

function ProgressContext(total::Union{Int, Nothing} = nothing;
                         desc::AbstractString = "",
                         layout::Union{Nothing, AbstractVector} = nothing,
                         io::IO = stdout,
                         vanish = 1.0,
                         fps::Real = 20.0,
                         flat_step::Integer = 10,
                         tty::Union{Bool, Nothing} = nothing,
                         log_file = nothing)
    state = BarState(total; desc = desc)
    columns = AbstractColumn[c for c in (layout === nothing ? default_layout() : layout)]
    interactive = tty === nothing ? _is_tty(io) : Bool(tty)
    fps > 0 || throw(ProgbioticError("fps must be positive; got ", fps))
    sink, destination = _open_log_sink(log_file)
    return ProgressContext(state,
                           columns,
                           io,
                           interactive,
                           _resolve_vanish(vanish),
                           1.0 / fps,
                           max(1, Int(flat_step)),
                           LogEntry[],
                           ReentrantLock(),
                           destination,
                           sink,
                           ReentrantLock(),
                           ReentrantLock(),
                           nothing,
                           Threads.Atomic{Bool}(false),
                           Threads.Atomic{Bool}(false),
                           0,
                           -1,
                           0,
                           0.0)
end

function Base.show(io::IO, ctx::ProgressContext)
    state = ctx.state
    print(io, "ProgressContext(", repr(state.desc[]), ", ",
          state.total === nothing ? "indeterminate" : string(state.current[], "/", state.total),
          ctx.tty ? ", tty" : ", flat", ")")
end
