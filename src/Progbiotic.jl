module Progbiotic

using ColorTypes: Colorant, RGB, N0f8, red, green, blue
using MacroTools: @capture
import Logging   # stdlib: log interception for @progress scopes

include("errors.jl")
export ProgbioticError

include("color.jl")

include("bar.jl")
export BarState
export pbdone, pbtotal, pbfraction, pbrate, pbeta, pbelapsed, pbruntime, isfinished

include("look.jl")
export Theme
export CYBERPUNK, NEON, MATRIX, AMBER, EMERALD, OCEAN, GLACIER, TOKYO_NIGHT
export SYNTHWAVE, MAGMA, MONOCHROME, AURORA, DRACULA, SAKURA, GRUVBOX, REDLINE
export MIAMI, SOLARIZED, HALLOWEEN, UNICORN, COFFEE, TERMINAL, MONO, SLATE
export MIDNIGHT, FOREST, STEEL, PUNK, ACID, BLOODMOON, GLITCH, REBEL, VAPORWAVE
export HONEY, EMBER, TANGERINE, COPPER, MARIGOLD, SUNSET, AMBER_GLOW

include("time.jl")
export duration_str

# --- The column renderer -----------------------------------------------------
# types.jl holds the shared vocabulary (columns, log records, atomic state and the
# render context); columns.jl the pluggable layout pieces; engine.jl the
# background render task and the terminal controls.
include("types.jl")
export AbstractColumn
export render_column
export ProgressContext

include("columns.jl")
export Spinner, Tag, Bar, Percent
export Count, Rate, Eta, Postfix
export theme_layout, default_layout

include("engine.jl")
export render_frame, render_block, render_flat_line

# --- The tree renderer -------------------------------------------------------
include("jobs.jl")
export ProgJob
export show_progjob_with_theme
export with_job

include("context.jl")
export push_log!
export prune_logs!
export active_logs

include("bars.jl")
export ProgBar
export ProgContext
export add_job!
export get_children
export render_progbar_tree
export print_progbar_in_gutter
export with_tree_gutter

include("render.jl")
export stop_gutter!

include("logger.jl")
export ProgbioticLogger
export current_prog_context
export current_progress_target
export LogEntry
export set_postfix!
export with_progress_logging

# --- Ergonomic interfaces ----------------------------------------------------
include("iterator.jl")
export prog
export ProgbioticIterator
export progress_context

include("imperative.jl")
export Progress
export next!
export update!
export finish!
export withprogress

include("macro.jl")
export @progress
end
