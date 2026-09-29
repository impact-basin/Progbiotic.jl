# Progbiotic.jl: neat progress bars.

This package implements thread-safe progress bars. These bars can be nested into a tree structure. There are TQDM and macro interfaces.

Here's a quick example:

```julia
@progress "doing something" for i=1:10
    @progress "doing something else; i=$i" for j=1:10
        sleep(0.05)
    end
    @progress "doing something 2; i=$i" for j=1:10
        sleep(0.05)
    end
end
```

That looks like this:

<img width="2392" height="325" alt="image" src="https://github.com/user-attachments/assets/eb22dd24-8704-4246-9271-79bf2d7194cc" />


## Usage (a la TQDM)

```julia
# tqdm-like!
for i in prog(1:100; desc = "Ordinary")
    sleep(0.1)
end

# thread-safe!
@threads for i in prog(1:100; desc = "Multithreaded")
    sleep(0.1)
end

# themeable! a theme is a way of building a layout, and a layout is what you pass
files = ["data1.csv", "data2.csv", "data3.csv", "data4.csv"]
for file in prog(files; layout = theme_layout(OCEAN), desc = "Parsing files")
    sleep(0.3)
end

# works with comprehensions!
[x^2 for x in prog(1:9001; layout = theme_layout(GLACIER), desc = "Squaring")];

# comprehensions over matrices!
[x^2 for x in prog(rand(32,32); layout = theme_layout(GLACIER), desc = "Squaring matrix elements!")]
```

## Iterator interface (no macro required)

`prog` wraps any iterable and infers its length, so an ordinary loop becomes a
progress bar with no boilerplate:

```julia
for record in prog(1:1000; desc = "Parsing Records", vanish = 2.0)
    # ...
end
```

Collections with a known length (`HasLength` or `HasShape`) get a determinate bar
with a percentage, a rate and an ETA. Unbounded or size-unknown sources - a
`Channel`, an `Iterators.filter` - get an indeterminate spinner instead of a
percentage that would be a lie:

```julia
stream = Channel(ch -> foreach(i -> put!(ch, i), 1:500))

for item in prog(stream; desc = "Streaming Input")
    # the spinner rotates until the channel closes
end
```

`prog` forwards the collection's shape traits, so comprehensions, `collect`,
indexing and `Threads.@threads` behave exactly as they do on the collection itself:

```julia
squares = [x^2 for x in prog(1:9001; desc = "Squaring")]

Threads.@threads for i in prog(1:10_000; desc = "Parallel")
    # ...
end
```

Pass `total=n` to override the inference, or `total=nothing` to force spinner mode
on a collection that does have a length. There is also a do-block form, which finishes
the bar when the block returns:

```julia
prog(1:100; desc = "Training") do x
    # ...
end
```

## Manual handles

When the work is not a simple loop over a collection, drive the bar yourself:

```julia
p = Progress(100; desc = "Custom Pipeline", layout = my_layout)
for i in 1:100
    next!(p)              # advance by one
end
finish!(p)

update!(p, 42)            # or set an absolute value
```

`next!` is a single lock-free atomic add, so a handle can be advanced from any
number of threads with no lock contention and no lost updates:

```julia
p = Progress(10_000; desc = "Parallel Processing")

Threads.@threads for i in 1:10_000
    next!(p)
end

finish!(p)
```

The do-block form finishes the bar for you, even if the body throws:

```julia
Progress(100; desc = "Training") do p
    for i in 1:100
        next!(p)
    end
end
```

## Dynamic status with `set_postfix!`

`set_postfix!` attaches live key/value metrics to the active bar. They are
overwritten on every call, so they are *state* rather than history and never clutter
the scrollback:

```julia
@progress "Model Training" total=100 vanish=3.0 for epoch in 1:100
    loss = 1.0 / epoch
    acc = 0.5 + (epoch / 200)

    set_postfix!(loss = round(loss, digits = 4), accuracy = "$(round(acc*100, digits=1))%")
end
```

With no argument the metrics go to the innermost active bar: inside a `@progress`
scope, the job of the innermost level; inside a `prog(...)` or `Progress(...)`
scope, that bar. Pass a bar explicitly (`set_postfix!(p; ...)`) to target a
particular one. A bare `set_postfix!()` outside any scope raises, since there
would be no bar for the metrics to land on.

