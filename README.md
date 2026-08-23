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
for i in ProgJob(1:100; desc = "Ordinary")
    sleep(0.1)
end

# thread-safe!
@threads for i in ProgJob(1:100; desc = "Multithreaded")
    sleep(0.1)
end

# themeable!
files = ["data1.csv", "data2.csv", "data3.csv", "data4.csv"]
for file in ProgJob(files, OCEAN; desc = "Parsing files")
    sleep(0.3)
end

# works with comprehensions!
[x^2 for x in ProgJob(1:9001, GLACIER; desc = "Squaring")];

# comprehensions over matrices!
[x^2 for x in ProgJob(rand(32,32), GLACIER; desc = "Squaring matrix elements!")]
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
switches vanishing on/off.

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
- `@progress ctx "desc"` binds `ctx` to the new job. This can be passed to helper
  functions, which can register their own progress: `@progress "desc" with=ctx for ...`.

# AI use.

There were a few aspects of the progress bar libraries in the ecosystem that I wanted to address.
There was no thread-safe, multi-job option. Being able to pass progress bar context around also
ranked highly on my scratch-an-itch list. Unfortunately, as much as I would have liked to write this
all myself, I did not have time to. So, I leaned on AI for this.

There are a few down-the-line packages from me which will depend on this, which don't use AI - hence the registration in General.

However, I _am_ committed to maintaining this (as I'm using this myself) - if you find this library useful, but find issues, please do raise them, and I'll get to them as quickly as I can.
