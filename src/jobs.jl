# bar rendered as: [blinker] [desc] [progress] [rate] [eta]

"""
    ProgJob([desc=""]; total=nothing, theme=AMBER, spinner=nothing, barunits=nothing, empty=nothing, caps=nothing, head=nothing, width=nothing, dt=0.05, io=stdout)
    ProgJob(iter, [theme=AMBER]; desc="", total=nothing, ...)

A single progress bar. The first form is a standalone job with no iterable; the
second wraps an iterable, inferring `total` from its length when possible, and
behaves transparently as that iterable (`for`, indexing, comprehensions,
`@threads` all work).

# Keyword arguments
- `total`: number of items; `nothing` makes the bar indeterminate (no rate/ETA —
  it reports its elapsed time instead).
- `theme`: the [`Theme`](@ref) used for colors and glyphs.
- `spinner`, `barunits`, `empty`, `caps`, `head`: per-job style overrides of the
  theme's glyphs (strings or `Char` vectors/pairs).
- `width`: per-job bar width override (defaults to the renderer's choice).
- `dt`: minimum seconds between terminal redraws.
- `io`: output stream.

Use [`update!`](@ref) to advance a standalone job's state.
"""
mutable struct ProgJob{I}
    lock        :: ReentrantLock
    desc        :: String
    state       :: Int
    total       :: Union{Int, Nothing}
    start       :: Float64
    finish      :: Float64
    last_update :: Float64
    iter        :: I
    theme       :: Theme
    bar_width   :: Union{Nothing, Int}
    dt          :: Float64
    last_render :: Float64
    io          :: IO

    # Standalone job (no iterator wrapped)
    function ProgJob(desc::String = "";
                     total::Union{Int, Nothing} = nothing,
                     theme::Theme = AMBER,
                     spinner = nothing, barunits = nothing, empty = nothing,
                     caps = nothing, head = nothing,
                     width::Union{Nothing, Int} = nothing,
                     dt::Float64 = 0.05, io::IO = stdout)
        now = time()
        new{Nothing}(ReentrantLock(), desc, 0, total, now, 0.0, now,
                     nothing, _apply_style(theme, spinner, barunits, empty, caps, head), width, dt, 0.0, io)
    end

    # Iterator-wrapping job: ProgJob(iter, [theme]; desc="...", dt=0.05, io=stdout)
    function ProgJob(iter::I, theme::Theme = AMBER;
                     desc::String = "",
                     total::Union{Int, Nothing} = nothing,
                     spinner = nothing, barunits = nothing, empty = nothing,
                     caps = nothing, head = nothing,
                     width::Union{Nothing, Int} = nothing,
                     dt::Float64 = 0.05, io::IO = stdout) where I
        tot = total !== nothing ? total : try length(iter) catch; nothing end
        now = time()
        new{I}(ReentrantLock(), desc, 0, tot, now, 0.0, now,
               iter, _apply_style(theme, spinner, barunits, empty, caps, head), width, dt, 0.0, io)
    end
end

# Compact REPL summary, e.g. `ProgJob("Downloading", 3/10)` or `ProgJob("Watching")`.
function Base.show(io::IO, job::ProgJob)
    desc, state, total = lock(job.lock) do
        (job.desc, job.state, job.total)
    end
    print(io, "ProgJob(", repr(desc), ", ", state)
    total === nothing || print(io, "/", total)
    print(io, ")")
end

function Base.iterate(job::ProgJob)
    job.iter === nothing && throw(ArgumentError("This ProgJob does not wrap an iterable."))
    # Reset progress timing and state
    job.state = 0
    job.start = time()
    job.last_update = job.start
    job.last_render = 0.0

    # Initial draw (0% or starting spinner)
    print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))
    flush(job.io)

    next = iterate(job.iter)
    if next === nothing
        # Empty collection: finish immediately
        print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme), "\n")
        flush(job.io)
        return nothing
    end

    item, iter_state = next
    job.state = 1
    job.last_update = time()
    return (item, iter_state)
end

# Subsequent iteration steps
function Base.iterate(job::ProgJob, iter_state)
    next = iterate(job.iter, iter_state)

    if next === nothing
        # Reached the end: print final 100% frame and a newline
        print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme), "\n")
        flush(job.io)
        return nothing
    end

    item, next_iter_state = next
    job.state += 1
    job.last_update = time()

    # Throttled redraw to maintain high performance in tight loops
    now_sec = time()
    if (now_sec - job.last_render >= job.dt) || (job.total !== nothing && job.state == job.total)
        print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))
        flush(job.io)
        job.last_render = now_sec
    end

    return (item, next_iter_state)
