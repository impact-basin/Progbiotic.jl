# the zero-boilerplate iterator interface.
#
#     for record in prog(1:1000; desc = "Parsing Records")
#         ...
#     end
#
# no macro, no boilerplate, no manual handle: wrapping a collection infers its length,
# installs a background renderer, and advances the bar once per item. When the length
# cannot be known - an unbounded channel, an iterator that reports SizeUnknown - the bar
# falls back to an indeterminate spinner, which is the honest thing to show.

"""
    ProgbioticIterator(iter, bar::Progress)

A transparent wrapper around an iterable that advances a progress bar as it is consumed.
Construct one with the prog function rather than directly.

Besides the iteration protocol it forwards the collection's shape traits (IteratorSize,
IteratorEltype, eltype, length, size), so comprehensions, collect, and Threads.@threads
over a wrapped collection all behave exactly as they do over the collection itself. The
bar it drives is `it.bar`.
"""
struct ProgbioticIterator{I, B<:Progress}
    iter :: I
    bar  :: B
end

stateof(it::ProgbioticIterator) = it.bar.state

@state_methods ProgbioticIterator

"""
    infer_total(iter) -> Union{Int, Nothing}

The length of a collection when it can be known in advance, and nothing otherwise.

Iterators that report HasLength or HasShape have a meaningful length, so the bar can be
determinate. IsInfinite and SizeUnknown iterators - channels, generators over unknown
ranges, filters - have none, so the bar goes indeterminate and shows a spinner instead of a
percentage that would be a lie.
"""
function infer_total(iter)
    trait = Base.IteratorSize(typeof(iter))
    (trait isa Base.HasLength || trait isa Base.HasShape) || return nothing
    return try
        Int(length(iter))
    catch
        nothing
    end
end

"""Sentinel meaning "work the total out from the collection"."""
const _AUTO_TOTAL = :auto

"""
    prog(iter; desc = "", vanish = 1.0, kwargs...) -> ProgbioticIterator
    prog(f, iter; kwargs...)

Wrap a collection in a progress bar.

    for x in prog(1:100; desc = "Training")
        ...
    end

The total is inferred from the collection when possible: HasLength and HasShape
collections get a determinate bar with a percentage, a rate and an ETA, while infinite or
size-unknown ones get an indeterminate spinner. Pass total = n to override the inference,
or total = nothing to force indeterminate mode.

# keyword arguments

- desc:       the bar's description.
- vanish:     seconds the finished bar (and its log lines) stays on screen.
- total:      override the inferred total (nothing forces indeterminate).
- layout:     a tuple of columns to draw instead of the theme's.
- io:         output stream (defaults to stdout).
- fps:        render cap, in frames per second (default 20).
- flat_step:  non-interactive mode emits a line every this many percent.
- tty:        force interactive or flat output.
- log_file:   permanently append intercepted log records to this path or IO.
- threaded:   render from a separate thread (worth it only for long, never-yielding loops).

The two-argument form runs the whole loop inside a log-capturing scope and returns nothing:

    prog(1:100; desc = "Training") do x
        @info "processing \$x"
    end
"""
function prog(iter;
              desc::AbstractString = "",
              vanish = 1.0,
              total = _AUTO_TOTAL,
              layout = nothing,
              io::IO = stdout,
              fps::Real = 20.0,
              flat_step::Integer = 10,
              tty = nothing,
              log_file = nothing,
              threaded::Bool = Threads.nthreads() > 1)
    resolved = total === _AUTO_TOTAL ? infer_total(iter) : total
    resolved isa Integer && (resolved = Int(resolved))
    (resolved === nothing || resolved isa Int) ||
        throw(ProgbioticError("total must be an Int or nothing; got ", repr(resolved)))

    bar = Progress(resolved; desc = desc, layout = layout, io = io, vanish = vanish,
                   fps = fps, flat_step = flat_step, tty = tty, log_file = log_file,
                   threaded = threaded)
    return ProgbioticIterator(iter, bar)
end

"""
    prog(f::Function, iter; kwargs...)

Run f over a wrapped collection inside a log-capturing scope, and finish the bar when the
loop ends. This is the form to use when the body logs:

    prog(1:100; desc = "Training") do x
        x == 50 && @info "halfway"
    end
"""
function prog(f::Function, iter; kwargs...)
    wrapped = prog(iter; kwargs...)
    _with_progress_logging(wrapped.bar) do
        for item in wrapped
            f(item)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# iteration protocol
# ---------------------------------------------------------------------------

# each step advances the atomic counter *before* handing the item to the loop body, so the
# count always means "items produced so far" and no work is needed after the body returns.
# When the underlying iterator is exhausted the bar is finished, which is what triggers the
# final frame and, on a terminal, the vanish timer.
function Base.iterate(it::ProgbioticIterator)
    step = iterate(it.iter)
    step === nothing && return _finish_iteration!(it)
    next!(it.bar)
    return step
end

function Base.iterate(it::ProgbioticIterator, state)
    step = iterate(it.iter, state)
    step === nothing && return _finish_iteration!(it)
    next!(it.bar)
    return step
end

function _finish_iteration!(it::ProgbioticIterator)
    finish!(it.bar)
    return nothing
end

# ---------------------------------------------------------------------------
# transparent collection traits
# ---------------------------------------------------------------------------

Base.IteratorSize(::Type{ProgbioticIterator{I, B}}) where {I, B} = Base.IteratorSize(I)
Base.IteratorEltype(::Type{ProgbioticIterator{I, B}}) where {I, B} = Base.IteratorEltype(I)
Base.eltype(::Type{ProgbioticIterator{I, B}}) where {I, B} = eltype(I)
Base.size(it::ProgbioticIterator) = size(it.iter)
Base.axes(it::ProgbioticIterator) = axes(it.iter)
Base.firstindex(it::ProgbioticIterator) = firstindex(it.iter)
Base.lastindex(it::ProgbioticIterator) = lastindex(it.iter)
Base.eachindex(it::ProgbioticIterator) = eachindex(it.iter)
Base.keys(it::ProgbioticIterator) = keys(it.iter)

function Base.length(it::ProgbioticIterator)
    total = it.bar.state.total
    total === nothing && return length(it.iter)
    return total
end

# Threads.@threads over an indexable collection splits the index range and reads elements
# with getindex rather than with iterate, so index access has to advance the bar as well -
# otherwise a parallel loop would report no progress at all.
function Base.getindex(it::ProgbioticIterator, index...)
    value = getindex(it.iter, index...)
    next!(it.bar)
    return value
end

# ---------------------------------------------------------------------------
# handles
# ---------------------------------------------------------------------------

"""Attach dynamic metrics to a wrapped collection's bar."""
set_postfix!(it::ProgbioticIterator; kwargs...) = set_postfix!(it.bar; kwargs...)

"""Finish a wrapped collection's bar early (for example after breaking out)."""
finish!(it::ProgbioticIterator; wait::Bool = !it.bar.opts.tty) = finish!(it.bar; wait = wait)

function Base.show(io::IO, it::ProgbioticIterator)
    state = it.bar.state
    print(io, "ProgbioticIterator(", repr(state.desc[]), ", ",
          state.total === nothing ? "indeterminate" :
                                    string(pbdone(state), "/", state.total), ")")
end