## Column layouts

A bar is a *layout*: a tuple of columns rendered left-to-right and joined with
single spaces. The default is the AMBER theme's, and a theme is just a way of
building one -- `theme_layout(t)` -- so styling is fixed when the bar is built
rather than consulted at render time:

```julia
my_layout = (
    Spinner(:dots),
    Tag("{desc}"),
    Bar(; fill = '#', empty = '-', width = 30),
    Percent(),
    Count(),
    Rate(unit = "it/s"),
    Eta(),
    Postfix(),
)

p = Progress(100; layout = my_layout, desc = "Custom Pipeline", vanish = 1.0)
for i in 1:100
    sleep(0.01)
    next!(p)
end
finish!(p)
```

| Column | Renders |
|--------|---------|
| `Spinner(style)` | an animated glyph; styles include :dots, :line, :arc, :clock, :moon |
| `Tag(template)` | `{desc}`, `{n}`, `{total}`, `{pct}`, `{elapsed}`, `{postfix}`; takes a `width` to pad to and `bold` |
| `Bar(; fill, empty, width)` | the bar, or a bouncing marquee when the total is unknown |
| `Bar(units, empty, palette, caps, head)` | the themed bar: stipple glyphs, a palette interpolated along the fill, a tip glyph |
| `Percent(digits; pad)` | `45.2%`; the theme uses `digits = 0, pad = 3` for ` 45%` |
| `Count()` | `(42/100)`, the count padded to the total's width; `1 unit` when there is no total |
| `Rate(unit; pad)` | `[12.3 it/s]`, or `[1.5 s/it]` below one item per second; empty at a rate of zero |
| `Eta()` | `ETA: 1.23s` running, `done in 2.51s` finished, `(elapsed: 4.10s)` indeterminate |
| `Postfix()` | the metrics set by `set_postfix!` |

The label column is `Tag`, not `Text`: Base already owns that name.

Adding your own is two lines:

```julia
using Progbiotic: AbstractColumn, render_column, BarState, pbdone, pbtotal

struct HeartbeatColumn <: AbstractColumn end

render_column(::HeartbeatColumn, s::BarState) =
    pbtotal(s) === nothing ? "?" : string(round(Int, 100 * pbdone(s) / pbtotal(s)), "%")
```

It is a pure function of the bar's state: no I/O, no locks, no blocking. An
unstyled column emits no escape sequences at all, so a bar is plain text unless a
palette gives it colour.

## Terminal vs. CI

The engine detects whether its output stream is an interactive terminal (and whether
`CI` is set). On a terminal the bar tree lives in a gutter: the engine reserves the
bottom rows of the screen outside the terminal's scroll region and parks the cursor
inside that region, so a `println` from your own loop scrolls *above* the bar rather
than clobbering it. When the tree grows, the engine scrolls to make room rather than
clearing, so the output already on screen is pushed up intact; when it shrinks or
finishes, the rows go back. Anywhere else - a pipe, a redirected file, a CI build -
it emits flat, append-only lines and *not a single escape sequence*:

```text
Parsing Records 0% (0/1000) ETA: N/A
Parsing Records 25% (250/1000) [412.5 it/s] ETA: 730.3ms
Parsing Records 100% (1000/1000) [398.1 it/s] done in 2.51s
```

One line is emitted per `flat_step` percent (default 10), so a ten-million-iteration
loop adds eleven lines to a build log rather than thousands. Force either mode with
`tty=true` / `tty=false`, and use `io=` to send a bar anywhere.

## Threads and overhead

The computational loop never touches the terminal. Advancing a bar is a single
lock-free `Threads.Atomic` add, and drawing happens on a separate task that wakes at
most `fps` times a second (default 20). Every terminal write takes one short lock,
from a single renderer.

That means a `Threads.@threads` loop can advance one bar from every worker with no
lock contention and no lost updates, and a fine-grained loop over `10^7` items pays
for a handful of atomic adds per item and nothing else.

By default the renderer is an async task, which runs exactly when the loop yields -
that is, when terminal I/O is free - and costs nothing at all while a tight loop is
running. Pass `threaded=true` to render from a separate thread instead, which keeps
the bar animating during a long computation that never yields.

```julia
p = Progress(10^7; desc = "Long computation", threaded = true)
```

## Macro interface

