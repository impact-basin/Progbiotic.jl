# Log interception, transient buffers, persistent sinks and ProgressLogging
# integration.
#
# Two independent renderers need log plumbing:
#
#   * the tree renderer (@progress / ProgBar), whose records live in a
#     ProgLogStore keyed by ProgJob;
#   * the column renderer (prog / Progress), whose records live in a
#     Vector{LogEntry} on a ProgressContext.
#
# Both share the three ideas implemented here: records are *intercepted* by a
# ProgbioticLogger installed for the scope, buffered per progress bar, and pruned
# once they are older than the scope's vanish timeout.  When the scope was given a
# log_file, every record is also appended, permanently and in plain text, to that
# sink - a transient line on the screen, a durable line on disk.

# ---------------------------------------------------------------------------
# The logger
# ---------------------------------------------------------------------------

"""
    ProgbioticLogger(context = current_prog_context(); capture = true,
                     parent = Logging.current_logger())

Logging.AbstractLogger that diverts log records emitted inside a progress scope
into that scope's bar, so they can be drawn underneath it.

capture selects the levels that are intercepted:

- true (default): every level (@debug, @info, @warn, @error);
- false: nothing - every record is passed straight through;
- a Logging.LogLevel: that level and above;
- a collection of levels and/or symbols, e.g. [:warn, :error].

Records that are not captured are forwarded to parent - the logger that was
current when the progress scope was entered, by default the global logger - so they
behave exactly as they would outside the scope.

The context may be either a ProgContext (tree renderer) or a ProgressContext
(column renderer); with neither, the current task's context is looked up.
"""
struct ProgbioticLogger <: Logging.AbstractLogger
    context :: Union{ProgContext, ProgressContext, Nothing}
    capture :: Union{Bool, Logging.LogLevel, Vector{Logging.LogLevel}}
    parent  :: Union{Logging.AbstractLogger, Nothing}
end

"""
    _capture_levels(capture) -> Union{Bool, Logging.LogLevel, Vector{Logging.LogLevel}}

Normalise the capture / capture_logs option of a @progress scope, or of
ProgbioticLogger.
"""
function _capture_levels(capture)
    capture === nothing && return true
    capture isa Bool && return capture
    capture isa Logging.LogLevel && return capture
    if capture isa AbstractVector || capture isa Tuple || capture isa AbstractSet
        return Logging.LogLevel[_log_level(level) for level in capture]
    end
    error("Progbiotic: capture must be a Bool, a LogLevel, or a collection of ",
          "levels; got ", repr(capture))
end

function ProgbioticLogger(context::Union{ProgContext, ProgressContext, Nothing} = current_prog_context();
                          capture = true,
                          parent::Union{Logging.AbstractLogger, Nothing} = Logging.current_logger())
    # A scope logger forwards its uncaptured records straight past the global
    # capture layer, so opting out of capture locally really does opt out.
    return ProgbioticLogger(context, _capture_levels(capture), _strip_capture_wrapper(parent))
end

_strip_capture_wrapper(logger) = logger

# Task-local storage key holding the innermost context executing in this task.
const _PROG_CTX_KEY = :__progbiotic_current_context__

# Task-local storage key holding whatever set_postfix!() should update: a ProgJob
# (tree renderer) or a ProgressContext (column renderer).
const _PROG_TARGET_KEY = :__progbiotic_current_target__

"""
    current_prog_context() -> Union{ProgContext, Nothing}

The innermost ProgContext active in the current task, or nothing when no progress
scope is running.
"""
current_prog_context() = get(task_local_storage(), _PROG_CTX_KEY, nothing)

"""
    current_progress_target() -> Union{ProgJob, ProgressContext, Nothing}

What a bare set_postfix!(; kwargs...) should attach its metrics to.  Inside a
@progress scope this is the innermost job; inside a prog/Progress scope it is the
context itself.
"""
current_progress_target() = get(task_local_storage(), _PROG_TARGET_KEY, nothing)

# ---------------------------------------------------------------------------
# Active-context registry (fallback for set_postfix!)
# ---------------------------------------------------------------------------
#
# "for x in prog(...)" runs the loop body in the caller's task, so there is no
# dynamic scope in which to install a task-local target.  Rather than paying a
# task-local write on every iteration - which is exactly the overhead this package
# exists to avoid - the engine keeps a small registry of live bars and a bare
# set_postfix!() falls back to the innermost one.

