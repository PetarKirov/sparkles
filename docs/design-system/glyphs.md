# Glyphs

What a cell target draws for each glyph the components ask for, and what it
draws instead when it cannot. The rules are
[`GLY1`–`GLY3`](../specs/design-system/glyphs.md); the tables here are the ones
in `sparkles.ui.glyphs` and `sparkles.ui.tokens`, whose tests walk them
exhaustively.

## Tiers

A glyph needs something of its target, and the needs nest:

| Needs       | Glyphs                                     | Target flag         |
| ----------- | ------------------------------------------ | ------------------- |
| nothing     | ASCII                                      | —                   |
| Unicode     | box drawing, marks, arrows, any other text | `unicode`           |
| half blocks | `▀ ▄ █`, the eighth blocks `▏ … ▉`, shades | `blocks ≥ half`     |
| quadrants   | the 2×2 quadrants `▖ ▗ ▘ ▝ …`              | `blocks ≥ quadrant` |
| sextants    | the 2×3 sextants (Legacy Computing)        | `blocks ≥ sextant`  |
| octants     | the 2×4 octants (Unicode 16)               | `blocks = octant`   |
| braille     | the 2×4 dot grid `⠁ … ⣿`                   | `braille`           |
| Nerd Font   | Private Use Area icons                     | `nerdFont`          |

## Ladders

When the target lacks a glyph's tier, the glyph steps down to a weaker one —
always one cell wide, always ending in ASCII:

| Asked for                                        | Steps to                              |
| ------------------------------------------------ | ------------------------------------- |
| a Nerd Font status icon                          | its Unicode mark, then its ASCII mark |
| another Nerd Font icon                           | `?`                                   |
| a braille cell, a quadrant, a sextant, an octant | `▒`, then `:`                         |
| an eighth-block bar `▏ ▎`                        | `│`, then <code>&#124;</code>         |
| a half-block bar `▍ ▌ ▐`                         | `┃`, then <code>&#124;</code>         |
| a fill `█ ▓ ▀ ▄ …`                               | `#`                                   |
| a box-drawing run `─ ━ ═`                        | `-`                                   |
| a box-drawing run `│ ┃ ║`                        | <code>&#124;</code>                   |
| a dotted run `┈ ┄` / `┊ ┆`                       | `.` / `:`                             |
| a corner or a junction                           | `+`                                   |
| `▸ → ›` / `◂ ← ‹` / `▾ ↓` / `▴ ↑`                | `>` / `<` / `v` / `^`                 |
| `· • ▪ ◆` / `▫ □ ◇` / `○`                        | `*` / `.` / `o`                       |
| `— –` / `…`                                      | `-` / `~`                             |
| anything else, e.g. `π` or `日`                  | `?` in each of its cells              |

## Status marks

Status is never shown by color alone. Each status has a mark in three
charsets; a theme names the charset it prefers and the target caps it:

| Status  | Nerd Font                    | Unicode | ASCII |
| ------- | ---------------------------- | ------- | ----- |
| ok      | `nf-fa-check`                | `✔`     | `+`   |
| fail    | `nf-fa-xmark`                | `✖`     | `x`   |
| warn    | `nf-fa-triangle_exclamation` | `⚠`     | `!`   |
| info    | `nf-fa-circle_info`          | `•`     | `*`   |
| pending | `nf-fa-circle`               | `○`     | `o`   |
| running | `nf-fa-spinner`              | `◐`     | `~`   |
| skipped | `nf-fa-minus`                | `┄`     | `.`   |

## Borders

A bordered box always reserves one cell per drawn edge; the border's width,
style and radius choose the glyphs in that cell:

| Border            | Unicode target | Without Unicode |
| ----------------- | -------------- | --------------- |
| 1px solid         | `┌─┐ │ └─┘`    | `+-+ \| +-+`    |
| 1px solid, radius | `╭─╮ │ ╰─╯`    | `+-+ \| +-+`    |
| 2px solid         | `┏━┓ ┃ ┗━┛`    | `+-+ \| +-+`    |
| dashed            | `┌╌┐ ╎ └╌┘`    | `+-+ \| +-+`    |
| dotted            | `┌┈┐ ┊ └┈┘`    | `+.+ : +.+`     |
| double            | `╔═╗ ║ ╚═╝`    | `+-+ \| +-+`    |

The heavy and double families have no rounded corners. A border both heavy and
rounded keeps its arcs, drawn light, and reports the weight lost; a rounded
double border keeps square corners and reports the radius lost. The [Decoration](./catalog/decoration.md)
page shows every row.
