# the state of one bar, and the readers over it.

"""
    BarState(total = nothing; desc = "")

The shared, mutable state of a single bar.

`current` is the only contended field: advancing a bar is one
`Threads.atomic_add!`, which is what keeps a `Threads.@threads` loop from
serialising on the bar. `finish` is atomic because the render task reads it while
`finish!` writes it. Everything else is immutable, or written under `lock`, which also
guards `error`, the one field written by whichever thread is unwinding.

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
    # the exception that took the bar down, if any; written once, under lock
    error       :: Base.RefValue{Union{Nothing, ErrorInfo}}
    # a node beneath this one failed, so it draws the error colour without being an error
    tainted     :: Bool
    last_update :: Float64
    desc        :: Base.RefValue{String}
    # dynamic metrics, in insertion order, rendered to text at set_postfix! time
    postfix     :: Base.RefValue{Vector{Pair{Symbol, String}}}
    lock        :: ReentrantLock
end

function BarState(total::Union{Int, Nothing} = nothing; desc::AbstractString = "")
    now = time()
    return BarState(Threads.Atomic{Int}(0), total, now, Threads.Atomic{Float64}(0.0),
                    Ref{Union{Nothing, ErrorInfo}}(nothing), false, now,
                    Ref(String(desc)), Ref(Pair{Symbol, String}[]), ReentrantLock())
end

function Base.show(io::IO, s::BarState)
    print(io, "BarState(", repr(s.desc[]), ", ")
    s.total === nothing ? print(io, "indeterminate") : print(io, s.current[], "/", s.total)
    s.error[] === nothing || print(io, ", error=", s.error[].type)
    s.tainted && print(io, ", tainted")
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

"""
    isfinished(s) -> Bool

True once the bar has completed successfully. A failed bar is over, but it is not
finished: `haserror` is what says so.
"""
isfinished(s::BarState) = s.finish[] > 0 && s.error[] === nothing

"""Whether the bar has registered an error. See `pberror` and `fail!`."""
haserror(s::BarState) = s.error[] !== nothing

"""The error a bar registered, as an `ErrorInfo`, or nothing when it has none."""
pberror(s::BarState) = s.error[]

"""
    istainted(s) -> Bool

Whether the bar should draw in the error colour: it registered an error, or a node beneath
it did. A tainted bar is not itself an error, so its time column stays a time.
"""
istainted(s::BarState) = s.error[] !== nothing || s.tainted

"""The state readers a wrapper type forwards to the BarState it projects."""
const _STATE_READERS = (:pbdone, :pbtotal, :pbfraction, :pbelapsed, :pbruntime,
                        :pbrate, :pbeta, :isfinished, :haserror, :pberror)

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
    error, tainted, postfix =
        @lock state.lock (state.error[], state.tainted, copy(state.postfix[]))
    return BarState(Threads.Atomic{Int}(state.current[]), state.total, state.start,
                    Threads.Atomic{Float64}(state.finish[]),
                    Ref{Union{Nothing, ErrorInfo}}(error), tainted, state.last_update,
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
    Opts(; vanish = 1.0, error_vanish = Inf, dt = 0.05, flat_step = 10, width = 0,
         tty = false, threaded = false)

How a node draws, fixed when it is built. Immutable, so a node is a value plus a set
of mutable cells rather than a soup of flags.

`vanish` is the seconds a finished node stays on screen (Inf keeps it, 0.0 erases it
at once), `error_vanish` the same for an errored one (Inf keeps it forever, which is
the default), and `width` a bar-width override, where 0 means "measure what the rest
of the line left". All three arrive here already resolved: see `_resolve_vanish` and
`_resolve_error_vanish`.
"""
struct Opts
    vanish       :: Float64
    error_vanish :: Float64
    dt           :: Float64
    flat_step    :: Int
    width        :: Int
    tty          :: Bool
    threaded     :: Bool
end

Opts(; vanish::Real = 1.0, error_vanish::Real = Inf, dt::Real = 0.05,
     flat_step::Integer = 10, width::Integer = 0, tty::Bool = false,
     threaded::Bool = false) =
    Opts(float(vanish), float(error_vanish), float(dt), max(1, Int(flat_step)),
         max(0, Int(width)), tty, threaded)

"""
    Paint()

Renderer bookkeeping for one node: the counter value seen at the previous tick, the last
percentage announced in flat mode and when, whether that announcement already said the
node had settled, and when the node settled.

`completed_at` is separate from `BarState.finish` because a child that reaches its
total by being advanced never calls `finish!`; the render tick is what notices, and the
vanish timeout is measured from there. The same stamp covers an errored node, which may
never call `finish!` either.

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

# how many failures one tree keeps on screen; older records fall off the top of the
# gutter anyway, and this keeps a loop that catches thousands from growing forever
const _MAX_FAILURES = 64

"""
    FailureRecord

