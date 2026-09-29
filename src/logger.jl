# the current bar, and the dynamic metrics that attach to it.

"""
    current_bar() -> Union{Progress, Nothing}

The innermost bar active in the current task, or nothing when no progress scope is
running. This is where a bare `set_postfix!` attaches its metrics.
"""
current_bar() = get(task_local_storage(), _CURRENT_KEY, nothing)

# Task-local storage key holding the innermost node executing in this task.
const _CURRENT_KEY = :__progbiotic_current_bar__

"""
    _install_bar!(bar) -> prior

Make bar the current task's innermost one, and hand back whatever was there so that
_restore_bar! can put it back.

A pair of calls rather than a do-block, because @progress installs this inline: a body
wrapped in a closure cannot return out of the function it was written in, so a return
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
    _with_scope(f, bar)

Run f with bar installed as the current task's innermost one, so that a bare
`set_postfix!()` inside f attaches its metrics to bar. The do-block front-ends use this;
@progress installs the same thing inline.
"""
function _with_scope(f::Function, bar::Progress)
    previous = _install_bar!(bar)
    try
        return f()
    finally
        _restore_bar!(previous)
    end
end

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
error rather than a silent no-op, because the scope is what says which bar a bare call
means. Metrics may also be attached to a specific bar by passing it explicitly.
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
