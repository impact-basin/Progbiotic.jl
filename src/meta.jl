function _is_macrocall_progress(e)
    if e isa Expr && e.head == :macrocall
        mname = e.args[1]
        return mname == Symbol("@progress") ||
               (mname isa Expr && mname.head == :. && mname.args[end] == QuoteNode(Symbol("@progress")))
    end
    return false
end

function _extract_macrocall_args(e)
    return filter(a -> !(a isa LineNumberNode), e.args[2:end])
end

function _parse_progress_item(item, res::Dict{Symbol, Any})
    if item isa String
        res[:desc] = item
    elseif item isa Symbol
        # Theme symbol (e.g. AMBER, GLACIER, NEON)
        res[:theme] = item
    elseif item isa Expr
        if item.head == :call && item.args[1] == :(=>)
            # Pair binding: (pbar => args...)
            res[:bind] = item.args[2]
            _parse_progress_item(item.args[3], res)
        elseif item.head == :tuple
            for elem in item.args
                _parse_progress_item(elem, res)
            end
        elseif item.head == :(=) || item.head == :kw
            # Keyword form (full name or short alias, e.g. `final_depth=1` or `d=1`)
            key, val = item.args[1], item.args[2]
            key, val = _canonical_progress_option(key, val)
            res[key] = val
        elseif item.head == :string # Interpolated string
            res[:desc] = item
        else
            res[:theme] = item
        end
    end
end

"""
    _coerce_final_depth(val) -> Int

Normalises a `final_depth` value to an `Int`. Dynamic expressions (symbols etc.) are
passed through unchanged and resolved at runtime.
"""
function _coerce_final_depth(val)
    val isa Integer && return Int(val)
    if val isa Real
        val == round(val) || error("@progress: `final_depth` must be an integer, got $(repr(val))")
        return Int(val)
    end
    return val
end

"""
    _canonical_progress_option(key, val) -> (canonical_key, val)

Maps short-form option names to their full names and normalises values:
- `d=1`     -> `final_depth=1`
- `t=OCEAN` -> `theme=OCEAN`
- `v=false` -> `vanish=false`      (keep bars on screen)
- `v=1.2`   -> `vanish_timeout=1.2` (seconds)
"""
function _canonical_progress_option(key, val)
    if key === :d
        return (:final_depth, _coerce_final_depth(val))
    elseif key === :t
        return (:theme, val)
    elseif key === :v
        if val isa Bool
            return (:vanish, val)
        elseif val isa Real
            return (:vanish_timeout, float(val))
        else
            error("@progress: `v=$val` is ambiguous — use `vanish=<bool>` (e.g. `v=false` keeps bars on screen) or `vanish_timeout=<seconds>` (e.g. `v=1.2`)")
        end
    elseif key === :vanish_timeout && val isa Real
        # Normalise e.g. `vanish_timeout=1` to Float64 for add_job!
        return (:vanish_timeout, float(val))
    elseif key === :final_depth
        return (:final_depth, _coerce_final_depth(val))
    elseif key === :threads
        error("@progress: the `threads=true` option was removed — wrap the loop with `Threads.@threads` instead, e.g. `@progress \"desc\" Base.Threads.@threads for i in 1:100 ... end`")
    end
    return (key, val)
end

function _parse_progress_args(args)
    res = Dict{Symbol, Any}(
        :bind           => nothing,
        :desc           => "",
        :theme          => :(Progbiotic.AMBER),
        :title          => "",
        :vanish         => nothing,
        :vanish_timeout => nothing,
        :final_depth    => 0,
        :with           => nothing,
        :spinner        => nothing,
        :barunits       => nothing,
        :empty          => nothing,
        :caps           => nothing,
        :head           => nothing,
        :width          => nothing,
    )
    # A bare symbol as the first argument binds a context variable:
    # `@progress ctx "desc" ...` is shorthand for `@progress (ctx => "desc") ...`.
    if !isempty(args) && args[1] isa Symbol
        res[:bind] = args[1]
        args = args[2:end]
    end
    for arg in args
        _parse_progress_item(arg, res)
    end
    return res
end

# Keyword arguments passed through to `add_job!` / `_statement_job` when set.
function _extract_extra_kws(opts)
    kws = Any[]
    for key in (:vanish, :vanish_timeout, :spinner, :barunits, :empty, :caps, :head, :width)
        opts[key] !== nothing && push!(kws, Expr(:kw, key, opts[key]))
    end
    return kws