const _ACTIVE_LOCK = ReentrantLock()
const _ACTIVE_CONTEXTS = Any[]

"""Register a live bar so a bare set_postfix!() can find it."""
function _register_active!(ctx)
    @lock _ACTIVE_LOCK push!(_ACTIVE_CONTEXTS, ctx)
    return ctx
end

"""Drop a finished bar from the registry."""
function _unregister_active!(ctx)
    @lock _ACTIVE_LOCK filter!(existing -> existing !== ctx, _ACTIVE_CONTEXTS)
    return nothing
end

"""
    current_active_context() -> Union{ProgressContext, ProgContext, Nothing}

The innermost live progress bar: the most recently started one that has not
finished.  Used only as a fallback when no task-local target is installed.
"""
function current_active_context()
    @lock _ACTIVE_LOCK begin
        for index in length(_ACTIVE_CONTEXTS):-1:1
            candidate = _ACTIVE_CONTEXTS[index]
            if candidate isa ProgressContext
                candidate.finished[] || return candidate
            else
                return candidate
            end
        end
    end
    return nothing
end

"""The bar a bare set_postfix!() should update, or nothing."""
function _postfix_target()
    target = current_progress_target()
    target === nothing || return target
    return current_active_context()
end

# ---------------------------------------------------------------------------
# Persistent sinks
# ---------------------------------------------------------------------------

"""
    _open_log_sink(destination) -> (sink, destination)

Open the persistent log sink.  A path is opened in append mode and owned by us (so
it is closed again when the bar is torn down); an IO is used as given and left
alone.  Returns (nothing, nothing) when no sink was requested.
"""
function _open_log_sink(destination)
    destination === nothing && return (nothing, nothing)
    destination isa IO && return (destination, destination)
    destination isa AbstractString ||
        error("Progbiotic: log_file must be a path or an IO; got ", repr(destination))
    return (open(String(destination), "a"), destination)
end

"""
    _write_sink!(owner, line) -> Bool

Append one already-formatted line to an owner's sink, if it has one.  Owners are
ProgressContext values and ProgBar values; both expose log_sink and sink_lock.

Every line is flushed immediately, so a log file is complete and readable at any
moment - including while the bar is still running, and including after the process
was killed.
"""
function _write_sink!(owner, line::AbstractString)
    sink = owner.log_sink
    sink === nothing && return false
    @lock owner.sink_lock begin
        print(sink, line, "\n")
        flush(sink)
    end
    return true
end

"""
    _ensure_log_sink!(owner, destination) -> owner

Attach a persistent sink to a bar, opening it if this is the first request.  Used
by nested @progress levels that introduce their own log_file.
"""
function _ensure_log_sink!(owner, destination)
    destination === nothing && return owner
    owner.log_file === destination && return owner
    sink, resolved = _open_log_sink(destination)
    @lock owner.sink_lock begin
        owner.log_file = resolved
        owner.log_sink = sink
    end
    return owner
end

"""
    _close_log_sink!(owner)

Close the sink if we opened it.  Sinks the caller handed us as an IO are left open:
they own them.
"""
function _close_log_sink!(owner)
    @lock owner.sink_lock begin
        sink = owner.log_sink
        if !(sink === nothing || owner.log_file isa IO)
            try
                flush(sink)
                close(sink)
            catch
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Column-renderer log buffer (ProgressContext)
# ---------------------------------------------------------------------------

"""The most log lines buffered per bar (older ones are dropped)."""
const LOG_BUFFER_LIMIT = 1024

"""
    push_log!(ctx::ProgressContext, level, message; kwargs...) -> LogEntry

Append an intercepted record to a column-renderer bar, and mirror it to the
persistent sink when one is configured.
"""
function push_log!(ctx::ProgressContext, level::Logging.LogLevel, message; kwargs...)
    entry = LogEntry(level, _format_log_message(message, kwargs), time())
    @lock ctx.log_lock begin
        push!(ctx.logs, entry)
        # Bound the buffer: only the newest entries can ever be on screen.
        overflow = length(ctx.logs) - LOG_BUFFER_LIMIT
        overflow > 0 && deleteat!(ctx.logs, 1:overflow)
    end
    _write_sink!(ctx, format_plain_log_line(entry))
    return entry
end

