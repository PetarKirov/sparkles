# Sparkles design system

The style guide for applications built on [`sparkles:ui`](../libs/ui/index.md):
what every component looks like, and what it becomes on a terminal that can
show less. The requirements behind it are the
[design-system specification](../specs/design-system/index.md); this section is
what they produce.

> [!NOTE]
> The **Sparkles** look itself — the palette, the type, the glyph preferences
> — has not been designed yet: it is the plan's M4, done against the rendered
> components below. Until then the catalog is painted in `tokyo-night`, the
> gallery's default theme.

## The catalog is the gallery

Every page of the [catalog](#catalog) is a page of
[`ui-gallery`](../apps/ui-gallery/index.md) painted headless, the way
Storybook serves a web design system: the canonical rendering of a component is
the one the reference application produces, through the terminal's own
painter. The frames are checked-in files that `dub test :ui-gallery` compares
every render against, so the style guide cannot drift from the code.

```bash
ui-gallery --render --page decoration --profile enhanced
ui-gallery --render --page decoration --profile baseline --degradations
```

## Profiles

A target declares what it can show as a set of flags — color depth, Unicode,
block elements, braille, Nerd Font icons, hyperlinks, styled underlines, and
the chrome only a pixel target honours (radius, shadow, alpha). The flags are
the data; the three **profiles** are named points on that space, used to show
and test the ladder:

| Profile    | Stands for                                       | Color        | Glyphs                                       | Links, styled underlines |
| ---------- | ------------------------------------------------ | ------------ | -------------------------------------------- | ------------------------ |
| `baseline` | a pipe, `TERM=dumb`, a serial console            | none         | ASCII only                                   | no                       |
| `enhanced` | any xterm-compatible emulator of the last decade | 256 colors   | Unicode, box drawing, half and eighth blocks | links only               |
| `full`     | kitty, Ghostty, WezTerm or foot with a Nerd Font | 24-bit color | everything, braille and Nerd Font icons too  | yes                      |

A real terminal is rarely exactly one of them: its declaration is whatever it
answers, and every flag degrades on its own.

### Emulator presets

To see what a page looks like in a particular terminal, there are also
**presets** for eight emulators whose answers to a capability query were
recorded: `xterm`, `apple-terminal`, `iterm2`, `alacritty`, `wezterm`, `kitty`,
`ghostty` and `tmux`. A preset claims what its emulator answered — color depth,
synchronized output, grapheme clustering, scheme reports, images, bracketed
paste, key releases — and nothing no query can confirm, so it may show less
than the emulator can, never more. The measured values are in the
[capabilities specification](../specs/design-system/capabilities.md#emulator-presets).

```bash
ui-gallery --render --page primitives --emulator kitty --degradations
ui-gallery --tui --emulator tmux --profile enhanced
```

Presets are not a ladder: kitty has key releases WezTerm lacks, and WezTerm
clusters graphemes where kitty does not. A preset combines with a profile by
taking what both allow.

## How a glyph degrades

A component asks for the richest glyph it wants; the target caps it when the
frame is painted. Every glyph has a published ladder of one-cell stand-ins
ending in ASCII — see [Glyphs](./glyphs.md) — so a column never shifts between
a Nerd Font terminal and a pipe, and nothing the target cannot show reaches it.

## The degradation report

What a frame gave up is never silent. Each substitution the target forced is
counted and named, with the capability it lacked:

```text
color-dropped ×68 (colorDepth)
ascii-border ×7 (unicode)
ascii-glyph ×2 (unicode)
radius-dropped ×1 (radius)
alpha-flattened ×3 (alpha)
```

`ui-gallery --render --degradations` prints it for any page and profile, and
every catalog page shows it for all three.

## Catalog

| Page                                        | What it shows                      |
| ------------------------------------------- | ---------------------------------- |
| [Welcome](./catalog/welcome.md)             | what this build is                 |
| [Primitives](./catalog/primitives.md)       | the ten widget kinds               |
| [Layout](./catalog/layout.md)               | sizing, spacing, alignment         |
| [Tracks](./catalog/tracks.md)               | the grid subset, resolved live     |
| [Text](./catalog/text.md)                   | wrapping and measurement           |
| [Themes](./catalog/themes.md)               | thirty-six built-ins, live         |
| [Slots](./catalog/slots.md)                 | the semantic colour vocabulary     |
| [Decoration](./catalog/decoration.md)       | box and text chrome                |
| [Grid](./catalog/grid.md)                   | Cartesian backdrop, lines and dots |
| [Components](./catalog/components.md)       | the application chrome             |
| [Tree](./catalog/tree.md)                   | data, interaction, view            |
| [Property tree](./catalog/property-tree.md) | one value, reflected               |
| [Table](./catalog/table.md)                 | one grid, two views                |
| [Scrolling](./catalog/scrolling.md)         | one thumb formula                  |
| [State](./catalog/state.md)                 | the interaction machines           |
| [Split](./catalog/split.md)                 | a divider between two panes        |
| [Dock](./catalog/dock.md)                   | panes as a value                   |
| [Terminal](./catalog/terminal.md)           | a shell as a widget                |
