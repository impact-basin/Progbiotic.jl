# log interception, transient buffers, persistent sinks and ProgressLogging
# integration.
#
# records are *intercepted* by a ProgbioticLogger installed for a scope, buffered on the
# node they belong to, and pruned once they are older than that node's vanish timeout.
# when the scope was given a log_file, every record is also appended, permanently and in
# plain text, to that sink: a transient line on the screen, a durable line on disk.

# ---------------------------------------------------------------------------
# the logger
# ---------------------------------------------------------------------------

"""
    ProgbioticLogger(bar = current_bar(); capture = true,
                     parent = Logging.current_logger())

Logging.AbstractLogger that diverts log records emitted inside a progress scope into that
scope's bar, so they can be drawn underneath it.

capture selects the levels that are intercepted:

- true (default): every level (@debug, @info, @warn, @error);
- false: nothing - every record is passed straight through;
- a Logging.LogLevel: that level and above;
- a collection of levels and/or symbols, e.g. [:warn, :error].

Records that are not captured are forwarded to `parent` - the logger that was current when
the progress scope was entered, by default the global logger - so they behave exactly as
they would outside the scope.

With no bar, the innermost bar active in the current task is used.
"""
struct ProgbioticLogger <: Logging.AbstractLogger
    bar     :: Union{Progress, Nothing}
    capture :: Union{Bool, Logging.LogLevel, Vector{Logging.LogLevel}}
    parent  :: Union{Logging.AbstractLogger, Nothing}
end

"""
    _capture_levels(capture) -> Union{Bool, Logging.LogLevel, Vector{Logging.LogLevel}}

Normalise the capture / capture_logs option of a @progress scope, or of ProgbioticLogger.
"""
function _capture_levels(capture)
    capture === nothing && return true
    capture isa Bool && return capture
    capture isa Logging.LogLevel && return capture
    if capture isa AbstractVector || capture isa Tuple || capture isa AbstractSet
        return Logging.LogLevel[_log_level(level) for level in capture]
    end
    throw(ProgbioticError("capture must be a Bool, a LogLevel, or a collection of ",
                          "levels; got ", repr(capture)))
end

function ProgbioticLogger(bar::Union{Progress, Nothing} = current_bar();
                          capture = true,
                          parent::Union{Logging.AbstractLogger, Nothing} = Logging.current_logger())
    return ProgbioticLogger(bar, _capture_levels(capture), parent)
end

"""
    current_bar() -> Union{Progress, Nothing}

The innermost bar active in the current task, or nothing when no progress scope is
running. This is where a bare `set_postfix!` attaches its metrics and where an unscoped
logger looks for a bar to fill.
"""
current_bar() = get(task_local_storage(), _CURRENT_KEY, nothing)

# Task-local storage key holding the innermost node executing in this task.
const _CURRENT_KEY = :__progbiotic_current_bar__

# ---------------------------------------------------------------------------
# message formatting
# ---------------------------------------------------------------------------

# renders a log message together with its keyword arguments, e.g.
# `"checkpoint" (record=25)`.
function _format_log_message(message, kwargs)
    # multi-line messages are flattened: the gutter draws exactly one row per entry, so
    # an embedded newline would desynchronise its height and tear the UI.
    msg = replace(string(message), '\n' => ' ', '\r' => ' ')
    isempty(kwargs) && return msg
    parts = String[string(k, "=", v) for (k, v) in kwargs]
    return string(msg, " (", join(parts, ", "), ")")
end

"""
    _log_level(name::Symbol) -> Logging.LogLevel

Maps :debug, :info, :warn and :error onto their Logging.LogLevel.
"""
function _log_level(name::Symbol)
    name === :debug && return Logging.Debug
    name === :info  && return Logging.Info
    name === :warn  && return Logging.Warn
    name === :error && return Logging.Error
    throw(ProgbioticError("unknown log level :", name,
                          "; expected :debug, :info, :warn or :error"))
end

_log_level(level::Logging.LogLevel) = level

# ---------------------------------------------------------------------------
# persistent sinks
# ---------------------------------------------------------------------------