push_log!(ctx::ProgressContext, level::Symbol, message; kwargs...) =
    push_log!(ctx, _log_level(level), message; kwargs...)

"""
    prune_logs!(ctx::ProgressContext, now_sec = time())

Drop every buffered record older than the bar's vanish timeout.  Called on each
render tick, so the renderer only ever measures lines it is about to draw.
"""
function prune_logs!(ctx::ProgressContext, now_sec::Float64 = time())
    @lock ctx.log_lock begin
        filter!(entry -> !_expired(entry, now_sec, ctx.vanish), ctx.logs)
    end
    return nothing
end

"""
    active_logs(ctx::ProgressContext, now_sec = time()) -> Vector{LogEntry}

The non-expired records of a column-renderer bar, oldest first.  Expired records
are pruned as a side effect.
"""
function active_logs(ctx::ProgressContext, now_sec::Float64 = time())
    prune_logs!(ctx, now_sec)
    @lock ctx.log_lock return copy(ctx.logs)
end

"""
    pending_logs!(ctx::ProgressContext, now_sec = time()) -> Vector{LogEntry}

Mark and return the buffered records the non-interactive renderer has not streamed
out yet.  Entries are marked rather than removed: the flat renderer has nothing to
redraw over a line and so prints each record exactly once, but active_logs must keep
reporting everything the scope captured.
"""
function pending_logs!(ctx::ProgressContext, now_sec::Float64 = time())
    return @lock ctx.log_lock begin
        pending = LogEntry[]
        for entry in ctx.logs
            entry.printed && continue
            entry.printed = true
            push!(pending, entry)
        end
        pending
    end
end

"""
    has_active_logs(ctx::ProgressContext, now_sec = time()) -> Bool

Whether the bar currently has at least one non-expired log line.
"""
function has_active_logs(ctx::ProgressContext, now_sec::Float64 = time())
    prune_logs!(ctx, now_sec)
    @lock ctx.log_lock return !isempty(ctx.logs)
end

# ---------------------------------------------------------------------------
# ProgressLogging.jl integration
# ---------------------------------------------------------------------------

"""
    _progress_payload(level, message, kwargs) -> Union{NamedTuple, Nothing}

Recognise a ProgressLogging.jl progress record.

ProgressLogging has two on-the-wire shapes, and both are supported here so that
Progbiotic works with every released version without depending on the package:

  * 0.1.6 and later pass the record's message as a Progress struct carrying
    fraction / name / done / id fields;
  * earlier versions pass a keyword argument named progress, or the older
    underscore-prefixed spelling, alongside the log message.

Records of the second shape look like

    @info "msg" progress = 0.5
    @logmsg ProgressLevel "msg" progress = i / n _id = id

Returning nothing means "not a progress record", and the caller then falls back to
ordinary logging.
"""
function _progress_payload(level, message, kwargs)
    carried = _carried_progress(message)
    carried === nothing || return carried
    for key in (:progress, :_progress)
        haskey(kwargs, key) || continue
        parsed = _progress_value(kwargs[key])
        # A keyword of the right name carrying a value of the wrong type is not a
        # progress record, so the caller falls back to ordinary logging.
        parsed === nothing && break
        fraction, done = parsed
        name = haskey(kwargs, :_progress_desc) ? string(kwargs[:_progress_desc]) :
               (message isa AbstractString ? string(message) : "")
        return (fraction = fraction, name = name, done = done,
                id = haskey(kwargs, :_id) ? kwargs[:_id] : nothing)
    end
    return nothing
end

"""
    _carried_progress(message) -> Union{NamedTuple, Nothing}

A ProgressLogging.Progress carried by a record's message, in either of the two
shapes the package has used: the struct itself, or the ProgressString wrapper it
introduced so that monitors keyed on the bare struct keep working.
"""
function _carried_progress(message)
    message === nothing && return nothing
    if hasproperty(message, :fraction)
        return _progress_fields(message)
    end
    if hasproperty(message, :progress)
        inner = message.progress
        if inner !== nothing && hasproperty(inner, :fraction)
            return _progress_fields(inner)
        end
    end
    return nothing
end

_progress_fields(progress) =
    (fraction = _as_fraction(progress.fraction),
     name     = hasproperty(progress, :name) ? string(progress.name) : "",
     done     = hasproperty(progress, :done) ? Bool(progress.done) : false,
     id       = hasproperty(progress, :id) ? progress.id : nothing)

