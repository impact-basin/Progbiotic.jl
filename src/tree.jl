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
"""
function print_tree(
    dict::AbstractDict;
    style::Symbol = :round,
    root = nothing,
    sort_keys::Bool = true,
    io::IO = stdout
)
    syms = get(TREE_STRS, style) do
        error("Unknown style :$style. Available styles: $(collect(keys(TREE_STRS)))")
    end

    prefix = ""
    if root !== nothing
        println(io, root)
    end

    _print_tree_nodes(io, dict, prefix, syms, sort_keys)
end

# Convenience overload for pair syntax: print_tree("Root" => dict)
print_tree(pair::Pair; kwargs...) = print_tree(pair.second; root=pair.first, kwargs...)

function _print_tree_nodes(io::IO, d::AbstractDict, prefix::String, syms::Dict, sort_keys::Bool)
    ks = collect(keys(d))
    if sort_keys
        # Try sorting directly, fallback to string representation if keys aren't comparable
        try
            sort!(ks)
        catch
            sort!(ks, by=string)
        end
    end

    n = length(ks)
    for (i, k) in enumerate(ks)
        v = d[k]
        is_last = (i == n)
        branch = is_last ? syms[:term] : syms[:leaf]
        extension = is_last ? syms[:nada] : syms[:line]

        if v isa AbstractDict
            println(io, prefix, branch, k)
            _print_tree_nodes(io, v, prefix * extension, syms, sort_keys)
        else
            # Format leaf nodes (key => value) or just key if value is nothing
            if v === nothing
                println(io, prefix, branch, k)
            else
                println(io, prefix, branch, k, " => ", v)
            end
        end
    end
end


"""
    with_tree_gutter(f, tree_data; style=:round, io=stdout)

Pins the tree at the bottom of the terminal as a fixed gutter.
All `println()` and standard output inside the `do` block will scroll 
naturally above the tree.
"""
function with_tree_gutter(f::Function, dict::AbstractDict; io::IO = stdout, kwargs...)
    # 1. Render tree into a buffer to determine height
    buf = IOBuffer()
    print_tree(dict; io = buf, kwargs...)
    tree_str = String(take!(buf))
    tree_height = count(==('\n'), tree_str)

    term_height, term_width = displaysize(io)
    scroll_bottom = max(1, term_height - tree_height)
    gutter_start = scroll_bottom + 1

    # 2. Restrict scrolling region to top part of the screen
    print(io, "\e[1;", scroll_bottom, "r")

    # 3. Draw the tree in the bottom gutter
    print(io, "\e[", gutter_start, ";1H")  # Move to gutter start
    print(io, "\e[J")                       # Clear gutter area
    print(io, tree_str)

    # 4. Move cursor back to the active scrolling area
    print(io, "\e[", scroll_bottom, ";1H")
    flush(io)

    try
        f()
    catch e
        nothing
    finally
        # Reset scrolling region
        print(io, "\e[r")
        # Move cursor to the bottom
        print(io, "\e[", term_height, ";1H\n")
        flush(io)
    end
end
