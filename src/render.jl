# Rendering of intercepted log lines underneath their progress bars.

# The colour map, the level names and the line formatters live in src/engine.jl,
# which is included before this file.
"""The most log lines drawn under a single bar."""
const MAX_RENDERED_LOGS = 8

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