The `@progress` macro is exported to wrap for loops. This macro manipulates the AST to place `@progress` invocations within that loop into the context of the outer progress tree.

```julia
@progress "Downloading weights" for i in 1:100
    sleep(0.01)
end

# Outer loop is the root of the tree (rendered flush at column 0)
@progress "Data Ingestion Pipeline" for phase in 1:2
    @progress "Reading files" for file in 1:5
        sleep(0.02)
    end
end

# Provides an explicit header title for the whole tree
@progress title="Model Training Pipeline"  "Epochs" for epoch in 1:3
    @progress "Epoch $epoch Batches" for batch in 1:20
        sleep(0.01)
    end
end

# Group phases with a plain begin/end block
@progress "Ingest" begin
    @progress "Reading" for file in 1:5
        sleep(0.01)
    end
    @progress "Cleaning" for chunk in 1:3
        sleep(0.01)
    end
end

# Sequential subtasks progress.
@progress "foo" d=1 begin
    @progress "job 1"
    sleep(0.5)
    @progress "job 2"
    sleep(0.5)
    @progress "job 3"
    sleep(0.5)
end

# Passing a progress context to subroutines.
function subtask(ctx, n)
    @progress with=ctx "working..." for k in 1:n
        sleep(0.01)
    end
end

@progress ctx "outer..." for i in 1:10
    @progress "inner" for j in 1:10
        subtask(ctx, i)          # ctx already points at "inner" here
    end
end

# Keep 1 level of children in the final (collapsed) render
@progress "Training" final_depth=1 for epoch in 1:10
    @progress "Batch $epoch" for b in 1:100
        sleep(0.001)
    end
end

# Supports multithreading! (wrap the loop with Threads.@threads)
@progress "Loop 1" Base.Threads.@threads for i = 1:3
    @progress "Loop 2, i=$i" for j = 1:5
        @progress "Micro-batch" for k = 1:10
            sleep(0.05)
        end
    end
end
```

## Short form options

The `@progress` keyword options accept short aliases:

| Short form   | Full form        | Meaning                                        |
|--------------|------------------|------------------------------------------------|
| `d=1`        | `final_depth=1`  | keep 1 level of children in the final render   |
| `v=1.2`      | `vanish_timeout=1.2` | finished bars linger 1.2s                  |
| `v=false`    | `vanish=false`   | keep bars on screen (never vanish)             |
| `t=OCEAN`    | `theme=OCEAN`    | use the OCEAN theme                            |

`v` can be set to a number or a boolean. A number sets the vanish timeout in seconds and a boolean
switches vanishing on/off. The full names work as well: `vanish_timeout=2.0` (or
`vanish=2.0`) sets the timeout, and `vanish=false` keeps bars on screen.

An example usage:

```julia
@progress "Foo" d=1 v=0.8 for foo in 1:10
    @progress "Bar $foo" for bar in 1:100
        sleep(0.001)
    end
end
```

# Notes

- Completed bars vanish from the tree shortly after finishing by default.
  Pass `vanish=false` to keep every bar on screen or `vanish_timeout=<seconds>` to tune.
  These options are inherited by nested `@progress` levels. `v=` is a shorthand for both.
- Once the tree completes, the bar collapses to the top-level state.
  `final_depth=N` keeps `N` levels of children in the final render (0 = summary
  only, 1 = also its direct children, ...). Children within the retained depth are
  kept on screen past their vanish timeouts.
- Bare `@progress "desc"` statements are "milestones", which report elapsed time.
  A `@progress begin ... end` block with milestones has a total equal to the number
  of milestones, and its progress advances as each milestone completes.
- `@progress ctx "desc"` binds `ctx` to the new bar, which is a node in the tree.
  It can be passed to helper functions, which can register their own progress:
  `@progress "desc" with=ctx for ...`.

# AI use.

There were a few aspects of the progress bar libraries in the ecosystem that I wanted to address.
There was no thread-safe, multi-job option. Being able to pass progress bar context around also
ranked highly on my scratch-an-itch list. Unfortunately, as much as I would have liked to write this
all myself, I did not have time to. So, I leaned on AI for this.

There are a few down-the-line packages from me which will depend on this, which don't use AI - hence the registration in General.

However, I _am_ committed to maintaining this (as I'm using this myself) - if you find this library useful, but find issues, please do raise them, and I'll get to them as quickly as I can.
