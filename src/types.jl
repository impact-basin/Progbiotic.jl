# Core value types shared by the whole package.
#
# This file defines the vocabulary the rest of the refactor is built on:
#
#   * AbstractColumn   - the pluggable rendering interface (src/columns.jl);
#   * LogEntry         - one intercepted log record (src/logger.jl);
#   * ProgressState    - the lock-free, atomic progress counters;
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

A column is a small, stateless value that knows how to turn a ProgressState into
one string.  Columns are composed into a Vector{AbstractColumn} (a *layout*) and
joined with single spaces by the renderer, so a layout reads left-to-right like the
bar it draws:

    layout = [SpinnerColumn(:dots), TextColumn("{desc}"), BarColumn(),
              PercentageColumn(), RateColumn("it/s"), ETAColumn(), PostfixColumn()]

Implementations must define

    render_column(col::MyColumn, state::ProgressState) -> String

Columns must be cheap to render (the engine calls them up to 20 times a second) and
must never block: they only read the atomic progress state.
"""
abstract type AbstractColumn end

"""
    render_column(col::AbstractColumn, state::ProgressState) -> String

Render one column of a progress line.  This is the extension point for custom
columns: subtype AbstractColumn and add a method.

Returning an empty string is allowed and means "this column contributes nothing
right now"; the engine drops empty columns along with the whitespace around them.
"""
function render_column end

# ---------------------------------------------------------------------------
# Intercepted log records
# ---------------------------------------------------------------------------

"""
    LogEntry

A single log record intercepted inside a prog(...) or Progress(...) scope.

Fields:

- level:      the Logging.LogLevel of the record (Logging.Info, Logging.Warn, ...);
- message:    the rendered message, including any log keyword arguments;
- created_at: the time() at which the record was emitted.
- printed:    set once the non-interactive renderer has streamed the entry out, so
              an append-only stream prints each record exactly once while
              active_logs keeps reporting everything the scope captured.

Entries live in a Vector{LogEntry} inside the owning ProgressContext and are pruned
once they are older than the scope's vanish timeout.  Rendering them never nests
them inside the bar's own frame, so a transient line cannot tear the display; see
src/engine.jl.
"""
mutable struct LogEntry
    level      :: Logging.LogLevel
    message    :: String
    created_at :: Float64
    # Set once the non-interactive renderer has streamed the entry out, so an
    # append-only stream prints each record exactly once while active_logs keeps
    # reporting everything the scope captured.
    printed    :: Bool

    LogEntry(level, message, created_at) = new(level, message, created_at, false)
end

Base.show(io::IO, e::LogEntry) = print(io, "LogEntry(", e.level, ", ", repr(e.message), ")")

"""True once the entry is older than the given number of seconds."""
_expired(e::LogEntry, now_sec::Float64, vanish::Float64) = (now_sec - e.created_at) > vanish

# ---------------------------------------------------------------------------
# Progress state
# ---------------------------------------------------------------------------

"""
    ProgressState(total = nothing; desc = "") -> ProgressState

The mutable, shared state of a single progress bar.

The counter itself is a Threads.Atomic{Int}, so that advancing it is a single
lock-free atomic_add!.  That is the property which lets a Threads.@threads loop
advance one bar from every worker without lock contention, and which keeps the
overhead of a fine-grained loop in the noise.

A total of nothing means *indeterminate*: the length of the work is unknown (an
unbounded channel, an iterator with SizeUnknown), so the bar renders a spinner and
a marquee instead of a percentage and an ETA.

Only the description and the postfix metrics ever change after construction, and
each of those is a Base.RefValue updated under the state lock.
"""
mutable struct ProgressState
    # Number of completed units.  Only ever touched through atomics.
    current        :: Threads.Atomic{Int}
    # Total units, or nothing for an indeterminate bar.
    total          :: Union{Int, Nothing}
    # time() at which the bar started.
    start          :: Float64
    # time() at which the bar finished, or 0.0 while still running.
    finish         :: Float64
    # time() of the most recent advance, used for rate and ETA.
    last_update    :: Float64
    # Bar description, e.g. "Parsing Records".
    desc           :: Base.RefValue{String}
    # Dynamic key/value metrics, e.g. Dict(:loss => 0.041).
    postfix        :: Base.RefValue{Dict{Symbol, Any}}
    # Insertion order of the postfix keys, so the rendered order stays stable.
    postfix_order  :: Base.RefValue{Vector{Symbol}}
    # Guards updates to the description and the postfix metrics.
    lock           :: ReentrantLock
end

function ProgressState(total::Union{Int, Nothing} = nothing; desc::AbstractString = "")
    now = time()
    return ProgressState(Threads.Atomic{Int}(0), total, now, 0.0, now,
                         Ref(String(desc)), Ref(Dict{Symbol, Any}()),
                         Ref(Symbol[]), ReentrantLock())
end

"""Number of completed units, read atomically."""
progress_current(s::ProgressState) = s.current[]

"""
    progress_fraction(s) -> Union{Float64, Nothing}

