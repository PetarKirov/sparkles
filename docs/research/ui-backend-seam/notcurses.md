# Notcurses — a cell target that addresses below the cell

**Category:** cell-only, sub-cell. **Last reviewed:** August 23, 2026.
Pinned at [`b26048ee`][rev]; capability notes from the [project wiki][wiki].

On the list for one question. Friction §5 says `sparkles:ui` spells sub-cell
placement as a compass direction (`RuleEdge.top`, `centerX`, …) because the
toolkit has no unit below a cell. Notcurses is a terminal library that
routinely addresses below the cell, so it has had to answer this without the
luxury of continuous coordinates that Slint and Qt enjoy.

| Field                | Value                                                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | C (with C++, Python, Rust and Nim bindings in-tree or adjacent)                                                                           |
| **License**          | Apache-2.0 ([`COPYRIGHT`][copyright]; `src/fetch/ncart.c` is MIT, from Neofetch)                                                          |
| **Repository**       | [`dankamongmen/notcurses`][repo]                                                                                                          |
| **Documentation**    | [notcurses.com man pages][man], [dankwiki][wiki], [`USAGE.md`][usage], [`TERMINALS.md`][terminals]                                        |
| **Category**         | cell-only, sub-cell                                                                                                                       |
| **Pinned revision**  | [`b26048eebc74d5d254717d3332fa484718f9efe6`][rev]                                                                                         |
| **Target range**     | terminal emulators only — but spanning ASCII-only through sextant/octant fonts to Sixel/Kitty/iTerm2 pixel graphics                       |
| **Backends shipped** | one renderer, many _terminals_: capability is probed per terminal via terminfo plus terminal identification ([`TERMINALS.md`][terminals]) |
| **The seam**         | `ncplane` (a cell grid) plus `ncblitter_e` — a fidelity ladder chosen per draw                                                            |
| **The intermediate** | `nccell` — 16 bytes: an EGC reference, fg, bg, style ([`notcurses.h`][header])                                                            |

## Overview

### What it solves

Terminals differ not in _which drawing calls_ they accept — they all accept
cells — but in _how finely a cell can be subdivided_: half blocks, quadrants,
sextants, octants, Braille, or real pixels via Sixel/Kitty/iTerm2. Notcurses'
problem is to let a caller draw an image or a plot at the best fidelity the
terminal in front of it can manage, without the caller branching on terminal
identity.

### Design philosophy

The library's own framing of what it is and is not
([`README.md`][readme]):

> **What it is**: a library facilitating complex TUIs on modern terminal
> emulators, supporting vivid colors, multimedia, threads, and Unicode to the
> maximum degree possible. […] **What it is not**: a source-compatible X/Open
> Curses implementation, nor a replacement for NCURSES on existing systems.

And, from the `nccell` commentary, the sentence that decides Q1 for this
subject ([`notcurses.h`][header]):

> Existence is suffering, and thus wcwidth() is not reliable. It's just quoting
> whether or not the EGC contains a "Wide Asian" double-width character. […]
> True display width is a _function of the font and terminal_.

A library that says display width is a function of the font and the terminal
has already decided it cannot be a property of the drawing call.

## Q1 — measurement

The frame is built per cell — an `nccell` holds "a theoretically arbitrarily
long UTF-8 EGC, a foreground color, a background color, and an attribute set"
([`notcurses.h`][header]) — so advance is a Unicode property resolved above the
blitter, not something a blitter answers. Width is exposed as a free function
over a string, `ncstrwidth(const char* egcs, int* validbytes, int* validwidth)`,
not as a method on any drawing object.

Consistent with Slint, Qt and egui: **not the painter's job**, even here.

## Q2 — degradation is automatic, and refusable

Two details worth taking:

- **Automatic downgrade, as an explicit ladder.** `lookup_blitset` in
  [`blit.c`][blit] is the whole policy: `NCBLIT_BRAILLE` decays to `NCBLIT_4x2`
  without Braille support, `NCBLIT_4x2` to `NCBLIT_3x2` without octants,
  `NCBLIT_PIXEL` to `NCBLIT_3x2` without bitmaps, `NCBLIT_3x2` to `NCBLIT_2x2`
  without sextants, `NCBLIT_2x2` to `NCBLIT_2x1` without quadrants, and
  `NCBLIT_2x1` to `NCBLIT_1x1` without half blocks — ending in
  `assert(NCBLIT_1x1 == setid)`. The caller does not branch on terminal
  capability, and `NCBLIT_1x1` is the floor by construction.
- **`NCVISUAL_OPTION_NODEGRADE`.** The caller can _refuse_ the downgrade and
  get a failure instead — "If the specified blitter is not available, fail
  rather than degrading" ([`notcurses_visual.3.md`][visualman]). The same
  function implements both halves through one `bool may_degrade` parameter,
  and the plot API carries its own `NCPLOT_OPTION_NODEGRADE`.