"""
    _open_log_sink(destination) -> (sink, destination)

Open the persistent log sink. A path is opened in append mode and owned by us, so it is
closed again when the tree is torn down; an IO is used as given and left alone. Returns
(nothing, nothing) when no sink was requested.
"""
function _open_log_sink(destination)
    destination === nothing && return (nothing, nothing)
    destination isa IO && return (destination, destination)
    destination isa AbstractString ||
        throw(ProgbioticError("log_file must be a path or an IO; got ", repr(destination)))
    return (open(String(destination), "a"), destination)
end

"""
    _write_sink!(node, line) -> Bool

Append one already-formatted line to the tree's sink, if it has one.

Every line is flushed immediately, so a log file is complete and readable at any moment -
including while the bar is still running, and including after the process was killed.
"""
function _write_sink!(node::Progress, line::AbstractString)
    root = root_of(node).root
    sink = root.sink
    sink === nothing && return false
    @lock root.sink_lock begin
        print(sink, line, "\n")
        flush(sink)
    end
    return true
end

"""
    _ensure_log_sink!(node, destination)

Attach a persistent sink to the tree, opening it if this is the first request. Used by
nested @progress levels that introduce their own log_file: a sink belongs to the whole
scope, so it is the root's however deep the level that asked for it.
"""
function _ensure_log_sink!(node::Progress, destination)
    destination === nothing && return node
    root = root_of(node).root
    root.dest === destination && return node

    sink, resolved = _open_log_sink(destination)
    @lock root.sink_lock begin
        root.dest = resolved
        root.sink = sink
    end
    return node
end

"""
    _close_log_sink!(root::RootState)

Close the sink if we opened it. A sink the caller handed us as an IO is left open: they
own it.
"""
function _close_log_sink!(root::RootState)
    @lock root.sink_lock begin
        sink = root.sink
        if !(sink === nothing || root.dest isa IO)
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
# a node's log buffer
# ---------------------------------------------------------------------------

"""The most log lines buffered per bar (older ones are dropped)."""
const LOG_BUFFER_LIMIT = 1024

# drop every expired entry from a buffer, in place.
function _prune_buffer!(buf::Vector{LogEntry}, now_sec::Float64)
    filter!(e -> !_expired(e, now_sec), buf)
    return buf
end

"""
    push_log!(node, level, message; kwargs...) -> LogEntry

Append an intercepted record to a bar, and mirror it to the persistent sink when one is
configured. `level` is a Logging.LogLevel (a :debug/:info/:warn/:error symbol is also
accepted) and any keyword arguments are rendered into the stored message.

The entry lives exactly as long as the bar it is attached to: it inherits the node's
vanish timeout.
"""
function push_log!(node::Progress, level::Logging.LogLevel, message; kwargs...)
    entry = LogEntry(level, _format_log_message(message, kwargs), time(), node.opts.vanish)

    buf = node.logs
    @lock buf.lock begin
        _prune_buffer!(buf.entries, entry.created_at)
        push!(buf.entries, entry)
        # bound the buffer: only the newest entries can ever be on screen
        overflow = length(buf.entries) - LOG_BUFFER_LIMIT
        overflow > 0 && deleteat!(buf.entries, 1:overflow)
    end

    # permanent half of the contract: the line may vanish from the screen, but a
    # configured sink keeps it forever
    _write_sink!(node, format_plain_log_line(entry))
    return entry
end

push_log!(node::Progress, level::Symbol, message; kwargs...) =
    push_log!(node, _log_level(level), message; kwargs...)

"""
    prune_logs!(node, now_sec = time())

Drop every buffered record older than the bar's vanish timeout. Called on each render tick,
so the renderer only ever measures lines it is about to draw.
"""
function prune_logs!(node::Progress, now_sec::Float64 = time())
    buf = node.logs
    @lock buf.lock _prune_buffer!(buf.entries, now_sec)
    return nothing
end