_as_fraction(value) = value isa Real ? float(value) : nothing

"""
    _progress_value(value) -> Union{Tuple{Union{Float64,Nothing}, Bool}, Nothing}

Interpret the value of a progress keyword argument the way ProgressLogging defines
it: a number is a fraction, nothing (or NaN) means indeterminate, and the string
"done" closes the bar.  Returns nothing when the value is not a progress value at
all.
"""
function _progress_value(value)
    value isa Real && return (float(value), false)
    value === nothing && return (nothing, false)          # indeterminate
    value isa AbstractString && return (nothing, value == "done")
    return nothing
end

"""
    handle_progress_record(bar, payload) -> Bool

Route a ProgressLogging.jl progress record into a live progress bar, returning
whether it was consumed.

A numeric fraction is translated into a counter value when the bar knows its total
(which is what the ProgressLogging protocol means by a fraction), and always
mirrored into the bar's postfix metrics as progress=<fraction>.  The record's name
becomes the bar's description if it does not already have one.
"""
function handle_progress_record(bar::ProgressContext, payload)::Bool
    state = bar.state
    fraction = payload.fraction
    if fraction !== nothing && state.total !== nothing
        state.current[] = clamp(round(Int, fraction * state.total), 0, state.total)
        state.last_update = time()
    end
    isempty(payload.name) || _set_description!(state, payload.name)
    if fraction !== nothing
        _merge_postfix!(state; progress = round(fraction, digits = 4))
    end
    if payload.done && state.total !== nothing
        state.current[] = state.total
    end
    return true
end

function handle_progress_record(job::ProgJob, payload)::Bool
    fraction = payload.fraction
    @lock job.lock begin
        if fraction !== nothing && job.total !== nothing
            job.state = clamp(round(Int, fraction * job.total), 0, job.total)
            job.last_update = time()
        end
        isempty(payload.name) || isempty(job.desc) && (job.desc = payload.name)
        fraction === nothing || (job.postfix[:progress] = round(fraction, digits = 4))
    end
    return true
end

handle_progress_record(::Nothing, payload) = false
handle_progress_record(bar::ProgContext, payload) = handle_progress_record(bar.parent, payload)

# ---------------------------------------------------------------------------
# Logger callbacks
# ---------------------------------------------------------------------------

_captures(logger::ProgbioticLogger, level::Logging.LogLevel) = _captures(logger.capture, level)
_captures(capture::Bool, level::Logging.LogLevel) = capture
_captures(capture::Logging.LogLevel, level::Logging.LogLevel) = level >= capture
_captures(capture::Vector{Logging.LogLevel}, level::Logging.LogLevel) = level in capture

# Debug stays enabled so that @debug records are generated at all: each record is
# then either captured or handed to parent unchanged.  The ProgressLogging level
# (-1) is enabled too, since it sits below Debug.
Logging.min_enabled_level(logger::ProgbioticLogger) =
    min(Logging.Debug,
        logger.parent === nothing ? Logging.Info : Logging.min_enabled_level(logger.parent))

function Logging.shouldlog(logger::ProgbioticLogger, level, _module, group, id)
    _captures(logger, level) && return true
    parent = logger.parent
    return parent !== nothing && Logging.shouldlog(parent, level, _module, group, id)
end

Logging.catch_exceptions(logger::ProgbioticLogger) =
    logger.parent === nothing ? true : Logging.catch_exceptions(logger.parent)

"""
    _logger_context(logger) -> Union{ProgContext, ProgressContext, Nothing}

The bar a logger's records belong to: the one it was built with, or the innermost
one active in the current task.
"""
function _logger_context(logger::ProgbioticLogger)
    context = logger.context
    context === nothing || return context
    return current_prog_context()
end

function Logging.handle_message(logger::ProgbioticLogger, level, message, _module, group, id,
                                file, line; kwargs...)
    # ProgressLogging records are state, not history: they update the bar rather
    # than producing a line under it.
    payload = _progress_payload(level, message, kwargs)
    if payload !== nothing
        bar = _logger_context(logger)
        if bar !== nothing
            handle_progress_record(bar, payload)
            return nothing
        end
    end
    if _captures(logger, level)
        context = _logger_context(logger)
        if context isa ProgContext || context isa ProgressContext
            push_log!(context, level, message; kwargs...)
            return nothing
        end
    end
    # Not captured here: preserve the record's normal behaviour by handing it to the
    # logger that was current when the scope was entered.
    parent = logger.parent
    if parent !== nothing && Logging.shouldlog(parent, level, _module, group, id)
        Logging.handle_message(parent, level, message, _module, group, id, file, line; kwargs...)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# The global capture layer
