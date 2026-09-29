"""
    with_tree_gutter(f, tree_data; style=:round, io=stdout, kwargs...)

Pin `tree_data` at the bottom of the terminal as a fixed gutter while `f()` runs.
Anything `println`ed inside the `do` block scrolls naturally above the tree.

The scroll region is restored and the cursor parked at the bottom in a `finally`
block, so an exception in `f` propagates normally with the terminal intact.
"""
function with_tree_gutter(f::Function, dict::AbstractDict; io::IO = stdout, kwargs...)
    buf = IOBuffer()
    print_tree(dict; io = buf, kwargs...)
    tree_str = String(take!(buf))
    tree_height = count(==('\n'), tree_str)

    term_height, _ = displaysize(io)
    scroll_bottom = max(1, term_height - tree_height)
    gutter_start  = scroll_bottom + 1

    # restrict scrolling to the rows above the gutter, then draw the tree in it
    print(io, "\e[1;", scroll_bottom, "r")
    print(io, "\e[", gutter_start, ";1H")
    print(io, "\e[J")
    print(io, tree_str)
    print(io, "\e[", scroll_bottom, ";1H")
    flush(io)

    try
        f()
    finally
        print(io, "\e[r")
        print(io, "\e[", term_height, ";1H\n")
        flush(io)
    end
end