end

# Forward iterator traits so ProgJob behaves transparently like the underlying collection
Base.length(job::ProgJob) = job.total !== nothing ? job.total : length(job.iter)
Base.eltype(::Type{ProgJob{I}}) where I = eltype(I)
Base.size(job::ProgJob{I}) where I = job.total !== nothing ? (job.total,) : size(job.iter)
Base.IteratorSize(::Type{ProgJob{I}}) where I = Base.IteratorSize(I)
Base.IteratorEltype(::Type{ProgJob{I}}) where I = Base.IteratorEltype(I)

# Forward Indexing & Array Bounds Interfaces
Base.firstindex(job::ProgJob) = firstindex(job.iter)
Base.lastindex(job::ProgJob)  = lastindex(job.iter)
Base.eachindex(job::ProgJob)  = eachindex(job.iter)
Base.axes(job::ProgJob)       = axes(job.iter)
Base.keys(job::ProgJob)       = keys(job.iter)

# Thread-safe getindex: updates progress and renders throttled output
function Base.getindex(job::ProgJob, idx...)
    val = getindex(job.iter, idx...)

    @lock job.lock begin
        if job.state == 0
            job.start = time()
            job.last_update = job.start
            job.last_render = 0.0
            # Initial 0% draw
            print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))
            flush(job.io)
        end

        job.state += 1
        job.last_update = time()

        now_sec = time()
        is_final = (job.total !== nothing && job.state == job.total)

        # Render if throttled interval elapsed OR if all items are completed
        if is_final || (now_sec - job.last_render >= job.dt)
            if is_final
                # Print 100% completed bar with final newline
                print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme), "\n")
            else
                print(job.io, "\r\e[K", show_progjob_with_theme(job, job.theme))
            end
            flush(job.io)
            job.last_render = now_sec
        end
    end

    return val
end

function _ansi_fg(c::Color)
    rgb = RGB(c)
    r = round(Int, Colors.red(rgb) * 255)
    g = round(Int, Colors.green(rgb) * 255)
    b = round(Int, Colors.blue(rgb) * 255)
    return "\e[38;2;$(r);$(g);$(b)m"
end

const _ANSI_RESET = "\e[0m"
const _ANSI_DIM   = "\e[2m"
const _ANSI_BOLD  = "\e[1m"

"""Interpolates a color at fractional position t ∈ [0, 1] across the theme palette."""
function _palette_gradient(palette::Vector{Color}, t::Float64)
    isempty(palette) && return ""
    length(palette) == 1 && return _ansi_fg(palette[1])

    # Position along the palette segments
    scaled = clamp(t, 0.0, 1.0) * (length(palette) - 1)
    idx = floor(Int, scaled) + 1
    frac = scaled - floor(scaled)

    if idx >= length(palette)
        return _ansi_fg(palette[end])
    end

    # Linear interpolation between adjacent palette colors in RGB
    c1, c2 = RGB(palette[idx]), RGB(palette[idx + 1])
    interp_c = RGB(
        red(c1)   + frac * (red(c2)   - red(c1)),
        green(c1) + frac * (green(c2) - green(c1)),
        blue(c1)  + frac * (blue(c2)  - blue(c1))
    )
    return _ansi_fg(interp_c)
end

