# the state of one bar, and the readers over it.

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
    _snapshot(state::BarState) -> BarState

A copy of a bar's state as it stands at this moment.

A line reads several fields and a worker thread can move them between two reads, which is
enough for one line to contradict itself: a percentage from before the work finished beside
a "done in" from after. A line is rendered from one of these instead, so what it says is one
moment. The lock is shared rather than copied; only the values are frozen.
"""
function _snapshot(state::BarState)
    postfix = @lock state.lock copy(state.postfix[])
    return BarState(Threads.Atomic{Int}(state.current[]), state.total, state.start,
                    Threads.Atomic{Float64}(state.finish[]), state.last_update,
                    Ref(state.desc[]), Ref(postfix), state.lock)
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
# render options, log buffer, and the shared state of a tree
# ---------------------------------------------------------------------------

"""
    Opts(; vanish = 1.0, dt = 0.05, flat_step = 10, width = 0, tty = false,
         threaded = false)

How a node draws, fixed when it is built. Immutable, so a node is a value plus a set
of mutable cells rather than a soup of flags.

`vanish` is the seconds a finished node stays on screen (Inf keeps it, 0.0 erases it
at once) and `width` a bar-width override, where 0 means "measure what the rest of
the line left". Both arrive here already resolved: see `_resolve_vanish`.
"""
struct Opts
    vanish    :: Float64
    dt        :: Float64
    flat_step :: Int
    width     :: Int
    tty       :: Bool
    threaded  :: Bool
end

Opts(; vanish::Real = 1.0, dt::Real = 0.05, flat_step::Integer = 10,
     width::Integer = 0, tty::Bool = false, threaded::Bool = false) =
    Opts(float(vanish), float(dt), max(1, Int(flat_step)), max(0, Int(width)), tty, threaded)

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
    vanish     :: Float64
    printed    :: Bool
end

LogEntry(level, message, created_at, vanish) = LogEntry(level, message, created_at, vanish, false)

Base.show(io::IO, e::LogEntry) = print(io, "LogEntry(", e.level, ", ", repr(e.message), ")")

"""True once the entry is older than its own vanish timeout."""
_expired(e::LogEntry, now_sec::Float64) = (now_sec - e.created_at) > e.vanish


"""
    LogBuf()

One node's intercepted records and the lock guarding them. The permanent sink is the
tree's, not the node's: a `log_file` belongs to the whole scope, so it lives on the
`RootState` every node of the tree shares.
"""
mutable struct LogBuf
    entries :: Vector{LogEntry}
    lock    :: ReentrantLock
end

LogBuf() = LogBuf(LogEntry[], ReentrantLock())

"""
    Paint()

Renderer bookkeeping for one node: the counter value seen at the previous tick, the last
percentage announced in flat mode and when, whether that announcement already said the
node had finished, and when the node reached its total.

`completed_at` is separate from `BarState.finish` because a child that reaches its
total by being advanced never calls `finish!`; the render tick is what notices, and
the vanish timeout is measured from there.

`flat_done` is what stops the append-only renderer repeating itself. A node's last
percentage cannot say whether its line already read "done in ...", because an
indeterminate node's percentage is -1 the whole way through.
"""
mutable struct Paint
    count        :: Int
    flat_pct     :: Int
    last_flat    :: Float64
    flat_done    :: Bool
    completed_at :: Float64
end

Paint() = Paint(0, -1, 0.0, false, 0.0)

"""
    RootState(; title = "", final_depth = 0, child_vanish = 1.0, sink = nothing,
              dest = nothing)

State shared by every node of one tree: the render task, the rows drawn last frame,
the header title and collapse depth, the whole tree's log sink, and the locks guarding
the shared stream and the tree's shape.

A child holds the same object as its root, which is what makes "children never spawn
a task" a property of the types rather than a convention someone has to remember.

