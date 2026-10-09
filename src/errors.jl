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

"""
    ErrorInfo(type, msg)

What a failed bar remembers about the exception that took it down: the exception's type
and the message `showerror` would have printed. Only the type is drawn, as
`ERROR: <Type>` in the time column; `msg` is there for callers reading `pberror`.
"""
struct ErrorInfo
    type :: DataType
    msg  :: String
end

Base.show(io::IO, info::ErrorInfo) = print(io, "ErrorInfo(", info.type, ")")
