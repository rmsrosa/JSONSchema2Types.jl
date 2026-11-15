# ---------------------------------------------------------------------------------------
# Runtime support for typed formats (`typed_formats = true`): strings with the formats
# `date`, `date-time` and `uuid` are stored as `Dates.Date`, `Dates.DateTime` and
# `UUIDs.UUID`. Copied into the generated modules that use them.
# ---------------------------------------------------------------------------------------

import Dates
import UUIDs

function _jsfrom(::Type{Dates.Date}, x)
    x isa Dates.Date && return x
    x isa AbstractString || _jsfail("expected a date string, got $(repr(x))")
    m = match(r"^(\d{4})-(\d{2})-(\d{2})$", x)
    d = m === nothing ? nothing : tryparse(Dates.Date, x, Dates.dateformat"yyyy-mm-dd")
    d === nothing && _jsfail("$(repr(x)) is not a valid date (YYYY-MM-DD)")
    return d
end

# RFC 3339 date-times are converted to UTC, with millisecond precision
function _jsfrom(::Type{Dates.DateTime}, x)
    x isa Dates.DateTime && return x
    x isa AbstractString || _jsfail("expected a date-time string, got $(repr(x))")
    m = match(r"^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(\.\d+)?([Zz]|([+-])(\d{2}):(\d{2}))$", x)
    m === nothing && _jsfail("$(repr(x)) is not a valid date-time (RFC 3339)")
    t = tryparse(Dates.DateTime, m[1] * "T" * m[2], Dates.dateformat"yyyy-mm-ddTHH:MM:SS")
    t === nothing && _jsfail("$(repr(x)) is not a valid date-time (RFC 3339)")
    m[3] === nothing || (t += Dates.Millisecond(round(Int, parse(Float64, "0" * m[3]) * 1000)))
    if m[5] !== nothing
        offset = Dates.Hour(parse(Int, m[6])) + Dates.Minute(parse(Int, m[7]))
        t = m[5] == "+" ? t - offset : t + offset
    end
    return t
end

function _jsfrom(::Type{UUIDs.UUID}, x)
    x isa UUIDs.UUID && return x
    x isa AbstractString || _jsfail("expected a UUID string, got $(repr(x))")
    u = tryparse(UUIDs.UUID, x)
    u === nothing && _jsfail("$(repr(x)) is not a valid UUID")
    return u
end

_jsto(x::Dates.Date) = Dates.format(x, Dates.dateformat"yyyy-mm-dd")
_jsto(x::Dates.DateTime) = Dates.format(x, Dates.millisecond(x) == 0 ?
    Dates.dateformat"yyyy-mm-ddTHH:MM:SS" : Dates.dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
_jsto(x::UUIDs.UUID) = string(x)

# string constraints (`pattern`, `minLength`...) apply to the string form
_jsscalar(x::Union{Dates.Date, Dates.DateTime, UUIDs.UUID}) = _jsto(x)
