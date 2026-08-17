struct Theme
    name     :: Symbol
    palette  :: Vector{Color}
    barunits :: Vector{Char}
    empty    :: Char
    spinner  :: Vector{Char}
end

"""Neon cyberpunk: cyan → magenta → green → amber."""
const CYBERPUNK = Theme(:cyberpunk,
    [colorant"#00FFFF", colorant"#FF00FF", colorant"#00FF00", colorant"#FFB000"],
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
    [colorant"#00FF00", colorant"#00C800", colorant"#009600"],
    ['░', '▒', '▓', '█'], '░',
    ['◈'],
)

"""Retro amber monochrome, like an old VT220 terminal."""
const AMBER = Theme(
    :amber,
    [colorant"#FFB000", colorant"#FF8C00", colorant"#FF6400"],
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