# ---------------------------------------------------------------------------
#
# A macro can wrap its loop body in a logger, but "for x in prog(...)" cannot: the
# loop body runs in the caller's task, outside any dynamic scope the iterator could
# open.  So that a bare prog/Progress loop intercepts logs the same way @progress
# does, Progbiotic wraps the process-wide logger once, at load time.
#
# The wrapper is completely transparent whenever no bar is running: it asks the
# logger it wraps whether the record would be logged at all, and with no bar active
# it simply forwards the record.  It never lowers min_enabled_level, so no @debug
# statement starts being evaluated merely because Progbiotic was loaded.

"""
    ProgbioticGlobalLogger(parent)

The process-wide log-capture layer installed by the Progbiotic __init__ hook.

When a progress bar is active, records are diverted into it - which is what makes a
bare prog(...) loop intercept @info and @warn exactly as a @progress scope does.
When no bar is active the record is handed to parent untouched, and
min_enabled_level / shouldlog defer entirely to parent, so installing this layer
changes nothing about which records exist.

Turn it off with disable_log_capture!, or by setting the environment variable
PROGBIOTIC_CAPTURE_LOGS to false before loading Progbiotic.
"""
struct ProgbioticGlobalLogger <: Logging.AbstractLogger
    parent :: Union{Logging.AbstractLogger, Nothing}
end

Logging.min_enabled_level(logger::ProgbioticGlobalLogger) =
    logger.parent === nothing ? Logging.Info : Logging.min_enabled_level(logger.parent)

Logging.shouldlog(logger::ProgbioticGlobalLogger, level, _module, group, id) =
    logger.parent !== nothing && Logging.shouldlog(logger.parent, level, _module, group, id)

Logging.catch_exceptions(logger::ProgbioticGlobalLogger) =
    logger.parent === nothing ? true : Logging.catch_exceptions(logger.parent)

function Logging.handle_message(logger::ProgbioticGlobalLogger, level, message, _module,
                                group, id, file, line; kwargs...)
    bar = _active_capture_bar()
    if bar !== nothing
        payload = _progress_payload(level, message, kwargs)
        if payload !== nothing
            handle_progress_record(bar, payload)
            return nothing
        end
        push_log!(bar, level, message; kwargs...)
        return nothing
    end
    parent = logger.parent
    parent === nothing && return nothing
    Logging.handle_message(parent, level, message, _module, group, id, file, line; kwargs...)
    return nothing
end

_strip_capture_wrapper(logger::ProgbioticGlobalLogger) = logger.parent

"""The bar logs should be diverted into, or nothing when none is running."""
function _active_capture_bar()
    scope = current_prog_context()
    scope === nothing || return scope
    return current_active_context()
end

const _CAPTURE_LOCK = ReentrantLock()
const _CAPTURE_LAYER = Ref{Union{ProgbioticGlobalLogger, Nothing}}(nothing)

"""
    enable_log_capture!() -> Bool

Install the global capture layer, so that log records emitted while a progress bar
is running are drawn under that bar (and mirrored to its log_file) instead of being
printed.  Called automatically when Progbiotic is loaded; returns whether the layer
is installed afterwards.
"""
function enable_log_capture!()
    @lock _CAPTURE_LOCK begin
        _CAPTURE_LAYER[] === nothing || return true
        previous = Logging.global_logger()
        previous isa ProgbioticGlobalLogger && return false
        layer = ProgbioticGlobalLogger(previous)
        Logging.global_logger(layer)
        _CAPTURE_LAYER[] = layer
    end
    return true
end

"""
    disable_log_capture!() -> Bool

Remove the global capture layer, restoring the logger that was installed before it.
Progress bars keep working; their log records simply go to the ordinary logger.
"""
function disable_log_capture!()
    @lock _CAPTURE_LOCK begin
        layer = _CAPTURE_LAYER[]
        layer === nothing && return false
        Logging.global_logger(layer.parent)
        _CAPTURE_LAYER[] = nothing
    end
    return true
end

