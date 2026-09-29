# manual progress handles: next!, update!, finish!, withprogress.
#
#     p = Progress(100; desc = "Custom Pipeline", layout = my_layout)
#     for i in 1:100
#         next!(p)
#     end
#     finish!(p)
#
# a handle *is* a node: Progress(100) builds the root of a one-node tree, and every
# function in this file is a method on it. This is the escape hatch for when the work is
# not a simple for loop over a collection: an event-driven protocol, several loops sharing
# one bar, or work done from a dozen threads. Advancing the handle is a single atomic add,
# so a handle is safe to share across threads exactly as prog(...) is.

"""
    Progress(f::Function, total = nothing; kwargs...)

Run f(p) with a fresh bar, finishing it when f returns (or throws):

    Progress(100; desc = "Training") do p
        for i in 1:100
            next!(p)
        end
    end

The whole call is a log-capturing scope, so records emitted inside f are drawn under the
bar and a bare `set_postfix!` resolves to it.
"""
function Progress(f::Function, total::Union{Int, Nothing} = nothing; kwargs...)
    bar = Progress(total; kwargs...)
    _with_progress_logging(bar) do
        try
            f(bar)
        finally
            finish!(bar)
        end
    end
    return bar
end

"""
    next!(p::Progress, n::Int = 1)

Advance a bar by n units.

This is a single lock-free atomic add, so it is both the fast path for a tight loop and the
safe path for a Threads.@threads loop: any number of threads may advance the same bar with
no lock contention and no chance of a lost update.
"""
function next!(node::Progress, n::Int = 1)
    n == 0 || Threads.atomic_add!(node.state.current, n)
    return nothing
end

"""
    update!(p::Progress, value::Int)

Set a bar's counter to an absolute value (clamped to the total when it has one), for work
whose progress is reported rather than counted.
"""
function update!(node::Progress, value::Int)
    state = node.state
    state.current[] = state.total === nothing ? value : clamp(value, 0, state.total)
    return nothing
end

"""
    withprogress(f::Function, total = nothing; kwargs...)

Alias of the do-block form of Progress, for symmetry with the rest of the ecosystem.
"""
withprogress(f::Function, total::Union{Int, Nothing} = nothing; kwargs...) =
    Progress(f, total; kwargs...)
