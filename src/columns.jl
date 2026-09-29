# the pieces a bar's line is built from.
#
# every column is a tiny immutable value implementing
#
#     render_column(col::MyColumn, state::BarState) -> String
#
# and a *layout* is a Tuple of them. A tuple rather than a vector: a layout is fixed
# when the bar is built, and a heterogeneous tuple keeps rendering concretely typed
# instead of dispatching through Vector{AbstractColumn} on every frame.

# ---------------------------------------------------------------------------
# the column interface
# ---------------------------------------------------------------------------

"""
    AbstractColumn

Supertype of every progress-bar column.

A column is a small, stateless value that knows how to turn a BarState into one string.
Columns are composed into a tuple (a *layout*) and joined with single spaces by the
renderer, so a layout reads left-to-right like the bar it draws:

    layout = (Spinner(:dots), Tag("{desc}"), Bar(), Percent(), Count(), Rate("it/s"), Eta())

Implementations must define

    render_column(col::MyColumn, state::BarState) -> String

Columns must be cheap to render (the engine calls them up to fps times a second) and must
never block: they only read the atomic progress state.
"""
abstract type AbstractColumn end

"""
    render_column(col::AbstractColumn, state::BarState) -> String

Render one column of a progress line. This is the extension point for custom columns:
subtype AbstractColumn and add a method.

Returning an empty string is allowed and means "this column contributes nothing right
now"; the renderer drops empty columns along with the whitespace around them.
"""
function render_column end

# ---------------------------------------------------------------------------
# shared formatting
# ---------------------------------------------------------------------------

"""
    _format_hms(seconds) -> String

A duration as HH:MM:SS. Non-finite inputs render as "--:--:--" so the column never
changes width mid-run.
"""
function _format_hms(seconds::Real)
    (isfinite(seconds) && seconds >= 0) || return "--:--:--"
    total = floor(Int, seconds)
    hours, rest = divrem(total, 3600)
    minutes, secs = divrem(rest, 60)
    return string(lpad(hours, 2, '0'), ":", lpad(minutes, 2, '0'), ":", lpad(secs, 2, '0'))
end

"""
    _inverse_unit(unit) -> String

Invert a rate unit, so "it/s" becomes "s/it" below one item per second.
"""
function _inverse_unit(unit::AbstractString)
    occursin('/', unit) || return string("s/", unit)
    parts = split(unit, '/'; limit = 2)
    return string(parts[2], "/", parts[1])
end

"""
    _format_rate(rate, unit) -> String

A rate with SI-ish magnitude prefixes ("1.2k it/s"). Below one item per second it is
shown inverted as seconds per item ("1.5 s/it"), which is far easier to read for slow
work.
"""
function _format_rate(rate::Real, unit::AbstractString)
    (!isfinite(rate) || rate <= 0) && return ""
    rate >= 1e9 && return string(round(rate / 1e9, digits = 1), "G ", unit)
    rate >= 1e6 && return string(round(rate / 1e6, digits = 1), "M ", unit)
    rate >= 1e3 && return string(round(rate / 1e3, digits = 1), "k ", unit)
    rate >= 1   && return string(round(rate, digits = 1), " ", unit)
    return string(round(1 / rate, digits = 1), " ", _inverse_unit(unit))
end

# ---------------------------------------------------------------------------
# Spinner
# ---------------------------------------------------------------------------

"""
    _SPINNER_STYLES

Named animation frame sets for Spinner. The :dots and :line styles are the portable
ones; the rest exist because a progress bar is allowed to be fun.
"""
const _SPINNER_STYLES = Dict{Symbol, Vector{String}}(
    :dots    => ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
    :line    => ["-", "\\", "|", "/"],
    :dots2   => ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"],
    :arc     => ["◜", "◠", "◝", "◞", "◡", "◟"],
    :circle  => ["◐", "◓", "◑", "◒"],
    :clock   => ["🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛"],
    :moon    => ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"],
    :bounce  => ["⠁", "⠂", "⠄", "⠂"],
    :grow    => ["▁", "▃", "▄", "▅", "▆", "▇", "▆", "▅", "▄", "▃"],
    :blocks  => ["▖", "▘", "▝", "▗"],
    :arrow   => ["←", "↖", "↑", "↗", "→", "↘", "↓", "↙"],
    :bounce2 => ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"],
)

"""The frame set for a named spinner style."""
function _spinner_frames(style::Symbol)
    frames = get(_SPINNER_STYLES, style, nothing)
    frames === nothing || return frames
    throw(ProgbioticError("unknown spinner style :", style, "; available: ",
                          join(sort!(collect(keys(_SPINNER_STYLES))), ", ")))
