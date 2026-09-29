using ShowTree
using Test

const DATA = Dict(
    "src" => Dict(
        "ProgBar.jl" => "4.2 KB",
        "render" => Dict("ascii.jl" => "1.8 KB", "colors.jl" => "2.1 KB"),
    ),
    "Project.toml" => "240 B",
    "README.md" => "1.1 KB",
)

@testset "ShowTree.jl" begin
    @testset "print_tree round style" begin
        out = sprint(io -> print_tree(DATA; io = io))
        @test occursin("Project.toml => 240 B", out)
        @test occursin("README.md => 1.1 KB", out)
        @test occursin("╰─ src", out)
        @test occursin("ProgBar.jl => 4.2 KB", out)
        @test occursin("ascii.jl => 1.8 KB", out)
    end

    @testset "print_tree square style with root" begin
        out = sprint(io -> print_tree(DATA; style = :square, root = "Progbiotic", io = io))
        @test startswith(out, "Progbiotic\n")
        @test occursin("└─ src", out)
        @test !occursin("╰─", out)
    end

    @testset "pair root and unknown style" begin
        out = sprint(io -> print_tree("Root" => Dict("a" => 1); io = io))
        @test startswith(out, "Root\n")
        @test occursin("a => 1", out)
        @test_throws ShowTreeError sprint(io -> print_tree(DATA; style = :bogus, io = io))
    end

    @testset "dict gutter restores the terminal" begin
        buf = IOBuffer()
        with_tree_gutter(Dict("a" => 1, "b" => 2); io = buf) do
            nothing
        end
        out = String(take!(buf))
        @test occursin("a => 1", out)
        @test occursin("b => 2", out)
        @test occursin("\e[r", out)
    end

    @testset "gutter propagates exceptions" begin
        buf = IOBuffer()
        @test_throws ErrorException with_tree_gutter(Dict("a" => 1); io = buf) do
            error("boom")
        end
    end

    @testset "@showtree renders fields" begin
        @showtree struct Point
            x :: Float64
            y :: Float64
        end

        out = sprint(show, Point(1.5, 2.5))
        @test occursin("Point", out)
        @test occursin("x :: Float64 => 1.5", out)
        @test occursin("y :: Float64 => 2.5", out)
    end

    @testset "@showtree keeps non-symbol field types" begin
        @showtree struct Bag
            items :: Vector{Int}
        end

        out = sprint(show, Bag([1, 2]))
        @test occursin("items :: Vector{Int} => [1, 2]", out)
    end

    @testset "@showtree rejects non-structs" begin
        @test_throws LoadError @eval @showtree x = 1
    end
end
