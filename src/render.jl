# Rendering of intercepted log lines underneath their progress bars.

# The colour map, the level names and the line formatters live in src/engine.jl,
# which is included before this file.
"""The most log lines drawn under a single bar."""
const MAX_RENDERED_LOGS = 8


"""
    format_plain_log_line(entry::ProgressLogEntry) -> String

The same record as one plain, ANSI-free line, for the non-interactive flat
renderer and for a log_file sink.
"""
format_plain_log_line(entry::ProgressLogEntry) =
    string("[", _log_level_name(entry.level), "] ", entry.message)

"""
    format_log_line(entry::ProgressLogEntry) -> String

Formats one intercepted record as a colour-coded line: cyan for `@info`, yellow for
`@warn`, blue for `@debug` and red for `@error`.
"""
function format_log_line(entry::ProgressLogEntry)
    return string(_log_color(entry.level), "▏", uppercase(string(entry.level)), " ",
                  entry.message, _ANSI_RESET)
end

"""
    _render_job_logs(io, pbar, job, prefix, syms, now_sec) -> Int

Draws the non-expired log lines buffered for `job` directly beneath its bar, using
`prefix` (the job's tree gutter) as indentation, and returns the number of lines
written. Expired entries are pruned on the way, so the renderer's height
calculation only ever counts the lines that are actually drawn.
"""
function _render_job_logs(io::IO, pbar::ProgBar, job::ProgJob, prefix::AbstractString,
                          syms::Dict{Symbol, String}, now_sec::Float64)
    entries = active_logs(pbar, job, now_sec)
    isempty(entries) && return 0
    if length(entries) > MAX_RENDERED_LOGS
        entries = entries[(end - MAX_RENDERED_LOGS + 1):end]
    end
    gutter = get(syms, :line, "│  ")
    for entry in entries
        println(io, prefix, gutter, format_log_line(entry))
    end
    return length(entries)
end
