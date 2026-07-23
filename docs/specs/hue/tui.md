# `hue` TUI — Feature Requirements (full-screen terminal viewer)

_**Status:** planned (extends the shipped previewer) · **Date:** 2026-07-23 ·
**Scope:** the interactive **terminal** mode — a full-screen TUI with scrolling,
a scrollbar, mouse support, selection, wrapping, line numbers, and the markdown
preview. It grows the current minimal theme-selection previewer (`previewer.d`,
[`PRV*`](./feature-requirements.md)) into a terminal port of the [GUI](./gui.md)
viewer._

> [!NOTE]
> Today's interactive tty mode is a **minimal theme-selection previewer** — a
> viewport slice with ↑/↓ theme cycling ([`PRV1`–`PRV8`](./feature-requirements.md),
> shipped). This document specifies the **full TUI** it becomes; every row here is
> `not started` unless it cites a `PRV`/`NFR` commit for a capability the
> previewer already has (marked `partial`). Status legend and ID conventions: see
> the [overview](./index.md).

## Design & scope

The full TUI is the **same interactive viewer as the [GUI](./gui.md), painted
into terminal cells instead of GPU quads.** It consumes hue's identical
`(source, events, theme)` triple and — crucially — **reuses the GUI's
raylib-free layout unchanged**: `gui_preview.d` (`layoutPreview`/`buildRawPlines`
→ the wrapped `PreviewLine[]` model) and `gui_text.d` (pure metrics/search) are
already terminal-independent and unit-tested. The TUI is therefore a **second
painter over the same `PreviewLine[]`**, not a parallel layouter — the GUI's
[`RND2`](./gui.md) ("one wrapped visual-line list, painted by a single painter")
generalizes across backends.

Three things the GUI gets from raylib that the TUI must supply itself: **input**
(SGR mouse + an expanded key vocabulary), **clipboard** (OSC 52, there being no
windowing clipboard API), and the **surface** (the alt-screen cell grid, which the
shipped previewer already manages). Two things get _simpler_ in a terminal: the
grid is natively monospace ([`RND6`](./gui.md) is free), box-drawing glyphs render
without gaps (the [`BOX`](./gui.md) GPU workaround is unnecessary), and ` ```ansi `
fences can be **passed straight to the real terminal** instead of decoded through
an off-screen VT ([`MDP12`](./gui.md) / `sparkles:ghostty`).

## GUI → TUI parity map

How each GUI requirement area applies to the TUI. **full** = ports directly ·
**best-effort** = ports with a terminal caveat · **n/a** = not a terminal concern ·
**future** = backend-agnostic, deferred with the GUI's. All GUI areas are in
[gui.md](./gui.md); IDs below are bare references into it.

| GUI area                     | Applies                    | Terminal note                                                                                                                |
| ---------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `RND` render model           | full                       | same wrapped `PreviewLine[]`; `byStyledLine`/`toRgb` fold to **SGR** runs; the terminal is natively monospace (`RND6` free)  |
| `VIW` views & toggle         | full                       | raw + markdown preview, Tab toggles                                                                                          |
| `WRP` wrapping               | full                       | same soft/hard wrap; reflow on `SIGWINCH` (`TSF2`)                                                                           |
| `NUM` line numbers           | full                       | file gutter + per-code-block gutter, in cells                                                                                |
| `NAV` navigation & scroll    | full                       | wheel (SGR mouse), `j`/`k`, PageUp/Down, Home/End, goto-line                                                                 |
| `SCB` scrollbar              | best-effort → `TSB`        | cell-column bar, block-glyph thumb, mouse drag / track-click; no smooth width easing                                         |
| `THG` live theme cycling     | full _(partial now)_       | ←/→ cycle — the shipped previewer already does this (`PRV2`)                                                                 |
| `FND` search & goto          | full                       | incremental search; matches via reverse-video / tint                                                                         |
| `MDP` markdown constructs    | best-effort → `MDP` (here) | all decorations; Nerd-glyph dependence like `FNT8`; box-drawing is native; ` ```ansi ` fences pass through the real terminal |
| `COD` code blocks            | full (best-effort)         | code gutter + highlighted body + border via native box glyphs; copy region + OSC 52 (`TCL`)                                  |
| `SEL` selection & clipboard  | best-effort → `TSL`        | app-level drag-select → source offsets; clipboard via OSC 52; suppresses the terminal's native selection                     |
| `FNT` font                   | n/a                        | the terminal owns the font/cell; bold/italic/underline → SGR attributes (the `FNT5` analog)                                  |
| `WIN` window & lifecycle     | n/a                        | no window; the alt-screen is the surface; resize arrives as `SIGWINCH`                                                       |
| `FSC` fullscreen             | n/a                        | the terminal emulator's concern, not hue's                                                                                   |
| `BOX` procedural box-drawing | n/a _(solved)_             | box glyphs render natively without gaps — the GPU arms-to-edges workaround isn't needed                                      |
| `DBG` debug/CI hooks         | best-effort                | a headless frame-dump analog for golden capture (the previewer already assembles a frame buffer)                             |
| `SEM` semantic refinement    | future                     | backend-agnostic, deferred with the GUI's `SEM1`                                                                             |

