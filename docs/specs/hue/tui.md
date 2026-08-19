# `hue` TUI — Feature Requirements (full-screen terminal viewer)

_**Status:** shipped (T1–T4); T5 outstanding · **Date:** 2026-07-29 ·
**Scope:** the interactive **terminal** mode — a full-screen TUI with scrolling,
a scrollbar, mouse support, selection, wrapping, line numbers, and the markdown
preview. It is the terminal port of the [GUI](./gui.md) viewer._

> [!NOTE]
> The full-screen viewer **is shipped** (`tui.d`, on `sparkles:tui`) and is the
> interactive tty mode on POSIX. The older minimal theme-selection previewer
> (`previewer.d`, [`PRV1`–`PRV8`](./feature-requirements.md)) survives only as the
> non-POSIX fallback and is scheduled for removal, with theme selection folding
> into this viewer as a widget overlay — see
> [ui-architecture.md](./ui-architecture.md) `UIA4`. Status legend and ID
> conventions: see the [overview](./index.md).

## Design & scope

The full TUI is the **same interactive viewer as the [GUI](./gui.md), painted
into terminal cells instead of GPU quads.** It consumes hue's identical
`(source, events, theme)` triple and — crucially — **reuses the GUI's
raylib-free views unchanged**: the shared widget views (`viewMarkdown` /
`viewCodeDocument` / `viewTwoslashDocument`) and `gui_text.d` (pure metrics/search) are
already terminal-independent and unit-tested. The TUI is therefore a **second
canvas over the same widget trees**, not a parallel layouter — the GUI's
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