end

# frames advance at a fixed rate; 12 Hz reads as motion without being distracting
const _SPINNER_HZ = 12.0

"""
    Spinner(style::Symbol = :dots; palette = [], hz = 12.0) -> Spinner
    Spinner(frames::AbstractVector; palette = [], hz = 12.0) -> Spinner

An animated glyph showing the bar is alive. It rotates on wall-clock time rather
than on progress, so it keeps moving for an indeterminate bar where there is no
percentage to advance.

Styles: :dots, :line, :dots2, :arc, :circle, :clock, :moon, :bounce, :grow, :blocks,
:arrow, :bounce2. Pass `frames` to use a theme's own glyphs, as `theme_layout` does.
"""
struct Spinner{P<:Colorant} <: AbstractColumn
    frames  :: Vector{String}
    palette :: Vector{P}
    hz      :: Float64
end

Spinner(style::Symbol = :dots; palette = RGB{N0f8}[], hz::Real = _SPINNER_HZ) =
    Spinner(_spinner_frames(style), palette, hz)

Spinner(frames::AbstractVector; palette = RGB{N0f8}[], hz::Real = _SPINNER_HZ) =
    Spinner(String[string(f) for f in frames], palette, hz)

function render_column(col::Spinner, state::BarState)
    frames = col.frames
    index = mod(floor(Int, time() * col.hz), length(frames)) + 1
    isempty(col.palette) && return frames[index]

    # the glyph walks the palette, so an idle bar still reads as alive
    colour = col.palette[mod(floor(Int, time() * 4), length(col.palette)) + 1]
    return string(ansi_fg(colour), frames[index], _ANSI_RESET)
end

# ---------------------------------------------------------------------------
# Tag
# ---------------------------------------------------------------------------

"""
    Tag(template::String = "{desc}"; width = 0, bold = false) -> Tag

A static or interpolated label, optionally padded to a width and bolded. A tree's
layout pads it to its widest visible label, which is what lines the bars up down the
rows. Placeholders:

    {desc}      the bar's description
    {n}         completed units
    {total}     total units ("" when indeterminate)
    {pct}       completion percentage, e.g. "42.0"
    {elapsed}   wall-clock seconds since the bar started, as HH:MM:SS
    {postfix}   the dynamic metrics, e.g. "loss=0.041, lr=1e-4"

Unknown placeholders are left alone, so a template with literal braces still works.
"""
struct Tag <: AbstractColumn
    template :: String
    width    :: Int
    bold     :: Bool
end

Tag(template::AbstractString; width::Int = 0, bold::Bool = false) =
    Tag(String(template), max(0, width), bold)
Tag(; template::AbstractString = "{desc}", width::Int = 0, bold::Bool = false) =
    Tag(String(template), max(0, width), bold)

function render_column(col::Tag, state::BarState)
    text = strip(_interpolate(col.template, state))
    col.width == 0 || (text = rpad(text, col.width))
    # bold is off unless asked for: an unstyled column emits no escape sequences at all,
    # and it is the theme's layout that turns it on for a description.
    return col.bold ? string(_ANSI_BOLD, text, _ANSI_RESET) : text
end

function _interpolate(template::AbstractString, state::BarState)
    text = template
    occursin("{desc}", text)    && (text = replace(text, "{desc}"    => state.desc[]))
    occursin("{n}", text)       && (text = replace(text, "{n}"       => string(pbdone(state))))
    occursin("{total}", text)   && (text = replace(text, "{total}"   => _total_text(state)))
    occursin("{pct}", text)     && (text = replace(text, "{pct}"     => _percent_text(state, 1)))
    occursin("{elapsed}", text) && (text = replace(text, "{elapsed}" => _format_hms(pbruntime(state))))
    occursin("{postfix}", text) && (text = replace(text, "{postfix}" => postfix_text(state)))
    return text
end

_total_text(state::BarState) = pbtotal(state) === nothing ? "" : string(pbtotal(state))

function _percent_text(state::BarState, digits::Int)
    fraction = pbfraction(state)
    fraction === nothing && return ""
    value = 100 * fraction
    return digits == 0 ? string(round(Int, value)) : string(round(value, digits = digits))
end

# ---------------------------------------------------------------------------
# bar
# ---------------------------------------------------------------------------

# marquee speed, in track positions per second
const _MARQUEE_HZ = 10.0