That pairing is better than either alone. Degrading by default keeps callers
simple; being able to opt out means a caller that genuinely needs fidelity —
a golden test, a pixel-exact preview — finds out rather than silently rendering
something else. `sparkles:ui` has the first half (a canvas without `rule` paints
a whole-cell line) and none of the second: there is no way to ask for a hairline
and be told no.

Capability itself is discovered by "advanced and extensive runtime querying" of
terminfo and terminal identification, which is `sparkles:base.term_caps`'
territory rather than the drawing seam's.

## Q3 — primitives over planes

Primitives over planes (`ncplane`), not widgets. Notcurses _ships_ widgets —
`ncselector`, `ncreel`, `ncprogbar`, `nctabbed` and more are declared in
[`notcurses.h`][header] — but they are built on planes and cells, and none of
them reaches the blitter as a named operation. The seam is the plane; the
widget vocabulary lives entirely above it.

## Q4 — command shape

No reified command stream; direct calls against a plane, which then holds the
result. Like [Ratatui][ratatui], the thing that persists between "drawing" and
"output" is the _grid_, not the instructions — so the recording, comparison and
replay properties `RecordingCanvas` gives us come from the cell buffer here
rather than from an op stream.

## Q5 — name a fidelity, not a position

Notcurses' answer is the **blitter**: a family of encodings that trade
resolution against terminal support, chosen per draw. The enum
([`notcurses.h`][header], mirrored in [`notcurses_visual.3.md`][visualman]):

| Blitter          | Sub-cell resolution | Mechanism                                        |
| ---------------- | ------------------- | ------------------------------------------------ |
| `NCBLIT_DEFAULT` | chosen for you      | "let the ncvisual pick"                          |
| `NCBLIT_1x1`     | none                | spaces + background colour; works in ASCII       |
| `NCBLIT_2x1`     | 2 vertical          | adds half blocks (▄▀)                            |
| `NCBLIT_2x2`     | 4                   | adds left/right halves (▌▐) and quadrants (▖▗▟▙) |
| `NCBLIT_3x2`     | 6                   | adds sextants                                    |
| `NCBLIT_4x2`     | 8                   | adds octants                                     |
| `NCBLIT_BRAILLE` | 8 (4 rows × 2 cols) | Braille                                          |
| `NCBLIT_PIXEL`   | true pixels         | Sixel, Kitty, or iTerm2 protocol                 |

Two further enumerators, `NCBLIT_4x1` and `NCBLIT_8x1`, add quarter and eighth
vertical blocks; they are "intended for use with plots, and are not really
applicable for general visuals" ([`notcurses_visual.3.md`][visualman]).

The caller says _how finely_ it wants to draw; the library says what the
terminal can actually do. That is a different axis from ours entirely: we
enumerate six **positions** a hairline may occupy, they enumerate seven
general-purpose **resolutions** a cell may be subdivided into. Ours grows an
enumerator every time a new place needs a thin thing; theirs does not, because
position falls out of the resolution.

> [!NOTE]
> An earlier pass on this subject spelled these `NCBLITTER_*`. The symbols are
> `NCBLIT_*`; the table above is transcribed from the enum at the pinned
> revision.

## Q6 — resolved or semantic styling

Resolved — each `nccell` carries a concrete foreground, background and style,
with alpha bits for the small compositing model the header documents. There is
no semantic role to re-resolve, because there is no consumer below the cell
that could resolve one differently.

## Q7 — payload ownership

The plane owns its cells. An `nccell` is 16 static bytes and stores longer
grapheme clusters by reference into the plane's own `egcpool`
([`notcurses.h`][header]), so a payload's lifetime is the plane's. There is no
borrowed-payload problem because there is no deferred command to outlive a
frame.

## Q8 — extent query

Planes have explicit dimensions — `ncplane_dim_yx(const struct ncplane*, unsigned*, unsigned*)`
— so extent is a property of the target, as in Qt. Notcurses adds one wrinkle
`sparkles:ui` will meet: `ncvgeom` reports `maxpixely`/`maxpixelx`, defined
only for `NCBLIT_PIXEL` ([`notcurses.h`][header]), i.e. the _unit_ of the
extent answer depends on the fidelity chosen.

## Strengths

- **Fidelity is a named, ordered ladder**, so a caller expresses intent
  ("as fine as you can, at least quadrants") rather than a position.
- **The degradation policy is one function.** `lookup_blitset` is the entire
  fallback story, readable top to bottom, terminating in a provable floor.
- **Degradation is refusable** through the same code path
  (`bool may_degrade`), so correctness-sensitive callers are not second-class.
- **Position falls out of resolution**, so new sub-cell placements cost no new
  vocabulary.
- **Capability probing is separated from drawing** — terminfo and terminal
  identification, not a method on the plane.
- **A single 16-byte cell** makes the intermediate cheap enough to keep, diff
  and reason about.

## Weaknesses

