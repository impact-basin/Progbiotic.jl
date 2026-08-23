"""
    duration_str(seconds; compact=true, show_ms=false) -> String

Formats a duration in seconds as a human-readable string, e.g. `duration_str(95)`
gives `"1m 35 s"` (or `"1 minute, 35 seconds"` with `compact=false`). With
`show_ms=true`, sub-second and sub-hour durations include milliseconds; `Inf` and
`NaN` render as `"∞"` and `"N/A"`.
"""
function duration_str(seconds::Number; compact::Bool = true, show_ms::Bool = false)
    if isnan(seconds)
        return "N/A"
    elseif isinf(seconds)
        return seconds > 0 ? "∞" : "-∞"
    end
    # No branch for negative seconds: durations are never negative (callers
    # clamp elapsed/ETA values to >= 0 before formatting).
    # Handle sub-second intervals if requested
    if show_ms && seconds < 1.0
        if seconds < 1e-3
            val = round(seconds * 1e6, digits = 1)
            return string(val, compact ? "µs" : " microsecond" * (val == 1 ? "" : "s"))
        else
            val = round(seconds * 1e3, digits = 1)
            return string(val, compact ? "ms" : " millisecond" * (val == 1 ? "" : "s"))
        end
    end

    total_secs = floor(Int, seconds)
    ms = round(Int, (seconds - total_secs) * 1000)

    days, rem_secs = divrem(total_secs, 86400)
    hours, rem_secs = divrem(rem_secs, 3600)
    mins, secs = divrem(rem_secs, 60)

    parts = String[]

    if days > 0
        push!(parts, compact ? "$(days)d" :
            "$(days) day" * (days == 1 ? "" : "s"))
    end
    if hours > 0 || days > 0
        push!(parts, compact ? "$(hours)h" : "$(hours) hour" * (hours == 1 ? "" : "s"))
    end
    if mins > 0 || hours > 0 || days > 0
        push!(parts, compact ? "$(mins)m" : "$(mins) minute" * (mins == 1 ? "" : "s"))
    end

    # Include milliseconds if under an hour and show_ms is true
    if show_ms && ms > 0 && days == 0 && hours == 0
        sec_val = secs + ms / 1000.0
        push!(parts, compact ? "$(round(sec_val,digits = 2))s" : "$(round(sec_val, digits=2)) seconds")
    else
        push!(parts, compact ? "$(secs) s" : "$(secs) second" * (secs == 1 ? "" : "s"))
    end

    return compact ? join(parts, " ") : join(parts, ", ")
end