## Terminal input (`TIN`)

| ID   | Requirement                                                                                                                                                                                                                  | Status      | Traces to                                            |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------- |
| TIN1 | The input layer must decode an **expanded key vocabulary** — arrows, PageUp/Down, Home/End, Tab, Enter, Ctrl-C, and printable characters (for search / goto) — beyond the shipped minimal `Key{up,down,enter,cancel,other}`. | not started | `core-cli` `key_input.d` (must grow / be superseded) |
| TIN2 | **SGR mouse tracking** (mode 1006 + 1000/1002) must be enabled on entry and disabled on exit; press / release / drag / wheel events with button + modifiers must decode to `(row, col)` cell coordinates.                    | not started | proposed mouse decoder (`core-cli`)                  |
| TIN3 | Wheel events must scroll (`NAV`); left press/drag/release must drive selection (`TSL`); clicks must hit-test the scrollbar (`TSB`), the code-block copy region (`COD`), and notifier popup items ([`NTF6`](./notifier.md)).  | not started | `previewer.d` input dispatch (proposed)              |
| TIN4 | Mouse tracking must be **restored** (disabled) on exit, signal, and crash, so the terminal is never left in mouse mode.                                                                                                      | not started | `scope(exit)` / signal handler (proposed)            |

## Terminal clipboard (`TCL`)

| ID   | Requirement                                                                                                                        | Status      | Traces to               |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------- |
| TCL1 | Copy must write to the system clipboard via **OSC 52** (base64) — the only portable in-band terminal clipboard; no read is needed. | not started | proposed OSC 52 writer  |
| TCL2 | A terminal without OSC 52 support must **degrade** — show a status message instead; copy must never block or corrupt the screen.   | not started | `TCP1` capability probe |

## Surface & frame (`TSF`)

Extends the shipped previewer's frame discipline.

| ID   | Requirement                                                                                                                                                          | Status                          | Traces to                                           |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- | --------------------------------------------------- |
| TSF1 | The TUI must render into the **alt-screen** (hide cursor), one **synchronized-output** frame per repaint, assembled into a single buffer and flushed with one write. | partial (`844680a3`/`0657c94a`) | `PRV7`/`PRV8`; `NFR2` (previewer already does this) |
| TSF2 | The wrapped `PreviewLine[]` must **reflow on terminal resize** (`SIGWINCH`) — rebuilt at the new column width (the `WRP4` analog).                                   | not started                     | proposed `SIGWINCH` handler                         |
| TSF3 | The TUI must **reuse the GUI's raylib-free layout** (`gui_preview.d` `layoutPreview`/`buildRawPlines`, `gui_text.d`) unchanged — one layouter, two painters.         | not started                     | `gui_preview.d`; `gui_text.d`                       |
| TSF4 | The per-frame paint core should stay **`@nogc nothrow`** ([`NFR1`](./feature-requirements.md)); load-time layout may allocate, as the GUI's does.                    | partial                         | `previewer.d` `@nogc` core (`NFR1`)                 |

