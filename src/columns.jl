# Modular progress-bar columns.
#
# Every column is a tiny immutable value implementing
#
#     render_column(col::MyColumn, state::BarState) -> String
#
# and layouts are just vectors of them, composed left-to-right by the engine.  This
# replaces the hard-coded single-line format of the original renderer: a user can
# now build any bar they want out of these pieces, or drop in their own.

# ---------------------------------------------------------------------------
# Shared formatting helpers
# ---------------------------------------------------------------------------

"""
    _format_hms(seconds) -> String

Format a duration as HH:MM:SS, the format the ETA column uses.  Non-finite inputs
render as "--:--:--" so the column never changes width mid-run.
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

Invert a rate unit, so that "it/s" becomes "s/it" when the rate drops below one
item per second and the column switches to seconds-per-item.
"""
function _inverse_unit(unit::AbstractString)
    if occursin('/', unit)
        parts = split(unit, '/'; limit = 2)
        return string(parts[2], "/", parts[1])
    end
    return string("s/", unit)
end

"""
    _format_rate(rate, unit) -> String

Render an items-per-second rate using SI-ish magnitude prefixes, e.g. "1.2k it/s"
or "3.4M it/s".  Rates below one item per second are shown inverted, as seconds per
item ("1.5 s/it"), which is far easier to read for slow work.
"""
function _format_rate(rate::Real, unit::AbstractString)
    (!isfinite(rate) || rate <= 0) && return ""
    if rate >= 1_000_000_000
        return string(round(rate / 1_000_000_000, digits = 1), "G ", unit)
    elseif rate >= 1_000_000
        return string(round(rate / 1_000_000, digits = 1), "M ", unit)
    elseif rate >= 1_000
        return string(round(rate / 1_000, digits = 1), "k ", unit)
    elseif rate >= 1
        return string(round(rate, digits = 1), " ", unit)
    else
        return string(round(1 / rate, digits = 1), " ", _inverse_unit(unit))
    end
end

# ---------------------------------------------------------------------------
# SpinnerColumn
# ---------------------------------------------------------------------------

"""
    _SPINNER_STYLES

Named animation frame sets for SpinnerColumn.  The :dots and :line styles are the
portable ones; the rest are provided because a progress bar is allowed to be fun.
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

"""
    _spinner_frames(style::Symbol) -> Vector{String}

The frame set for a named spinner style.  Unknown styles raise an error listing the
available names rather than silently rendering nothing.
"""
function _spinner_frames(style::Symbol)
    frames = get(_SPINNER_STYLES, style, nothing)
    frames === nothing && error("Progbiotic: unknown spinner style :", style,
                                "; available styles: ",
                                join(sort!(collect(keys(_SPINNER_STYLES))), ", "))
    return frames
end

"""
    SpinnerColumn(style::Symbol = :dots) -> SpinnerColumn

An animated glyph that shows the bar is alive.  It rotates on wall-clock time (not
on progress), so it keeps moving for an indeterminate bar - an unbounded channel,
say - where there is no percentage to advance.

Styles: :dots, :line, :dots2, :arc, :circle, :clock, :moon, :bounce, :grow,
:blocks, :arrow, :bounce2.
"""
struct SpinnerColumn <: AbstractColumn
    style  :: Symbol
    frames :: Vector{String}

    SpinnerColumn(style::Symbol) = new(style, _spinner_frames(style))
    SpinnerColumn(; style::Symbol = :dots) = new(style, _spinner_frames(style))
end

# Frames advance at a fixed rate; 12 Hz reads as motion without being distracting.
const _SPINNER_HZ = 12.0

function render_column(col::SpinnerColumn, state::BarState)
    frames = col.frames
    index = mod(floor(Int, time() * _SPINNER_HZ), length(frames)) + 1
    return frames[index]
end

# ---------------------------------------------------------------------------
# TextColumn
# ---------------------------------------------------------------------------

"""
    TextColumn(template::String = "{desc}") -> TextColumn

A static or interpolated label.

The template may contain any of these placeholders:

    {desc}      the bar's description
    {n}         completed units
    {total}     total units ("" when indeterminate)
    {pct}       completion percentage, e.g. "42.0"
    {elapsed}   wall-clock seconds since the bar started, as HH:MM:SS
    {postfix}   the dynamic metrics, e.g. "loss=0.041, lr=1e-4"

Unknown placeholders are left untouched, so templates that contain literal braces
still work.
"""
struct TextColumn <: AbstractColumn
    template :: String

    TextColumn(template::AbstractString) = new(String(template))
    TextColumn(; template::AbstractString = "{desc}") = new(String(template))
end

function render_column(col::TextColumn, state::BarState)
    text = col.template
    occursin("{desc}", text)    && (text = replace(text, "{desc}" => state.desc[]))
    occursin("{n}", text)       && (text = replace(text, "{n}" => string(state.current[])))
    occursin("{total}", text)   && (text = replace(text, "{total}" =>
        state.total === nothing ? "" : string(state.total)))
    occursin("{pct}", text)     && (text = replace(text, "{pct}" =>
        state.total === nothing ? "" : string(round(100 * pbfraction(state), digits = 1))))
    occursin("{elapsed}", text) && (text = replace(text, "{elapsed}" =>
        _format_hms(pbruntime(state))))
    occursin("{postfix}", text) && (text = replace(text, "{postfix}" => postfix_text(state)))
    return strip(text)
end

# ---------------------------------------------------------------------------
# BarColumn
# ---------------------------------------------------------------------------

"""
    BarColumn(fill = '█', empty = '░', width = 30) -> BarColumn

