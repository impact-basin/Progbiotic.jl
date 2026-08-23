module Progbiotic

using Dates
using Colors
using MacroTools

include("tree.jl")
export print_tree
export with_tree_gutter

include("look.jl")
export Theme
export CYBERPUNK, NEON, MATRIX, AMBER, EMERALD, OCEAN, GLACIER, TOKYO_NIGHT
export SYNTHWAVE, MAGMA, MONOCHROME, AURORA, DRACULA, SAKURA, GRUVBOX, REDLINE
export MIAMI, SOLARIZED, HALLOWEEN, UNICORN, COFFEE, TERMINAL, MONO, SLATE
export MIDNIGHT, FOREST, STEEL, PUNK, ACID, BLOODMOON, GLITCH, REBEL, VAPORWAVE
export HONEY, EMBER, TANGERINE, COPPER, MARIGOLD, SUNSET, AMBER_GLOW

include("time.jl")
export duration_str

include("jobs.jl")
export ProgJob
export show_progjob_with_theme
export with_job

include("bars.jl")
export ProgBar
export ProgContext
export add_job!
export get_children
export render_progbar_tree
export print_progbar_in_gutter
export update!

include("meta.jl")
export @progress

end
