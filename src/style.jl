# branch glyphs for the tree renderer, keyed by role
const TREE_STRS = Dict(
    :square => Dict(
        :nada => "   ",
        :root => "┬  ",
        :line => "│  ",
        :leaf => "├─ ",
        :term => "└─ ",
    ),

    :round => Dict(
        :nada => "   ",
        :root => "┬  ",
        :line => "│  ",
        :leaf => "├─ ",
        :term => "╰─ ",
    ),
)

"""
    Theme(name, palette, barunits, empty, spinner[, caps, head])

Describes the look of a progress bar: a `palette` of colors (interpolated along
the bar), the `barunits` stipple glyphs (low to high fill), the `empty` glyph,
the `spinner` frames, optional `caps` flanking the bar, and an optional `head`
glyph marking the tip of an in-progress bar.

Use the [`Theme`](@ref) copy constructor to mix elements of the
built-in themes (e.g. `Theme(AMBER; spinner=EMERALD.spinner)`).
"""
struct Theme{P<:Colorant}
    name     :: Symbol
    palette  :: Vector{P}
    barunits :: Vector{Char}
    empty    :: Char
    spinner  :: Vector{Char}
    caps     :: Tuple{Char, Char}
    head     :: Union{Nothing, Char}

    function Theme(name::Symbol, palette::AbstractVector{P}, barunits, empty, spinner,
                   caps::Tuple{Char, Char} = (' ', ' '),
                   head::Union{Nothing, Char} = nothing) where {P<:Colorant}
        new{P}(name, Vector{P}(palette), barunits, empty, spinner, caps, head)
    end
end

"""
    Theme(base::Theme; palette=base.palette, barunits=base.barunits, empty=base.empty, spinner=base.spinner, caps=base.caps, head=base.head)

Builds a new theme by mixing elements of an existing one, e.g.

    Theme(AMBER; spinner=EMERALD.spinner)                 # AMBER palette, EMERALD spinner
    Theme(OCEAN; barunits=MONOCHROME.barunits, empty='·') # swap the bar glyphs
    Theme(AMBER; caps="[]", head='>')                     # frame the bar and tip it
"""
function Theme(base::Theme;
               palette = base.palette,
               barunits :: Vector{Char}  = base.barunits,
               empty    :: Char          = base.empty,
               spinner  :: Vector{Char}  = base.spinner,
               caps = base.caps,
               head = base.head)
    return Theme(base.name, palette, barunits, empty, spinner, _as_caps(caps), _as_head(head))
end

# normalises a `caps` override (a 2-char string like "[]" or a Char pair) to a pair.
_as_caps(caps) = caps isa AbstractString ? (first(caps), last(caps)) : (caps[1], caps[2])
# normalises a `head` override (a char or single-char string) to a Char.
_as_head(head) = head isa AbstractString ? first(head) : head

# merges per-job style overrides (spinner/barunits/empty/caps/head) into a theme;
# returns the theme unchanged when no override is given.
function _apply_style(t::Theme, spinner, barunits, empty, caps, head)
    if spinner === nothing && barunits === nothing && empty === nothing &&
       caps === nothing && head === nothing
        return t
    end
    return Theme(t;
        spinner  = spinner  === nothing ? t.spinner  : (spinner  isa AbstractString ? collect(spinner)  : spinner),
        barunits = barunits === nothing ? t.barunits : (barunits isa AbstractString ? collect(barunits) : barunits),
        empty    = empty    === nothing ? t.empty    : (empty    isa AbstractString ? first(empty)     : empty),
        caps     = caps     === nothing ? t.caps     : _as_caps(caps),
        head     = head     === nothing ? t.head     : _as_head(head),
    )
end

"""Neon cyberpunk: cyan → magenta → green → amber."""
const CYBERPUNK = Theme(:cyberpunk,
    [
        rgb"#FF00FF",
        rgb"#8888FF",
        rgb"#00FFFF",
        rgb"#00FF00",
    ],
    ['░', '▒', '▓', '█'], '░',
    ['◉'],
)

