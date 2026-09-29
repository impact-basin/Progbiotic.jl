"""Branch glyphs for the two tree styles, keyed by role."""
const TREE_STRS = Dict(
    :square => Dict(
        :nada => "   ",
        :root => "┬  ",
        :line => "│  ",
        :leaf => "├─ ",
        :term => "└─ ",
    ),

    :round => Dict(
        :nada => "   ",
        :root => "┬  ",
        :line => "│  ",
        :leaf => "├─ ",
        :term => "╰─ ",
    ),
)

"""
    print_tree(data; style=:round, root=nothing, sort_keys=true, io=stdout)

Recursively print a nested `Dict` structure as a visual tree.

`style` is `:round` or `:square`, and `root` is an optional label printed above
the tree. Keys are sorted when `sort_keys` is true, falling back to string
ordering for keys that do not compare.
"""
function print_tree(
    dict::AbstractDict;
    style::Symbol = :round,
    root = nothing,
    sort_keys::Bool = true,
    io::IO = stdout,
    rootsym = false
)
    syms = get(TREE_STRS, style) do
        throw(ShowTreeError("unknown style :", style, "; available styles: ",
                            join(collect(keys(TREE_STRS)), ", ")))
    end

    prefix = ""
    if root !== nothing
        rootsym && print(io, TREE_STRS[:round][:root])
        println(io, root)
    end

    _print_tree_nodes(io, dict, prefix, syms, sort_keys)
end

# convenience overload for pair syntax: print_tree("Root" => dict)
print_tree(pair::Pair; kwargs...) = print_tree(pair.second; root = pair.first, kwargs...)

function _print_tree_nodes(io::IO, d::AbstractDict, prefix::String, syms::Dict, sort_keys::Bool)
    ks = collect(keys(d))
    if sort_keys
        # sort directly when the keys compare, by string representation otherwise
        try
            sort!(ks)
        catch
            sort!(ks, by = string)
        end
    end

    n = length(ks)
    for (i, k) in enumerate(ks)
        v = d[k]
        is_last   = (i == n)
        branch    = is_last ? syms[:term] : syms[:leaf]
        extension = is_last ? syms[:nada] : syms[:line]

        if v isa AbstractDict
            println(io, prefix, branch, k)
            _print_tree_nodes(io, v, prefix * extension, syms, sort_keys)
        elseif v === nothing
            println(io, prefix, branch, k)
        else
            println(io, prefix, branch, k, " => ", v)
        end
    end
end
