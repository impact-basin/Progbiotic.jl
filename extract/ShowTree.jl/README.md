# ShowTree.jl

Print nested data as a tree, and give a struct a tree-rendering `show` method.

Extracted from [Progbiotic.jl](https://github.com/impact-basin/Progbiotic.jl), where it
was unrelated to progress bars.

## `print_tree`

```julia
using ShowTree

data = Dict(
    "src" => Dict(
        "ProgBar.jl" => "4.2 KB",
        "render"   => Dict("ascii.jl" => "1.8 KB", "colors.jl" => "2.1 KB"),
    ),
    "Project.toml" => "240 B",
    "README.md"    => "1.1 KB",
)

print_tree(data; root = "progbiotic", style = :round)
```

```text
progbiotic
├─ Project.toml => 240 B
├─ README.md => 1.1 KB
╰─ src
   ├─ ProgBar.jl => 4.2 KB
   ╰─ render
      ├─ ascii.jl => 1.8 KB
      ╰─ colors.jl => 2.1 KB
```

`style` is `:round` or `:square`. Keys are sorted by default, falling back to
string ordering when they do not compare.

## `with_tree_gutter`

Pins a tree to the bottom of the terminal as a fixed gutter while a function runs;
anything printed inside scrolls above it. The scroll region is restored in a
`finally` block, so exceptions propagate with the terminal intact.

```julia
with_tree_gutter(Dict("a" => 1, "b" => 2)) do
    for i in 1:100
        println("line ", i)
    end
end
```

## `@showtree`

Defines a struct and gives it a `Base.show` method that renders its fields as a
tree.

```julia
@showtree struct Point
    x :: Float64
    y :: Float64
end

julia> Point(1, 2)
Point
╰─ x :: Float64 => 1.0
╰─ y :: Float64 => 2.0
```

Set `fieldtypes = false` inside a block to render bare field names instead of
`name :: Type`.

## Status

Extracted, not yet registered. Let me know about bugs.
