# Hex colour literals, and the only two things this package does with colour:
# turning one into an escape, and interpolating along a palette.

"""Terminal attributes the renderer uses."""
const _ANSI_RESET = "\e[0m"
const _ANSI_DIM   = "\e[2m"
const _ANSI_BOLD  = "\e[1m"

"""
    rgb"#FF6400" -> RGB{N0f8}

A hex colour literal, used by the theme table. Equivalent to Colors.jl's
`colorant"…"`, which is the only thing this package ever needed that package for.

The digits are parsed at expansion time, so a typo is a compile error rather than a
wrong colour at run time.
"""
macro rgb_str(hex)
    digits = replace(hex, "#" => "")
    length(digits) == 6 ||
        throw(ProgbioticError("rgb\"…\" expects six hex digits; got ", repr(hex)))
    channels = ntuple(i -> parse(UInt8, digits[2i - 1:2i]; base = 16), 3)
    # a hex literal is a byte encoding, which is exactly what reinterpret undoes
    return :(RGB{N0f8}($([:(reinterpret(N0f8, $c)) for c in channels]...)))
end

"""
    ansi_fg(c::Colorant) -> String

The 24-bit foreground escape for a colour.
"""
function ansi_fg(c::Colorant)
    rgb = RGB{Float64}(c)
    r = round(Int, red(rgb)   * 255)
    g = round(Int, green(rgb) * 255)
    b = round(Int, blue(rgb)  * 255)
    return string("\e[38;2;", r, ";", g, ";", b, "m")
end

"""
    palette_gradient(palette, t) -> String

The escape for the colour at fractional position `t` along a palette, linearly
interpolated between adjacent entries. An empty palette yields no escape, so an
unstyled bar renders identically to one drawn before colour existed.
"""
function palette_gradient(palette::AbstractVector{<:Colorant}, t::Float64)
    isempty(palette) && return ""
    length(palette) == 1 && return ansi_fg(palette[1])

    scaled = clamp(t, 0.0, 1.0) * (length(palette) - 1)
    index = floor(Int, scaled) + 1
    index >= length(palette) && return ansi_fg(palette[end])

    frac = scaled - floor(scaled)
    lo, hi = RGB{Float64}(palette[index]), RGB{Float64}(palette[index + 1])
    return ansi_fg(RGB(red(lo)   + frac * (red(hi)   - red(lo)),
                       green(lo) + frac * (green(hi) - green(lo)),
                       blue(lo)  + frac * (blue(hi)  - blue(lo))))
end