"""
    _render_bar(prog::Float64, t::Theme; width::Int = 40) -> String

Renders a high-resolution progress bar using fractional `barunits` stipple levels,
optionally framed by the theme's `caps` and tipped with its `head` glyph (shown at
the leading edge of an in-progress bar).
"""
function _render_bar(prog::Float64, t::Theme; width::Int = 40)
    p = clamp(prog, 0.0, 1.0)
    k = length(t.barunits)

    # Sub-character stipple resolution
    total_subunits = round(Int, p * width * k)
    full_chars = div(total_subunits, k)
    rem_subunits = rem(total_subunits, k)

    fg_color = isempty(t.palette) ? "" : _palette_gradient(t.palette, prog)
    dim_color = isempty(t.palette) ? _ANSI_DIM : _ansi_fg(t.palette[begin])

    # Filled portion; a `head` glyph replaces the tip of an in-progress bar
    head = t.head
    if head === nothing || p >= 1.0 || (full_chars == 0 && rem_subunits == 0)
        bar_full = repeat(string(t.barunits[end]), full_chars)
        bar_partial = rem_subunits > 0 ? string(t.barunits[rem_subunits]) : ""
        filled = string(bar_full, bar_partial)
    elseif rem_subunits > 0
        filled = string(repeat(string(t.barunits[end]), full_chars), head)
    else
        filled = string(repeat(string(t.barunits[end]), max(0, full_chars - 1)), head)
    end

    # Empty portion
    empty_count = width - full_chars - (rem_subunits > 0 ? 1 : 0)
    bar_empty = repeat(string(t.empty), max(0, empty_count))

    left, right = t.caps
    return string(dim_color, left, fg_color, filled, dim_color, bar_empty, right, _ANSI_RESET)
end

"""
    show_progjob_with_theme(p::ProgJob, t::Theme; bar_width::Int = 40, desc_width::Int = 14, rate_width::Int = 10) -> String

Renders the progress job line according to the format:
    `[blinker] [desc] [progress] [rate] [eta]`

`desc` is padded (right-aligned within `desc_width` columns) and the rate field is
padded (within `rate_width` columns) so that the bar, rate, and ETA columns line up
vertically across rows. A per-job `bar_width` override (from `@progress width=...`)
takes precedence over the passed `bar_width`.
"""
function show_progjob_with_theme(p::ProgJob, t::Theme; bar_width::Int = 40, desc_width::Int = 14, rate_width::Int = 10)
    # Thread-safe snapshot of job state
    desc, state, total, start_time, finish_time, last_update, job_width = lock(p.lock) do
        (p.desc, p.state, p.total, p.start, p.finish, p.last_update, p.bar_width)
    end
    bar_width = job_width !== nothing ? job_width : bar_width

    now_sec = time()
    # Rate/ETA are measured up to the job's last update (or completion), so they
    # freeze while the job is idle (e.g. waiting on a nested process).
    work_until = finish_time ≈ 0.0 ? last_update : finish_time
    work_elapsed = max(0.0, work_until - start_time)
    # Displayed elapsed: the current run time for active jobs, frozen at completion.
    run_elapsed = finish_time ≈ 0.0 ? max(0.0, now_sec - start_time) : max(0.0, finish_time - start_time)

    rate = work_elapsed > 0 ? (state / work_elapsed) : 0.0
    rate_str = if rate >= 1_000_000
        string(round(rate / 1_000_000, digits=1), "M it/s")
    elseif rate >= 1_000
        string(round(rate / 1_000, digits=1), "k it/s")
    elseif rate >= 1.0
        string(round(rate, digits=1), " it/s")
    else
        string(round(1.0 / max(rate, 1e-6), digits=1), " s/it")
    end

    # 1. [Blinker / Spinner] - Cycles through spinner glyphs and palette colors
    spinner_char = isempty(t.spinner) ? '◉' : t.spinner[mod(floor(Int, now_sec * 8), length(t.spinner)) + 1]
    spinner_color = isempty(t.palette) ? "" : _ansi_fg(t.palette[mod(floor(Int, now_sec * 4), length(t.palette)) + 1])
    blinker_str = string(spinner_color, spinner_char, _ANSI_RESET)

    # 2. [Desc] - fixed-width so the bar column lines up across rows
    desc_str = string(_ANSI_BOLD, rpad(desc, desc_width), _ANSI_RESET, " ")

    # 3. [Progress] & 4. [ETA]
    if total === nothing
        # Indeterminate mode (no total known): no rate and no ETA; report elapsed.
        # An indeterminate job represents a single unit of work (milestones never
        # advance their own state), so a fresh job reads "1 unit".
        shown = max(state, 1)
        prog_str = string(_ANSI_DIM, "$shown unit", shown == 1 ? "" : "s", _ANSI_RESET)
        if finish_time ≈ 0.0
            eta_str = string(_ANSI_DIM, "(elapsed: ", duration_str(run_elapsed, show_ms=true), ")", _ANSI_RESET)
        else
            eta_str = string(_ANSI_DIM, "done in ", duration_str(run_elapsed, show_ms=true), _ANSI_RESET)
        end
        return "$blinker_str $desc_str$prog_str $eta_str"
    else
        # Determinate mode
        prog = total > 0 ? (state / total) : 1.0
        pct = round(Int, prog * 100)
        bar = _render_bar(prog, t; width = bar_width)
        # Pad the state to the total's width so "(x/y)" lines up when totals agree
        prog_str = "$bar $(lpad(pct, 3))% ($(lpad(state, ndigits(total)))/$total)"

        if prog >= 1.0
            finish_time ≈ 0 && @lock p.lock begin
                finish_time = time()
                p.finish = finish_time
            end
            run_elapsed = max(0.0, finish_time - start_time)
            eta_str = string(_ANSI_DIM, "done in ", duration_str(finish_time - start_time, show_ms = true), _ANSI_RESET)
        elseif prog > 0.0
            eta_sec = (1.0 - prog) * (work_elapsed / prog)
            eta_str = string(_ANSI_DIM, "ETA: ", duration_str(eta_sec, show_ms = true), _ANSI_RESET)
        else
            eta_str = string(_ANSI_DIM, "ETA: N/A", _ANSI_RESET)
        end
    end

    # Return full rendered line: [blinker] [desc] [progress] [rate] [eta]
    return "$blinker_str $desc_str$prog_str [$(rpad(rate_str, rate_width))] $eta_str"
