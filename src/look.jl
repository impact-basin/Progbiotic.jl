"""
    Theme(name, palette, barunits, empty, spinner[, caps, head])

Describes the look of a progress bar: a `palette` of colors (interpolated along
the bar), the `barunits` stipple glyphs (low to high fill), the `empty` glyph,
the `spinner` frames, optional `caps` flanking the bar, and an optional `head`
glyph marking the tip of an in-progress bar.

Use the [`Theme`](@ref) copy constructor to mix elements of the
built-in themes (e.g. `Theme(AMBER; spinner=EMERALD.spinner)`).
"""
struct Theme    name     :: Symbol
    palette  :: Vector{Color}
    barunits :: Vector{Char}
    empty    :: Char
    spinner  :: Vector{Char}
    caps     :: Tuple{Char, Char}
    head     :: Union{Nothing, Char}
    function Theme(name::Symbol, palette, barunits, empty, spinner,
                   caps::Tuple{Char, Char} = (' ', ' '),
                   head::Union{Nothing, Char} = nothing)
        new(name, palette, barunits, empty, spinner, caps, head)
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
               palette  :: Vector{Color} = base.palette,
               barunits :: Vector{Char}  = base.barunits,
               empty    :: Char          = base.empty,
               spinner  :: Vector{Char}  = base.spinner,
               caps = base.caps,
               head = base.head)
    return Theme(base.name, palette, barunits, empty, spinner, _as_caps(caps), _as_head(head))
end

# Normalises a `caps` override (a 2-char string like "[]" or a Char pair) to a pair.
_as_caps(caps) = caps isa AbstractString ? (first(caps), last(caps)) : (caps[1], caps[2])
# Normalises a `head` override (a char or single-char string) to a Char.
_as_head(head) = head isa AbstractString ? first(head) : head

# Merges per-job style overrides (spinner/barunits/empty/caps/head) into a theme;
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
        colorant"#FF00FF",
        colorant"#8888FF",
        colorant"#00FFFF",
        colorant"#00FF00",
    ],
    ['░', '▒', '▓', '█'], '░',
    ['◉'],
)

"""Hot-pink / violet / electric blue."""
const NEON = Theme(
    :neon,
    [colorant"#FF0080", colorant"#8000FF", colorant"#0080FF"],
    ['·', '▪', '▫', '█'], ' ',
    ['●'],
)

"""Phosphor-green CRT aesthetic."""
const MATRIX = Theme(
    :matrix,
    [colorant"#009600", colorant"#00C800", colorant"#00FF00"],
    ['░', '▒', '▓', '█'], '░',
    ['◈'],
)

"""Retro amber monochrome, like an old VT220 terminal."""
const AMBER = Theme(
    :amber,
    [colorant"#FF6400", colorant"#FF8C00", colorant"#FFB000"],
    ['░', '▒', '▓', '█'], '░',
    ['◉'],
)

