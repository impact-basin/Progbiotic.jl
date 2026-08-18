module Progbiotic

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
export HALLOWEEN
export UNICORN
export COFFEE
export TERMINAL
export MONO
export SLATE
export MIDNIGHT
export FOREST
export STEEL
export PUNK
export ACID
export BLOODMOON
export GLITCH
export REBEL
export VAPORWAVE


include("time.jl")
export duration_str

include("jobs.jl")
export ProgJob
export show_progjob_with_theme
export _render_bar
export with_job

include("bars.jl")
export ProgBar
export add_job!
export get_children
export render_progbar_tree
export _render_job_nodes
export print_progbar_in_gutter
export update!
export with_tree_gutter
export ProgContext

include("meta.jl")
export @progress

end
