module ShowTree

using MacroTools: @capture, postwalk
using StyledStrings

export print_tree
export with_tree_gutter
export @showtree
export ShowTreeError

"""
    ShowTreeError(msg)

Raised for malformed input: an unknown tree style, or an expression passed to
`@showtree` that is not a struct definition.
"""
struct ShowTreeError <: Exception
    msg :: String
end

ShowTreeError(parts...) = ShowTreeError(string(parts...))

Base.showerror(io::IO, err::ShowTreeError) = print(io, "ShowTreeError: ", err.msg)

include("print-tree.jl")
include("gutter.jl")
include("show-tree.jl")

end
