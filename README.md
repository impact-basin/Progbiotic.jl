# Progbiotic.jl: neat progress bars.

This package implements thread-safe progress bars. These bars can be nested into a tree structure. There are TQDM and macro interfaces.

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
@progress title="Model Training Pipeline" theme=OCEAN "Epochs" for epoch in 1:3
    @progress ("Epoch $epoch Batches", CYBERPUNK) for batch in 1:20
        sleep(0.01)
    end
end


# 3-level deep nested progress tree with vanishing micro-batch bars.
@progress ("Outer Pipeline", OCEAN) for i = 1:3
    @progress (stage => ("Stage $i", CYBERPUNK)) for j = 1:5
        @progress "Micro-batch" for k = 1:10
            sleep(0.005)
        end
    end
end

# Supports multithreading!
@progress "Loop 1" threads=true for i = 1:3
    @progress "Loop 2, i=$i" for j = 1:5
        @progress "Micro-batch" for k = 1:10
            sleep(0.05)
        end
    end
end
```

# Caveat emptor! AI slop.

After the State of Julia keynote, where both Keno Fischer and Tim Holy mentioned that they found AI useful, it was time to take AI for a test-drive.

This package has scratched a low-priority itch I've had for a while, but haven't had the time to implement myself. I suppose that's good.

On the other hand, the quality of the source code is lower than what I'd desire; perhaps some work over a free weekend will sort it out.

Overall, AI-assisted programming seems useful for low-criticality tasks. Interesting!