- **The ladder is hard-coded, not data.** Adding a fidelity means editing a
  cascade of `if` statements in `blit.c` and the enum in lockstep.
- **The floor is an `assert`**, not a type: `assert(NCBLIT_1x1 == setid)` is
  the only statement that the bottom of the ladder is reachable.
- **`NCBLIT_BRAILLE` sits awkwardly in the ordering** — same nominal 8× density
  as `NCBLIT_4x2` but a different aspect ratio, and the man page warns it does
  not "tend to work out very well for images".
- **The extent unit is fidelity-dependent** (`maxpixely`/`maxpixelx` only for
  `NCBLIT_PIXEL`), so a caller must know which blitter it got before reading
  the answer.
- **Terminal-only by construction.** Nothing here is a seam a GPU backend could
  implement; the design's clarity comes from having exactly one device class.
- **Refusal is a flag, not a type.** `NODEGRADE` is duplicated per API family
  (`NCVISUAL_OPTION_NODEGRADE`, `NCPLOT_OPTION_NODEGRADE`) rather than being
  one policy.

## Key design decisions and trade-offs

| Decision                                                                              | Rationale                                                                                | Trade-off                                                                                            |
| ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Express sub-cell drawing as a **fidelity enum**, not coordinates                      | Terminals differ in resolution, not in geometry; one axis captures the whole difference  | The caller cannot ask for an _arbitrary_ sub-cell position — only for a subdivision the ladder names |
| Degrade **automatically** down a fixed ladder                                         | The common caller never branches on terminal identity                                    | The ladder's order encodes aesthetic judgements (Braille vs octants) that a caller cannot override   |
| Make degradation **refusable** (`NODEGRADE`, `may_degrade`)                           | Golden tests and pixel-exact previews must fail loudly rather than render something else | Two behaviours through one function; every caller must decide which it wants                         |
| Probe capability from **terminfo + terminal identification**, outside the drawing API | Keeps the drawing seam free of capability questions                                      | A large, terminal-specific database ([`TERMINALS.md`][terminals]) to maintain                        |
| **Plane owns its cells**, EGCs pooled per plane                                       | 16-byte cells stay cheap while arbitrary-length graphemes remain representable           | Cells are not self-contained values; a cell means nothing without its plane's pool                   |
| Widgets built **above** the plane, never at the seam                                  | The blitter never has to learn what a progress bar is                                    | A terminal with better native affordances cannot render a known widget its own way                   |
| Width as a **free function** (`ncstrwidth`), not a painter method                     | Display width is a property of font and terminal, not of a drawing call                  | The library must maintain its own width oracle rather than deferring to `wcwidth`                    |

## Bearing on the proposal

1. **Replace `RuleEdge` with a resolution, not more enumerators.** A seam that
   says "draw this at hairline fidelity within this rect" lets a pixel backend
   use one device pixel, a cell backend fill a cell, and a sextant-capable
   terminal do something in between — without the toolkit naming positions.
2. **Add the refusable half of degradation.** Silent degradation is right by
   default and wrong when a caller is verifying output.
3. Confirms that even a cell-native library keeps text advance above the
   drawing layer.
4. **Write the ladder as one function.** `lookup_blitset` is 80 lines and _is_
   the policy; `sparkles:ui`'s degradation is currently scattered across
   `__traits(compiles)` sites in the interpreter, which is the same decision
   made in a dozen places.

## Sources

Every path verified to resolve at
[`b26048eebc74d5d254717d3332fa484718f9efe6`][rev] over
`raw.githubusercontent.com`.

- The seam and the vocabulary:
  [`include/notcurses/notcurses.h`][header] — `ncblitter_e`, `nccell`,
  `ncplane_dim_yx`, `ncstrwidth`, `NCVISUAL_OPTION_NODEGRADE`,
  `NCPLOT_OPTION_NODEGRADE`
- The degradation policy: [`src/lib/blit.c`][blit] — `lookup_blitset`,
  `notcurses_blitters`
- The stated contract: [`doc/man/man3/notcurses_visual.3.md`][visualman]
  (`BLITTERS`, the `NODEGRADE` flag)
- Context: [`README.md`][readme], [`COPYRIGHT`][copyright],
  [`USAGE.md`][usage], [`TERMINALS.md`][terminals], [dankwiki][wiki],
  [notcurses.com][man]

<!-- References -->

[blit]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/blit.c
[copyright]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/COPYRIGHT
[header]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h
[man]: https://notcurses.com/
[ratatui]: ./ratatui.md
[readme]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/README.md
[repo]: https://github.com/dankamongmen/notcurses
[rev]: https://github.com/dankamongmen/notcurses/tree/b26048eebc74d5d254717d3332fa484718f9efe6
[terminals]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/TERMINALS.md
[usage]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/USAGE.md
[visualman]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/doc/man/man3/notcurses_visual.3.md
[wiki]: https://nick-black.com/dankwiki/index.php/Notcurses
