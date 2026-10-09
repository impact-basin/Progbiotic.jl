# Progbiotic.jl: neat progress bars.

This package implements thread-safe progress bars. These bars can be nested into a tree structure. There are TQDM and macro interfaces.

A quick example:

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

# Provide an explicit header title for the whole tree
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
        subtask(ctx, i)          # ctx points at "inner"
    end
end

# Keep 1 level of children in the collapsed render
@progress "Training" final_depth=1 for epoch in 1:10
    @progress "Batch $epoch" for b in 1:100
        sleep(0.001)
    end
end

# Supports multithreading!
@progress "Loop 1" Base.Threads.@threads for i = 1:3
    @progress "Loop 2, i=$i" for j = 1:5
        @progress "Micro-batch" for k = 1:10
            sleep(0.05)
        end
    end
end
```

## Short form options

The `@progress` keyword options accept short aliases. This is so my fingers don't get tired :-).

| Short form   | Full form        | Meaning                                        |
|--------------|------------------|------------------------------------------------|
| `d=1`        | `final_depth=1`  | keep 1 level of children in the final render   |
| `v=1.2`      | `vanish_timeout=1.2` | finished bars linger 1.2s                  |
| `v=false`    | `vanish=false`   | keep bars on screen (never vanish)             |
| `ev=0.5`     | `error_vanish=0.5` | errored bars linger 0.5s                    |
| `ev=true`    | `error_vanish=true` | errored bars use the node's own vanish      |
| `t=OCEAN`    | `theme=OCEAN`    | use the OCEAN theme                            |

`v` can be set to a number or a boolean. A number sets the vanish timeout in seconds and a boolean
switches vanishing on/off.

`ev` is the same for errored bars, which stay on screen by default: `ev=true` lets one
vanish with its node's own timeout, and `ev=<seconds>` gives it a timeout of its own.

## Usage (a la TQDM)

```julia
# tqdm-like
for i in prog(1:100; desc = "Ordinary")
    sleep(0.1)
end

# thread-safe
@threads for i in prog(1:100; desc = "Multithreaded")
    sleep(0.1)
end

# works with comprehensions
[x^2 for x in prog(1:9001; layout = theme_layout(GLACIER), desc = "Squaring")];

# comprehensions over matrices
[x^2 for x in prog(rand(32,32); layout = theme_layout(GLACIER), desc = "Squaring matrix elements!")]
```

## Iterator interface

`prog` wraps iterables infers length:

```julia
for record in prog(1:1000; desc = "Parsing Records", vanish = 2.0)
    # ...
end
```

Collections with a known length (`HasLength` or `HasShape`) get a determinate bar
with a percentage, a rate and an ETA. Unbounded or size-unknown sources - e.g.
`Channel` or `Iterators.filter` - get an indeterminate spinner instead:

```julia
stream = Channel(ch -> foreach(i -> put!(ch, i), 1:500))

for item in prog(stream; desc = "Streaming Input")
    # spinner rotates until the channel closes
end
```

`prog` forwards shape traits, so comprehensions, `collect`,
indexing and `Threads.@threads` behave as they do on the collection itself:

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

You can drive the bar yourself:

```julia
p = Progress(100; desc = "Custom Pipeline", layout = my_layout)
for i in 1:100
    next!(p)              # advance by one
end
finish!(p)

update!(p, 42)            # or set an absolute value
```

`next!` is thread safe:

```julia
p = Progress(10_000; desc = "Parallel Processing")

Threads.@threads for i in 1:10_000
    next!(p)
end

finish!(p)
```

The do-block form finishes the bar for you, and if the body throws it registers the error:

```julia
Progress(100; desc = "Training") do p
    for i in 1:100
        next!(p)
    end
end
```

## Setting postfixes 

`set_postfix!` attaches key/value pairs to the active bar. They are
overwritten on every call.

```julia
@progress "Model Training" total=100 vanish=3.0 for epoch in 1:100
    loss = 1.0 / epoch
    acc = 0.5 + (epoch / 200)

    set_postfix!(loss = round(loss, digits = 4), accuracy = "$(round(acc*100, digits=1))%")
end
```

## Errors

A bar whose body throws does not read as complete: its counter stops where work stopped,
and the error is shown.

```julia
@progress "Working" for k in 1:100
    k == 25 && error("catastrophic failure")
end
```

This draws the whole live tree one last time rather than collapsing to
the root, so the failing node's position is visible.

# AI use.

There were a few aspects of the progress bar libraries in the ecosystem that I wanted to address.
There was no thread-safe, multi-job option. Being able to pass progress bar context around also
ranked highly on my scratch-an-itch list. Unfortunately, as much as I would have liked to write this
all myself, I did not have time to. So, I leaned on AI for this.

There are a few down-the-line packages from me which will depend on this, which don't use AI - hence the registration in General.

However, I _am_ committed to maintaining this (as I'm using this myself) - if you find this library useful, but find issues, please do raise them, and I'll get to them as quickly as I can.