One caught failure, frozen: the chain of nodes from the tree's root down to the node that
failed, each paired with a snapshot of its state at that moment. The failed node carries
the error; its ancestors are `tainted`, so they draw the error colour while keeping their
own time column. Records live on the root (`RootState.failures`) and are drawn above the
live tree.
"""
struct FailureRecord
    err  :: Any
    rows :: Vector{Tuple{Any, BarState}}
end

"""
    RootState(; title = "", final_depth = 0, child_vanish = 1.0)

State shared by every node of one tree: the render task, the rows drawn last frame,
the header title and collapse depth, and the lock guarding the shared stream.

A child holds the same object as its root, which is what makes "children never spawn
a task" a property of the types rather than a convention someone has to remember.

`child_vanish` is the timeout a node of this tree gets when it asks for none of its
own: `@progress` keeps its root for the whole scope and gives its children 0.5s, while
a standalone bar's children simply follow it. `failures` holds the frozen chains of caught
failures, drawn above the live tree.
"""
mutable struct RootState
    task         :: Union{Task, Nothing}
    running      :: Threads.Atomic{Bool}
    rows         :: Int
    title        :: String
    final_depth  :: Int
    style        :: Symbol
    child_vanish :: Float64
    last_draw    :: Float64
    failures     :: Vector{FailureRecord}
    lock         :: ReentrantLock
end

function RootState(; title::AbstractString = "", final_depth::Integer = 0,
                   style::Symbol = :round, child_vanish::Real = 1.0)
    style in keys(TREE_STRS) ||
        throw(ProgbioticError("unknown tree style :", style, "; available: ",
                              join(sort!(collect(keys(TREE_STRS))), ", ")))
    return RootState(nothing, Threads.Atomic{Bool}(false), 0, String(title),
                     max(0, Int(final_depth)), style, float(child_vanish), 0.0,
                     FailureRecord[], ReentrantLock())
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

"""
    _resolve_error_vanish(ev, own) -> Float64

Normalise the `error_vanish` option: nothing and false keep an errored node on screen
forever (Inf), true gives it the node's own resolved vanish (`own`), and a number is a
separate timeout in seconds.
"""
function _resolve_error_vanish(ev, own::Float64)
    ev === nothing && return Inf
    ev === false   && return Inf
    ev === true    && return own
    ev isa Real ||
        throw(ProgbioticError("error_vanish must be a Bool or a number of seconds; got ",
                              repr(ev)))
    v = float(ev)
    v < 0 && throw(ProgbioticError("error_vanish must be >= 0; got ", v))
    return v
end

# ---------------------------------------------------------------------------
# the node
# ---------------------------------------------------------------------------

"""
    Progress(total = nothing; desc = "", theme = AMBER, layout = nothing,
             kind = :bar, vanish = 1.0, child_vanish = nothing, width = 0,
             io = stdout, fps = 20.0, flat_step = 10, tty = nothing,
             threaded = Threads.nthreads() > 1,
             title = "", final_depth = 0, start = true) -> Progress

One node of a progress tree: its state, the layout its line is built from, and its
children.

A node with no children *is* a standalone bar, and `child(parent, total)` hangs one
under another. The three front-ends are views onto this: `prog` wraps an iterator
around a root, `Progress` hands you the root itself, and `@progress` builds a tree
of them.

The node is immutable. Every mutable thing it touches is a cell behind a reference:
the `BarState`, this node's `Paint`, and the `RootState` shared by every node of
the tree -- which is what makes "a child never spawns a render task" a property of the
types rather than a convention.

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
- error_vanish: how long an errored node stays: nothing or false keeps it forever, true
                gives it its own vanish, a number is a separate timeout.
- width:        a bar-width override; 0 measures what the rest of the line leaves.
- title:        a header row above the tree. Read on a root only.
- final_depth:  how many levels of children a finished node keeps on screen.
- start:        begin rendering immediately. A root nobody renders never draws.

`io`, `fps`, `flat_step`, `tty` and `threaded` are `Opts`'.
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
                  error_vanish = nothing,
                  width::Integer = 0,
                  fps::Real = 20.0,
                  flat_step::Integer = 10,
                  io::IO = stdout,
                  tty::Union{Bool, Nothing} = nothing,
                  threaded::Bool = Threads.nthreads() > 1,
                  title::AbstractString = "",
                  final_depth::Integer = 0,
                  style::Symbol = :round,
                  start::Bool = true)
    fps > 0 || throw(ProgbioticError("fps must be positive; got ", fps))

    own = _resolve_vanish(vanish_timeout === nothing ? vanish : vanish_timeout)
    opts = Opts(; vanish = own, error_vanish = _resolve_error_vanish(error_vanish, own),
                dt = 1.0 / fps, flat_step = flat_step, width = width,
                tty = tty === nothing ? _is_tty(io) : Bool(tty), threaded = threaded)
    root = RootState(; title = title, final_depth = final_depth, style = style,
                     child_vanish = child_vanish === nothing ? own : child_vanish)
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