"""Lush botanical greens: pine, emerald, and bright mint.
"""
const EMERALD = Theme(
    :emerald,
    [colorant"#1B4332", colorant"#2D6A4F",
colorant"#40916C", colorant"#74C69D", colorant"#D8F3DC"],
    ['░', '▒', '▓', '█'], ' ',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Deep ocean sapphire to electric sky blue."""
const OCEAN = Theme(
    :ocean,
    [colorant"#003366", colorant"#0066CC",
colorant"#0099FF", colorant"#33CCFF", colorant"#AEEEEE"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""Crisp arctic frost and glacial blue tones."""
const GLACIER = Theme(
    :glacier,
    [colorant"#5E81AC", colorant"#81A1C1",
colorant"#88C0D0", colorant"#8FBCBB", colorant"#ECEFF4"],
    ['░', '▒', '▓', '█'], '░',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Tokyo nightscape: dark indigo, electric violet-blue, and
azure."""
const TOKYO_NIGHT = Theme(
    :tokyo_night,
    [colorant"#3D59A1", colorant"#7AA2F7",
colorant"#7DCFFF", colorant"#BB9AF7"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◜', '◠', '◝', '◞', '◡', '◟'],
)

"""80s retro synthwave: deep violet, hot magenta, coral,
and gold."""
const SYNTHWAVE = Theme(
    :synthwave,
    [colorant"#7209B7", colorant"#F72585",
colorant"#FF4D6D", colorant"#FFB703"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◇', '◈', '◆', '◈'],
)

"""Blazing solar flare and molten magma gradient."""
const MAGMA = Theme(
    :magma,
    [colorant"#9B111E", colorant"#D00000",
colorant"#FF5400", colorant"#FFBD00"],
    ['░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '☆'],
)

"""Clean, distraction-free monochrome gradient."""
const MONOCHROME = Theme(
    :monochrome,
    [colorant"#555555", colorant"#888888",
colorant"#BBBBBB", colorant"#FFFFFF"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Northern Lights: deep celestial violet to glowing neon
turquoise."""
const AURORA = Theme(
    :aurora,
    [colorant"#3A0CA3", colorant"#4361EE",
colorant"#4CC9F0", colorant"#72EFDD", colorant"#80FFDB"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['✶', '✸', '✹', '✺', '✹', '✷'],
)

"""Gothic aesthetic: deep plum, orchid purple, hot pink,
and pastel cyan."""
const DRACULA = Theme(
    :dracula,
    [colorant"#6272A4", colorant"#BD93F9",
colorant"#FF79C6", colorant"#8BE9FD", colorant"#50FA7B"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['○', '◔', '◑', '◕', '●'],
)


"""Delicate Japanese cherry blossom: deep berry to soft
petal pink."""
const SAKURA = Theme(
    :sakura,
    [colorant"#800F2F", colorant"#C9184A",
colorant"#FF4D6D", colorant"#FF758F", colorant"#FFCCD5"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['❀', '✿', '✾', '✽'],
)

"""Warm vintage retro: earthy rust, ochre yellow, olive,
and warm amber."""
const GRUVBOX = Theme(
    :gruvbox,
    [colorant"#CC241D", colorant"#D79921",
colorant"#98971A", colorant"#458588", colorant"#D3869B"],
    ['░', '▒', '▓', '█'], '·',
    ['◰', '◳', '◲', '◱'],                      # Retro
)

"""High-performance telemetry: deep burgundy to blistering
scarlet red."""
const REDLINE = Theme(
    :redline,
    [colorant"#590D22", colorant"#A4133C",
colorant"#E01E37", colorant"#FF0054", colorant"#FF758F"],
    ['·', '▪', '▫', '■', '█'], '·',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Vibrant 80s South Beach: electric teal, hot magenta, and
pastel violet."""
const MIAMI = Theme(
    :miami,
    [colorant"#00F5D4", colorant"#00BBF9",
colorant"#F15BB5", colorant"#9B5DE5"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◇', '◈', '◆', '◈'],
)

"""Solarized dark: low-contrast teal, electric azure, and
solar yellow."""
const SOLARIZED = Theme(
    :solarized,
    [colorant"#073642", colorant"#268BD2",
colorant"#2AA198", colorant"#859900", colorant"#B58900"],
    ['╶', '─', '━', '█'], '┄',
    ['⠁', '⠂', '⠄', '⡀', '⢀', '⠠', '⠐', '⠈'],
)

"""Spooky season: deep plum, electric violet, pumpkin orange,
and a flicker of sickly green."""
const HALLOWEEN = Theme(
    :halloween,
    [colorant"#1A0B2E", colorant"#6D28D9",
colorant"#F97316", colorant"#84CC16"],
    [' ', '░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '✶'],
)

"""Pastel rainbow: cotton-candy pink, baby blue, butter
yellow, and soft mint."""
const UNICORN = Theme(
    :unicorn,
    [colorant"#FFD1DC", colorant"#A1CAF1",
colorant"#FCF6BD", colorant"#C1E1C1"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""Rich roasted coffee: dark mocha, caramel, cream, and a
hint of cinnamon."""
const COFFEE = Theme(
    :coffee,
    [colorant"#3E2723", colorant"#6D4C41",
colorant"#A1887F", colorant"#D7CCC8"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Classic phosphor terminal: pure green glow on dark, with
bold blocky cells."""
const TERMINAL = Theme(
    :terminal,
    [colorant"#0F380F", colorant"#306230",
colorant"#8BAC0F", colorant"#9BBC0F"],
    ['░', '▒', '▓', '█'], '░',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Minimalist black/white corporate: clean monochrome gradient."""
const MONO = Theme(
    :mono,
    [colorant"#000000", colorant"#333333",
colorant"#666666", colorant"#999999", colorant"#CCCCCC"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Cool slate gray: boardroom-clean professional gradient."""
const SLATE = Theme(
    :slate,
    [colorant"#2D3748", colorant"#4A5568",
colorant"#718096", colorant"#A0AEC0", colorant"#E2E8F0"],
    ['░', '▒', '▓', '█'], ' ',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Dark navy with subtle blue accents: understated elegance."""
const MIDNIGHT = Theme(
    :midnight,
    [colorant"#0A0E1A", colorant"#1A1F36",
colorant"#2D3561", colorant"#415A77"],
    ['·', '▪', '▫', '█'], ' ',
    ['◉', '◎', '●', '○'],
)

"""Deep professional greens: forest canopy gradient."""
const FOREST = Theme(
    :forest,
    [colorant"#1B4332", colorant"#2D6A4F",
colorant"#40916C", colorant"#95D5B2"],
    ['░', '▒', '▓', '█'], ' ',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
)

"""Metallic industrial gray: sleek and modern."""
const STEEL = Theme(
    :steel,
    [colorant"#2C3E50", colorant"#34495E",
colorant"#7F8C8D", colorant"#BDC3C7"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
)

"""Anarchy neon: high-contrast punk aesthetic with magenta,
green, and red on black."""
const PUNK = Theme(
    :punk,
    [colorant"#FF00FF", colorant"#00FF00",
colorant"#000000", colorant"#FF0000"],
    ['░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '☆'],
)

"""Toxic radioactive glow: acid green and hot pink on black."""
const ACID = Theme(
    :acid,
    [colorant"#39FF14", colorant"#FF073A",
colorant"#000000", colorant"#B026FF"],
    [' ', '░', '▒', '▓', '█'], ' ',
    ['◈', '◆', '◇', '◈'],
)

"""Deep crimson bloodmoon: aggressive red gradient."""
const BLOODMOON = Theme(
    :bloodmoon,
    [colorant"#1A0000", colorant"#660000",
colorant"#CC0000", colorant"#FF0000"],
    ['·', '▪', '▫', '■', '█'], '·',
    ['✦', '✧', '★', '☆'],
)

"""Chaotic RGB glitch: digital distortion aesthetic."""
const GLITCH = Theme(
    :glitch,
    [colorant"#00FFFF", colorant"#FF00FF",
colorant"#FFFF00", colorant"#00FF00"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◇', '◈', '◆', '◈'],
)

"""Anarchy flag: stark red, black, and white."""
const REBEL = Theme(
    :rebel,
    [colorant"#FF0000", colorant"#000000", colorant"#FFFFFF"],
    ['░', '▒', '▓', '█'], '░',
    ['⚠', '☢', '☣', '⚠'],
)

"""Retro future vaporwave: pink, cyan, and purple gradient."""
const VAPORWAVE = Theme(
    :vaporwave,
    [colorant"#FF71CE", colorant"#01CDFE",
colorant"#05FFA1", colorant"#B967FF"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""Golden honey: deep amber to luminous gold."""
const HONEY = Theme(
    :honey,
    [colorant"#B45309", colorant"#D97706",
     colorant"#F59E0B", colorant"#FBBF24", colorant"#FDE68A"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], '·',
    ['◐', '◓', '◑', '◒'],
    # ('▏', '▕'),
)

"""Burning coals: ember red-orange to bright gold, with a spark at the tip."""
const EMBER = Theme(
    :ember,
    [colorant"#7C2D12", colorant"#C2410C",
     colorant"#EA580C", colorant"#F97316", colorant"#FBBF24"],
    ['░', '▒', '▓', '█'], '░',
    ['✦', '✧', '★', '☆'],
    # (' ', ' '),
    # '✦',
)

"""Bright tangerine: juicy orange zest."""
const TANGERINE = Theme(
    :tangerine,
    [colorant"#9A3412", colorant"#EA580C",
     colorant"#FB923C", colorant"#FDBA74"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], ' ',
    ['◉', '◎'],
)

"""Metallic copper: brass instrument-panel warmth, framed with brackets."""
const COPPER = Theme(
    :copper,
    [colorant"#6B3A1F", colorant"#9C5A2F",
     colorant"#C77B3F", colorant"#E09F5C", colorant"#F2C58D"],
    ['░', '▒', '▓', '█'], '░',
    ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'],
    # ('[', ']'),
)

"""Marigold: saffron to soft butter yellow."""
const MARIGOLD = Theme(
    :marigold,
    [colorant"#A16207", colorant"#CA8A04",
     colorant"#EAB308", colorant"#FACC15", colorant"#FDE047"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], '·',
    ['◐', '◓', '◑', '◒'],
)

"""Warm dusk: the last oranges of sunset."""
const SUNSET = Theme(
    :sunset,
    [colorant"#9A3412", colorant"#C2410C",
     colorant"#F97316", colorant"#FB923C", colorant"#FBBF24", colorant"#FDBA74"],
    [' ', '▂', '▃', '▄', '▅', '▆', '▇', '█'], ' ',
    ['◐', '◓', '◑', '◒'],
)

"""High-contrast phosphor amber: a brighter, blockier AMBER for old CRT vibes."""
const AMBER_GLOW = Theme(
    :amber_glow,
    [colorant"#FF7A00", colorant"#FF9500",
     colorant"#FFB300", colorant"#FFD000"],
    ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'], '·',
    ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
    # ('◢', '◣'),
    # '◈',
)
