# Log-capture plumbing shared by the logger (`src/logger.jl`), the renderer
# (`src/render.jl`) and the `@progress` macro (`src/meta.jl`).

# Drops every expired entry from `buf`, in place.
function _prune_buffer!(buf::Vector{LogEntry}, now_sec::Float64)
    filter!(e -> !_expired(e, now_sec), buf)
    return buf
end

# Renders a log message together with its keyword arguments, e.g.
# `"checkpoint" (record=25)`.
function _format_log_message(message, kwargs)
    # Multi-line messages are flattened: the gutter measures exactly one row per
    # entry, so an embedded newline would desynchronise its height and tear the UI.
    msg = replace(string(message), '\n' => ' ', '\r' => ' ')
    isempty(kwargs) && return msg
    parts = String[string(k, "=", v) for (k, v) in kwargs]
    return string(msg, " (", join(parts, ", "), ")")
end

"""
    _log_level(name::Symbol) -> Logging.LogLevel

Maps `:debug`, `:info`, `:warn` and `:error` onto their `Logging.LogLevel`.
"""
function _log_level(name::Symbol)
    name === :debug && return Logging.Debug
    name === :info  && return Logging.Info
    name === :warn  && return Logging.Warn
    name === :error && return Logging.Error
    error("Progbiotic: unknown log level :", name, "; expected :debug, :info, :warn or :error")
end

_log_level(level::Logging.LogLevel) = level

"""
    ProgLogStore(; max_entries = 1024)

Thread-safe store of intercepted log entries holding one buffer per progress job.
Every `ProgBar` owns one; a single `ReentrantLock` guards all buffers so that
`@info` calls issued from `Threads.@threads` iterations can be appended
concurrently. Buffers are capped at `max_entries` entries per job (oldest entries
are dropped first).
"""
mutable struct ProgLogStore
    lock        :: ReentrantLock
    buffers     :: IdDict{ProgJob, Vector{LogEntry}}
    max_entries :: Int
end

ProgLogStore(; max_entries::Int = 1024) =
    ProgLogStore(ReentrantLock(), IdDict{ProgJob, Vector{LogEntry}}(), max_entries)

_log_lock(pbar) = pbar.logs.lock

# Buffer for `job`, created on first use and shared by every context referring to
# that job.
function _log_buffer(pbar, job::Union{ProgJob, Nothing})
    job === nothing && return LogEntry[]
    store = pbar.logs
    @lock store.lock begin
        return get!(store.buffers, job, LogEntry[])
    end
end

# The vanish timeout a log entry inherits: the timeout resolved for the job of the
# scope it was logged in (`Inf` = keep on screen).
function _log_timeout(pbar, job::Union{ProgJob, Nothing})
    job === nothing && return Inf
    timeout = get(pbar.vanish_timeouts, job, nothing)
    return timeout === nothing ? Inf : float(timeout)
end

"""
    ProgContext(pbar::ProgBar, parent::Union{ProgJob, Nothing})

Hierarchical context handle for passing a progress bar and its active parent node to
subroutines. Log records emitted while the context is the innermost active one are
buffered for `parent` (see [`push_log!`](@ref)) and rendered under its bar, then
pruned once the `parent` job's vanish timeout elapses.
"""
struct ProgContext{P}
    pbar       :: P
    parent     :: Union{ProgJob, Nothing}
    log_buffer :: Vector{LogEntry}
    log_lock   :: ReentrantLock
end

function ProgContext(pbar, parent::Union{ProgJob, Nothing})
    return ProgContext{typeof(pbar)}(pbar, parent, _log_buffer(pbar, parent), _log_lock(pbar))
end