end

# Advances a job's state under its lock, stamps `last_update`, and reports whether
# the job has now reached its total. Shared by the standalone and tree update!s.
function _advance!(job::ProgJob, new::Union{Int, Nothing} = nothing)
    @lock job.lock begin
        if isnothing(new)
            job.state += 1
        else
            job.state = new
        end
        job.last_update = time()
        job.total !== nothing && job.state >= job.total
    end
end

function update!(job::ProgJob, new::Union{Int, Nothing} = nothing)
    _advance!(job, new)
    return nothing
end

"""
    with_job(f::Function, iter, pbar::Union{ProgJob, Theme} = AMBER; desc = "", dt = 0.05, io = stdout)

Iterates over `iter`, executing `f(item)` on each element while rendering an animated progress bar.
Returns the collected results of `f(item)` for each element.

# Arguments
- `f::Function`: Callback function executed for each item.
- `iter`: Any iterable collection or generator.
- `pbar`: Either an existing `ProgJob` or a `Theme` (defaults to `AMBER`).
- `desc::String`: Description label for the job.
- `dt::Float64`: Minimum time interval (in seconds) between terminal redraws to prevent I/O bottlenecks.
- `io::IO`: Output stream (defaults to `stdout`).
"""
function with_job(
    f::Function,
    iter,
    pbar::Union{ProgJob, Theme} = AMBER;
    desc::String = "",
    theme::Theme = (pbar isa Theme ? pbar : AMBER),
    dt::Float64 = 0.05,
    io::IO = stdout
)
    # 1. Infer total length if available
    total = try
        length(iter)
    catch
        nothing
    end

    # 2. Initialize or configure the ProgJob
    job = if pbar isa ProgJob
        @lock pbar.lock begin
            if isnothing(pbar.total) && !isnothing(total)
                pbar.total = total
            end
            if !isempty(desc) && isempty(pbar.desc)
                pbar.desc = desc
            end
        end
        pbar
    else
        j = ProgJob(desc)
        j.total = total
        j
    end

    # 3. Pre-allocate results if size is known
    results = total !== nothing ? Vector{Any}(undef, total) : Any[]
    last_render = 0.0

    # Initial draw
    print(io, "\r\e[K", show_progjob_with_theme(job, theme))
    flush(io)

    try
        for (i, item) in enumerate(iter)
            # Execute user payload
            res = f(item)
            if total !== nothing
                results[i] = res
            else
                push!(results, res)
            end

            # Update job state
            update!(job, i)

            # Throttled render (and always render on the final iteration)
            now_sec = time()
            if (now_sec - last_render >= dt) || (total !== nothing && i == total)
                print(io, "\r\e[K", show_progjob_with_theme(job, theme))
                flush(io)
                last_render = now_sec
            end
        end
    finally
        # Final render to ensure 100% status is displayed, followed by a newline
        print(io, "\r\e[K", show_progjob_with_theme(job, theme), "\n")
        flush(io)
    end

    return results
end
