# drawing a node, and drawing a tree of them.
#
# one line per node comes from its column layout. The tree is a depth-first walk that
# measures the widest visible label first, so every row's bar, rate and time line up,
# then draws each line behind its branch prefix with that node's live log lines under
# it. Where the block goes and when it is redrawn is src/engine.jl's business; nothing
# here touches the terminal.

"""The most log lines drawn under a single bar."""
const MAX_RENDERED_LOGS = 8

"""The narrowest description column, so a short label does not crowd the bar."""
const _MIN_DESC_WIDTH = 14

# bar widths: what a theme's own Bar is built at, and the range a measured line will
# shrink or grow it to.
const _BAR_WIDTH = 30
const _BAR_MIN   = 10
const _BAR_MAX   = 40

# ---------------------------------------------------------------------------
# one line
# ---------------------------------------------------------------------------

"""
    node_layout(node, desc_width = 0, width = _BAR_WIDTH) -> Tuple

The columns a node's line is built from: its own layout when it was given one
explicitly, and otherwise a layout built from its theme with the tree's measured
description width and the width the terminal left for the bar.

A hand-built layout is used verbatim, which is what opts it out of the alignment: a
tuple of your own columns has no Tag to widen.
"""
node_layout(node::Progress, desc_width::Int = 0, width::Int = _BAR_WIDTH) =
    node.layout === nothing ? theme_layout(node.theme; desc_width = desc_width, width = width) :
                              node.layout

"""
    _line_width(node, width) -> Int

The bar width for one row: an explicit width on the node wins, then a width measured
for the row, then the theme's own.
"""
_line_width(node::Progress, width::Union{Int, Nothing}) =
    node.opts.width > 0 ? node.opts.width :
    width === nothing   ? _BAR_WIDTH      : width

"""
    render_line(node, desc_width = 0, width = nothing) -> String

One node's line: every column of its layout, in order, joined with single spaces and
with empty columns dropped. Pure: it reads the atomics and returns a string.

Pass a width for the bar, or nothing to let the node and its theme decide.
"""
function render_line(node::Progress, desc_width::Int = 0, width::Union{Int, Nothing} = nothing)
    parts = String[]
    for column in node_layout(node, desc_width, _line_width(node, width))
        text = render_column(column, node.state)
        isempty(text) || push!(parts, text)
    end
    return join(parts, " ")
end

"""
    render_frame(node) -> String

The same line as render_line, at the widths the node and its theme ask for: the
standalone form, with no tree around it and no terminal to fit into.
"""
render_frame(node::Progress) = render_line(node)

"""
    render_block(node, now_sec = time()) -> Vector{String}

A node's complete frame: its own line followed by one line per live log record.
"""
function render_block(node::Progress, now_sec::Float64 = time())
    lines = String[render_frame(node)]
    for entry in active_logs(node, now_sec)
        push!(lines, format_log_line(entry))
    end
    return lines
end

"""
    _rest_width(node, desc_width) -> Int

The visible width of everything in a node's line except the bar, its separators
included, so render_tree can hand the bar what the terminal has left.
"""
function _rest_width(node::Progress, desc_width::Int)
    parts = 0
    total = 0
    for column in node_layout(node, desc_width)
        column isa Bar && continue
        text = render_column(column, node.state)
        isempty(text) && continue
        total += _visible_width(text)
        parts += 1
    end
    # a separator after each of those parts, then the bar's own caps and separator
    return total + parts + 2
end

# ---------------------------------------------------------------------------
# the tree
# ---------------------------------------------------------------------------

"""
    Row(node, prefix, gutter, depth)

One drawn line: the node it belongs to, the branch prefix the line sits behind, the
prefix that node's log lines sit behind, and the node's depth in the tree.
"""
struct Row{P<:Progress}
    node   :: P
    prefix :: String
    gutter :: String
    depth  :: Int
end

"""
    _tree_rows(root, symbols, collapse, now_sec) -> Vector{Row}

Every visible line of the tree, depth-first, with the prefix it is drawn behind.

The root is flush at column 0 unless the tree has a title, in which case it branches
under the title like any other row. With `collapse` set, a node that has finished
hides its subtree below `root.final_depth`, which is what keeps a long run from
filling the screen with stale bars.
"""
function _tree_rows(root::Progress, symbols, collapse::Bool, now_sec::Float64)
    titled = !isempty(root.root.title)
    rows   = Row[(Row(root, titled ? symbols[:term] : "", titled ? symbols[:nada] : "", 0))]
    _collect_rows!(rows, root, "", symbols, collapse, now_sec)
    return rows
end