"""
    push_log!(ctx::ProgContext, level, message; kwargs...) -> Union{LogEntry, Nothing}

Appends an intercepted log record to the buffer of `ctx`'s job. `level` is a
`Logging.LogLevel` (a `:debug`/`:info`/`:warn`/`:error` symbol is also accepted)
and any keyword arguments are rendered into the stored message. The entry's vanish
timeout is taken from the scope's resolved `vanish_timeout`, so a log line lives
exactly as long as the bar it is attached to.
"""
function push_log!(ctx::ProgContext, level::Logging.LogLevel, message; kwargs...)
    ctx.parent === nothing && return nothing
    pbar = ctx.pbar
    entry = LogEntry(level, _format_log_message(message, kwargs), time(),
                             _log_timeout(pbar, ctx.parent))
    store = pbar.logs
    @lock store.lock begin
        buf = get!(store.buffers, ctx.parent, LogEntry[])
        _prune_buffer!(buf, entry.created_at)
        push!(buf, entry)
        overflow = length(buf) - store.max_entries
        overflow > 0 && deleteat!(buf, 1:overflow)
    end
    # Keep the gutter in step with the log stream; the bar's own `dt` throttles this.
    # Permanent half of the contract: the line may vanish from the screen, but a
    # configured sink keeps it forever.
    _write_sink!(pbar, format_plain_log_line(entry))
    _request_gutter_refresh(pbar)
    return entry
end

push_log!(ctx::ProgContext, level::Symbol, message; kwargs...) =
    push_log!(ctx, _log_level(level), message; kwargs...)

"""
    prune_logs!(store::ProgLogStore, now_sec = time())
    prune_logs!(pbar::ProgBar, now_sec = time())
    prune_logs!(ctx::ProgContext, now_sec = time())

Removes every log entry whose vanish timeout has elapsed. Buffers are kept
(empty, if everything expired) so that every `ProgContext` referring to a job keeps
pointing at the same buffer. Called on every render cycle, so the gutter only ever
measures the lines it is about to draw.
"""
function prune_logs!(store::ProgLogStore, now_sec::Float64 = time())
    @lock store.lock begin
        for buf in values(store.buffers)
            _prune_buffer!(buf, now_sec)
        end
    end
    return nothing
end

# `pbar` is a `ProgBar`; the argument is left unannotated because
# `context.jl` is included before `bars.jl` (so that `ProgBar` can own a
# `ProgLogStore`).
prune_logs!(pbar, now_sec::Float64 = time()) = prune_logs!(pbar.logs, now_sec)
prune_logs!(ctx::ProgContext, now_sec::Float64 = time()) = prune_logs!(ctx.pbar, now_sec)

"""
    active_logs(pbar::ProgBar, job, now_sec = time())
    active_logs(ctx::ProgContext, now_sec = time()) -> Vector{LogEntry}

The non-expired log entries buffered for `job` (or for `ctx`'s job), oldest first.
Expired entries are pruned as a side effect.
"""
function active_logs(pbar, job::Union{ProgJob, Nothing}, now_sec::Float64 = time())
    job === nothing && return LogEntry[]
    store = pbar.logs
    @lock store.lock begin
        buf = get(store.buffers, job, nothing)
        buf === nothing && return LogEntry[]
        _prune_buffer!(buf, now_sec)
        return copy(buf)
    end
end

active_logs(ctx::ProgContext, now_sec::Float64 = time()) =
    active_logs(ctx.pbar, ctx.parent, now_sec)

"""
    has_active_logs(pbar::ProgBar, job, now_sec = time()) -> Bool

Whether `job` currently has at least one non-expired log line; used to keep a
finished bar on screen until its logs have vanished.
"""
function has_active_logs(pbar, job::Union{ProgJob, Nothing}, now_sec::Float64 = time())
    job === nothing && return false
    store = pbar.logs
    @lock store.lock begin
        buf = get(store.buffers, job, nothing)
        buf === nothing && return false
        _prune_buffer!(buf, now_sec)
        return !isempty(buf)
    end
end

# Forward helper methods so subroutines can interact directly with the context
add_job!(ctx::ProgContext, iter_or_desc; parent = ctx.parent, kwargs...) =
    add_job!(ctx.pbar, iter_or_desc; parent = parent, kwargs...)

update!(ctx::ProgContext, args...) = update!(ctx.pbar, args...)
print_progbar_in_gutter(ctx::ProgContext; kwargs...) = print_progbar_in_gutter(ctx.pbar; kwargs...)
