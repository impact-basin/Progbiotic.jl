# Stage 4b: the node merge

Working notes for the one atomic stage left in the refactor. Delete this file when
the stage lands.

## Goal

One node type, one renderer. `ProgJob`, `ProgBar`, `ProgContext`, `ProgressContext`
and `ProgressState` all disappear.

## The node

```julia
struct Progress{L, T<:Theme}
    state    :: BarState
    theme    :: T                        # kept so a layout can be rebuilt with a measured width
    layout   :: L                        # a Tuple of columns, or nothing for theme-derived
    opts     :: Opts
    io       :: IO
    parent   :: Union{Progress, Nothing}
    children :: Vector{Progress}
    logs     :: LogBuf
    root     :: RootState                # shared by every node of one tree
    paint    :: Paint
end
```

Immutable; every mutable thing it touches is a cell behind a reference. The two
erasure points (`parent`, `children`) are deliberate: a tree is heterogeneous
because children have different layouts. Document them, do not "fix" them.

`child(p, total = nothing; desc = "", kw...) -> Progress` creates the child, pushes it
into `p.children` under the root lock, and returns it. `stateof` + `@state_methods`
give a node every reader.

## The renderer

- `render_line(node, desc_width = 0)` — one bar's line, from `node_layout(node, desc_width)`.
- `node_layout(node, desc_width)` — `node.layout` if set, else `theme_layout(node.theme; desc_width)`.
- `render_tree(root; now_sec)` — walks visible nodes depth-first, measures
  `desc_width = max(14, widest visible desc)`, draws each line behind its gutter
  prefix, and draws each node's live log lines beneath it.
- Flat mode: one function, no escapes, one line per `flat_step` percent per node.
- Delete `show_progjob_with_theme`, `_render_bar`, `_render_progbar_tree`,
  `render_frame`, and the second copy of the log formatters in `render.jl`.

## The engine

Root-owned task. `start_render!(root)` spawns one task; a child's `root` is its
parent's, so children never spawn. One tick walks the tree, prunes logs, draws.
Vanish/erase/cursor logic moves to `engine.jl` unchanged in behaviour.

## The macro

`@progress` keeps its AST logic; only the calls it emits change:

| was | becomes |
|---|---|
| `_root_progbar(title, ...)` | `Progress(nothing; ...)` as the root |
| `add_job!(pbar, iter; parent, desc, theme, ...)` | `child(parent, total; desc, theme, ...)` |
| `ProgContext(pbar, job)` | the node itself |
| `update!(pbar, job)` | `next!(job)` |
| `_with_log_capture(ctx, capture)` | adapted to the node |
| `_statement_job`, `_mark_container!`, `_complete_statement_jobs!` | reimplemented on `children` |

Milestone behaviour is preserved exactly (approved decision): a statement is an
indeterminate child, finished when the next sibling registers or the parent exits;
a block job's total is its milestone count.

## Order of work

1. `bar.jl`: the node, `child`, `stateof`, `Base.show`.
2. `render.jl`: rewritten on columns (delete `jobs.jl`'s bar code).
3. `engine.jl`: root-owned task.
4. `logger.jl`: one `LogEntry`, buffers on `LogBuf`, capture scope-only.
5. `imperative.jl`/`iterator.jl`: `next!`/`update!`/`finish!`/`prog` on nodes.
6. `macro.jl`: re-point the emitted calls.
7. Delete `jobs.jl`, `bars.jl`, `context.jl`, `types.jl`; rewire `Progbiotic.jl`.
8. Tests.

## Known consequences

- `prog` and `Progress` no longer take a `ProgressContext`; a node is the handle.
- Cross-row alignment applies to theme-derived layouts; a hand-built `layout=` is used
  verbatim and opts out.
- `finish!`/`wait` semantics unchanged.