end

_contains_for(e) =
    e isa Expr && (e.head == :for ||
                   (e.head == :macrocall && any(_contains_for, e.args[2:end])))

"""
    _unwrap_loop(expr) -> (for_expr, wrappers)

Finds the `for` loop inside `expr`, which may itself be wrapped by one or more
macrocalls (e.g. `Base.Threads.@threads for ... end` or `Base.@sync Base.@async for ... end`).
Returns the inner `for` expression together with the chain of wrapping
macrocalls (outermost first). Returns `(nothing, nothing)` if no `for` loop
can be found.
"""
function _unwrap_loop(expr)
    wrappers = Any[]
    while expr isa Expr
        if expr.head == :for
            return expr, wrappers
        elseif expr.head == :macrocall
            target = nothing
            for a in expr.args[2:end]
                if _contains_for(a)
                    target = a
                    break
                end
            end
            target === nothing && return nothing, nothing
            push!(wrappers, expr)
            expr = target
        else
            return nothing, nothing
        end
    end
    return nothing, nothing
end

"""
    _rewrap_loop(for_expr, wrappers)

Rebuilds a macro-wrapped `for` loop from its (possibly empty) chain of
wrapping macrocalls, substituting `for_expr` for the original loop.
"""
function _rewrap_loop(for_expr, wrappers)
    result = for_expr
    for w in reverse(wrappers)
        args = map(w.args) do a
            a isa Expr && _contains_for(a) ? result : a
        end
        result = Expr(:macrocall, args...)
    end
    return result
end

"""
    _build_loop_expr(var, iter_sym, new_body, pbar_sym, job_sym, wrappers)

Constructs the iteration loop that updates `job_sym` after every iteration of the
transformed body, so the progress start and completion are still reported
correctly. The loop may be re-wrapped by the caller's macros (e.g.
`Threads.@threads`, `Base.@sync`), which is how multithreading is expressed.
"""
function _build_loop_expr(var, iter_sym, new_body, pbar_sym, job_sym, wrappers)
    loop = :(
        for $var in $iter_sym
            $new_body
            Progbiotic.update!($pbar_sym, $job_sym)
        end
    )
    return _rewrap_loop(loop, wrappers)
end

"""
    _build_level_block(pbar_sym, job_sym, opts, parent_job_sym, body_expr;
                       is_loop, iter_sym=nothing, iter=nothing,
                       milestone_count=0, thread_ctx=nothing)

Registers a job for one `@progress` level (a `for` loop or a `begin ... end`
block), runs `body_expr` under it, and on exit completes any pending statement
subtasks and the job itself. When `thread_ctx` is a symbol, it is scoped-rebound
to the new job for the duration of the block and restored afterwards, so contexts
automatically track the innermost job.

A loop job's total is inferred from its iterable; a block job's total is
`max(1, milestone_count)` — the number of `@progress "desc"` milestones it
contains — and, when positive, the job is marked as a milestone container whose
state tracks how many milestones have completed.
"""
function _build_level_block(pbar_sym, job_sym, opts, parent_job_sym, body_expr;
                            is_loop::Bool = false,
                            iter_sym::Union{Symbol, Nothing} = nothing,
                            iter = nothing,
                            milestone_count::Int = 0,
                            thread_ctx::Union{Symbol, Nothing} = nothing)
    bind_assignment = opts[:bind] !== nothing ?
        :($(opts[:bind]) = Progbiotic.ProgContext($pbar_sym, $job_sym)) : :()
    extra_kws = _extract_extra_kws(opts)

    saved_ctx = gensym("saved_ctx")
    rebind_ctx = thread_ctx === nothing ? :() : :($thread_ctx = Progbiotic.ProgContext($pbar_sym, $job_sym))
    restore_ctx = thread_ctx === nothing ? :() : :($thread_ctx = $saved_ctx)

    if is_loop
        job_call = :($job_sym = Progbiotic.add_job!($pbar_sym, $iter_sym;
                          parent = $parent_job_sym, desc = $(opts[:desc]),
                          theme = $(opts[:theme]), $(extra_kws...)))
        bindings = [:($saved_ctx = $(thread_ctx === nothing ? nothing : thread_ctx)),
                    :($iter_sym = $(iter))]
        completion = :(if $job_sym.total !== nothing && $job_sym.state < $job_sym.total
                           Progbiotic.update!($pbar_sym, $job_sym, $job_sym.total)
                       end)
        mark = :()
    else
        total = max(1, milestone_count)
        job_call = :($job_sym = Progbiotic.add_job!($pbar_sym, $(opts[:desc]);
                          parent = $parent_job_sym, theme = $(opts[:theme]),
                          total = $total, $(extra_kws...)))
        bindings = [:($saved_ctx = $(thread_ctx === nothing ? nothing : thread_ctx))]
        completion = :(if $job_sym.state < $job_sym.total
                           Progbiotic.update!($pbar_sym, $job_sym, $job_sym.total)
                       end)
        mark = milestone_count > 0 ? :(Progbiotic._mark_container!($pbar_sym, $job_sym)) : :()
    end

    return quote
        let $(bindings...)
            $job_call
            $mark
            $bind_assignment
            $rebind_ctx
            try
                $body_expr
            finally
                $restore_ctx
                Progbiotic._complete_statement_jobs!($pbar_sym, $job_sym)
                $completion
            end
        end
    end