function _collect_rows!(rows::Vector, node::Progress, prefix::AbstractString, symbols,
                        collapse::Bool, now_sec::Float64)
    children_visible(node, collapse, now_sec) || return rows

    kids = [kid for kid in children(node) if _visible(kid, now_sec)]
    for (i, kid) in enumerate(kids)
        last      = i == length(kids)
        branch    = last ? symbols[:term] : symbols[:leaf]
        extension = last ? symbols[:nada] : symbols[:line]
        push!(rows, Row(kid, string(prefix, branch), string(prefix, extension),
                        node_depth(kid)))
        _collect_rows!(rows, kid, string(prefix, extension), symbols, collapse, now_sec)
    end
    return rows
end

# whether a node's subtree is drawn: a finished node keeps final_depth levels below the
# top of the tree and drops the rest.
children_visible(node::Progress, collapse::Bool, now_sec::Float64) =
    !(collapse && _completed(node) && node_depth(node) >= node.root.final_depth)

"""
    _visible(node, now_sec) -> Bool

Whether a node is drawn at all.

A node stays while any of its children does, and while it holds live log lines, so an
intercepted record is never cut short by the bar that owns it vanishing first. Nodes
within `final_depth` are kept regardless of their timeout, a node with an infinite
timeout stays forever, and anything else goes once its timeout has run out from the
tick that first saw it finished.
"""
function _visible(node::Progress, now_sec::Float64)
    any(child -> _visible(child, now_sec), children(node)) && return true
    has_active_logs(node, now_sec) && return true
    # final_depth promises to keep N levels of children below the top of the tree. The
    # root is not one of them: it vanishes on its own timeout, like any other bar.
    node.parent !== nothing && node_depth(node) <= node.root.final_depth && return true
    isinf(node.opts.vanish) && return true

    stamp = node.paint.completed_at
    stamp == 0.0 && return _stamp_completion!(node, now_sec)
    return (now_sec - stamp) < node.opts.vanish
end

# a node that has just finished starts its vanish timeout at the tick that notices.
function _stamp_completion!(node::Progress, now_sec::Float64)
    _completed(node) || return true
    node.paint.completed_at = now_sec
    return true
end

"""
    _tree_bar_width(rows, desc_width, term_width) -> Int

The bar width every row of the tree shares.

One width for the whole tree is what keeps the bars, rates and times aligned down the
column, and it is measured from the narrowest row: the deepest branch prefix and the
widest line of columns other than the bar. A node with an explicit width ignores this
entirely.
"""
function _tree_bar_width(rows::Vector, desc_width::Int, term_width::Int)
    term_width <= 0 && return _BAR_WIDTH

    prefix = maximum(row -> _visible_width(row.prefix), rows)
    rest   = maximum(row -> row.node.opts.width > 0 ? 0 :
                            _rest_width(row.node, desc_width), rows; init = 0)
    return clamp(term_width - prefix - rest, _BAR_MIN, _BAR_MAX)
end

"""
    render_tree(node; collapse = true, width = 0, now_sec = time()) -> String

The whole tree as lines joined by newlines, or an empty string when nothing is visible.

`width` is the terminal width the tree has to fit into, or 0 to draw at the widths the
columns and themes ask for. Every line is clipped to it, and the shared bar width is
chosen to leave room for the deepest branch prefix.
"""
function render_tree(node::Progress; collapse::Bool = true, width::Int = 0,
                     now_sec::Float64 = time())
    symbols = get(TREE_STRS, node.root.style, TREE_STRS[:round])
    rows    = _tree_rows(node, symbols, collapse, now_sec)

    desc_width = max(_MIN_DESC_WIDTH, maximum(row -> length(row.node.state.desc[]), rows))
    bar_width  = _tree_bar_width(rows, desc_width, width)

    io     = IOBuffer()
    titled = !isempty(node.root.title)
    titled && println(io, _ANSI_BOLD, node.root.title, _ANSI_RESET)

    for (i, row) in enumerate(rows)
        # an untitled tree draws its root flush at column 0, with no branch at all
        flush_root = i == 1 && !titled
        line = string(flush_root ? "" : row.prefix,
                      render_line(row.node, desc_width, bar_width))
        println(io, _clip(line, width))
        _render_logs(io, row.node, flush_root ? "" : row.gutter, symbols, now_sec, width)
    end
    return String(take!(io))
end