"""
    Bar(; fill = '█', empty = '░', width = 30) -> Bar
    Bar(units, empty, palette[, caps, head]; width = 30) -> Bar

The bar itself, as a run of `width` characters framed by `caps` and tipped with
`head`.

The single-glyph form is the plain bar. The `units` form is the themed one: a stipple
series from low to high fill, giving sub-character resolution, with the filled run
coloured by interpolating `palette` from its left end to its right.

For a determinate bar the filled run tracks the completed fraction. For an
indeterminate one a block of glyphs bounces left and right inside the track, which is
the conventional "working, but the amount left is unknown" cue.
"""
struct Bar{P<:Colorant} <: AbstractColumn
    units   :: Vector{Char}
    empty   :: Char
    palette :: Vector{P}
    caps    :: Tuple{Char, Char}
    head    :: Union{Char, Nothing}
    width   :: Int
end

Bar(; fill::Char = '█', empty::Char = '░', width::Int = 30) =
    Bar([fill], empty, RGB{N0f8}[], (' ', ' '), nothing, max(1, width))

Bar(fill::Char, empty::Char, width::Int) = Bar(; fill = fill, empty = empty, width = width)

function Bar(units::AbstractVector, empty::Char, palette::AbstractVector{P},
             caps::Tuple{Char, Char} = (' ', ' '), head::Union{Char, Nothing} = nothing;
             width::Int = 30) where {P<:Colorant}
    isempty(units) && throw(ProgbioticError("a Bar needs at least one fill glyph"))
    return Bar(Char[units...], empty, Vector{P}(palette), caps, head, max(1, width))
end

render_column(col::Bar, state::BarState) = _bar_frame(col, pbfraction(state))

_fg(col::Bar, t::Real) = palette_gradient(col.palette, float(t))
_track(col::Bar) = isempty(col.palette) ? "" : ansi_fg(col.palette[begin])

function _bar_frame(col::Bar, fraction::Union{Float64, Nothing})
    fraction === nothing && return _marquee(col)

    units = col.units
    width = col.width
    level = length(units)

    # sub-character resolution: how far into the track, in units of the finest glyph
    subunits = round(Int, clamp(fraction, 0.0, 1.0) * width * level)
    full  = div(subunits, level)
    rem_s = rem(subunits, level)
    solid = string(units[end])

    filled = if col.head === nothing || fraction >= 1.0 || (full == 0 && rem_s == 0)
        string(repeat(solid, full), rem_s > 0 ? string(units[rem_s]) : "")
    elseif rem_s > 0
        # a head glyph replaces the tip of an in-progress bar
        string(repeat(solid, full), col.head)
    else
        string(repeat(solid, max(0, full - 1)), col.head)
    end

    trailing = max(0, width - full - (rem_s > 0 ? 1 : 0))
    return _frame(col, filled, repeat(string(col.empty), trailing), _fg(col, fraction))
end

# no total: sweep a block back and forth so the bar still moves
function _marquee(col::Bar)
    width = col.width
    block = max(1, width ÷ 4)
    span = max(1, width - block)
    period = 2 * span
    tick = mod(floor(Int, time() * _MARQUEE_HZ), period)
    position = tick <= span ? tick : period - tick     # triangle wave: no jump at the ends
    return _frame(col,
                  repeat(string(col.units[end]), block),
                  repeat(string(col.empty), max(0, span - position)),
                  _fg(col, 0.0);
                  leading = repeat(string(col.empty), position))
end

function _frame(col::Bar, filled::AbstractString, trailing::AbstractString,
                colour::AbstractString; leading::AbstractString = "")
    left, right = col.caps
    track = _track(col)
    # with no colour anywhere there is nothing to reset, and the bar must then be
    # plain text: a stream that is not a terminal gets no escape sequences at all
    reset = isempty(track) && isempty(colour) ? "" : _ANSI_RESET
    return string(track, left, colour, leading, filled, track, trailing, right, reset)
end

# ---------------------------------------------------------------------------
# percentage and count
# ---------------------------------------------------------------------------

"""
    Percent(digits::Int = 1; pad = 0) -> Percent

The completion percentage, e.g. "45.2%", left-padded to `pad` columns so a field that
crosses 9% to 10% does not shuffle what is to its right. Renders nothing for an
indeterminate bar, where a percentage would be a lie.
"""
struct Percent <: AbstractColumn
    digits :: Int
    pad    :: Int
end

Percent(digits::Integer; pad::Integer = 0) = Percent(Int(digits), max(0, Int(pad)))
Percent(; digits::Integer = 1, pad::Integer = 0) = Percent(Int(digits), max(0, Int(pad)))

function render_column(col::Percent, state::BarState)
    text = _percent_text(state, col.digits)
    isempty(text) && return ""
    # a pad stops the field jittering as it crosses 9% to 10%
    return string(lpad(text, col.pad), "%")
end