end

# Counts the direct `@progress "desc"` statement invocations in a begin/end block
# body. These are the block's "milestones": they give the block job its total and
# each one completed advances the block's progress by one.
function _count_milestones(body_expr)
    body_expr isa Expr && body_expr.head == :block || return 0
    n = 0
    for arg in body_expr.args
        arg isa LineNumberNode && continue
        if _is_macrocall_progress(arg)
            m_args = _extract_macrocall_args(arg)
            if !isempty(m_args)
                last = m_args[end]
                # Statement-form only: no loop (possibly macro-wrapped) and no block body.
                if !(last isa Expr && (last.head == :block || _contains_for(last)))
                    n += 1
                end
            end
        end
    end
    return n
end

"""
    _build_progress_level(m_args, pbar_sym, parent_job_sym, parent_opts, thread_ctx) -> (block, opts)

Parses one `@progress` invocation's arguments and builds the code for its level:
form detection (loop / block / statement), option parsing, vanish inheritance from
the enclosing level, `with=<ctx>` threading, and the context save/rebind/restore
wrapping. Returns the generated block together with the parsed options (so the
caller can inspect e.g. `opts[:with]` or `opts[:title]`).
"""
function _build_progress_level(m_args, pbar_sym, parent_job_sym,
                               parent_opts::Union{Dict{Symbol, Any}, Nothing},
                               thread_ctx::Union{Symbol, Nothing})
    body_expr = m_args[end]
    cfg_args  = m_args[1:end-1]

    for_expr, wrappers = _unwrap_loop(body_expr)
    is_block = body_expr isa Expr && body_expr.head == :block
    is_loop = for_expr !== nothing &&
        (@capture(for_expr, for var_ = iter_ body_ end) || @capture(for_expr, for var_ in iter_ body_ end))
    # A bare `@progress "desc"` statement has no loop/block body: all args are config.
    opts = _parse_progress_args(is_loop || is_block ? cfg_args : m_args)

    # Inherit vanishing behaviour from the enclosing @progress level.
    if parent_opts !== nothing
        if opts[:vanish] === nothing && parent_opts[:vanish] !== nothing
            opts[:vanish] = parent_opts[:vanish]
        end
        if opts[:vanish_timeout] === nothing && parent_opts[:vanish_timeout] !== nothing
            opts[:vanish_timeout] = parent_opts[:vanish_timeout]
        end
    end

    # `with=<ctx>` threads an existing context: register under ctx.pbar/ctx.parent
    # and carry `ctx` (if a symbol) down to nested levels.
    if opts[:with] !== nothing
        ctxv = gensym("with_ctx")
        level_pbar   = :($ctxv.pbar)
        level_parent = :($ctxv.parent)
        # The `with=` context is an existing value: rebind it around this level.
        carried      = opts[:with] isa Symbol ? opts[:with] : thread_ctx
        block_thread = carried
    else
        ctxv = nothing
        level_pbar   = pbar_sym
        level_parent = parent_job_sym
        # The inherited context tracks this level (restored afterwards); a level's
        # own `bind` is a fresh assignment handled by the bind_assignment instead.
        carried      = opts[:bind] isa Symbol ? opts[:bind] : thread_ctx
        block_thread = thread_ctx
    end

    block = if is_loop
        job_sym  = gensym("child_job")
        iter_sym = gensym("child_iter")
        new_body = _transform_progress_ast(body, level_pbar, job_sym, opts, carried)
        loop_expr = _build_loop_expr(var, iter_sym, new_body, level_pbar, job_sym, wrappers)
        _build_level_block(level_pbar, job_sym, opts, level_parent, loop_expr;
                           is_loop = true, iter_sym = iter_sym, iter = iter,
                           thread_ctx = block_thread)
    elseif is_block
        # `@progress "desc" begin ... end`: register a block job and run the
        # (transformed) block body under it.
        job_sym   = gensym("child_job")
        new_body  = _transform_progress_ast(body_expr, level_pbar, job_sym, opts, carried)
        _build_level_block(level_pbar, job_sym, opts, level_parent, new_body;
                           milestone_count = _count_milestones(body_expr),
                           thread_ctx = block_thread)
    else
        # `@progress "desc"` statement: register a named subtask (milestone) under
        # the enclosing job.
        job_sym = gensym("stmt_job")
        _build_statement_block(level_pbar, job_sym, opts, level_parent)
    end

    if opts[:with] !== nothing
        # Evaluate the context once, check it, and run the level's code against it.
        guard = :($ctxv isa Progbiotic.ProgContext ||
                  error("@progress: `with=` expects a ProgContext (e.g. one bound by the caller's @progress), got ", repr($ctxv)))
        block = quote
            let $ctxv = $(opts[:with])
                $guard
                $block
            end
        end
    end
    return block, opts
