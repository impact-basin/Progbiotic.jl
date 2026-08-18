using ProgBiotic

sample_data = Dict(
    "src" => Dict(
        "ProgBar.jl" => "4.2 KB",
        "render" => Dict(
            "ascii.jl" => "1.8 KB",
            "colors.jl" => "2.1 KB"
        )
    ),
    "Project.toml" => "240 B",
    "README.md" => "1.1 KB"
)

# 1. Round style (default) with a root name
print_tree(sample_data; root="ProgBar.jl", style=:square)

function test_below()
    sample_data = Dict(
        "src" => Dict(
            "ProgBar.jl" => "4.2 KB",
            "render" => Dict(
                "ascii.jl" => "1.8 KB",
                "colors.jl" => "2.1 KB"
            )
        ),
        "Project.toml" => "240 B",
        "README.md" => "1.1 KB"
    )
    with_tree_gutter(sample_data) do
        println("First print")
        sleep(0.5)
        println("Second print")
        sleep(0.5)
        println("Third print")
        sleep(0.5)
    end
end

test_below()