"""Whether the global capture layer is currently installed."""
log_capture_enabled() = _CAPTURE_LAYER[] !== nothing

"""
    __init_capture!() -> Bool

Install the global capture layer at package load, unless the environment variable
PROGBIOTIC_CAPTURE_LOGS is set to false.
"""
function __init_capture!()
    capture = lowercase(strip(get(ENV, "PROGBIOTIC_CAPTURE_LOGS", "true")))
    (capture == "false" || capture == "0" || capture == "no") && return false
    return enable_log_capture!()
end

# ---------------------------------------------------------------------------
# Scope helpers
# ---------------------------------------------------------------------------

"""
    _with_log_capture(f, ctx::ProgContext, capture)

Run f with a ProgbioticLogger installed (through Logging.with_logger) and with ctx
registered as the current task's innermost context, so log records emitted by f
land in ctx's job buffer and set_postfix! attaches to that job.  Called by the code
generated by @progress for every progress level.
"""
function _with_log_capture(f::Function, ctx::ProgContext, capture)
    logger = ProgbioticLogger(ctx; capture = capture)
    _register_active!(ctx)
    return Logging.with_logger(logger) do
        try
            # Scoped, so that leaving a nested level restores the outer level's
            # job as the target of a bare set_postfix!().
            _with_scope(f, ctx)
        finally
            _unregister_active!(ctx)
        end
    end
end

# Run f with the task-local target installed, restoring whatever was there before.
function _with_scope(f::Function, context)
    previous_context = get(task_local_storage(), _PROG_CTX_KEY, nothing)
    previous_target = get(task_local_storage(), _PROG_TARGET_KEY, nothing)
    if context isa ProgContext
        task_local_storage(_PROG_CTX_KEY, context)
        task_local_storage(_PROG_TARGET_KEY, context.parent)
    else
        task_local_storage(_PROG_TARGET_KEY, context)
    end
    try
        return f()
    finally
        task_local_storage(_PROG_CTX_KEY, previous_context)
        task_local_storage(_PROG_TARGET_KEY, previous_target)
    end
end

"""
    _with_progress_logging(f, ctx::ProgressContext; capture = true)

Run f with log records captured into a column-renderer bar, and with a bare
set_postfix!() resolving to it.  This is the explicit scope form for the
iterator/handle interface:

    p = Progress(100)
    with_progress_logging(p) do
        for i in 1:100
            next!(p)
            i == 50 && @info "halfway"
        end
    end
"""
function _with_progress_logging(f::Function, ctx::ProgressContext; capture = true)
    logger = ProgbioticLogger(ctx; capture = capture)
    return Logging.with_logger(logger) do
        _with_scope(f, ctx)
    end
end

_as_context(ctx::ProgressContext) = ctx

"""
    with_progress_logging(f, bar; capture = true)

Run f with log records captured into bar and with a bare set_postfix!() resolving
to it.  Exported form of the scope helper used by Progress and prog.
"""
with_progress_logging(f::Function, bar; capture = true) =
    _with_progress_logging(f, _as_context(bar); capture = capture)

# ---------------------------------------------------------------------------
# set_postfix!
# ---------------------------------------------------------------------------

"""
    set_postfix!(; kwargs...)
    set_postfix!(bar; kwargs...)

Attach dynamic key/value metrics to the active progress bar.  They are rendered
inline on the right-hand side of the bar (see PostfixColumn) and overwritten on
every call, so they are state rather than history:

    for epoch in 1:100
        set_postfix!(loss = round(loss, digits = 4), lr = 1e-4)
    end

With no argument the metrics go to the innermost active bar: inside a @progress
scope, the job of the innermost level; inside a prog/Progress scope, that bar.
Metrics may also be attached to a specific bar by passing it explicitly.
"""
function set_postfix!(; kwargs...)
    target = _postfix_target()
    target === nothing && return nothing
    return set_postfix!(target; kwargs...)
end

"""Attach dynamic metrics to a column-renderer bar."""
function set_postfix!(ctx::ProgressContext; kwargs...)
    _merge_postfix!(ctx.state; kwargs...)
    return ctx
end

"""Attach dynamic metrics to a tree-renderer job (one bar of a @progress scope)."""
function set_postfix!(job::ProgJob; kwargs...)
    @lock job.lock begin
        for (key, value) in kwargs
            job.postfix[key] = value
        end
    end
    return job
end
