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
            res[item.args[1]] = item.args[2]
        elseif item.head == :string # Interpolated string
            res[:desc] = item
        else
            res[:theme] = item
        end
    end
end

function _parse_progress_args(args)
    res = Dict{Symbol, Any}(
        :bind           => nothing,
        :desc           => "",
        :theme          => :(Progbiotic.AMBER),
        :threads        => false,
        :title          => "",
        :vanish         => nothing,
        :vanish_timeout => nothing,
    )
    for arg in args
        _parse_progress_item(arg, res)
    end
    return res
end

function _extract_extra_kws(opts)
    kws = Any[]
    if opts[:vanish] !== nothing
        push!(kws, Expr(:kw, :vanish, opts[:vanish]))
    end
    if opts[:vanish_timeout] !== nothing
        push!(kws, Expr(:kw, :vanish_timeout, opts[:vanish_timeout]))
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
    _build_loop_expr(var, iter_sym, new_body, opts, pbar_sym, job_sym, wrappers)

Constructs the (optionally threaded, optionally macro-wrapped) iteration loop
that updates `job_sym` after every iteration of the transformed body, so the
progress start and completion are still reported correctly.
"""
function _build_loop_expr(var, iter_sym, new_body, opts, pbar_sym, job_sym, wrappers)
    loop = opts[:threads] ?
        :(
            Base.Threads.@threads for $var in $iter_sym
                $new_body
                Progbiotic.update!($pbar_sym, $job_sym)
            end
        ) :
        :(
            for $var in $iter_sym
                $new_body
                Progbiotic.update!($pbar_sym, $job_sym)
            end
        )
    return _rewrap_loop(loop, wrappers)
end

"""
    _build_progress_block(pbar_sym, job_sym, iter_sym, iter, opts, loop_expr, parent_job_sym)

Wraps the iteration loop with job registration in the progress tree and a
completion-checking `finally` clause.
"""
function _build_progress_block(pbar_sym, job_sym, iter_sym, iter, opts, loop_expr, parent_job_sym)
    bind_assignment = opts[:bind] !== nothing ?
        :($(opts[:bind]) = Progbiotic.ProgContext($pbar_sym, $job_sym)) : :()

    extra_kws = _extract_extra_kws(opts)

    return quote
        let $iter_sym = $(iter)
            $job_sym = Progbiotic.add_job!(
                $pbar_sym,
                $iter_sym;
                parent = $parent_job_sym,
                desc   = $(opts[:desc]),
                theme  = $(opts[:theme]),
                $(extra_kws...)
            )
            $bind_assignment
            try
                $loop_expr
            finally
                if $job_sym.total !== nothing && $job_sym.state < $job_sym.total
                    Progbiotic.update!($pbar_sym, $job_sym, $job_sym.total)
                end
            end
        end
    end
end

"""
Recursively transforms the AST, linking nested `@progress` invocations to parent jobs.
"""
function _transform_progress_ast(expr, pbar_sym, parent_job_sym)
    if _is_macrocall_progress(expr)
        m_args = _extract_macrocall_args(expr)
        isempty(m_args) && return expr

        loop_expr = m_args[end]
        cfg_args  = m_args[1:end-1]
        opts      = _parse_progress_args(cfg_args)

        for_expr, wrappers = _unwrap_loop(loop_expr)
        if for_expr !== nothing &&
           (@capture(for_expr, for var_ = iter_ body_ end) || @capture(for_expr, for var_ in iter_ body_ end))
            job_sym  = gensym("child_job")
            iter_sym = gensym("child_iter")
            new_body = _transform_progress_ast(body, pbar_sym, job_sym)

            loop_expr = _build_loop_expr(var, iter_sym, new_body, opts, pbar_sym, job_sym, wrappers)
            return _build_progress_block(pbar_sym, job_sym, iter_sym, iter, opts, loop_expr, parent_job_sym)
        end
        return expr
    elseif expr isa Expr
        return Expr(expr.head, map(arg -> _transform_progress_ast(arg, pbar_sym, parent_job_sym), expr.args)...)
    else
        return expr
    end
end

"""
    @progress [options] for var in collection ... end

Implicitly builds a progress tree across nested loops. The `for` loop may be
wrapped by other macros that affect it, e.g. `Base.Threads.@threads`:

    @progress "Downloading weights" Base.Threads.@threads for i in 1:100
        ...
    end

# Syntax
- `@progress "Description" for ...`
- `@progress ("Description", THEME) for ...`
- `@progress (pbar => THEME) for ...`  (binds `pbar` to a `ProgContext`)
- `@progress (pbar => ("Description", THEME)) for ...`
- `@progress ("Description", THEME, vanish_timeout=1.0) for ...`
"""
macro progress(args...)
    isempty(args) && error("@progress requires a loop expression")

    loop_expr = args[end]
    cfg_args  = args[1:end-1]
    opts      = _parse_progress_args(cfg_args)

    for_expr, wrappers = _unwrap_loop(loop_expr)
    if for_expr === nothing ||
       !(@capture(for_expr, for var_ = iter_ body_ end) || @capture(for_expr, for var_ in iter_ body_ end))
        error("@progress must be applied to a `for` loop (possibly wrapped by another macro, e.g. `Base.Threads.@threads for ... end`)")
    end

    pbar_sym = gensym("pbar")
    job_sym  = gensym("root_job")
    iter_sym = gensym("root_iter")

    new_body  = _transform_progress_ast(body, pbar_sym, job_sym)
    loop_expr = _build_loop_expr(var, iter_sym, new_body, opts, pbar_sym, job_sym, wrappers)

    extra_kws = _extract_extra_kws(opts)

    transformed = quote
        $pbar_sym = Progbiotic.ProgBar($(opts[:title]))
        Progbiotic.with_tree_gutter($pbar_sym) do
            $(_build_progress_block(pbar_sym, job_sym, iter_sym, iter, opts, loop_expr, nothing))
        end
    end

    return esc(transformed)
end