end

"""
    _build_statement_block(pbar_sym, job_sym, opts, parent_job_sym)

Builds the code for a `@progress "desc"` statement with no loop or block body: it
registers a named subtask (milestone) under `parent_job_sym` and optionally binds a
context. Milestones have no total and are kept on screen by `final_depth` (see
`is_job_visible`), or vanish like any other finished bar otherwise.
"""
function _build_statement_block(pbar_sym, job_sym, opts, parent_job_sym)
    bind_assignment = opts[:bind] !== nothing ?
        :($(opts[:bind]) = Progbiotic.ProgContext($pbar_sym, $job_sym)) : :()
    stmt_kws = Any[]
    for key in (:spinner, :barunits, :empty, :caps, :head, :width, :vanish, :vanish_timeout)
        opts[key] !== nothing && push!(stmt_kws, Expr(:kw, key, opts[key]))
    end
    return quote
        $job_sym = Progbiotic._statement_job($pbar_sym, $parent_job_sym;
                                             desc = $(opts[:desc]), theme = $(opts[:theme]),
                                             $(stmt_kws...))
        $bind_assignment
    end
end

"""
Recursively transforms the AST, linking nested `@progress` invocations to parent jobs
and carrying the context variable (`thread_ctx`) so contexts automatically track
the innermost job.
"""
function _transform_progress_ast(expr, pbar_sym, parent_job_sym, parent_opts::Dict{Symbol, Any},
                                 thread_ctx::Union{Symbol, Nothing} = nothing)
    if _is_macrocall_progress(expr)
        m_args = _extract_macrocall_args(expr)
        isempty(m_args) && return expr
        block, _ = _build_progress_level(m_args, pbar_sym, parent_job_sym, parent_opts, thread_ctx)
        return block
    elseif expr isa Expr
        return Expr(expr.head, map(arg -> _transform_progress_ast(arg, pbar_sym, parent_job_sym, parent_opts, thread_ctx), expr.args)...)
    else
        return expr
    end
end