`child_vanish` is the timeout a node of this tree gets when it asks for none of its
own: `@progress` keeps its root for the whole scope and gives its children 0.5s, while
a standalone bar's children simply follow it.
"""
mutable struct RootState
    task         :: Union{Task, Nothing}
    running      :: Threads.Atomic{Bool}
    rows         :: Int
    title        :: String
    final_depth  :: Int
    style        :: Symbol
    child_vanish :: Float64
    sink         :: Union{IO, Nothing}
    dest         :: Union{String, IO, Nothing}
    last_draw    :: Float64
    lock         :: ReentrantLock
    sink_lock    :: ReentrantLock
end

function RootState(; title::AbstractString = "", final_depth::Integer = 0,
                   style::Symbol = :round, child_vanish::Real = 1.0,
                   sink::Union{IO, Nothing} = nothing, dest = nothing)
    style in keys(TREE_STRS) ||
        throw(ProgbioticError("unknown tree style :", style, "; available: ",
                              join(sort!(collect(keys(TREE_STRS))), ", ")))
    return RootState(nothing, Threads.Atomic{Bool}(false), 0, String(title),
                     max(0, Int(final_depth)), style, float(child_vanish), sink, dest,
                     0.0, ReentrantLock(), ReentrantLock())
end

"""
    _resolve_vanish(vanish) -> Float64

Normalise a vanish option: false and nothing mean "keep on screen forever" (Inf), true
means the 1.0 second default, and a number is the timeout in seconds, where 0.0 erases
immediately.
"""
function _resolve_vanish(vanish)
    vanish === nothing && return Inf
    vanish === false   && return Inf
    vanish === true    && return 1.0
    vanish isa Real ||
        throw(ProgbioticError("vanish must be a Bool or a number of seconds; got ",
                              repr(vanish)))
    v = float(vanish)
    v < 0 && throw(ProgbioticError("vanish must be >= 0; got ", v))
    return v
end

# ---------------------------------------------------------------------------
# the node
# ---------------------------------------------------------------------------

"""
    Progress(total = nothing; desc = "", theme = AMBER, layout = nothing,
             kind = :bar, vanish = 1.0, child_vanish = nothing, width = 0,
             io = stdout, fps = 20.0, flat_step = 10, tty = nothing,
             log_file = nothing, threaded = Threads.nthreads() > 1,
             title = "", final_depth = 0, start = true) -> Progress

One node of a progress tree: its state, the layout its line is built from, and its
children.

A node with no children *is* a standalone bar, and `child(parent, total)` hangs one
under another. The three front-ends are views onto this: `prog` wraps an iterator
around a root, `Progress` hands you the root itself, and `@progress` builds a tree
of them.

The node is immutable. Every mutable thing it touches is a cell behind a reference:
the `BarState`, this node's `LogBuf` and `Paint`, and the `RootState` shared by
every node of the tree -- which is what makes "a child never spawns a render task" a
property of the types rather than a convention.

`parent` and `children` are the two deliberate points of type erasure. A tree is
heterogeneous, because a layout is per node and a tuple of columns is its own type, so
a child vector cannot name its element type. Read the children through
`children(node)`, which copies under the root lock.

# keyword arguments

- desc:         the node's description (see `Tag`'s `{desc}` template).
- theme:        builds the layout when none is given. A child defaults to its parent's.
- layout:       a tuple of columns, used verbatim, which opts out of the measured
                description width that keeps a tree's rows aligned.
- kind:         :bar, :container (a block whose total is its milestone count), or
                :milestone (a `@progress "desc"` statement).
- vanish:       seconds a finished node stays on screen: false or nothing keeps it,
                true is the 1.0 second default, a number is the timeout.
- child_vanish: the vanish a child gets when it asks for none of its own. Tree policy,
                so it is read on a root only.
- width:        a bar-width override; 0 measures what the rest of the line leaves.
- title:        a header row above the tree. Read on a root only.
- final_depth:  how many levels of children a finished node keeps on screen.
- start:        begin rendering immediately. A root nobody renders never draws.