| GUI area                     | Applies                      | Terminal note                                                                                                                |
| ---------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `RND` render model           | full                         | the same widget trees, painted into cells (`paintGrid`); the terminal is natively monospace (`RND6` free)                    |
| `VIW` views & toggle         | full                         | raw + markdown preview, Tab toggles                                                                                          |
| `WRP` wrapping               | full                         | same soft/hard wrap; reflow on `SIGWINCH` (`TSF2`)                                                                           |
| `NUM` line numbers           | full                         | file gutter + per-code-block gutter, in cells                                                                                |
| `NAV` navigation & scroll    | full                         | wheel (SGR mouse), `j`/`k`, PageUp/Down, Home/End, goto-line                                                                 |
| `SCB` scrollbar              | best-effort → `TSB`          | cell-column bar, block-glyph thumb, mouse drag / track-click; no smooth width easing                                         |
| `THG` live theme cycling     | full _(partial now)_         | ←/→ cycle — the shipped previewer already does this (`PRV2`)                                                                 |
| `FND` search & goto          | full                         | incremental search; matches via reverse-video / tint                                                                         |
| `MDP` markdown constructs    | best-effort → `MDP-T` (here) | all decorations; Nerd-glyph dependence like `FNT8`; box-drawing is native; ` ```ansi ` fences pass through the real terminal |
| `COD` code blocks            | full (best-effort)           | code gutter + highlighted body + border via native box glyphs; copy region + OSC 52 (`TCL`)                                  |
| `SEL` selection & clipboard  | best-effort → `TSL`          | app-level drag-select → source offsets; clipboard via OSC 52; suppresses the terminal's native selection                     |
| `FNT` font                   | n/a                          | the terminal owns the font/cell; bold/italic/underline → SGR attributes (the `FNT5` analog)                                  |
| `WIN` window & lifecycle     | n/a                          | no window; the alt-screen is the surface; resize arrives as `SIGWINCH`                                                       |
| `FSC` fullscreen             | n/a                          | the terminal emulator's concern, not hue's                                                                                   |
| `BOX` procedural box-drawing | n/a _(solved)_               | box glyphs render natively without gaps — the GPU arms-to-edges workaround isn't needed                                      |
| `DBG` debug/CI hooks         | best-effort                  | a headless frame-dump analog for golden capture (the previewer already assembles a frame buffer)                             |
| `SEM` semantic refinement    | future                       | backend-agnostic, deferred with the GUI's `SEM1`                                                                             |

## Terminal input (`TIN`)

| ID   | Requirement                                                                                                                                                                                                                  | Status               | Traces to                                            |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ---------------------------------------------------- |
| TIN1 | The input layer must decode an **expanded key vocabulary** — arrows, PageUp/Down, Home/End, Tab, Enter, Ctrl-C, and printable characters (for search / goto) — beyond the shipped minimal `Key{up,down,enter,cancel,other}`. | full (`dd70e1b4`)    | `core-cli` `key_input.d` (must grow / be superseded) |
| TIN2 | **SGR mouse tracking** (mode 1006 + 1000/1002) must be enabled on entry and disabled on exit; press / release / drag / wheel events with button + modifiers must decode to `(row, col)` cell coordinates.                    | full (`b8809549`)    | proposed mouse decoder (`core-cli`)                  |
| TIN3 | Wheel events must scroll (`NAV`); left press/drag/release must drive selection (`TSL`); clicks must hit-test the scrollbar (`TSB`), the code-block copy region (`COD`), and notifier popup items ([`NTF6`](./notifier.md)).  | partial (`b8809549`) | `previewer.d` input dispatch (proposed)              |
| TIN4 | Mouse tracking must be **restored** (disabled) on exit, signal, and crash, so the terminal is never left in mouse mode.                                                                                                      | full (`b8809549`)    | `scope(exit)` / signal handler (proposed)            |

## Keyboard policy (`TKB`)

| ID     | Requirement                                                                                                                                                                                                                                                                                                      | Status            | Traces to                                 |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------------- |
| `TKB1` | The terminal backends must resolve keys through the **one binding table** ([lantern](./lantern.md) `KEY1`), not a `switch` of their own. Both the viewer and the explorer carried one, and both had drifted from the window's.                                                                                   | full (`e71a9417`) | `tui.handleKey`; `explorer.handleCommand` |
| `TKB2` | The divergences that routing exposed are resolved **vim-correct**, not by picking a side: `gg` top, `Shift-G` bottom, `gl` go-to-line (both previous meanings survive because vim has both); `y` copies the selection everywhere and the ANSI-copy _mode_ moves to `<leader>uy`; `q` quits in both backends.     | full (`8e4b0250`) | [lantern](./lantern.md) `LMP3`–`LMP5`     |
| `TKB3` | `←`/`→` and `PgUp`/`PgDn` are **pane-scoped**: a focused tree navigates its rows as every tree does. This changed the window, not the terminal — the terminal explorer already behaved this way. Theme cycling keeps the arrows in the viewer and gains `<leader>ut` from anywhere.                              | full (`e71a9417`) | [lantern](./lantern.md) `LMP6`            |
| `TKB4` | The **key guide** must paint into the cell grid from the same widget tree the window paints ([lantern](./lantern.md) `LTN5`), and the event loop must take the guide's remaining delay as a **second deadline** — a terminal has no frames, so a panel that waits for the next keystroke is a panel nobody sees. | full (`8ec10bee`) | `tui.paintLantern`; `workspace.d` loop    |

## Terminal clipboard (`TCL`)

| ID   | Requirement                                                                                                                        | Status            | Traces to               |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------- |
| TCL1 | Copy must write to the system clipboard via **OSC 52** (base64) — the only portable in-band terminal clipboard; no read is needed. | full (`8b1d2aac`) | proposed OSC 52 writer  |
| TCL2 | A terminal without OSC 52 support must **degrade** — show a status message instead; copy must never block or corrupt the screen.   | not started       | `TCP1` capability probe |

## Surface & frame (`TSF`)

Extends the shipped previewer's frame discipline.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                             | Status                                 | Traces to                                           |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- | --------------------------------------------------- |
| TSF1 | The TUI must render into the **alt-screen** (hide cursor), one **synchronized-output** frame per repaint, assembled into a single buffer and flushed with one write.                                                                                                                                                                    | partial (`844680a3`/`0657c94a`)        | `PRV7`/`PRV8`; `NFR2` (previewer already does this) |
| TSF2 | The laid-out view must **reflow on terminal resize** (`SIGWINCH`) — rebuilt at the new column width (the `WRP4` analog) — **keeping the first visible source line in place** ([`gui.md` `NAV5`/`NAV6`](./gui.md)), in both axes: a narrower terminal re-wraps around the reader, a taller one only reveals more of the file below them. | full (`dd70e1b4`, anchored `52610621`) | `SIGWINCH` → `arrange` → `relayout`; `resize-probe` |
| TSF3 | The TUI must **reuse the shared raylib-free views** (`viewMarkdown`/`viewCodeDocument`/`viewTwoslashDocument`) unchanged — one view, two canvases.                                                                                                                                                                                      | full (`8172e070`)                      | `PreviewTui.rebuildMd`                              |
| TSF4 | The per-frame paint core should stay **`@nogc nothrow`** ([`NFR1`](./feature-requirements.md)); load-time layout may allocate, as the GUI's does.                                                                                                                                                                                       | partial                                | `previewer.d` `@nogc` core (`NFR1`)                 |

> [!NOTE]
> `TSF3` pulls `gui_preview.d` (and, for ` ```ansi ` fences, potentially
> `gui_ansi.d`/`sparkles:ghostty`) into the default terminal build. Reconcile
> with [`NFR3`](./feature-requirements.md) / the `no-gui` build
> ([`BLD2`](./feature-requirements.md)) — the preview layout is raylib-free, but
> the off-screen VT is not needed in a real terminal (fences pass through), so the
> TUI can take the layout without the VT dependency.

