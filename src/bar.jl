# The state of one bar, and the readers over it.

"""
    BarState(total = nothing; desc = "")

The shared, mutable state of a single bar.

`current` is the only contended field: advancing a bar is one
`Threads.atomic_add!`, which is what keeps a `Threads.@threads` loop from
serialising on the bar. `finish` is atomic because the render task reads it while
`finish!` writes it. Everything else is immutable, or written under `lock`.

A `total` of `nothing` means indeterminate: the amount of work is unknown (an
unbounded channel, a `SizeUnknown` iterator), so there is no percentage and no ETA
to report, only a spinner and elapsed time.

This is a `mutable struct` on purpose. It is the one shared mutable cell in the
package: the reads happen from the render task, the writes from whichever thread is
doing the work, and a bar's whole point is that its state changes. The fields that
are read across threads without a lock (`current`, `finish`) are atomics; the rest are
written under `lock`, or, for `last_update`, only from the render task.
"""
mutable struct BarState
    current     :: Threads.Atomic{Int}
    total       :: Union{Int, Nothing}
    start       :: Float64
    finish      :: Threads.Atomic{Float64}
    last_update :: Float64
    desc        :: Base.RefValue{String}
    # dynamic metrics, in insertion order, rendered to text at set_postfix! time
    postfix     :: Base.RefValue{Vector{Pair{Symbol, String}}}
    lock        :: ReentrantLock
end

function BarState(total::Union{Int, Nothing} = nothing; desc::AbstractString = "")
    now = time()
    return BarState(Threads.Atomic{Int}(0), total, now, Threads.Atomic{Float64}(0.0), now,
                    Ref(String(desc)), Ref(Pair{Symbol, String}[]), ReentrantLock())
end

function Base.show(io::IO, s::BarState)
    print(io, "BarState(", repr(s.desc[]), ", ")
    s.total === nothing ? print(io, "indeterminate") : print(io, s.current[], "/", s.total)
    print(io, ")")
end

"""Units completed, read atomically."""
pbdone(s::BarState) = s.current[]

"""Total units, or nothing when the bar is indeterminate."""
pbtotal(s::BarState) = s.total

"""
    pbfraction(s) -> Union{Float64, Nothing}

Completed fraction in [0, 1], or nothing for an indeterminate bar.
"""
function pbfraction(s::BarState)
    total = s.total
    total === nothing && return nothing
    total <= 0 && return 1.0
    return clamp(s.current[] / total, 0.0, 1.0)
end

"""
    pbelapsed(s) -> Float64

Seconds of *work*. Measured up to the last observed advance, or up to completion, so
rate and ETA freeze while a bar sits idle waiting on a nested job instead of
decaying towards zero.
"""
function pbelapsed(s::BarState)
    finish = s.finish[]
    work_until = finish > 0 ? finish : s.last_update
    return max(0.0, work_until - s.start)
end

"""Wall-clock seconds since the bar started, frozen once it finishes."""
function pbruntime(s::BarState)
    finish = s.finish[]
    finish > 0 && return max(0.0, finish - s.start)
    return max(0.0, time() - s.start)
end

"""Items per second, or zero when no time has passed to measure."""
function pbrate(s::BarState)
    elapsed = pbelapsed(s)
    elapsed <= 0 && return 0.0
    return s.current[] / elapsed
end

"""
    pbeta(s) -> Union{Float64, Nothing}

Estimated seconds remaining, or nothing when it cannot be estimated: an
indeterminate bar, no progress yet, or a finished bar.
"""
function pbeta(s::BarState)
    total = s.total
    total === nothing && return nothing
    done = s.current[]
    done <= 0 && return nothing
    done >= total && return 0.0
    return (total - done) * (pbelapsed(s) / done)
end

"""True once the bar has been marked finished."""
isfinished(s::BarState) = s.finish[] > 0

"""The state readers a wrapper type forwards, in the order a bar's line shows them."""
const _STATE_READERS = (:pbdone, :pbtotal, :pbfraction, :pbelapsed, :pbruntime,
                        :pbrate, :pbeta, :isfinished)