"""
    active_logs(node, now_sec = time()) -> Vector{LogEntry}

The non-expired records of a bar, oldest first. Expired records are pruned as a side
effect.
"""
function active_logs(node::Progress, now_sec::Float64 = time())
    buf = node.logs
    return @lock buf.lock begin
        _prune_buffer!(buf.entries, now_sec)
        copy(buf.entries)
    end
end

"""
    pending_logs!(node, now_sec = time()) -> Vector{LogEntry}

Mark and return the buffered records the non-interactive renderer has not streamed out
yet. Entries are marked rather than removed: the flat renderer has nothing to redraw over
a line and so prints each record exactly once, but `active_logs` must keep reporting
everything the scope captured.
"""
function pending_logs!(node::Progress, now_sec::Float64 = time())
    buf = node.logs
    return @lock buf.lock begin
        # nothing is pruned here on purpose. In a file the vanish timeout is beside the
        # point: a record that was captured belongs in the log whatever its screen
        # lifetime, and a bar built with vanish = 0.0 would otherwise swallow every line
        # it ever intercepted.
        pending = LogEntry[]
        for entry in buf.entries
            entry.printed && continue
            entry.printed = true
            push!(pending, entry)
        end
        pending
    end
end

"""
    has_active_logs(node, now_sec = time()) -> Bool

Whether the bar currently has at least one non-expired log line.
"""
function has_active_logs(node::Progress, now_sec::Float64 = time())
    buf = node.logs
    # a pure query: it deliberately does not prune. The renderer asks this while deciding
    # what is visible, and in the append-only mode a record that is about to be written to
    # the log has to survive being asked about.
    return @lock buf.lock begin
        any(entry -> !_expired(entry, now_sec), buf.entries)
    end
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
        # a keyword of the right name carrying a value of the wrong type is not a progress
        # record, so the caller falls back to ordinary logging.
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

A ProgressLogging.Progress carried by a record's message, in either of the two shapes the
package has used: the struct itself, or the ProgressString wrapper it introduced so that
monitors keyed on the bare struct keep working.
"""
function _carried_progress(message)
    message === nothing && return nothing
    hasproperty(message, :fraction) && return _progress_fields(message)
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

Interpret the value of a progress keyword argument the way ProgressLogging defines it: a
number is a fraction, nothing (or NaN) means indeterminate, and the string "done" closes
the bar. Returns nothing when the value is not a progress value at all.
"""
function _progress_value(value)
    value isa Real && return (float(value), false)
    value === nothing && return (nothing, false)          # indeterminate
    value isa AbstractString && return (nothing, value == "done")
    return nothing
end

"""
    handle_progress_record(bar::Progress, payload) -> Bool

Route a ProgressLogging.jl progress record into a live bar, returning whether it was
consumed.

A numeric fraction is translated into a counter value when the bar knows its total (which
is what the ProgressLogging protocol means by a fraction), and always mirrored into the
bar's postfix metrics as progress=<fraction>. The record's name becomes the bar's
description if it does not already have one.
"""
function handle_progress_record(node::Progress, payload)::Bool
    state = node.state
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

# ---------------------------------------------------------------------------
# logger callbacks
# ---------------------------------------------------------------------------

_captures(logger::ProgbioticLogger, level::Logging.LogLevel) = _captures(logger.capture, level)
_captures(capture::Bool, level::Logging.LogLevel) = capture
_captures(capture::Logging.LogLevel, level::Logging.LogLevel) = level >= capture
_captures(capture::Vector{Logging.LogLevel}, level::Logging.LogLevel) = level in capture

# debug stays enabled so that @debug records are generated at all: each record is then
# either captured or handed to parent unchanged. The ProgressLogging level (-1) is enabled
# too, since it sits below Debug.
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
    _logger_bar(logger) -> Union{Progress, Nothing}