The child shares the tree: its stream, frame rate, flat step, tty mode and render task
all come from the root. It takes `parent.theme` unless given one, and
`parent.root.child_vanish` seconds of vanish unless given its own; `error_vanish`
defaults to the parent's. The glyph keywords restyle a copy of the theme, exactly as
the `Theme` copy constructor does.

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
               error_vanish = nothing,
               width::Integer = 0,
               spinner = nothing, barunits = nothing, empty = nothing,
               caps = nothing, head = nothing)
    root = parent.root
    resolved = vanish_timeout !== nothing ? _resolve_vanish(vanish_timeout) :
               vanish === nothing        ? root.child_vanish :
                                           _resolve_vanish(vanish)
    error_resolved = error_vanish === nothing ?
                         parent.opts.error_vanish :
                         _resolve_error_vanish(error_vanish, resolved)
    opts = Opts(; vanish = resolved, error_vanish = error_resolved, dt = parent.opts.dt,
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
        Progress[], root, Paint())
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
    [kid for kid in children(parent) if ismilestone(kid) && !_settled(kid)]

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

"""
    _settled(node) -> Bool

Whether a node has stopped changing: it completed, or it registered an error. The
renderer draws a settled node's last frame and starts its vanish timeout, but the
progress readers keep their meaning: an errored bar is not `_completed`, and it is not
`isfinished` either.
"""
_settled(node::Progress) = _completed(node) || haserror(node.state)

"""
    fail!(bar, err) -> bar

Register an error against a bar, marking it failed without touching its counter.

The do-block front-ends (`@progress`, `Progress(f, n)`, `prog(f, iter)`) call this
themselves when the body throws. It is also the manual half of the error state: a bare
`for x in prog(...)` runs its body outside the wrapper, so its own `catch` is where
`fail!(it, err)` belongs, and a hand-driven `Progress(n)` might want it too.

A bar keeps the first error registered against it. The exception's type and message are
stored as an `ErrorInfo`, and the bar renders `ERROR: <Type>` in its time column, paints
its bar red, and keeps its counter where it stopped: it is over, but not finished.
"""
function fail!(s::BarState, err)
    _mark_failed!(s, err)
    return s
end

function fail!(node::Progress, err)
    fail!(node.state, err)
    _record_failure!(node, err)
    return node
end

function _mark_failed!(s::BarState, err)
    info = _error_info(err)
    @lock s.lock begin
        s.error[] === nothing && (s.error[] = info)
    end
    s.finish[] == 0 && (s.finish[] = time())
    return s
end

# the exception's type and the message showerror would print. A custom exception with a
# broken showerror must not take the bar down as it is already going down, so the message
# is guarded; only the type really matters.
function _error_info(err)
    err isa DataType && return ErrorInfo(err, "")
    msg = try
        sprint(showerror, err)
    catch
        ""
    end
    return ErrorInfo(typeof(err), msg)
end

# a snapshot of a live node that a descendant's failure marks red without erroring it
function _tainted_snapshot(state::BarState)
    snap = _snapshot(state)
    snap.tainted = true
    return snap
end

"""
    _record_failure!(node, err)

Freeze the chain from the tree's root down to `node`, once per exception. The innermost
node calls this first as the exception unwinds, so the chain holds every bar at the state
it had when the work died; outer levels that receive the same `err` afterwards are
ignored. A standalone node is skipped, and a record is drawn only when the failure was
caught inside the tree, since an escaped exception reproduces the live tree instead.
"""
function _record_failure!(node::Progress, err)
    node.parent === nothing && return nothing
    root = root_of(node)

    @lock root.root.lock begin
        any(record -> record.err === err, root.root.failures) && return nothing

        rows = Tuple{Any, BarState}[]
        current = node
        while current !== nothing
            state = current === node ? _snapshot(current.state) :
                                       _tainted_snapshot(current.state)
            pushfirst!(rows, (current, state))
            current = current.parent
        end
        length(root.root.failures) >= _MAX_FAILURES && popfirst!(root.root.failures)
        push!(root.root.failures, FailureRecord(err, rows))
    end
    return nothing
end

"""
    _fail_pending_milestones!(parent, err)

Register `err` against every milestone under `parent` that has not settled yet, so a
block that threw does not leave its in-flight statement reading as still running.
"""
function _fail_pending_milestones!(parent::Progress, err)
    for kid in _pending_milestones(parent)
        fail!(kid, err)
    end
    return nothing
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
          isfinished(state) ? "finished" :
          haserror(state)   ? "errored"  : "running")
    node.kind === :bar || print(io, ", ", node.kind)
    isempty(node.children) || print(io, ", ", length(node.children), " children")
    print(io, ")")
end

