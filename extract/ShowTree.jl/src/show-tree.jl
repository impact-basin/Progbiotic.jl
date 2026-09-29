"""
    @showtree struct_definition

Define `struct_definition` and give the type a `Base.show` method that renders its
fields as a tree:

    @showtree struct Point
        x :: Float64
        y :: Float64
    end

    julia> Point(1, 2)
    Point
    ╰─ x :: Float64 => 1.0
    ╰─ y :: Float64 => 2.0

Fields are annotated with their declared type. Declaring `fieldtypes = false`
inside a block renders the bare names instead:

    @showtree begin
        fieldtypes = false
        struct Point
            x :: Float64
            y :: Float64
        end
    end
"""
macro showtree(expr)
    opts  = (fieldtypes = true,)
    sname = nothing
    svals = Pair{Symbol, Any}[]

    postwalk(expr) do node
        if @capture(node, fieldtypes_ = flag_Bool)
            opts = (; opts..., fieldtypes = flag)
            return nothing
        end
        @capture(node, struct T_Symbol fields__ end) || return node
        sname = T
        empty!(svals)
        for field in fields
            field isa LineNumberNode && continue
            if field isa Symbol
                push!(svals, field => :Any)
                continue
            end
            @capture(field, f_Symbol :: t_) || continue
            push!(svals, f => t)
        end
        return node
    end

    sname === nothing &&
        throw(ShowTreeError("@showtree expects a struct definition; got ", repr(expr)))

    arg   = gensym("struct")
    iovar = gensym("io")
    # one `"label" => arg.field` expression per field; QuoteNode keeps the access static
    access(f) = Expr(:., arg, QuoteNode(f))
    pairs = opts.fieldtypes ?
        [Expr(:call, :(=>), string(f, " :: ", t), access(f)) for (f, t) in svals] :
        [Expr(:call, :(=>), string(f), access(f)) for (f, _) in svals]

    namestr = string(sname)
    label   = styled"┬  {bold,blue:$namestr}"

    return quote
        $(esc(expr))
        function Base.show($iovar::IO, $arg::$(esc(sname)))
            $(ShowTree).print_tree(Dict($(pairs...)), root = $label, io = $iovar)
        end
    end
end