"""
    Count() -> Count

Completed and total units, e.g. "(42/100)", with the completed count padded to the
width of the total so the field does not shuffle. An indeterminate bar has no total to
compare against, so it reports "1 unit" instead: it stands for one piece of work.
"""
struct Count <: AbstractColumn end

function render_column(::Count, state::BarState)
    done  = pbdone(state)
    total = pbtotal(state)
    # no total: an indeterminate node stands for one unit of work, and saying so beats
    # an empty field
    total === nothing && return string(max(done, 1), max(done, 1) == 1 ? " unit" : " units")
    # the count is padded to the total's width so "( 4/10)" does not shuffle
    return string("(", lpad(done, ndigits(total)), "/", total, ")")
end

# ---------------------------------------------------------------------------
# Rate and ETA
# ---------------------------------------------------------------------------

"""
    Rate(unit::String = "it/s"; pad = 10) -> Rate

Throughput, measured over elapsed *work* time so it freezes while a bar waits on
something else. Below one item per second it switches to seconds per item, which is
what you actually want to see for slow work.

Rendered in brackets and right-padded to `pad` columns, so the times further right line
up down a tree; a rate of zero renders nothing at all rather than a zero.
"""
struct Rate <: AbstractColumn
    unit :: String
    pad  :: Int
end

Rate(unit::AbstractString; pad::Integer = 10) = Rate(String(unit), max(0, Int(pad)))
Rate(; unit::AbstractString = "it/s", pad::Integer = 10) = Rate(String(unit), max(0, Int(pad)))

function render_column(col::Rate, state::BarState)
    text = _format_rate(pbrate(state), col.unit)
    isempty(text) && return ""
    # bracketed and padded, so the times to the right of it line up down the tree
    return string("[", rpad(text, col.pad), "]")
end

"""
    Eta() -> Eta

The time column, in whichever of the three states a node is in: "ETA: 1.2s"
extrapolated from the average rate so far, "done in 1.2s" once it has finished, and
"(elapsed: 1.2s)" for an indeterminate node, which has no end to count down to.
Durations carry sub-second precision rather than an HH:MM:SS that reads 00:00:00.
"""
struct Eta <: AbstractColumn end

function render_column(::Eta, state::BarState)
    total = pbtotal(state)
    # the time column, in all three of the states a node can be in
    if total === nothing
        isfinished(state) && return string("done in ", _duration(state))
        return string("(elapsed: ", _duration(state), ")")
    end
    pbdone(state) >= total && return string("done in ", _duration(state))

    eta = pbeta(state)
    eta === nothing && return "ETA: N/A"
    return string("ETA: ", duration_str(eta; show_ms = true))
end

# wall-clock time with sub-second precision: elapsed while running, frozen at completion
_duration(state::BarState) = duration_str(pbruntime(state); show_ms = true)

# ---------------------------------------------------------------------------
# Postfix
# ---------------------------------------------------------------------------

"""
    Postfix(separator::String = ", ") -> Postfix

The dynamic metrics attached by `set_postfix!`, e.g. "loss=0.041, accuracy=50.5%".
Unlike everything else a bar shows, these are *state* rather than history: they are
overwritten on every call, so they never clutter the scrollback.
"""
struct Postfix <: AbstractColumn
    separator :: String
end

Postfix(; separator::AbstractString = ", ") = Postfix(String(separator))

function render_column(col::Postfix, state::BarState)
    text = postfix_text(state; separator = col.separator)
    isempty(text) && return ""
    return string("[", text, "]")
end

# ---------------------------------------------------------------------------
# Theme layouts
# ---------------------------------------------------------------------------

"""
    theme_layout(t::Theme; desc_width = 0, width = 30) -> Tuple

The column layout a theme describes.

A theme is applied by *building* columns, not by columns consulting it: styling is
fixed when the bar is constructed, `render_column` stays a pure function of the state,
and a custom column needs no plumbing to be styled.

`desc_width` is the width the label is padded to, which a tree measures from its widest
visible node so the columns line up down the rows. `width` is the bar width, which the
engine measures from what the rest of the line leaves.
"""
theme_layout(t::Theme; desc_width::Int = 0, width::Int = _BAR_WIDTH) = (
    Spinner(t.spinner; palette = t.palette),
    Tag("{desc}"; width = desc_width, bold = true),
    Bar(t.barunits, t.empty, t.palette, t.caps, t.head; width = width),
    Percent(digits = 0, pad = 3),
    Count(),
    Rate("it/s"),
    Eta(),
    Postfix(),
)

"""
    default_layout() -> Tuple

The layout used when no theme is given: that of AMBER.
"""
default_layout() = theme_layout(AMBER)
