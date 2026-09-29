module Progbiotic

using ColorTypes: Colorant, RGB, N0f8, red, green, blue
using MacroTools: @capture

include("errors.jl")
export ProgbioticError

include("color.jl")

# a theme *builds* a layout, so it comes before the node that holds one
include("style.jl")
export Theme
export CYBERPUNK, NEON, MATRIX, AMBER, EMERALD, OCEAN, GLACIER, TOKYO_NIGHT
export SYNTHWAVE, MAGMA, MONOCHROME, AURORA, DRACULA, SAKURA, GRUVBOX, REDLINE
export MIAMI, SOLARIZED, HALLOWEEN, UNICORN, COFFEE, TERMINAL, MONO, SLATE
export MIDNIGHT, FOREST, STEEL, PUNK, ACID, BLOODMOON, GLITCH, REBEL, VAPORWAVE
export HONEY, EMBER, TANGERINE, COPPER, MARIGOLD, SUNSET, AMBER_GLOW

include("time.jl")
export duration_str

# --- the node ----------------------------------------------------------------
# one type for the whole package: a bar is state + layout + children, and a standalone
# bar is a node with no children. prog, Progress and @progress are three front-ends
# onto it.
include("bar.jl")
export BarState
export pbdone, pbtotal, pbfraction, pbrate, pbeta, pbelapsed, pbruntime, isfinished
export Progress
export child, children, root_of, node_depth

# --- the columns -------------------------------------------------------------
include("columns.jl")
export AbstractColumn
export render_column
export Spinner, Tag, Bar, Percent
export Count, Rate, Eta, Postfix
export theme_layout, default_layout

# --- drawing and the terminal ------------------------------------------------
include("render.jl")
export render_line, render_frame
export render_tree, render_flat_line

include("engine.jl")

include("logger.jl")
export current_bar
export set_postfix!

# --- the front-ends ----------------------------------------------------------
include("imperative.jl")
export next!
export update!
export finish!
export withprogress

include("iterator.jl")
export prog
export ProgbioticIterator

include("macros.jl")
export @progress
end