> [!NOTE]
> `TSF3` pulls `gui_preview.d` (and, for ` ```ansi ` fences, potentially
> `gui_ansi.d`/`sparkles:ghostty`) into the default terminal build. Reconcile
> with [`NFR3`](./feature-requirements.md) / the `no-gui` build
> ([`BLD2`](./feature-requirements.md)) — the preview layout is raylib-free, but
> the off-screen VT is not needed in a real terminal (fences pass through), so the
> TUI can take the layout without the VT dependency.

## Scrollbar (`TSB`, best-effort → gui.md `SCB`)

| ID   | Requirement                                                                                                                                                                           | Status      | Traces to                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------- |
| TSB1 | A scrollbar must occupy the right gutter column and appear only when content exceeds the viewport; the thumb size/position reflect the visible fraction and scroll progress (`SCB1`). | not started | proposed cell scrollbar    |
| TSB2 | The thumb must be **draggable** and the track **click-to-page/center** via SGR mouse (`SCB4`); the wheel scrolls (`NAV`).                                                             | not started | `TIN2`/`TIN3` dispatch     |
| TSB3 | The bar must render with block glyphs (`▏▎▍▐█` / half-blocks); hover-expansion is approximated (no smooth easing — `SCB2` degrades).                                                  | not started | proposed block-glyph thumb |

## Selection & clipboard (`TSL`, best-effort → gui.md `SEL`)

| ID   | Requirement                                                                                                                                                                                                            | Status      | Traces to                                     |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------- |
| TSL1 | Left-drag must select **content only** as a half-open **byte range into the original source** (`SEL1`/`SEL2`); gutters, line numbers, borders, and decorations are excluded, and the range survives wrapping (`SEL3`). | not started | reuse `PreviewRun.srcStart` (`gui_preview.d`) |
| TSL2 | The selection must be tinted (reverse-video / SGR); a copy key must write `source[a..b]` to the clipboard via **OSC 52** (`TCL1`) — the terminal analog of `SEL4`.                                                     | not started | selection pass; `TCL1`                        |
| TSL3 | App-level mouse selection requires SGR mouse tracking, which **suppresses the terminal emulator's native selection** — hue must provide its own; ` ```ansi ` and table runs remain unmapped to source (`SEL6`).        | not started | `TIN2`; synthetic runs lack `srcStart`        |

## Markdown preview in the terminal (`MDP`, best-effort → gui.md `MDP`)

The GUI's markdown constructs (`MDP*`) all port; the terminal-specific deltas:

| ID     | Requirement                                                                                                                                                                                                                  | Status      | Traces to                       |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------- |
| MDP-T1 | All render-markdown decorations (heading icons, bullets, checkboxes, callouts, quote bars, link/lang icons, aligned tables) must render in cells; Nerd-glyph fidelity depends on the terminal font, like [`FNT8`](./gui.md). | not started | reuse `layoutPreview` (`TSF3`)  |
| MDP-T2 | Box-drawing (tables, code-block borders, quote rules) must use the **native terminal glyphs** — no procedural `drawBox`; a real terminal renders `─│┼╭╮╰╯` without gaps.                                                     | not started | native SGR box glyphs           |
| MDP-T3 | ` ```ansi ` fences must be rendered by **passing the fence bytes through to the terminal** (which is itself a VT), rather than decoding through the off-screen `sparkles:ghostty` VT the GUI needs (`MDP12`).                | not started | pass-through (no off-screen VT) |

## Capabilities & degradation (`TCP`)

| ID   | Requirement                                                                                                                                                                            | Status            | Traces to                         |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------- |
| TCP1 | On entry the TUI must probe tty status, color depth ([`CLR1`](./feature-requirements.md)), mouse, and OSC 52 support, and adapt (no mouse → keyboard-only; no OSC 52 → copy disabled). | not started       | `core-cli` `term_caps.d`          |
| TCP2 | A non-tty invocation must fall through to the **non-interactive ANSI** whole-file emit ([`MOD3`/`MOD5`](./feature-requirements.md)) — the full TUI is only for interactive ttys.       | full (`74d8f6a3`) | `interactive` gate (general spec) |
| TCP3 | Nerd-glyph decorations depend on the terminal font (the `FNT8` doctrine); a non-Nerd terminal font shows tofu — acceptable and documented.                                             | not started       | decoration glyph sites            |

## Milestones

| Milestone | Scope                                                                | Status            | Requirements                        |
| --------- | -------------------------------------------------------------------- | ----------------- | ----------------------------------- |
| T0        | Minimal theme-selection previewer (viewport slice + ↑/↓ theme cycle) | full (`74d8f6a3`) | `PRV*` (baseline)                   |
| T1        | Viewport scrolling over the reused GUI wrapped-line layout           | not started       | `TSF3`, `RND`/`VIW`/`WRP`/`NUM`     |
| T2        | SGR mouse + wheel + the cell scrollbar                               | not started       | `TIN`, `TSB`, `NAV`                 |
| T3        | Selection → source offsets + OSC 52 copy                             | not started       | `TSL`, `TCL`, `SEL` parity          |
| T4        | Markdown-preview parity + code blocks + incremental search           | not started       | `MDP-T*`, `COD`, `FND`              |
| T5        | Notifier popups in the terminal                                      | not started       | [notifier.md](./notifier.md) `NTF6` |

## Module coverage (TUI)

| Source                                                      | Requirements                                          |
| ----------------------------------------------------------- | ----------------------------------------------------- |
| `apps/hue/src/previewer.d` (extended to a full viewer)      | `TSF*`, `TSB*`, `TSL*`, `MDP-T*`, `TCP*`, `PRV*`      |
| `apps/hue/src/gui_preview.d` / `gui_text.d` (reused as-is)  | `TSF3` (shared layout); `RND`/`WRP`/`NUM`/`SEL` model |
| `sparkles:core-cli` `key_input.d` (expanded), `term_caps.d` | `TIN*`, `TCP1`                                        |
| OSC 52 writer (proposed)                                    | `TCL*`                                                |

→ [GUI requirements](./gui.md) · [General requirements](./feature-requirements.md) · [Notifier](./notifier.md) · [Overview](./index.md)
