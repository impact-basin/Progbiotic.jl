module ProgBiotic

using Dates
using Colors
using MacroTools

include("tree.jl")
export print_tree
export with_tree_gutter

include("look.jl")
export CYBERPUNK
export NEON
export MATRIX
export AMBER
export EMERALD
export OCEAN
export GLACIER
export TOKYO_NIGHT
export SYNTHWAVE
export MAGMA
export MONOCHROME
export AURORA
export DRACULA
export SAKURA
export GRUVBOX
export REDLINE
export MIAMI
export SOLARIZED


include("time.jl")
export duration_str

include("jobs.jl")
export ProgJob
export show_progjob_with_theme
export _render_bar
export with_job

include("bars.jl")
include("user.jl")

end
