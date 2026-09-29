# Manual progress handles: Progress, next!, update!, finish!.
#
#     p = Progress(100; desc = "Custom Pipeline", layout = my_layout)
#     for i in 1:100
#         next!(p)
#     end
#     finish!(p)
#
# This is the escape hatch for when the work is not a simple for loop over a
# collection: an event-driven protocol, several loops sharing one bar, or work done
# from a dozen threads.  Advancing the handle is a single atomic add, so a handle is
# safe to share across threads exactly as prog(...) is.

"""
    Progress(total = nothing; desc = "", layout = default_layout(),
             vanish = 1.0, io = stdout, fps = 20.0, flat_step = 10,
             tty = nothing, log_file = nothing, threaded = false,
             start = true) -> Progress

A manual progress-bar handle.

total is the number of units of work, or nothing for an indeterminate bar with a
spinner instead of a percentage.  The remaining keyword arguments are those of
ProgressContext: layout, output stream, frame rate, vanish timeout and persistent
log sink.

The renderer starts immediately, so the bar is on screen before the first unit of
work is done; call finish! to complete it.  Advancing the handle from any number of
threads is safe:

    p = Progress(10_000; desc = "Parallel Processing")
    Threads.@threads for i in 1:10_000
        next!(p)
    end
    finish!(p)
"""
struct Progress
    # The render context that owns the state, the layout and the render task.
    ctx :: ProgressContext
end

function Progress(total::Union{Int, Nothing} = nothing;
                  desc::AbstractString = "",
                  layout = nothing,
                  vanish = 1.0,
                  io::IO = stdout,
                  fps::Real = 20.0,
                  flat_step::Integer = 10,
                  tty = nothing,
                  log_file = nothing,
                  threaded::Bool = Threads.nthreads() > 1,
                  start::Bool = true)
    ctx = ProgressContext(total; desc = desc, layout = layout, io = io,
                          vanish = vanish, fps = fps, flat_step = flat_step,
                          tty = tty, log_file = log_file)
    start && start_render_task!(ctx; threaded = threaded)
    return Progress(ctx)
end

"""
    Progress(f::Function, total; kwargs...)

Run f(p) with a fresh bar, finishing it when f returns (or throws):

    Progress(100; desc = "Training") do p
        for i in 1:100
            next!(p)
        end
    end
"""
function Progress(f::Function, total::Union{Int, Nothing} = nothing; kwargs...)
    handle = Progress(total; kwargs...)
    with_progress_logging(handle.ctx) do
        try
            f(handle)
        finally
            finish!(handle)
        end
    end
    return handle
end

"""The render context behind a handle."""
progress_context(p::Progress) = p.ctx
_as_context(p::Progress) = p.ctx

"""
    next!(p::Progress, n::Int = 1)

Advance a bar by n units.

This is a single lock-free atomic add, so it is both the fast path for a tight loop
and the safe path for a Threads.@threads loop: any number of threads may advance the
same bar with no lock contention and no chance of a lost update.
"""
function next!(p::Progress, n::Int = 1)
    next!(p.ctx, n)
    return nothing
end

function next!(ctx::ProgressContext, n::Int = 1)
    n == 0 || Threads.atomic_add!(ctx.state.current, n)
    return nothing
end

"""
    update!(p::Progress, value::Int)

Set a bar's counter to an absolute value (clamped to the total when it has one),
for work whose progress is reported rather than counted.
"""
function update!(p::Progress, value::Int)
    update!(p.ctx, value)
    return nothing
end

function update!(ctx::ProgressContext, value::Int)
    state = ctx.state
    state.current[] = state.total === nothing ? value : clamp(value, 0, state.total)
    return nothing
end

"""
    finish!(p::Progress; wait = !p.ctx.tty)

Complete a bar: the counter is clamped to the total, the final frame is drawn, and
the renderer is released.  On a terminal the finished bar stays on screen for its
vanish timeout and is then erased; with wait = true the call blocks until that
teardown is done.
"""
finish!(p::Progress; wait::Bool = !p.ctx.tty) = finish!(p.ctx; wait = wait)

"""Attach dynamic metrics to a handle."""
set_postfix!(p::Progress; kwargs...) = set_postfix!(p.ctx; kwargs...)

"""The state behind a handle."""
stateof(p::Progress) = p.ctx.state

@state_methods Progress

"""
    withprogress(f::Function, total = nothing; kwargs...)

Alias of the do-block form of Progress, for symmetry with the rest of the
ecosystem.
"""
withprogress(f::Function, total::Union{Int, Nothing} = nothing; kwargs...) =
    Progress(f, total; kwargs...)

function Base.show(io::IO, p::Progress)
    state = p.ctx.state
    print(io, "Progress(", repr(state.desc[]), ", ",
          state.total === nothing ? "indeterminate" : string(state.current[], "/", state.total),
          p.ctx.finished[] ? ", finished" : ", running", ")")
end