Completed fraction in [0, 1], or nothing when the bar is indeterminate.
"""
function progress_fraction(s::ProgressState)
    s.total === nothing && return nothing
    s.total <= 0 && return 1.0
    return clamp(s.current[] / s.total, 0.0, 1.0)
end

"""
    progress_elapsed(s) -> Float64

Seconds of *work* elapsed.  Measured up to the last observed advance (or up to
completion), so rate and ETA freeze while a bar sits idle waiting on a nested job
rather than decaying towards zero.
"""
function progress_elapsed(s::ProgressState)
    work_until = s.finish ≈ 0.0 ? s.last_update : s.finish
    return max(0.0, work_until - s.start)
end

"""Wall-clock seconds since the bar started (frozen once it finishes)."""
function progress_runtime(s::ProgressState)
    s.finish ≈ 0.0 && return max(0.0, time() - s.start)
    return max(0.0, s.finish - s.start)
end

"""Items per second, or zero when not enough time has passed to measure."""
function progress_rate(s::ProgressState)
    elapsed = progress_elapsed(s)
    elapsed <= 0 && return 0.0
    return s.current[] / elapsed
end

"""
    progress_eta(s) -> Union{Float64, Nothing}

Estimated seconds remaining, or nothing when it cannot be estimated: an
indeterminate bar, no progress yet, or a finished bar.
"""
function progress_eta(s::ProgressState)
    s.total === nothing && return nothing
    done = s.current[]
    done <= 0 && return nothing
    done >= s.total && return 0.0
    return (s.total - done) * (progress_elapsed(s) / done)
end

"""True once the bar has been marked finished."""
progress_finished(s::ProgressState) = !(s.finish ≈ 0.0)

# ---------------------------------------------------------------------------
# Render context
# ---------------------------------------------------------------------------

"""
    ProgressContext(total = nothing; desc = "", layout = default_layout(),
                    io = stdout, vanish = 1.0, fps = 20.0, flat_step = 10,
                    tty = nothing, log_file = nothing) -> ProgressContext

Everything needed to *draw* one progress bar: the atomic ProgressState, the column
layout, the output stream, the intercepted-log buffer and the background render
task.

# Keyword arguments
- desc:      the bar's description (see TextColumn's "{desc}" template).
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
    state          :: ProgressState
    # Thread-safe dynamic metrics; the same object as state.postfix.
    postfix        :: Base.RefValue{Dict{Symbol, Any}}
    # Insertion order of the postfix keys; the same as state.postfix_order.
    postfix_order  :: Base.RefValue{Vector{Symbol}}
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
    vanish isa Real || error("Progbiotic: vanish must be a Bool or a number of ",
                             "seconds; got ", repr(vanish))
    v = float(vanish)
    v < 0 && error("Progbiotic: vanish must be >= 0; got ", v)
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
    state = ProgressState(total; desc = desc)
    columns = layout === nothing ? default_layout() : Vector{AbstractColumn}(layout)
    interactive = tty === nothing ? _is_tty(io) : Bool(tty)
    fps > 0 || error("Progbiotic: fps must be positive; got ", fps)
    sink, destination = _open_log_sink(log_file)
    return ProgressContext(state,
                           state.postfix,
                           state.postfix_order,
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

"""
    _update_postfix!(state::ProgressState; kwargs...) -> ProgressState

Thread-safely merge keyword metrics into a state's postfix dictionary, recording the
insertion order of new keys so the rendered order never jumps around.
"""
function _update_postfix!(state::ProgressState; kwargs...)
    @lock state.lock begin
        dict = state.postfix[]
        order = state.postfix_order[]
        for (key, value) in kwargs
            haskey(dict, key) || push!(order, key)
            dict[key] = value
        end
    end
    return state
end

"""
    _postfix_pairs(state::ProgressState) -> Vector{Pair{Symbol, Any}}

A consistent snapshot of the postfix metrics, in the order the keys were first set.
Taken under the state lock, so a concurrent set_postfix! can never be observed
half-applied.
"""
function _postfix_pairs(state::ProgressState)
    @lock state.lock begin
        dict = state.postfix[]
        isempty(dict) && return Pair{Symbol, Any}[]
        order = state.postfix_order[]
        pairs = Pair{Symbol, Any}[]
        for key in order
            haskey(dict, key) && push!(pairs, key => dict[key])
        end
        # Keys inserted through the dictionary directly (bypassing
        # set_postfix!) still get rendered, just without a stable position.
        for key in keys(dict)
            key in order || push!(pairs, key => dict[key])
        end
        return pairs
    end
end

function Base.show(io::IO, ctx::ProgressContext)
    state = ctx.state
    print(io, "ProgressContext(", repr(state.desc[]), ", ",
          state.total === nothing ? "indeterminate" : string(state.current[], "/", state.total),
          ctx.tty ? ", tty" : ", flat", ")")
end