`io`, `fps`, `flat_step`, `tty`, `log_file` and `threaded` are `Opts`'.
"""
struct Progress{L, T<:Theme}
    state    :: BarState
    theme    :: T
    layout   :: L
    opts     :: Opts
    kind     :: Symbol
    io       :: IO
    parent   :: Union{Progress, Nothing}
    children :: Vector{Progress}
    logs     :: LogBuf
    root     :: RootState
    paint    :: Paint
end

"""The node kinds: a plain bar, a block counting its milestones, and a milestone."""
const _NODE_KINDS = (:bar, :container, :milestone)

function Progress(total::Union{Int, Nothing} = nothing;
                  desc::AbstractString = "",
                  theme::Theme = AMBER,
                  layout = nothing,
                  kind::Symbol = :bar,
                  vanish = 1.0,
                  vanish_timeout = nothing,
                  child_vanish = nothing,
                  width::Integer = 0,
                  fps::Real = 20.0,
                  flat_step::Integer = 10,
                  io::IO = stdout,
                  tty::Union{Bool, Nothing} = nothing,
                  log_file = nothing,
                  threaded::Bool = Threads.nthreads() > 1,
                  title::AbstractString = "",
                  final_depth::Integer = 0,
                  style::Symbol = :round,
                  start::Bool = true)
    fps > 0 || throw(ProgbioticError("fps must be positive; got ", fps))

    own = _resolve_vanish(vanish_timeout === nothing ? vanish : vanish_timeout)
    opts = Opts(; vanish = own, dt = 1.0 / fps, flat_step = flat_step, width = width,
                tty = tty === nothing ? _is_tty(io) : Bool(tty), threaded = threaded)
    sink, dest = _open_log_sink(log_file)
    root = RootState(; title = title, final_depth = final_depth, style = style,
                     child_vanish = child_vanish === nothing ? own : child_vanish,
                     sink = sink, dest = dest)
    node = _node(total, desc, theme, layout, opts, kind, io, nothing, root)

    start && start_render!(node)
    return node
end

"""
    child(parent::Progress, total = nothing; desc = "", theme = parent.theme,
          layout = nothing, kind = :bar, vanish = nothing, width = 0,
          spinner = nothing, barunits = nothing, empty = nothing, caps = nothing,
          head = nothing) -> Progress

Hang a node under `parent` and return it.

The child shares the tree: its stream, frame rate, flat step, tty mode, render task and
log sink all come from the root. It takes `parent.theme` unless given one, and
`parent.root.child_vanish` seconds of vanish unless given its own. The glyph keywords
restyle a copy of the theme, exactly as the `Theme` copy constructor does.

The node is pushed into `parent.children` under the root lock -- the same lock the
render task copies it under -- so a bar may be added from any thread while the tree is
being drawn.
"""
function child(parent::Progress, total::Union{Int, Nothing} = nothing;
               desc::AbstractString = "",
               theme::Theme = parent.theme,
               layout = nothing,
               kind::Symbol = :bar,
               vanish = nothing,
               vanish_timeout = nothing,
               width::Integer = 0,
               spinner = nothing, barunits = nothing, empty = nothing,
               caps = nothing, head = nothing)
    root = parent.root
    resolved = vanish_timeout !== nothing ? _resolve_vanish(vanish_timeout) :
               vanish === nothing        ? root.child_vanish :
                                           _resolve_vanish(vanish)
    opts = Opts(; vanish = resolved, dt = parent.opts.dt,
                flat_step = parent.opts.flat_step, width = width,
                tty = parent.opts.tty, threaded = parent.opts.threaded)
    node = _node(total, desc, _apply_style(theme, spinner, barunits, empty, caps, head),
                 layout, opts, kind, parent.io, parent, root)

    # registering a subtask finishes the parent's previous milestone, so only one of them
    # ever reads as running at a time. The list is taken *before* the push: the milestone
    # being registered is only just starting, and must not close itself.
    pending = _pending_milestones(parent)
    @lock root.lock push!(parent.children, node)
    _finish_milestones!(parent, pending)
    _refresh_container_state!(parent)
    return node
end

# the one place a Progress is built. Both front-ends resolve their keywords into these
# arguments first, so the struct is never assembled twice.
function _node(total, desc, theme::Theme, layout, opts::Opts, kind::Symbol, io::IO,
               parent::Union{Progress, Nothing}, root::RootState)
    kind in _NODE_KINDS ||
        throw(ProgbioticError("kind must be one of ", join(_NODE_KINDS, ", "),
                              "; got ", repr(kind)))

    columns = layout === nothing ? nothing : Tuple(layout)
    return Progress{typeof(columns), typeof(theme)}(
        BarState(total; desc = desc), theme, columns, opts, kind, io, parent,
        Progress[], LogBuf(), root, Paint())
end

"""
    children(node::Progress) -> Vector{Progress}