The bar itself, as a run of width characters.

For a determinate bar the filled portion tracks the fraction completed.  For an
indeterminate one (no total) a block of fill characters bounces left and right
inside the track, which is the conventional "we are working, but we do not know how
much is left" cue.
"""
struct BarColumn <: AbstractColumn
    fill  :: Char
    empty :: Char
    width :: Int

    BarColumn(fill::Char, empty::Char, width::Int) = new(fill, empty, width)
    BarColumn(; fill::Char = '█', empty::Char = '░', width::Int = 30) =
        new(fill, empty, max(1, width))
end

# Marquee speed, in track positions per second.
const _MARQUEE_HZ = 10.0

function render_column(col::BarColumn, state::BarState)
    width = col.width
    fraction = pbfraction(state)

    if fraction === nothing
        block = max(1, width ÷ 4)
        span = max(1, width - block)
        # Triangle wave: sweep right, then left, so the block never jumps.
        period = 2 * span
        tick = mod(floor(Int, time() * _MARQUEE_HZ), period)
        position = tick <= span ? tick : period - tick
        return string(repeat(string(col.empty), position),
                      repeat(string(col.fill), block),
                      repeat(string(col.empty), max(0, span - position)))
    end

    filled = clamp(round(Int, fraction * width), 0, width)
    return string(repeat(string(col.fill), filled),
                  repeat(string(col.empty), width - filled))
end

# ---------------------------------------------------------------------------
# PercentageColumn
# ---------------------------------------------------------------------------

"""
    PercentageColumn(digits::Int = 1) -> PercentageColumn

The completion percentage, e.g. "45.2%".  Renders nothing for an indeterminate bar,
where a percentage would be a lie.
"""
struct PercentageColumn <: AbstractColumn
    digits :: Int

    PercentageColumn(digits::Int) = new(max(0, digits))
    PercentageColumn(; digits::Int = 1) = new(max(0, digits))
end

function render_column(col::PercentageColumn, state::BarState)
    fraction = pbfraction(state)
    fraction === nothing && return ""
    value = 100 * fraction
    text = col.digits == 0 ? string(round(Int, value)) : string(round(value, digits = col.digits))
    return string(text, "%")
end

# ---------------------------------------------------------------------------
# RateColumn
# ---------------------------------------------------------------------------

"""
    RateColumn(unit::String = "it/s") -> RateColumn

Throughput in items per second, measured over elapsed *work* time so it freezes
while a bar waits on something else.  Below one item per second the column switches
to seconds per item ("1.5 s/it"), which is what you actually want to see for slow
work.
"""
struct RateColumn <: AbstractColumn
    unit :: String

    RateColumn(unit::AbstractString) = new(String(unit))
    RateColumn(; unit::AbstractString = "it/s") = new(String(unit))
end

function render_column(col::RateColumn, state::BarState)
    return _format_rate(pbrate(state), col.unit)
end

# ---------------------------------------------------------------------------
# ETAColumn
# ---------------------------------------------------------------------------

"""
    ETAColumn() -> ETAColumn

Estimated time remaining as HH:MM:SS, extrapolated from the average rate so far.
Renders nothing until enough progress has been made to extrapolate, and "00:00:00"
once the bar is complete.
"""
struct ETAColumn <: AbstractColumn end

function render_column(::ETAColumn, state::BarState)
    eta = pbeta(state)
    eta === nothing && return ""
    return string("ETA ", _format_hms(eta))
end

# ---------------------------------------------------------------------------
# PostfixColumn
# ---------------------------------------------------------------------------

"""
    PostfixColumn(separator::String = ", ") -> PostfixColumn

The dynamic metrics attached to the bar by set_postfix!, rendered inline on the
right-hand side of the line, e.g. "loss=0.041, accuracy=50.5%".

Unlike a log line these are *state*, not history: they are overwritten each time
set_postfix! is called, so they never clutter the scrollback.
"""
struct PostfixColumn <: AbstractColumn
    separator :: String

    PostfixColumn(separator::AbstractString) = new(String(separator))
    PostfixColumn(; separator::AbstractString = ", ") = new(String(separator))
end

function render_column(col::PostfixColumn, state::BarState)
    text = postfix_text(state; separator = col.separator)
    isempty(text) && return ""
    return string("[", text, "]")
end

# ---------------------------------------------------------------------------
# Default layout
# ---------------------------------------------------------------------------

"""
    default_layout() -> Vector{AbstractColumn}

The layout used when none is given:

    [SpinnerColumn(:dots), TextColumn("{desc}"), BarColumn(),
     PercentageColumn(), RateColumn("it/s"), ETAColumn(), PostfixColumn()]

which renders roughly

    ⠹ Parsing Records ████████████░░░░░░░░░░░░░░░░░░  42.0% 12.3 it/s ETA 00:00:07 [loss=0.041]
"""
function default_layout()
    return AbstractColumn[
        SpinnerColumn(:dots),
        TextColumn("{desc}"),
        BarColumn(),
        PercentageColumn(),
        RateColumn("it/s"),
        ETAColumn(),
        PostfixColumn(),
    ]
end
