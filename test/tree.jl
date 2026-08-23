using Progbiotic
using Test

@testset "tree.jl" begin
    data = Dict(
        "src" => Dict(
            "ProgBar.jl" => "4.2 KB",
            "render" => Dict("ascii.jl" => "1.8 KB", "colors.jl" => "2.1 KB"),
        ),
        "Project.toml" => "240 B",
        "README.md" => "1.1 KB",
    )

    @testset "print_tree round style" begin
        out = sprint(io -> print_tree(data; io=io))
        @test occursin("Project.toml => 240 B", out)
        @test occursin("README.md => 1.1 KB", out)
        @test occursin("╰─ src", out)                    # round terminator on the last top-level key
        @test occursin("ProgBar.jl => 4.2 KB", out)
        @test occursin("ascii.jl => 1.8 KB", out)
    end

    @testset "print_tree square style with root" begin
        out = sprint(io -> print_tree(data; style=:square, root="Progbiotic", io=io))
        @test startswith(out, "Progbiotic\n")
        @test occursin("└─ src", out)                    # square terminator
        @test !occursin("╰─", out)
    end

    @testset "print_tree pair and unknown style" begin
        out = sprint(io -> print_tree("Root" => Dict("a" => 1); io=io))
        @test startswith(out, "Root\n")
        @test occursin("a => 1", out)
        @test_throws ErrorException sprint(io -> print_tree(data; style=:bogus, io=io))
    end

    @testset "Dict with_tree_gutter smoke" begin
        buf = IOBuffer()
        with_tree_gutter(Dict("a" => 1, "b" => 2); io=buf) do
            nothing
        end
        out = String(take!(buf))
        @test occursin("a => 1", out)
        @test occursin("b => 2", out)
    end
end