## Scrollbar (`TSB`, best-effort → gui.md `SCB`)

| ID   | Requirement                                                                                                                                                                           | Status | Traces to                                           |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | --------------------------------------------------- |
| TSB1 | A scrollbar must occupy the right gutter column and appear only when content exceeds the viewport; the thumb size/position reflect the visible fraction and scroll progress (`SCB1`). | full   | container-reserved gutters + `DockFrames.bars`      |
| TSB2 | The thumb must be **draggable** and the track **click-to-page/center** via SGR mouse (`SCB4`); the wheel scrolls (`NAV`).                                                             | full   | `DockContainer.handle` → `ScrollView.stepV`/`stepH` |
| TSB3 | The bar must render with block glyphs (`▏▎▍▐█` / half-blocks); hover-expansion is approximated (no smooth easing — `SCB2` degrades).                                                  | full   | semantic `OpKind.scrollbar` cell degradation        |

## Selection & clipboard (`TSL`, best-effort → gui.md `SEL`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                | Status               | Traces to                                                                                                         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| TSL1 | Left-drag must select **content only** as a half-open **byte range into the original source** (`SEL1`/`SEL2`); gutters, line numbers, borders, and decorations are excluded, and the range survives wrapping (`SEL3`).                                                                                                                                                                     | partial (`8b1d2aac`) | reuse `PreviewRun.srcStart` (`gui_preview.d`)                                                                     |
| TSL2 | The selection must be tinted (reverse-video / SGR); a copy key must write `source[a..b]` to the clipboard via **OSC 52** (`TCL1`) — the terminal analog of `SEL4`.                                                                                                                                                                                                                         | full (`8b1d2aac`)    | selection pass; `TCL1`                                                                                            |
| TSL3 | App-level mouse selection requires SGR mouse tracking, which **suppresses the terminal emulator's native selection** — hue must provide its own.                                                                                                                                                                                                                                           | full (`8b1d2aac`)    | `TIN2`                                                                                                            |
| TSL4 | ` ```ansi ` blocks should gain **cell-granular** file-offset selection at TUI parity with the GUI's [`SEL6`](./gui.md) (the shared identity channel — `TextSpan.srcStart` / `sourceOffsetAt`); the GUI-first **table grid selection** ([`TBL`](./gui.md)) and **copy modes** ([`SEL7`](./gui.md)/`CLI10`/`CLI11`) are a later TUI parity item.                                             | not started          | the identity channel (`sourceOffsetAt`); `table_select.d` (GUI-first)                                             |
| TSL5 | The **code-fence** and **whole-table** copy buttons ([`COD3`](./gui.md)/[`TBL6`](./gui.md)) must render (fence: header-band right edge; table: top-border cutout) and, on click, copy the raw fence body / the table serialized per the resolved `--table-copy` format (`source` for a DSV document, [`DSC2`](./dsv-preview.md)) via **OSC 52** (`TCL1`), with a ✔ until the state clears. | full                 | `copyFenceAt` (the header-band hit) / `copyTableAt` (the `tableCopyHitBase` cutout hit)                           |
| TSL6 | A wheel or edge-band autoscroll during a live selection must keep extending it without another pointer event; the event-driven host must request ticks only while capture is live ([`SCV8`](../ui/containers.md#scrollview-scv)).                                                                                                                                                          | full                 | `Workspace.tickDock`; `DockContainer.nextTickIn`; `workspace.selection.edgeAutoscrollExtendsWithoutPointerMotion` |
| TSL7 | The table overflow viewports ([`TBL7`/`TBL8`](./gui.md)) at TUI parity: the framed table's bottom-border/right-border bars render as glyphs, press/drag/track-click run through the shared per-bar machine (`barPress`/`barDrag`, the fences' dispatch), and a wheel over a table scrolls it to its edge before the document.                                                              | full                 | `tui.d` `barPress`/`barDrag`/`handleWheel`; `tui.pointer.tableBarScrollsWideTable`                                |

## Markdown preview in the terminal (`MDP-T`, best-effort → gui.md `MDP`)

The TUI is a **second canvas over the shared widget views** (`TSF3`), so the GUI's markdown constructs reach the terminal **by construction** — `MDP-T1` binds each to its gui.md source, and `MDP-T4` records the gaps that inherit unchanged. Three deltas are terminal-specific (`MDP-T2`/`MDP-T3`):

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Status               | Traces to                                                           |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------------------------------------------------------------------- |
| MDP-T1 | Every GUI markdown construct must render in cells, painted from the same widget view: headings ([`MDP1`](./gui.md)), inline styles ([`MDP2`](./gui.md)), inline code ([`MDP3`](./gui.md)), bullets / ordered lists ([`MDP4`](./gui.md)), task checkboxes ([`MDP5`](./gui.md)), quote bars ([`MDP6`](./gui.md)), callouts ([`MDP7`](./gui.md)), links ([`MDP8`](./gui.md)), images ([`MDP9`](./gui.md)), tables ([`MDP10`](./gui.md)), rules / HTML blocks ([`MDP11`](./gui.md)). Nerd-glyph fidelity depends on the terminal font, like [`FNT8`](./gui.md) / `TCP3`.                                                          | full (`dd70e1b4`)    | `paintGrid` paints the `viewMarkdown` ops (`TSF3`)                  |
| MDP-T2 | Box-drawing (tables, code-block borders, quote rules) must use the **native terminal glyphs** — no procedural `drawBox`; a real terminal renders `─│┼╭╮╰╯` without gaps.                                                                                                                                                                                                                                                                                                                                                                                                                                                      | full (`dd70e1b4`)    | native SGR box glyphs                                               |
| MDP-T3 | ` ```ansi ` fences render through the shared fence renderer: in the default (ghostty) build they are decoded by the off-screen VT and re-emitted as resolved-color spans (full fidelity, the code-panel box preserved); in the raylib-/ghostty-free `no-gui` build the SGR is **stripped to plain text** (no VT). Raw byte pass-through into the bordered panel was rejected — it would corrupt the box.                                                                                                                                                                                                                      | partial (`241e8052`) | `hueFenceRenderer`; `ViewerModel`'s decode hook; the strip fallback |
| MDP-T4 | The GUI's markdown **gaps and non-goals** inherit unchanged — the TUI paints the same model, so it renders neither more nor less: definition lists / footnotes fall back to plain paragraphs ([`MDP13`](./gui.md)); LaTeX math, wiki-links, and `==highlight==` are not rendered ([`MDP14`](./gui.md)); footnote superscripts / bare-URL autolinks ([`MDP16`](./gui.md)) and YAML/TOML front-matter ([`MDP17`](./gui.md)) are not; only the 5 GitHub callout types are recognized ([`MDP18`](./gui.md)); table cells are flattened to plain text ([`MDP10`](./gui.md)). "Parity" is bounded to what the shared model renders. | not started          | inherited from `viewMarkdown`                                       |

