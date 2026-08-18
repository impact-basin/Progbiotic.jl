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
        :theme          => :(ProgBiotic.AMBER),
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

        if @capture(loop_expr, for var_ = iter_ body_ end) || @capture(loop_expr, for var_ in iter_ body_ end)
            job_sym  = gensym("child_job")
            iter_sym = gensym("child_iter")
            new_body = _transform_progress_ast(body, pbar_sym, job_sym)

            bind_assignment = opts[:bind] !== nothing ?
                :($(opts[:bind]) = ProgBiotic.ProgContext($pbar_sym, $job_sym)) : :()

            extra_kws = _extract_extra_kws(opts)

            return quote
                let $iter_sym = $(iter)
                    $job_sym = ProgBiotic.add_job!(
                        $pbar_sym,
                        $iter_sym;
                        parent = $parent_job_sym,
                        desc   = $(opts[:desc]),
                        theme  = $(opts[:theme]),
                        $(extra_kws...)
                    )
                    $bind_assignment
                    try
                        for $var in $iter_sym
                            $new_body
                            ProgBiotic.update!($pbar_sym, $job_sym)
                        end
                    finally
                        if $job_sym.total !== nothing && $job_sym.state < $job_sym.total
                            ProgBiotic.update!($pbar_sym, $job_sym, $job_sym.total)
                        end
                    end
                end
            end
        else
            return expr
        end
    elseif expr isa Expr
        return Expr(expr.head, map(arg -> _transform_progress_ast(arg, pbar_sym, parent_job_sym), expr.args)...)
    else
        return expr
    end
end

"""
    @progress [options] for var in collection ... end

Implicitly builds a progress tree across nested loops.

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

    if !(@capture(loop_expr, for var_ = iter_ body_ end) || @capture(loop_expr, for var_ in iter_ body_ end))
        error("@progress must be applied to a `for` loop")
    end

    pbar_sym = gensym("pbar")
    job_sym  = gensym("root_job")
    iter_sym = gensym("root_iter")

    new_body = _transform_progress_ast(body, pbar_sym, job_sym)

    bind_assignment = opts[:bind] !== nothing ?
        :($(opts[:bind]) = ProgBiotic.ProgContext($pbar_sym, $job_sym)) : :()

    extra_kws = _extract_extra_kws(opts)

    transformed = quote
        $pbar_sym = ProgBiotic.ProgBar($(opts[:title]))
        ProgBiotic.with_tree_gutter($pbar_sym) do
            let $iter_sym = $(iter)
                $job_sym = ProgBiotic.add_job!(
                    $pbar_sym,
                    $iter_sym;
                    parent = nothing,
                    desc   = $(opts[:desc]),
                    theme  = $(opts[:theme]),
                    $(extra_kws...)
                )
                $bind_assignment
                try
                    for $var in $iter_sym
                        $new_body
                        ProgBiotic.update!($pbar_sym, $job_sym)
                    end
                finally
                    if $job_sym.total !== nothing && $job_sym.state < $job_sym.total
                        ProgBiotic.update!($pbar_sym, $job_sym, $job_sym.total)
                    end
                end
            end
        end
    end

    return esc(transformed)
end