"""Hot-pink / violet / electric blue."""
const NEON = Theme(
    :neon,
    [rgb"#FF0080", rgb"#8000FF", rgb"#0080FF"],
    ['·', '▪', '▫', '█'], ' ',
    ['●'],
)

"""Phosphor-green CRT aesthetic."""
const MATRIX = Theme(
    :matrix,
    [rgb"#009600", rgb"#00C800", rgb"#00FF00"],
    ['░', '▒', '▓', '█'], '░',
    ['◈'],
)

"""Retro amber monochrome, like an old VT220 terminal."""
const AMBER = Theme(
    :amber,
    [rgb"#FF6400", rgb"#FF8C00", rgb"#FFB000"],
    ['░', '▒', '▓', '█'], '░',
    ['◉'],
)

"""Lush botanical greens: pine, emerald, and bright mint.
"""
const EMERALD = Theme(
    :emerald,
    [rgb"#1B4332", rgb"#2D6A4F",
rgb"#40916C", rgb"#74C69D", rgb"#D8F3DC"],
    ['░', '▒', '▓', '█'], ' ',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Deep ocean sapphire to electric sky blue."""
const OCEAN = Theme(
    :ocean,
    [rgb"#003366", rgb"#0066CC",
rgb"#0099FF", rgb"#33CCFF", rgb"#AEEEEE"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""Crisp arctic frost and glacial blue tones."""
const GLACIER = Theme(
    :glacier,
    [rgb"#5E81AC", rgb"#81A1C1",
rgb"#88C0D0", rgb"#8FBCBB", rgb"#ECEFF4"],
    ['░', '▒', '▓', '█'], '░',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Tokyo nightscape: dark indigo, electric violet-blue, and
azure."""
const TOKYO_NIGHT = Theme(
    :tokyo_night,
    [rgb"#3D59A1", rgb"#7AA2F7",
rgb"#7DCFFF", rgb"#BB9AF7"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◜', '◠', '◝', '◞', '◡', '◟'],
)

"""80s retro synthwave: deep violet, hot magenta, coral,
and gold."""
const SYNTHWAVE = Theme(
    :synthwave,
    [rgb"#7209B7", rgb"#F72585",
rgb"#FF4D6D", rgb"#FFB703"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◇', '◈', '◆', '◈'],
)

"""Blazing solar flare and molten magma gradient."""
const MAGMA = Theme(
    :magma,
    [rgb"#9B111E", rgb"#D00000",
rgb"#FF5400", rgb"#FFBD00"],
    ['░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '☆'],
)

"""Clean, distraction-free monochrome gradient."""
const MONOCHROME = Theme(
    :monochrome,
    [rgb"#555555", rgb"#888888",
rgb"#BBBBBB", rgb"#FFFFFF"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Northern Lights: deep celestial violet to glowing neon
turquoise."""
const AURORA = Theme(
    :aurora,
    [rgb"#3A0CA3", rgb"#4361EE",
rgb"#4CC9F0", rgb"#72EFDD", rgb"#80FFDB"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['✶', '✸', '✹', '✺', '✹', '✷'],
)

"""Gothic aesthetic: deep plum, orchid purple, hot pink,
and pastel cyan."""
const DRACULA = Theme(
    :dracula,
    [rgb"#6272A4", rgb"#BD93F9",
rgb"#FF79C6", rgb"#8BE9FD", rgb"#50FA7B"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['○', '◔', '◑', '◕', '●'],
)


"""Delicate Japanese cherry blossom: deep berry to soft
petal pink."""
const SAKURA = Theme(
    :sakura,
    [rgb"#800F2F", rgb"#C9184A",
rgb"#FF4D6D", rgb"#FF758F", rgb"#FFCCD5"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['❀', '✿', '✾', '✽'],
)

"""Warm vintage retro: earthy rust, ochre yellow, olive,
and warm amber."""
const GRUVBOX = Theme(
    :gruvbox,
    [rgb"#CC241D", rgb"#D79921",
rgb"#98971A", rgb"#458588", rgb"#D3869B"],
    ['░', '▒', '▓', '█'], '·',
    ['◰', '◳', '◲', '◱'],                      # Retro
)

"""High-performance telemetry: deep burgundy to blistering
scarlet red."""
const REDLINE = Theme(
    :redline,
    [rgb"#590D22", rgb"#A4133C",
rgb"#E01E37", rgb"#FF0054", rgb"#FF758F"],
    ['·', '▪', '▫', '■', '█'], '·',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Vibrant 80s South Beach: electric teal, hot magenta, and
pastel violet."""
const MIAMI = Theme(
    :miami,
    [rgb"#00F5D4", rgb"#00BBF9",
rgb"#F15BB5", rgb"#9B5DE5"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◇', '◈', '◆', '◈'],
)

"""Solarized dark: low-contrast teal, electric azure, and
solar yellow."""
const SOLARIZED = Theme(
    :solarized,
    [rgb"#073642", rgb"#268BD2",
rgb"#2AA198", rgb"#859900", rgb"#B58900"],
    ['╶', '─', '━', '█'], '┄',
    ['⠁', '⠂', '⠄', '⡀', '⢀', '⠠', '⠐', '⠈'],
)

"""Spooky season: deep plum, electric violet, pumpkin orange,
and a flicker of sickly green."""
const HALLOWEEN = Theme(
    :halloween,
    [rgb"#1A0B2E", rgb"#6D28D9",
rgb"#F97316", rgb"#84CC16"],
    [' ', '░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '✶'],
)

"""Pastel rainbow: cotton-candy pink, baby blue, butter
yellow, and soft mint."""
const UNICORN = Theme(
    :unicorn,
    [rgb"#FFD1DC", rgb"#A1CAF1",
rgb"#FCF6BD", rgb"#C1E1C1"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""Rich roasted coffee: dark mocha, caramel, cream, and a
hint of cinnamon."""
const COFFEE = Theme(
    :coffee,
    [rgb"#3E2723", rgb"#6D4C41",
rgb"#A1887F", rgb"#D7CCC8"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Classic phosphor terminal: pure green glow on dark, with
bold blocky cells."""
const TERMINAL = Theme(
    :terminal,
    [rgb"#0F380F", rgb"#306230",
rgb"#8BAC0F", rgb"#9BBC0F"],
    ['░', '▒', '▓', '█'], '░',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Minimalist black/white corporate: clean monochrome gradient."""
const MONO = Theme(
    :mono,
    [rgb"#000000", rgb"#333333",
rgb"#666666", rgb"#999999", rgb"#CCCCCC"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Cool slate gray: boardroom-clean professional gradient."""
const SLATE = Theme(
    :slate,
    [rgb"#2D3748", rgb"#4A5568",
rgb"#718096", rgb"#A0AEC0", rgb"#E2E8F0"],
    ['░', '▒', '▓', '█'], ' ',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Dark navy with subtle blue accents: understated elegance."""
const MIDNIGHT = Theme(
    :midnight,
    [rgb"#0A0E1A", rgb"#1A1F36",
rgb"#2D3561", rgb"#415A77"],
    ['·', '▪', '▫', '█'], ' ',
    ['◉', '◎', '●', '○'],
)

"""Deep professional greens: forest canopy gradient."""
const FOREST = Theme(
    :forest,
    [rgb"#1B4332", rgb"#2D6A4F",
rgb"#40916C", rgb"#95D5B2"],
    ['░', '▒', '▓', '█'], ' ',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Metallic industrial gray: sleek and modern."""
const STEEL = Theme(
    :steel,
    [rgb"#2C3E50", rgb"#34495E",
rgb"#7F8C8D", rgb"#BDC3C7"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Anarchy neon: high-contrast punk aesthetic with magenta,
green, and red on black."""
const PUNK = Theme(
    :punk,
    [rgb"#FF00FF", rgb"#00FF00",
rgb"#000000", rgb"#FF0000"],
    ['░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '☆'],
)

"""Toxic radioactive glow: acid green and hot pink on black."""
const ACID = Theme(
    :acid,
    [rgb"#39FF14", rgb"#FF073A",
rgb"#000000", rgb"#B026FF"],
    [' ', '░', '▒', '▓', '█'], ' ',
    ['◈', '◆', '◇', '◈'],
)

"""Deep crimson bloodmoon: aggressive red gradient."""
const BLOODMOON = Theme(
    :bloodmoon,
    [rgb"#1A0000", rgb"#660000",
rgb"#CC0000", rgb"#FF0000"],
    ['·', '▪', '▫', '■', '█'], '·',
    ['✦', '✧', '★', '☆'],
)

"""Chaotic RGB glitch: digital distortion aesthetic."""
const GLITCH = Theme(
    :glitch,
    [rgb"#00FFFF", rgb"#FF00FF",
rgb"#FFFF00", rgb"#00FF00"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◇', '◈', '◆', '◈'],
)

"""Anarchy flag: stark red, black, and white."""
const REBEL = Theme(
    :rebel,
    [rgb"#FF0000", rgb"#000000", rgb"#FFFFFF"],
    ['░', '▒', '▓', '█'], '░',
    ['⚠', '☢', '☣', '⚠'],
)

"""Retro future vaporwave: pink, cyan, and purple gradient."""
const VAPORWAVE = Theme(
    :vaporwave,
    [rgb"#FF71CE", rgb"#01CDFE",
rgb"#05FFA1", rgb"#B967FF"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""Golden honey: deep amber to luminous gold."""
const HONEY = Theme(
    :honey,
    [rgb"#B45309", rgb"#D97706",
     rgb"#F59E0B", rgb"#FBBF24", rgb"#FDE68A"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], '·',
    ['◐', '◓', '◑', '◒'],
    # ('▏', '▕'),
)

"""Burning coals: ember red-orange to bright gold, with a spark at the tip."""
const EMBER = Theme(
    :ember,
    [rgb"#7C2D12", rgb"#C2410C",
     rgb"#EA580C", rgb"#F97316", rgb"#FBBF24"],
    ['░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '☆'],
    # (' ', ' '),
    # '✦',
)

"""Bright tangerine: juicy orange zest."""
const TANGERINE = Theme(
    :tangerine,
    [rgb"#9A3412", rgb"#EA580C",
     rgb"#FB923C", rgb"#FDBA74"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◉', '◎'],
)

"""Metallic copper: brass instrument-panel warmth, framed with brackets."""
const COPPER = Theme(
    :copper,
    [rgb"#6B3A1F", rgb"#9C5A2F",
     rgb"#C77B3F", rgb"#E09F5C", rgb"#F2C58D"],
    ['░', '▒', '▓', '█'], '░',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
    # ('[', ']'),
)

"""Marigold: saffron to soft butter yellow."""
const MARIGOLD = Theme(
    :marigold,
    [rgb"#A16207", rgb"#CA8A04",
     rgb"#EAB308", rgb"#FACC15", rgb"#FDE047"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], '·',
    ['◐', '◓', '◑', '◒'],
)

"""Warm dusk: the last oranges of sunset."""
const SUNSET = Theme(
    :sunset,
    [rgb"#9A3412", rgb"#C2410C",
     rgb"#F97316", rgb"#FB923C", rgb"#FBBF24", rgb"#FDBA74"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""High-contrast phosphor amber: a brighter, blockier AMBER for old CRT vibes."""
const AMBER_GLOW = Theme(
    :amber_glow,
    [rgb"#FF7A00", rgb"#FF9500",
     rgb"#FFB300", rgb"#FFD000"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], '·',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
    # ('◢', '◣'),
    # '◈',
)