"""
    @progress [options] for var in collection ... end
    @progress [options] begin ... end

Implicitly builds a progress tree across nested loops and blocks. The `for` loop may be
wrapped by other macros that affect it, e.g. `Base.Threads.@threads`:

    @progress "Downloading weights" Base.Threads.@threads for i in 1:100
        ...
    end

A plain `begin ... end` block is also accepted: the block itself becomes a job in
the tree (starting at 0% and completing when the block finishes), so you can group
phases or produce a context without a loop:

    @progress "foo" begin
        @progress "bar" for j in 1:10
            ...
        end
    end

A bare description — `@progress "desc" [options]` with no loop or block body —
registers a named subtask under the enclosing progress scope, for marking
sequential steps:

    @progress "foo" d=1 begin
        @progress "job 1"
        sleep(0.5)
        @progress "job 2"
        sleep(0.5)
        @progress "job 3"
        sleep(0.5)
    end

These subtasks are *milestones*: they have no total of their own, so they show no
rate and no ETA — instead they report their elapsed time — and each one finishes
when the next subtask is registered (or when the enclosing scope finishes). The
enclosing `begin ... end` block's total is the number of milestones it contains,
and its progress advances as each milestone completes (here `foo` runs 0/3 → 3/3).
Finished milestones are kept on screen by `final_depth` (e.g. `d=1` above).

# Contexts and subroutines

A context can be bound with `(ctx => "desc")` or a bare symbol as the first
argument (`@progress ctx "desc"`). The bound context automatically tracks the
innermost running job inside nested `@progress` levels and is restored afterwards,
so it can be passed to subroutines:

    function subtask(ctx, n)
        @progress with=ctx "working..." for k in 1:n
            ...
        end
    end

    @progress ctx "outer..." for i in 1:10
        @progress "inner" for j in 1:10
            subtask(ctx, i)          # ctx already points at "inner" here
        end
    end

`with=ctx` registers the job under the job `ctx` points at, on the same `ProgBar`
(no new gutter). The context is also scoped-rebound to the new job inside its body,
so deeper calls thread further, and restored afterwards.

# Syntax
- `@progress "Description" for ...`
- `@progress ("Description", THEME) for ...`
- `@progress (pbar => THEME) for ...`  (binds `pbar` to a `ProgContext`)
- `@progress (pbar => ("Description", THEME)) for ...`
- `@progress ("Description", THEME, vanish_timeout=1.0) for ...`
- `@progress "Description"`  (a named subtask; no body)
- `@progress ctx "Description" for ...`  (binds `ctx`; shorthand for `(ctx => ...)`)
- `@progress "Description" with=ctx for ...`  (register under `ctx`, e.g. in a subroutine)

# Short form options

The keyword options accept short aliases:
- `d=1`      — `final_depth=1` (levels of children kept in the final render)
- `v=false`  — `vanish=false` (keep bars on screen)
- `v=1.2`    — `vanish_timeout=1.2` (seconds)
- `t=OCEAN`  — `theme=OCEAN`

To run a loop multithreaded, wrap it with `Threads.@threads` instead of passing an
option:

    @progress "Downloading weights" Base.Threads.@threads for i in 1:100
        ...
    end

# Per-bar styling

A level can override its theme's glyphs or bar width without defining a whole
theme (`spinner`/`barunits`/`caps`/`head` may be strings or `Char` vectors):

    @progress "x" spinner="⠋⠙⠹" barunits="░▒▓█" empty="░" caps="[]" head=">" width=30 for i in 1:10
        ...
    end

`caps` flanks the bar (e.g. `[████░░]`); `head` marks the tip of an in-progress
bar (e.g. `█████>░░░`). To build a custom theme by mixing elements of the built-in
ones, use the `Theme` copy constructor: `Theme(AMBER; spinner=EMERALD.spinner)`.

# Vanishing

By default, completed bars vanish from the tree shortly after finishing
(`vanish_timeout` defaults to 0.5s), so a long-running loop does not fill the
screen with stale, finished sub-bars. Pass `vanish=false` to keep every bar on
screen, or `vanish_timeout=<seconds>` to control how long finished bars linger.
These options are inherited by nested `@progress` levels unless overridden.

# Final depth

Once the tree completes, the live gutter collapses finished jobs to just the
top-level summary. Pass `final_depth=N` to keep `N` levels of children in the
final render (0 keeps only the top-level job, 1 also keeps its direct children,
and so on):

    @progress "foo" final_depth=1 for i in 1:10
        ...
    end
"""
macro progress(args...)
    isempty(args) && error("@progress requires a loop, a block, or a description")

    pbar_sym = gensym("pbar")
    block, opts = _build_progress_level(args, pbar_sym, nothing, nothing, nothing)

    if opts[:with] !== nothing
        # `with=<ctx>`: thread an existing context — no new ProgBar or gutter.
        return esc(block)
    end

    transformed = quote
        $pbar_sym = Progbiotic.ProgBar($(opts[:title]); vanish_timeout = 0.5,
                                       final_depth = $(opts[:final_depth]))
        Progbiotic.with_tree_gutter($pbar_sym) do
            $block
        end
    end

    return esc(transformed)
end