## Diff view in the terminal (`DIF-T`, best-effort → [diff-view.md](./diff-view.md))

The diff/PR/review feature reaches the terminal by construction (the shared
widget views, `TSF3`); these rows bind the terminal-specific deltas.

| ID     | Requirement                                                                                                                                                                                                                                                                                                                | Status      | Traces to                                                        |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------- |
| DIF-T1 | Both diff layouts render in cells from the shared widget view — dual gutters, filler rows, and hunk separators via **native terminal glyphs** (the `MDP-T2` doctrine), diff row backgrounds as SGR over the syntax colors ([`DVL1`/`DVL2`](./diff-view.md)).                                                               | not started | `paintGrid` over the diff widget view                            |
| DIF-T2 | Below the split-width threshold the TUI degrades to the **stacked single-rail** unified variant (a context-aware line-number column: old numbers on `-`, new on `+`/context) rather than two cramped rails ([`DVL3`](./diff-view.md); the diffs.nvim precedent).                                                           | not started | [research: diffs.nvim](../../research/diff-review/diffs-nvim.md) |
| DIF-T3 | Staging, hunk/conflict navigation, and the LINE/RANGE/HUNK selection modes ([`DST2`/`DST3`](./diff-view.md), [`CFV3`](./diff-view.md)) operate through the keymap and the existing `TSL` selection machinery; copying honors `--diff-copy=text\|patch` ([`DVL8`](./diff-view.md)) via OSC 52 (`TCL1`).                     | not started | `keymap.d`; `TSL*`; `TCL1`                                       |
| DIF-T4 | The write surface reaches the terminal: inline editing ([`DST5`](./diff-view.md)) and the comment composer ([`DCM3`](./diff-view.md)) through the [`UIA9`](./ui-architecture.md) editor component's terminal input; degraded terminals fall back per `TCP1` (no mouse → keyboard-only staging; no OSC 52 → copy disabled). | not started | [`UIA9`](./ui-architecture.md); `TCP1`                           |