The bar a logger's records belong to: the one it was built with, or the innermost one
active in the current task.
"""
function _logger_bar(logger::ProgbioticLogger)
    bar = logger.bar
    bar === nothing || return bar
    return current_bar()
end

function Logging.handle_message(logger::ProgbioticLogger, level, message, _module, group, id,
                                file, line; kwargs...)
    # ProgressLogging records are state, not history: they update the bar rather than
    # producing a line under it.
    payload = _progress_payload(level, message, kwargs)
    if payload !== nothing
        bar = _logger_bar(logger)
        if bar !== nothing
            handle_progress_record(bar, payload)
            return nothing
        end
    end

    if _captures(logger, level)
        bar = _logger_bar(logger)
        if bar !== nothing
            push_log!(bar, level, message; kwargs...)
            return nothing
        end
    end

    # not captured here: preserve the record's normal behaviour by handing it to the
    # logger that was current when the scope was entered.
    parent = logger.parent
    if parent !== nothing && Logging.shouldlog(parent, level, _module, group, id)
        Logging.handle_message(parent, level, message, _module, group, id, file, line; kwargs...)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# scope helpers
# ---------------------------------------------------------------------------

# run f with the task-local bar installed, restoring whatever was there before. This is
# the whole of the capture layer's state: there is no registry and no global patch, so a
# bare loop over prog(...) leaves the surrounding logger alone.
function _with_scope(f::Function, bar::Progress)
    previous = get(task_local_storage(), _CURRENT_KEY, nothing)
    task_local_storage(_CURRENT_KEY, bar)
    try
        return f()
    finally
        task_local_storage(_CURRENT_KEY, previous)
    end
end

"""
    _install_bar!(bar) -> prior

Make bar the current task's innermost one, and hand back whatever was there so that
_restore_bar! can put it back.

A pair of calls rather than a do-block, because @progress has to install this inline: a
body wrapped in a closure cannot return out of the function it was written in, so a return
inside a progress scope would leave the scope instead of the function.
"""
function _install_bar!(bar::Progress)
    previous = get(task_local_storage(), _CURRENT_KEY, nothing)
    task_local_storage(_CURRENT_KEY, bar)
    return previous
end

"""Put back whatever _install_bar! displaced."""
function _restore_bar!(prior)
    task_local_storage(_CURRENT_KEY, prior)
    return nothing
end

"""
    _with_progress_logging(f, bar; capture = true)

Run f with log records captured into a bar, and with a bare set_postfix!() resolving to it.
The explicit scope form, for the iterator and handle interfaces.
"""
function _with_progress_logging(f::Function, bar::Progress; capture = true)
    logger = ProgbioticLogger(bar; capture = capture)
    return Logging.with_logger(logger) do
        _with_scope(f, bar)
    end
end

"""
    with_progress_logging(f, bar; capture = true)

Run f with log records captured into bar and with a bare set_postfix!() resolving to it:

    p = Progress(100)
    with_progress_logging(p) do
        for i in 1:100
            next!(p)
            i == 50 && @info "halfway"
        end
    end
"""
with_progress_logging(f::Function, bar::Progress; capture = true) =
    _with_progress_logging(f, bar; capture = capture)

# ---------------------------------------------------------------------------
# set_postfix!
# ---------------------------------------------------------------------------

"""
    set_postfix!(; kwargs...)
    set_postfix!(bar; kwargs...)

Attach dynamic key/value metrics to the active progress bar. They are rendered inline on
the right-hand side of the bar (see Postfix) and overwritten on every call, so they are
state rather than history:

    for epoch in 1:100
        set_postfix!(loss = round(loss, digits = 4), lr = 1e-4)
    end

With no argument the metrics go to the innermost active bar. Outside any scope that is an
error rather than a silent no-op, because capture is scope-only by design: there is no
process-wide registry for a bare call to find. Metrics may also be attached to a specific
bar by passing it explicitly.
"""
function set_postfix!(; kwargs...)
    bar = current_bar()
    bar === nothing && throw(ProgbioticError(
        "set_postfix! was called outside a progress scope; call it inside @progress, ",
        "prog(f, iter) or Progress(f, n), or pass a bar explicitly: set_postfix!(bar; ...)"))
    return set_postfix!(bar; kwargs...)
end

"""Attach dynamic metrics to a bar."""
function set_postfix!(node::Progress; kwargs...)
    _merge_postfix!(node.state; kwargs...)
    return node
end