"""
    _render_logs(io, node, prefix, symbols, now_sec, width = 0) -> Int

Draw the live log lines buffered for a node directly beneath its bar, indented by
`prefix` (the node's tree gutter), and return how many were written. Expired entries
are pruned on the way, so a renderer measuring the block's height only ever counts the
lines that are really drawn.
"""
function _render_logs(io::IO, node::Progress, prefix::AbstractString, symbols,
                      now_sec::Float64, width::Int = 0)
    entries = active_logs(node, now_sec)
    isempty(entries) && return 0
    if length(entries) > MAX_RENDERED_LOGS
        entries = entries[(end - MAX_RENDERED_LOGS + 1):end]
    end

    gutter = get(symbols, :line, "│  ")
    for entry in entries
        println(io, _clip(string(prefix, gutter, format_log_line(entry)), width))
    end
    return length(entries)
end

# ---------------------------------------------------------------------------
# the append-only line
# ---------------------------------------------------------------------------

"""
    flat_percentage(node) -> Int

A node's integer completion percentage, or -1 when it has no total.
"""
function flat_percentage(node::Progress)
    state = node.state
    total = state.total
    total === nothing && return -1
    total <= 0 && return 100
    return clamp(floor(Int, 100 * pbdone(state) / total), 0, 100)
end

# the columns a flat line already accounts for: a spinner and a bar carry nothing in a
# file, and the label, percentage and count are all in the head already.
const _FLAT_SKIP = (Spinner, Tag, Bar, Percent, Count)

"""
    render_flat_line(node, depth = 0) -> String

One line of the non-interactive format, e.g.

    [INFO] Parsing Records 25% (250/1000) 412.5 it/s ETA: 1.2ms [loss=0.041]

Not an escape sequence anywhere: this is output you grep.
"""
function render_flat_line(node::Progress, depth::Int = 0)
    state  = node.state
    label  = isempty(state.desc[]) ? "Progress" : state.desc[]
    indent = repeat("  ", depth)

    head = if state.total === nothing
        string("[INFO] ", indent, label, " ", max(pbdone(state), 1), " (indeterminate)")
    else
        done = clamp(pbdone(state), 0, state.total)
        pct  = state.total > 0 ? floor(Int, 100 * done / state.total) : 100
        string("[INFO] ", indent, label, " ", pct, "% (", done, "/", state.total, ")")
    end

    extras = String[]
    for column in node_layout(node)
        any(T -> column isa T, _FLAT_SKIP) && continue
        text = render_column(column, state)
        isempty(text) || push!(extras, text)
    end

    postfix = postfix_text(state)
    isempty(postfix) || push!(extras, string("[", postfix, "]"))

    isempty(extras) && return head
    return string(head, " ", join(extras, " "))
end

# ---------------------------------------------------------------------------
# measuring a line that carries escape sequences
# ---------------------------------------------------------------------------

"""
    _visible_width(s) -> Int

The columns a string occupies on screen, counting a CSI escape sequence as zero-width
and anything else as one column.
"""
function _visible_width(s::AbstractString)
    n    = 0
    i    = firstindex(s)
    last = lastindex(s)
    while i <= last
        if s[i] == '\e' && i < last && s[nextind(s, i)] == '['
            i = _skip_csi(s, i, last)
            i === nothing && return n
        else
            n += 1
            i = nextind(s, i)
        end
    end
    return n
end

"""
    _truncate_ansi(s, width) -> String

Truncate a string to at most `width` visible columns, treating ANSI escape sequences as
zero-width. Only CSI sequences are recognised as zero-width; anything else counts as
one column. Truncation ends with a reset, so no colour bleeds into what follows.
"""
function _truncate_ansi(s::AbstractString, width::Int)
    n    = 0
    i    = firstindex(s)
    last = lastindex(s)
    buf  = IOBuffer()
    while i <= last && n < width
        if s[i] == '\e' && i < last && s[nextind(s, i)] == '['
            j = _skip_csi(s, i, last)
            j === nothing && break          # unterminated escape: drop the rest
            write(buf, SubString(s, i, j))
            i = nextind(s, j)
        else
            write(buf, s[i])
            n += 1
            i = nextind(s, i)
        end
    end
    out = String(take!(buf))
    return n >= width ? string(out, _ANSI_RESET) : out
end

# the index of the last byte of the CSI sequence starting at i, or nothing when it is
# unterminated. Its final byte is in '@'..'~'.
function _skip_csi(s::AbstractString, i::Int, last::Int)
    j = nextind(s, i)                       # the '['
    while j <= last
        j = nextind(s, j)
        j > last && break
        '@' <= s[j] <= '~' && return j
    end
    return nothing
end

# clip a line to a terminal width, where 0 means there is no terminal to fit into.
_clip(line::AbstractString, width::Int) =
    width <= 0 ? String(line) : _truncate_ansi(line, width)