## Capabilities & degradation (`TCP`)

| ID   | Requirement                                                                                                                                                                            | Status            | Traces to                         |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------- |
| TCP1 | On entry the TUI must probe tty status, color depth ([`CLR1`](./feature-requirements.md)), mouse, and OSC 52 support, and adapt (no mouse → keyboard-only; no OSC 52 → copy disabled). | not started       | `core-cli` `term_caps.d`          |
| TCP2 | A non-tty invocation must fall through to the **non-interactive ANSI** whole-file emit ([`MOD3`/`MOD5`](./feature-requirements.md)) — the full TUI is only for interactive ttys.       | full (`74d8f6a3`) | `interactive` gate (general spec) |
| TCP3 | Nerd-glyph decorations depend on the terminal font (the `FNT8` doctrine); a non-Nerd terminal font shows tofu — acceptable and documented.                                             | not started       | decoration glyph sites            |

## Milestones

| Milestone | Scope                                                                | Status               | Requirements                        |
| --------- | -------------------------------------------------------------------- | -------------------- | ----------------------------------- |
| T0        | Minimal theme-selection previewer (viewport slice + ↑/↓ theme cycle) | full (`74d8f6a3`)    | `PRV*` (baseline)                   |
| T1        | Viewport scrolling over the reused GUI wrapped-line layout           | full (`dd70e1b4`)    | `TSF3`, `RND`/`VIW`/`WRP`/`NUM`     |
| T2        | SGR mouse + wheel + the cell scrollbar                               | full (`b8809549`)    | `TIN`, `TSB`, `NAV`                 |
| T3        | Selection → source offsets + OSC 52 copy                             | full (`8b1d2aac`)    | `TSL`, `TCL`, `SEL` parity          |
| T4        | Markdown-preview parity + code blocks + incremental search           | partial (`30e8e133`) | `MDP-T*`, `COD`, `FND`              |
| T5        | Notifier popups in the terminal                                      | not started          | [notifier.md](./notifier.md) `NTF6` |

## Module coverage (TUI)

| Source                                                      | Requirements                                          |
| ----------------------------------------------------------- | ----------------------------------------------------- |
| `apps/hue/src/previewer.d` (extended to a full viewer)      | `TSF*`, `TSB*`, `TSL*`, `MDP-T*`, `TCP*`, `PRV*`      |
| `apps/hue/src/gui_preview.d` / `gui_text.d` (reused as-is)  | `TSF3` (shared layout); `RND`/`WRP`/`NUM`/`SEL` model |
| `sparkles:core-cli` `key_input.d` (expanded), `term_caps.d` | `TIN*`, `TCP1`                                        |
| OSC 52 writer (proposed)                                    | `TCL*`                                                |

→ [GUI requirements](./gui.md) · [General requirements](./feature-requirements.md) · [Notifier](./notifier.md) · [Overview](./index.md)