"""
    @state_methods T

Give a wrapper type every reader above, forwarded through `stateof`.

    stateof(p::Handle) = p.state
    @state_methods Handle

so `pbdone(p)` reads a handle exactly as it reads the `BarState` itself. Wrapping is
a convenience, never a second source of truth: there is one `BarState` per bar and
these methods only project it.
"""
macro state_methods(T)
    arg = gensym("x")
    defs = [esc(:($f($arg::$T) = $f(stateof($arg)))) for f in _STATE_READERS]
    return Expr(:block, defs...)
end

"""
    _merge_postfix!(s::BarState; kwargs...) -> BarState

Merge keyword metrics into a bar's postfix, rendering each value to text now rather
than on every frame.

Rendering here rather than in the render tick is deliberate: the tick runs at
`fps` and would otherwise call `show` on user values under a lock, every frame, for
every bar on screen. The order keys were first set is preserved, so the display
never shuffles under the reader.
"""
function _merge_postfix!(s::BarState; kwargs...)
    @lock s.lock begin
        pairs = s.postfix[]
        for (key, value) in kwargs
            text = string(value)
            index = findfirst(pair -> first(pair) === key, pairs)
            index === nothing ? push!(pairs, key => text) : (pairs[index] = key => text)
        end
    end
    return s
end

"""
    postfix_text(s::BarState; separator = ", ") -> String

The dynamic metrics as `key=value` pairs, in the order the keys were first set.
"""
function postfix_text(s::BarState; separator::AbstractString = ", ")
    pairs = @lock s.lock copy(s.postfix[])
    isempty(pairs) && return ""
    return join((string(first(pair), "=", last(pair)) for pair in pairs), separator)
end

"""Set a bar's description, unless it already has one."""
function _set_description!(s::BarState, name::AbstractString)
    @lock s.lock begin
        isempty(s.desc[]) && (s.desc[] = String(name))
    end
    return s
end

# ---------------------------------------------------------------------------
# Render options, log buffer, and the shared state of a tree
# ---------------------------------------------------------------------------

"""
    Opts(vanish, dt, flat_step, tty, threaded)

How a bar draws, fixed when it is built. Immutable, so a node is a value plus a set
of mutable cells rather than a soup of flags.
"""
struct Opts
    vanish    :: Float64
    dt        :: Float64
    flat_step :: Int
    tty       :: Bool
    threaded  :: Bool
end

"""
    LogEntry(level, message, created_at)

One intercepted log record.

`printed` is set once the append-only renderer has streamed the entry out, so a CI
log shows each record exactly once while `active_logs` keeps reporting everything the
scope captured. Entries are pruned once they are older than the scope's vanish
timeout.
"""
mutable struct LogEntry
    level      :: Logging.LogLevel
    message    :: String
    created_at :: Float64
    printed    :: Bool
end

LogEntry(level, message, created_at) = LogEntry(level, message, created_at, false)

Base.show(io::IO, e::LogEntry) = print(io, "LogEntry(", e.level, ", ", repr(e.message), ")")

"""True once the entry is older than the given number of seconds."""
_expired(e::LogEntry, now_sec::Float64, vanish::Float64) = (now_sec - e.created_at) > vanish


"""
    LogBuf()

A bar's intercepted records, the lock guarding them, and its optional permanent sink.
"""
mutable struct LogBuf
    entries :: Vector{LogEntry}
    lock    :: ReentrantLock
    sink    :: Union{IO, Nothing}
    dest    :: Union{String, IO, Nothing}
end

LogBuf() = LogBuf(LogEntry[], ReentrantLock(), nothing, nothing)

"""
    Paint()

Renderer bookkeeping for one node: the counter value seen at the previous tick, the
last percentage announced in flat mode, and the rows this node's block occupied.
"""
mutable struct Paint
    count    :: Int
    flat_pct :: Int
    rows     :: Int
end

Paint() = Paint(0, -1, 0)

"""
    RootState()

State shared by every node of one tree: the render task, the rows drawn last frame,
and the lock guarding writes to the shared stream.

A child holds the same object as its root, which is what makes "children never spawn
a task" a property of the types rather than a convention someone has to remember.
"""
mutable struct RootState
    task      :: Union{Task, Nothing}
    running   :: Threads.Atomic{Bool}
    rows      :: Int
    last_draw :: Float64
    lock      :: ReentrantLock
end

RootState() = RootState(nothing, Threads.Atomic{Bool}(false), 0, 0.0, ReentrantLock())
