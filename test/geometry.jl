module GeometryTests

using Progbiotic
using Test

plain(s) = replace(s, r"\e\[[0-9;:]*m|\e\]8;[^\a\e]*(?:\a|\e\\)" => "")

struct TextColumn <: AbstractColumn
    text :: String
end
Progbiotic.render_column(col::TextColumn, ::BarState) = col.text

@testset "terminal text geometry" begin
    @testset "CSI and hyperlink sequences occupy no cells" begin
        @test Progbiotic._visible_width("\e[31mX\e[0m") == 1
        @test Progbiotic._visible_width("\e[38:2::1:2:3mXY\e[m") == 2
        @test Progbiotic._visible_width("\e]8;id=job;https://example.com\aLink\e]8;;\a") == 4
        @test Progbiotic._visible_width("\e]8;;file:///tmp/job\e\\\u754c\e]8;;\e\\") == 2
    end

    @testset "known grapheme widths and complete prefixes" begin
        # each entry is one grapheme and its expected modern-terminal cell width
        clusters = [("a", 1), ("e\u0301", 1), ("\u754c", 2),
                    ("\U0001f469\u200d\U0001f4bb", 2), ("\U0001f1ec\U0001f1e7", 2),
                    ("\u2764\ufe0f", 2), ("1\ufe0f\u20e3", 2)]
        for (g, cells) in clusters
            @test Progbiotic._visible_width(g) == cells
            @test Progbiotic._truncate_ansi(g, cells - 1) == ""
            @test plain(Progbiotic._truncate_ansi(g, cells)) == g
        end

        text = join(first.(clusters))
        prefixes = [join(first.(clusters[1:n])) for n in 0:length(clusters)]
        widths = [sum(last, clusters[1:n]; init = 0) for n in 0:length(clusters)]
        for width in 1:20
            expected = prefixes[findlast(<=(width), widths)]
            for wrapped in (text, "\e[31m" * text,
                            "\e]8;;https://example.com\e\\" * text)
                out = Progbiotic._truncate_ansi(wrapped, width)
                @test plain(out) == expected
                @test isvalid(out)
            end
        end

        @test plain(Progbiotic._clip("e\e[31m\u0301Z", 1)) == "e\u0301"
        @test plain(Progbiotic._clip("\U0001f469\e[31m\u200d\U0001f4bbZ", 2)) ==
              "\U0001f469\u200d\U0001f4bb"
        @test Progbiotic._clip("\u754c\u754c", 2) == "\u754c"
        @test Progbiotic._clip("e\u0301e\u0301", 2) == "e\u0301e\u0301"
        @test Progbiotic._visible_width("\u0915\u094d\u0937") == 2
        @test_throws ProgbioticError Bar(; fill = '\U0001f1ec')
    end

    @testset "fragments are single-line and styles cannot escape" begin
        @test Progbiotic._safe_text("a\nb\rc\td\ve\ff\u2028g\u2029h") == "a b c d e f g h"
        @test Progbiotic._safe_text("a\e[2Jb\e[?25lc\bd\ae") == "abcde"
        @test Progbiotic._safe_text("a\e]0;change title\ab") == "ab"
        @test Progbiotic._safe_text("a\ePignored\e\\b") == "ab"
        @test Progbiotic._safe_text("a\e]8;;https://example.com") == "a"
        @test Progbiotic._safe_text("a\e[38;2;") == "a"
        @test Progbiotic._safe_text("\e[31mred") == "\e[31mred\e[0m"
        @test Progbiotic._safe_text("\e]8;;https://example.com\aLink") ==
              "\e]8;;https://example.com\e\\Link\e]8;;\e\\"
        @test Progbiotic._plain_text("\e]8;;https://example.com\a\e[31mLink\e[0m") == "Link"
        @test Progbiotic._safe_text(String(UInt8[0xff])) == "\ufffd"
        @test Progbiotic._safe_text("\u202asecret\u202c") == "secret"
        @test Progbiotic._clip("a\nb\e[2Jc", 0) == "a bc"

        for width in 1:10
            out = Progbiotic._clip("\e]8;;https://example.com\e\\\e[31mabcdef", width)
            @test !occursin('\e', plain(out))
            @test endswith(out, "\e]8;;\e\\\e[0m")
            @test plain(out) == first("abcdef", min(width, 6))
        end
    end

    @testset "padding and interpolation use literal cell-aware values" begin
        for desc in ("x", "\e[31mx\e[0m", "\u754c", "e\u0301", "\U0001f469\u200d\U0001f4bb")
            state = BarState(10; desc)
            @test Progbiotic._visible_width(render_column(Tag(; width = 14), state)) == 14
        end
        state = BarState(10; desc = "file{n}{total}{postfix}.dat")
        state.current[] = 3
        @test render_column(Tag(), state) == "file{n}{total}{postfix}.dat"
        @test render_column(Tag("{desc}: {n}/{total}"), state) ==
              "file{n}{total}{postfix}.dat: 3/10"
        state.postfix[] = [:value => "{n}"]
        @test render_column(Tag("{postfix}"), state) == "value={n}"
        state.desc[] = "file\e]8;;unterminated"
        @test render_column(Tag("{desc}: {n}"), state) == "file: 3"
    end

    @testset "titles, labels and custom columns remain one physical row" begin
        for width in 1:64
            p = Progress(10; title = repeat("\u754c", 30) * "\nheader",
                         desc = repeat("e\u0301\u754c", 30), start = false)
            lines = split(render_tree(p; width), '\n')
            @test length(lines) == 2
            @test all(line -> Progbiotic._visible_width(line) <= width, lines)

            col = TextColumn("\e[2J\e[?25lA\nB\rC\t" * repeat("\u754c", 20))
            p = Progress(10; layout = (col,), start = false)
            frame = render_tree(p; width)
            @test length(split(frame, '\n')) == 1
            @test Progbiotic._visible_width(frame) <= width
            @test !any(iscntrl, plain(frame))
            @test !occursin('\e', render_flat_line(p))
            @test !occursin('\n', render_flat_line(p))
        end
    end

    @testset "constrained rows retain failure and cancellation status" begin
        for width in 1:40
            p = Progress(10; desc = repeat("\u754c", 40), start = false)
            fail!(p, ErrorException("failure"))
            line = plain(render_tree(p; width))
            @test occursin(width >= 5 ? "ERROR" : "!", line)
            @test Progbiotic._visible_width(line) <= width
        end
        p = Progress(10; desc = repeat("long label", 10), scoped = true, start = false)
        Progbiotic._cancel_state!(p.state)
        @test occursin("cancelled", plain(render_tree(p; width = 12)))

        p = Progress(10; desc = "file\e]8;;unterminated", start = false)
        fail!(p, ErrorException("failure"))
        @test occursin("ERROR: ErrorException", render_flat_line(p))
        @test startswith(render_flat_line(p), "file ")
    end
end

end
