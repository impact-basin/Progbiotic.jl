# Hex colour literals, and the one conversion this package needs.

"""
    rgb"#FF6400" -> RGB{N0f8}

A hex colour literal, used by the theme table. Equivalent to Colors.jl's
`colorant"…"`, which is the only thing this package ever needed that package for.

The macro parses the digits at expansion time, so a typo is a compile error rather
than a wrong colour at run time.
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

The 24-bit foreground escape for a colour. This is the whole of the package's
colour handling: a palette is only ever turned into one of these.
"""
function ansi_fg(c::Colorant)
    rgb = RGB{Float64}(c)
    r = round(Int, red(rgb)   * 255)
    g = round(Int, green(rgb) * 255)
    b = round(Int, blue(rgb)  * 255)
    return string("\e[38;2;", r, ";", g, ";", b, "m")
end