A copy of a node's direct children, taken under the root lock.
"""
children(node::Progress) = @lock node.root.lock copy(node.children)

"""A `@progress "desc"` statement: no total of its own, done when a sibling arrives."""
ismilestone(node::Progress) = node.kind === :milestone

"""A block whose total is the number of milestones it contains."""
iscontainer(node::Progress) = node.kind === :container

"""
    _complete_statement_jobs!(parent::Progress)

Finish every milestone under `parent` that is still pending. A milestone has no total of
its own, so it is done when the next sibling registers or when its enclosing scope exits --
which is what makes `@progress "step"` a statement about the work that follows it.
"""
function _complete_statement_jobs!(parent::Progress)
    _finish_milestones!(parent, _pending_milestones(parent))
    return _refresh_container_state!(parent)
end

"""The milestones under a node that have not finished yet."""
_pending_milestones(parent::Progress) =
    [kid for kid in children(parent) if ismilestone(kid) && !_completed(kid)]

# close a set of milestones. The container is refreshed by the caller, which is also what
# adds a newly registered milestone to the count.
function _finish_milestones!(parent::Progress, pending::Vector)
    isempty(pending) && return nothing

    now_sec = time()
    for kid in pending
        kid.state.finish[] == 0 && (kid.state.finish[] = now_sec)
        kid.paint.completed_at == 0.0 && (kid.paint.completed_at = now_sec)
    end
    return nothing
end

# A container's total is the number of milestones it has actually seen, rather than a
# count taken from the source: a milestone written inside an if, or inside a loop, is one
# statement but several registrations, so no syntactic count can be right. Counting as
# they arrive cannot overshoot, and it reads a block opening as one unit of work until the
# first milestone lands. Its state is how many of them have completed, so its line reads
# 2/3 once two are done.
function _refresh_container_state!(parent::Progress)
    iscontainer(parent) || return nothing

    kids = children(parent)
    seen = count(ismilestone, kids)
    done = count(kid -> ismilestone(kid) && _completed(kid), kids)
    # total is read by the render task without a lock, and this is the only writer. It
    # only ever grows here, so a tick sees either the old count or the new one.
    @lock parent.state.lock parent.state.total = max(1, seen)
    parent.state.current[] = done
    parent.state.last_update = time()
    return nothing
end

"""True once a node is done: at its total, or finished when it has no total."""
function _completed(node::Progress)
    total = node.state.total
    total === nothing && return isfinished(node.state)
    return pbdone(node.state) >= total
end

"""Distance of a node from the top of its tree (roots are at depth 0)."""
function node_depth(node::Progress)
    depth = 0
    current = node.parent
    while current !== nothing
        current = current.parent
        depth += 1
    end
    return depth
end

stateof(node::Progress) = node.state

@state_methods Progress

function Base.show(io::IO, node::Progress)
    state = node.state
    print(io, "Progress(", repr(state.desc[]), ", ",
          state.total === nothing ? "indeterminate" :
                                    string(pbdone(state), "/", state.total), ", ",
          isfinished(state) ? "finished" : "running")
    node.kind === :bar || print(io, ", ", node.kind)
    isempty(node.children) || print(io, ", ", length(node.children), " children")
    print(io, ")")
end

