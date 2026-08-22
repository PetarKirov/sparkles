# Notcurses — a cell target that addresses below the cell

**Category:** cell-only, sub-cell. **Last reviewed:** August 22, 2026.
Pinned at [`b26048ee`][rev]; capability notes from the [project wiki][wiki].

On the list for one question. Friction §5 says `sparkles:ui` spells sub-cell
placement as a compass direction (`RuleEdge.top`, `centerX`, …) because the
toolkit has no unit below a cell. Notcurses is a terminal library that
routinely addresses below the cell, so it has had to answer this without the
luxury of continuous coordinates that Slint and Qt enjoy.

## Q5 — name a fidelity, not a position

Notcurses' answer is the **blitter**: a family of encodings that trade
resolution against terminal support, chosen per draw.

| Blitter           | Sub-cell resolution | Mechanism                              |
| ----------------- | ------------------- | -------------------------------------- |
| `NCBLITTER_1x1`   | none                | spaces + background colour; ASCII-safe |
| `NCBLITTER_2x1`   | 2 vertical          | upper/lower half blocks                |
| `NCBLITTER_2x2`   | 4                   | quadrants and three-quarter blocks     |
| `NCBLITTER_3x2`   | 6                   | sextants, left/right half blocks       |
| `NCBLITTER_4x2`   | 8                   | Braille                                |
| `NCBLITTER_PIXEL` | true pixels         | Sixel, Kitty, or iTerm2 protocol       |

The caller says _how finely_ it wants to draw; the library says what the
terminal can actually do. That is a different axis from ours entirely: we
enumerate six **positions** a hairline may occupy, they enumerate seven
**resolutions** a cell may be subdivided into. Ours grows an enumerator every
time a new place needs a thin thing; theirs does not, because position falls
out of the resolution.

## Q2 — degradation is automatic, and refusable

Two details worth taking:

- **Automatic downgrade.** In ASCII mode every blitter degrades to
  `NCBLITTER_1x1`. The caller does not branch on terminal capability.
- **`NCVISUAL_OPTION_NODEGRADE`.** The caller can _refuse_ the downgrade and
  get a failure instead.

That pairing is better than either alone. Degrading by default keeps callers
simple; being able to opt out means a caller that genuinely needs fidelity —
a golden test, a pixel-exact preview — finds out rather than silently rendering
something else. `sparkles:ui` has the first half (a canvas without `rule` paints
a whole-cell line) and none of the second: there is no way to ask for a hairline
and be told no.

Capability itself is discovered by "advanced and extensive runtime querying" of
terminfo and terminal identification, which is `sparkles:base.term_caps`'
territory rather than the drawing seam's.

## Q1 — measurement

The frame is built per cell — "an extended grapheme cluster, foreground colour,
background colour, and style for each cell" — so advance is a Unicode property
resolved above the blitter, not something a blitter answers. Consistent with
Slint, Qt and egui: **not the painter's job**, even here.

## Q3, Q4, Q6, Q7, Q8

- **Q3:** primitives over planes (`ncplane`), not widgets.
- **Q4:** no reified command stream; direct calls against a plane.
- **Q6:** resolved — each cell carries concrete fg/bg/style.
- **Q7:** the plane owns its cells; there is no borrowed-payload problem
  because there is no deferred command to outlive a frame.
- **Q8:** planes have explicit dimensions, so extent is a property of the
  target, as in Qt.

## Bearing on the proposal

1. **Replace `RuleEdge` with a resolution, not more enumerators.** A seam that
   says "draw this at hairline fidelity within this rect" lets a pixel backend
   use one device pixel, a cell backend fill a cell, and a sextant-capable
   terminal do something in between — without the toolkit naming positions.
2. **Add the refusable half of degradation.** Silent degradation is right by
   default and wrong when a caller is verifying output.
3. Confirms that even a cell-native library keeps text advance above the
   drawing layer.

[rev]: https://github.com/dankamongmen/notcurses/tree/b26048eebc74d5d254717d3332fa484718f9efe6
[wiki]: https://nick-black.com/dankwiki/index.php/Notcurses
