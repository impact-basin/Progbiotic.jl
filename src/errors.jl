"""
    ProgbioticError(msg)

Every error this package raises. `showerror` prefixes the message, so the type is
the only thing callers need to catch.
"""
struct ProgbioticError <: Exception
    msg :: String
end

ProgbioticError(parts...) = ProgbioticError(string(parts...))

Base.showerror(io::IO, err::ProgbioticError) = print(io, "ProgbioticError: ", err.msg)
