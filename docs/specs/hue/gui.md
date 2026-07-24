# `hue --gui` — Feature Requirements (raylib GPU window)

_**Status:** living inventory · **Date:** 2026-07-23 · **Scope:** the `hue`
raylib backend — `apps/hue/src/gui.d` (window + interaction + paint),
`gui_preview.d` (markdown model → wrapped-line layout), `gui_ansi.d` (` ```ansi `
fence decode), `gui_text.d` (pure metrics/search) — plus the shared libraries it
drives: `sparkles:raylib-text` (fonts, glyph draw, procedural box-drawing),
`sparkles:ghostty` (off-screen VT), `sparkles:syntax` (the markdown model), and
`sparkles:core-cli` (table renderer)._

Compiled into hue's **default** build (the GUI backend is included by default —
[`BLD1`](./feature-requirements.md#build-and-packaging-bld)); a raylib-/ghostty-free
variant is the `no-gui` config ([`BLD2`](./feature-requirements.md#build-and-packaging-bld)).
The window opens automatically when a display is detected and can be forced or
suppressed with `--gui`/`--no-gui` (general [`MOD6`](./feature-requirements.md#output-mode-dispatch-mod)).
Status scheme and ID conventions: see the [overview](./index.md). App-wide
behaviour (source, engine, themes) is in
[feature-requirements.md](./feature-requirements.md); this doc covers only the
GUI. The entry point is `gui.runGui`.

## Design & scope (issue [#121](https://github.com/PetarKirov/sparkles/issues/121))

`hue --gui` is a **third consumer of hue's identical `(source, events, theme)`
triple** — the same triple `renderAnsi`/`renderHtml` consume — folded into raylib
draw calls instead of ANSI escapes or HTML markup. Nothing in hue's producer
pipeline changes (file read, `canonicalLanguage`, `highlightInjected`, theme
resolution, the plain-text fallback); only the sink is new. This is the
"styled runs as data" GPU backend `sparkles:syntax` was designed around
(`StyledSpan`/`byStyledSpan`/`ResolvedTheme` are its third-backend contract, and
`FontStyle` stays backend-neutral), and building it forced the two seams the
syntax spec reserved: `toRgb(Color, palette, default)` and `byStyledLine`.

**It is** a read-only, windowed, syntax-highlighted view with a live theme
previewer and a render-markdown.nvim-style markdown preview. **It is deliberately
not** a text editor, an incremental/LSP-backed surface, a terminal emulator, or
the Vulkan engine (#47) — it is the smallest honest GPU consumer of the styled-run
API, hosted in the app that already produces it.

> [!NOTE]
> Most GUI areas below — `SEL` (selection), `MDP` (markdown constructs), `NUM`
> (line numbers), `RND`/`VIW`/`WRP`/`NAV`/`SCB`/`FND`/`COD` — are **not
> GPU-specific**; they apply **best-effort** to the other interactive backends.
> The full terminal port and its GUI→TUI parity map are in
> [tui.md](./tui.md); the HTML best-effort rows are `HTM3`–`HTM5` in the
> [general spec](./feature-requirements.md). This document remains the source of
> truth for the raylib backend itself.

## Window & lifecycle (`WIN`)

| ID   | Requirement                                                                                                                                                                                                                                                                                     | Status            | Traces to                                                           |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------- |
| WIN1 | `--gui` must open a resizable raylib window titled `hue — <file>` and run a 60 fps event loop until closed.                                                                                                                                                                                     | full (`e6063309`) | `runGui`: `InitWindow`, `FLAG_WINDOW_RESIZABLE`, `SetTargetFPS(60)` |
| WIN2 | The window's initial size must follow `--window-width`/`--window-height` **in cells**, sized to the loaded cell metrics.                                                                                                                                                                        | full (`c2b49e99`) | `SetWindowSize(w*cellW, h*cellH)`                                   |
| WIN3 | Resizing must reflow content: any change in the available column count re-runs layout.                                                                                                                                                                                                          | full (`2febf905`) | `widthCols() != lastWidthCols` → `relayout`                         |
| WIN4 | The window title must always show the current theme name and index (`file — theme (i/n)`).                                                                                                                                                                                                      | full (`2febf905`) | `applyTheme` → `SetWindowTitle`                                     |
| WIN5 | The close button must exit; app keys must not be hijacked by raylib's default exit key.                                                                                                                                                                                                         | full (`e6063309`) | `SetExitKey(KEY_NULL)`; `WindowShouldClose`                         |
| WIN6 | With neither `--gui` nor `--no-gui`, the window must open by default when a display is available; `--no-gui`/`--tui` forces the terminal previewer instead (general [`MOD6`](./feature-requirements.md#output-mode-dispatch-mod)/[`MOD7`](./feature-requirements.md#output-mode-dispatch-mod)). | full (`cdc813f6`) | general `MOD6`/`MOD7`; `displayAvailable`/`wantGui` in `app.main`   |

## Font (`FNT`)

Fonts are owned by `sparkles:raylib-text` (`FontSet`); hue configures and drives it.

| ID    | Requirement                                                                                                                                                                                                    | Status            | Traces to                                           |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------- |
| FNT1  | `--font` must accept a path, a family, or a fontconfig **preference list** (first installed family wins); default leads with Nerd-Font coding families.                                                        | full (`c2b49e99`) | `FontSet.tryLoad(fontName)`; `defaultGuiFont`       |
| FNT2  | `--font-size` is in **points**; it must be converted to pixels at 96-DPI, matching the terminal.                                                                                                               | full (`c2b49e99`) | `fontSizePx = fontSize*96/72`                       |
| FNT3  | Ctrl-`=` / Ctrl-`-` must grow/shrink the font at runtime (reload faces + re-measure the cell), with a floor.                                                                                                   | full (`2febf905`) | `fonts.reload(size ± 2)`                            |
| FNT4  | Glyphs outside the base atlas (icons, higher-plane, CJK) must load on demand: draw requests a codepoint, atlas grows after `EndDrawing`.                                                                       | full (`efa6cd7f`) | `fonts.flushPending()` after `EndDrawing`           |
| FNT5  | Bold/italic/strike/underline attributes must map onto the shared `TextStyle`; real bold/italic faces are used when present.                                                                                    | full (`d1dd79d5`) | `mapStyle`/`mapAttrs`; `sparkles:raylib-text`       |
| FNT6  | Monospace column width (v1) counts one column per codepoint — **wide/CJK/tab characters count as 1 cell**, so wide glyphs may overlap.                                                                         | partial           | `gui_text.columnWidth` (documented v1 limit)        |
| FNT7  | Color-emoji / flag glyphs render as tofu (raylib/stb_truetype ignores CBDT/COLR); monochrome symbols render.                                                                                                   | partial           | raylib limitation (documented in `raylib-text`)     |
| FNT8  | Preview decoration glyphs (heading/callout/link icons, checkboxes, box-drawing) are Nerd-Font codepoints; a non-Nerd `--font` degrades them to tofu.                                                           | partial           | `defaultGuiFont` doc; icon glyph sites              |
| FNT9  | CJK renders only when the **primary** face covers it — on-demand loading asks only the primary, and hue does not expose the terminal's `--font-codepoint-map`, so CJK is tofu unless a CJK `--font` is chosen. | partial           | `FontSet.resolveFace`; `tryLoad` (no codepoint map) |
| FNT10 | Underline is drawn as a single straight rule; the shaped `TermStyle`'s curly/dotted/double/dashed styles and independent underline color are not rendered.                                                     | partial           | `mapStyle` (underline bit only)                     |

## Render model (`RND`)

| ID   | Requirement                                                                                                                                                                                                                                           | Status            | Traces to                                      |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ---------------------------------------------- |
| RND1 | Each frame must clear to the page background and paint only the viewport-visible rows (index-culled by `topLine`).                                                                                                                                    | full (`a0b0f93a`) | `drawPreview` `foreach(row; 0..visibleRows)`   |
| RND2 | Both views must be one wrapped visual-line list (`PreviewLine[]`), painted by a single painter; content scrolls by visual line.                                                                                                                       | full (`8a03bff1`) | `plines`; `drawPreview`; `relayout`            |
| RND3 | A styled run must draw per grid column via the shared per-run `drawText` (per-codepoint face routing).                                                                                                                                                | full (`b55be7aa`) | `sparkles.raylib_text.drawText`                |
| RND4 | Content must have a 1-cell background-filled left padding and a scrollbar gutter on the right; the left padding is page background.                                                                                                                   | full (`5ca88625`) | `padX`, `rightPad`, `originX` in `drawPreview` |
| RND5 | **Totality is the law:** an unknown language, missing grammar, oversized file, or parse failure must degrade to plain uncolored text in the window — never a crash, never half-colored output.                                                        | full (`74d8f6a3`) | `ENG4` fallback (general spec); `drawText`     |
| RND6 | The grid is **monospace with a fixed cell advance** (v1) — keeps column/gutter math and hit-testing trivial and matches `apps/terminal`.                                                                                                              | full (`b55be7aa`) | `cellW`/`cellH`; `gui_text.columnWidth`        |
| RND7 | The render fold must go through the two `sparkles:syntax` seams this backend motivated: `byStyledLine` (spans clipped at `\n`, stable per-row y) and `toRgb(Color, palette, default)` (the `unset`/`default_`/`palette`/`rgb` sum type → `RgbColor`). | full (`b55be7aa`) | `byStyledLine`; `toRgb` (`sparkles:syntax`)    |

## Views & toggle (`VIW`)

| ID   | Requirement                                                                                                                 | Status            | Traces to                |
| ---- | --------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------ |
| VIW1 | A **raw** highlighted-source view must render the file's styled runs (wrapped); it is the only view for non-markdown files. | full (`b55be7aa`) | `buildRawPlines`         |
| VIW2 | A markdown file must open in a rendered **preview** by default; Tab must toggle preview ↔ raw.                              | full (`9ec7f847`) | `showPreview`; `KEY_TAB` |
| VIW3 | The preview model must be built once at load from the markdown structural model + per-fence highlight/ANSI decode.          | full (`9b0a4b50`) | `buildPreviewModel`      |

## Wrapping & visual-line model (`WRP`)

| ID   | Requirement                                                                                                                                                 | Status            | Traces to                         |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------- |
| WRP1 | Prose must **soft-wrap** (word-wrap) to the available width, with hang-indent on continuation lines.                                                        | full (`d871c47c`) | `Layouter.emitFlow`               |
| WRP2 | Code and ` ```ansi ` fence lines must **hard-wrap** (character-level, styled runs split at the column) to the panel width; no horizontal overflow/clipping. | full (`f1a53bd3`) | `hardWrapRuns`; `codeFence`       |
| WRP3 | The raw (non-markdown) view must wrap long physical lines too; it is built as wrapped `PreviewLine[]`.                                                      | full (`8a03bff1`) | `buildRawPlines` + `hardWrapRuns` |
| WRP4 | All views must reflow on window/font resize (rebuild the wrapped-line list on width change).                                                                | full (`8a03bff1`) | `relayout` on `widthCols` change  |

## Line numbers (`NUM`)

| ID   | Requirement                                                                                                                                      | Status            | Traces to                                       |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ----------------------------------------------- |
| NUM1 | A file line-number gutter must number by **physical (source) line**, shown only on the first visual row of a wrapped line (continuations blank). | full (`8a03bff1`) | `PreviewLine.srcLine`/`showNumber`; `beginLine` |
| NUM2 | The file gutter is on by default; `--line-numbers=false` disables it and `l` toggles it at runtime (reflow follows).                             | full (`5ca88625`) | `lineNumbers`; `KEY_L`                          |
| NUM3 | The gutter width must be stable (from the source line count) so toggling never oscillates the wrap width.                                        | full (`8a03bff1`) | `gutterCols()` from `srcTotal`                  |
| NUM4 | Each code block must have an in-panel code-relative line-number gutter (`1..N`), first-wrapped-row only, dimmed.                                 | full (`5b862346`) | `codeGutterStr`; `codeLineNumbers`              |
| NUM5 | Code line numbers are on by default; `--code-line-numbers=false` disables and `c` toggles at runtime.                                            | full (`5b862346`) | `codeLineNumbers`; `KEY_C`                      |

## Navigation & scroll (`NAV`)

| ID   | Requirement                                                                                                     | Status            | Traces to                         |
| ---- | --------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------- |
| NAV1 | Mouse wheel must scroll (3 lines/notch); ↑/↓ and j/k scroll one line; PageUp/PageDown a page; Home/End to ends. | full (`e813f99a`) | normal-mode key block in `runGui` |
| NAV2 | `g` must enter goto-line mode; entering a number jumps to that **source** line's visual row.                    | full (`1e218180`) | `Mode.gotoLine`; `visualOfSrc`    |
| NAV3 | Scroll position must be clamped to `[0, maxTop]` every frame.                                                   | full (`a0b0f93a`) | `top` clamp                       |

## Scrollbar (`SCB`)

| ID   | Requirement                                                                                                                               | Status            | Traces to                                  |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------ |
| SCB1 | A scrollbar must appear only when content exceeds the viewport; its thumb size/position reflect the visible fraction and scroll progress. | full (`e813f99a`) | `thumbGeometry`; `maxTop > 0`              |
| SCB2 | On hover/drag the handle must expand to a font-proportional width (1.5 cells) from a thin proportional idle rail, eased over time.        | full (`5ca88625`) | `hoverW`/`idleW`; `sb.currentWidth` easing |
| SCB3 | The reserved right gutter must equal the expanded handle width so the handle fills the gutter without overlapping text.                   | full (`5ca88625`) | `scrollbarGutter()` == `rightPad`          |
| SCB4 | Dragging the thumb must track the cursor; clicking the track must center the viewport on the click.                                       | full (`e813f99a`) | `sb.isDragging`; track-click branch        |
| SCB5 | The hover track + thumb must use a distinct (link-tinted) color, so they read against the grayscale page/code bands.                      | full (`e463ac95`) | `scrollbarTrack`/`scrollbarThumb`          |

## Live theme cycling (`THG`)

| ID   | Requirement                                                                                                        | Status            | Traces to                            |
| ---- | ------------------------------------------------------------------------------------------------------------------ | ----------------- | ------------------------------------ |
| THG1 | ←/→ must cycle the theme (wrapping), re-resolve colors, rebuild the derived palette, and repaint live.             | full (`2febf905`) | `applyTheme`; `KEY_LEFT`/`KEY_RIGHT` |
| THG2 | Decoration colors (heading accents, quote-bar cycle, callout accents, scrollbar) must be theme-derived, not fixed. | full (`17b33d09`) | `resolvePalette`; `quoteBarColors`   |

## Search & goto (`FND`)

| ID   | Requirement                                                                                                            | Status            | Traces to                       |
| ---- | ---------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------- |
| FND1 | `/` (raw view) must start an incremental search; a bottom input line shows the query + match count.                    | full (`1e218180`) | `Mode.search`; input-line paint |
| FND2 | All matches must be found in the source and overlaid as a translucent tint, the current match brighter.                | full (`1e218180`) | `findMatches`; match overlay    |
| FND3 | Enter jumps to the first match at/after the view; `n`/Shift-`n` cycle matches (centered).                              | full (`1e218180`) | `jumpToMatch`; `KEY_N`          |
| FND4 | Because lines wrap, matches (source coords) must be remapped to visual rows via each line's `srcLine`+`wrapColOffset`. | full (`8a03bff1`) | `visualOfMatch`; overlay remap  |

## Markdown preview constructs (`MDP`)

`gui_preview.d` `Layouter`, over the `sparkles:syntax` structural model
(`extractMarkdown`). Each block/inline construct is a requirement.

| ID    | Requirement                                                                                                                                                                                                                                                       | Status            | Traces to                                                       |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------- |
| MDP1  | Headings must render a per-level Nerd icon leader + per-level accent color + a subtle full-width band.                                                                                                                                                            | full (`21da63cf`) | `Layouter.heading`; `headingAccents`                            |
| MDP2  | Paragraphs must soft-wrap; inline styling (bold/italic/strikethrough) must map to attributes.                                                                                                                                                                     | full (`17b33d09`) | `inlineRuns`; `emitFlow`                                        |
| MDP3  | Inline code spans must render with a distinct background.                                                                                                                                                                                                         | full (`17b33d09`) | `inlineRuns` codeSpan; `inlineCodeBg`                           |
| MDP4  | Bullet lists must use `●○◆◇` glyphs cycled by nesting depth; ordered lists number.                                                                                                                                                                                | full (`76405ab1`) | `Layouter.list`; `listDepth`                                    |
| MDP5  | Task-list checkboxes must render Nerd glyphs (`󰄱` unchecked, `󰱒` checked in green).                                                                                                                                                                               | full (`76405ab1`) | `Layouter.list` checkbox                                        |
| MDP6  | Block quotes must draw per-depth colored gutter bars.                                                                                                                                                                                                             | full (`17b33d09`) | `quoteBarColors`; `drawPreview` bars                            |
| MDP7  | GitHub callouts (`> [!NOTE/TIP/IMPORTANT/WARNING/CAUTION]`) must render a titled, iconed, accent-barred block; the marker is stripped from the body. Detection is source-based (the marker parses as a shortcut-link).                                            | full (`bb296176`) | `blockQuote`/`detectCallout`/`renderCallout` (fixed `3d3ad89f`) |
| MDP8  | Links must prepend a per-destination icon (github/gitlab/mail/web/file), then the underlined label.                                                                                                                                                               | full (`39c16ce5`) | `inlineRuns` link; `linkIcon`                                   |
| MDP9  | Images must render a monochrome Nerd glyph + alt text + destination (not the tofu-prone `🖼` emoji).                                                                                                                                                              | full (`39c16ce5`) | `inlineRuns` image                                              |
| MDP10 | Tables must render box-drawing borders with per-column alignment via `sparkles:core-cli`'s `drawTableLines`; the header row bold.                                                                                                                                 | full (`6760c5b1`) | `Layouter.table`; `renderTableLines`                            |
| MDP11 | Thematic breaks must render a full-width rule; HTML blocks render their raw lines (muted italic).                                                                                                                                                                 | full (`d871c47c`) | `Layouter.rule`/`htmlBlock`                                     |
| MDP12 | ` ```ansi ` fences must be decoded to styled lines by an **off-screen** libghostty-vt terminal (no PTY/window) and rendered with the live theme's default colors substituted for default-colored cells.                                                           | full (`ffd36f7c`) | `gui_ansi.decodeAnsi`; `AnsiLine`/`AnsiSpan`                    |
| MDP13 | Definition lists and footnotes are not rendered (the bundled grammar collapses them); they degrade to plain paragraphs / nothing.                                                                                                                                 | partial           | `md/model.d` (documented grammar limits)                        |
| MDP14 | LaTeX math, wiki-links (`[[…]]`), and inline highlight (`==text==`) are not rendered — deferred from the render-markdown.nvim shortlist.                                                                                                                          | not started       | render-markdown gap-analysis (deferred tier)                    |
| MDP15 | Custom checkbox states beyond `[ ]`/`[x]` (e.g. `[-]`) are intentionally not recognized (a `[-]` is a genuine markdown shortcut-link — ambiguous).                                                                                                                | non-goal          | dropped in `3d3ad89f`                                           |
| MDP16 | Footnote superscripts (`[^1]`) and bare-URL autolinks (GFM) are not rendered — not modeled by the bundled grammar / inline pass.                                                                                                                                  | not started       | `md/model.d` (not modeled)                                      |
| MDP17 | YAML/TOML front-matter is not rendered as a distinct block.                                                                                                                                                                                                       | not started       | render-markdown parity gap                                      |
| MDP18 | Only the 5 GitHub callout types are recognized; the wider Obsidian set (abstract/todo/question/failure/danger/bug/example/…) is not.                                                                                                                              | not started       | `matchCalloutType` (5 types)                                    |
| MDP19 | Table border **presets** (round/double/none) and explicit alignment-indicator glyphs are not exposed (box borders + alignment ship via core-cli).                                                                                                                 | not started       | `renderTableLines` (fixed preset)                               |
| MDP20 | Further render-markdown cosmetic parity — heading border glyphs / min-width / margins, code-block diff backgrounds & insets, inline-code icon affixes, per-level org indent, sign-column gutter — is intentionally not matched (hue's preview is lighter-weight). | non-goal          | design (lighter-weight preview)                                 |

## Code blocks (`COD`)

| ID   | Requirement                                                                                                                                                                   | Status            | Traces to                                                          |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------ |
| COD1 | A code block must render as a **rounded box** on all four sides (top `╭─ lang ─╮`, side `│…│`, bottom `╰──╯`), connected by procedural box-drawing.                           | full (`88c5df57`) | `codeFence`; box runs                                              |
| COD2 | The top border must embed a devicon + language label in a left cutout, with 1-char horizontal padding.                                                                        | full (`88c5df57`) | `codeFence` header; `langIcon`                                     |
| COD3 | A copy-to-clipboard button must sit in a right-side cutout of the top border (a space on each side); clicking copies the block body and flips to a green checkmark for ~1.2s. | full (`f1d468ac`) | `PreviewLine.copyFence`; copy pass in `runGui` (cutout `88c5df57`) |
| COD4 | The copy button must anchor to the border cutout column (not `screenW`) so it stays aligned across widths.                                                                    | full (`88c5df57`) | icon `iconX = gutterPx + (runStartCells+lineCols-3)*cellW`         |
| COD5 | Highlighted code must keep its per-token syntax colors inside the panel; the panel background is distinct from the page.                                                      | full (`f1a53bd3`) | `codeFence` highlighted branch                                     |

## Mouse selection & clipboard (`SEL`)

| ID   | Requirement                                                                                                                                                      | Status            | Traces to                                          |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------- |
| SEL1 | A left-drag must select content; the selection is a half-open **byte range into the original source file** (`const(char)[]`).                                    | full (`88c5df57`) | `offsetAt`/`srcOffsetAtCol`; `PreviewRun.srcStart` |
| SEL2 | Selection must include content only — gutters, line numbers, box borders, bullets, and other decorations are excluded (they have no `srcStart`).                 | full (`88c5df57`) | `srcStart == size_t.max` skip                      |
| SEL3 | `srcStart` must survive wrapping and word-splitting (each split piece carries its byte offset).                                                                  | full (`88c5df57`) | `hardWrapRuns`/`emitFlow` `srcStart` propagation   |
| SEL4 | The selection must be highlighted with a translucent tint; Ctrl-C must copy `source[a..b]` to the clipboard.                                                     | full (`88c5df57`) | selection highlight pass; `SetClipboardText`       |
| SEL5 | A click consumed by the copy button or over the scrollbar must not start a selection.                                                                            | full (`88c5df57`) | `copyClicked`/`overSb` guards                      |
| SEL6 | Content inside ` ```ansi ` fences and inside tables is **not** mapped to source offsets (those runs are synthetic/flattened), so it is not selectable-to-source. | partial           | ANSI/table runs lack `srcStart`                    |

## Fullscreen (`FSC`)

| ID   | Requirement                                                                                                                                                                         | Status            | Traces to                                                                              |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------- |
| FSC1 | F11 must toggle borderless fullscreen and restore window decorations on the way back (managing the undecorated flag + geometry ourselves, not raylib's `ToggleBorderlessWindowed`). | full (`e463ac95`) | F11 handler in `runGui` (fixed `8a03bff1`)                                             |
| FSC2 | Fullscreen must target the window's **current** monitor on X11; on Wayland the app cannot set its position, so the window stays on its monitor rather than jumping to the primary.  | partial           | `GetCurrentMonitor`/`SetWindowPosition` (Wayland size may be wrong if monitors differ) |

## Debug / CI hooks (`DBG`)

Environment-variable hooks that make the GUI deterministically capturable headless.

| ID   | Requirement                                                                                                                                                             | Status            | Traces to                    |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ---------------------------- |
| DBG1 | `HUE_GUI_SCREENSHOT=<path>` must render a few warm-up frames then write a PNG and exit (headless golden capture).                                                       | full (`a0b0f93a`) | `shotPath`; `TakeScreenshot` |
| DBG2 | `HUE_GUI_TOP`, `HUE_GUI_FONTSIZE`, `HUE_GUI_PREVIEW`, `HUE_GUI_SEARCH` must pin initial scroll / font px / view mode / a preselected search for deterministic captures. | full (`1e218180`) | env reads in `runGui`        |

## Box-drawing (`BOX`, shared library)

Implemented in `sparkles:raylib-text` (`box.d`), consumed by hue's tables, code
boxes, and quote bars.

| ID   | Requirement                                                                                                                                                                            | Status            | Traces to                                    |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------- |
| BOX1 | Box-drawing glyphs (`─│┼╭╮╰╯` + heavy/header-rule forms) must render **procedurally** (arms drawn to the cell edges) so rules connect across cells instead of using gappy font glyphs. | full (`1ab4e71d`) | `sparkles.raylib_text.box.drawBox`/`boxSpec` |
| BOX2 | Uncovered forms (dashed/double/diagonal) must fall back to the font glyph.                                                                                                             | full (`1ab4e71d`) | `boxSpec` returns `valid == false`           |

## Semantic refinement (`SEM`)

| ID   | Requirement                                                                                                                                                                                                 | Status                 | Traces to                            |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------ |
| SEM1 | The tree-sitter base highlighting may be refined with semantic kinds (member vs local, `@safe` call, …) from `sparkles:dmd-lsp`'s `identifierTypes` — the semantic-tokens overlay the syntax spec reserves. | researched/not-started | issue #121 M6; issue #120 §5 (bonus) |

## Milestones (issue [#121](https://github.com/PetarKirov/sparkles/issues/121))

The GUI backend shipped as milestones M0–M5; M6 is optional/future. (There is no
M7+ in the hue-GUI track; the M0–M8 / D1–D3 ladder belongs to the twoslash /
`dmd-lsp` design — see [twoslash.md](./twoslash.md).)

| Milestone | Scope                                                                        | Status                           | Requirements                                                                |
| --------- | ---------------------------------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------- |
| M0        | `gui` config + `--gui` gate + `version(HueGui)` seam                         | full (`e6063309`)                | `WIN1/5`, general `MOD1/2`, `NFR3`                                          |
| M1        | The render fold (`toRgb`/`byStyledLine` seams; draw the triple on the GPU)   | full (`b55be7aa`)                | `RND1/3/6/7`, `VIW1`                                                        |
| M2        | Viewport culling + line-number gutter + scrollbar                            | full (`a0b0f93a`)                | `RND1`, `NUM1`, `SCB1`                                                      |
| M3        | Font sizing + window resize + live theme cycling                             | full (`2febf905`)                | `FNT3`, `WIN3`, `THG1`                                                      |
| M4        | Incremental search + goto-line                                               | full (`1e218180`)                | `FND*`, `NAV2`                                                              |
| M5        | Extract `sparkles:raylib-text`; refactor terminal + hue onto it              | full (`d1dd79d5`)                | `FNT*`, `RND3`, `BOX*`                                                      |
| M6        | _(optional)_ Semantic refine via `sparkles:dmd-lsp` `identifierTypes`        | not started                      | `SEM1`                                                                      |
| —         | Markdown preview (render-markdown.nvim parity) — a later effort on top of M5 | full                             | `WRP*`, `MDP*`, `COD*`, `SEL*`                                              |
| —         | GUI-by-default: gui/tui autodetection + `no-gui` config/package              | partial (`cdc813f6`, `29bf1a65`) | `WIN6`/`MOD6/7`/`BLD1`/`BLD2` done; `BLD3` `hue-no-gui` nix package pending |

## Module coverage (GUI spec)

| Source                       | Key symbols                                                                                                                                                                                                         | Requirements                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `apps/hue/src/gui.d`         | `runGui`, `drawPreview`, scrollbar (`Scrollbar`/`thumbGeometry`), `offsetAt`/`srcOffsetAtCol`, copy pass, F11, env hooks, `mix`/`alpha`/`rl`                                                                        | `WIN*`, `FNT2/3`, `RND*`, `VIW2`, `NUM2/3/5`, `NAV*`, `SCB*`, `THG*`, `FND*`, `COD3/4`, `SEL*`, `FSC*`, `DBG*` |
| `apps/hue/src/gui_preview.d` | `PreviewModel`/`PreviewLine`/`PreviewRun`/`CodeFence`/`BandKind`, `buildPreviewModel`, `layoutPreview`, `buildRawPlines`, `Layouter` (block/inline handlers), `hardWrapRuns`, `colorizeTableLine`, `quoteBarColors` | `RND2`, `VIW1/3`, `WRP*`, `NUM1/4`, `MDP*`, `COD1/2/5`, `SEL3`                                                 |
| `apps/hue/src/gui_ansi.d`    | `decodeAnsi`, `AnsiLine`/`AnsiSpan`, `Attr`                                                                                                                                                                         | `MDP12`                                                                                                        |
| `apps/hue/src/gui_text.d`    | `columnWidth`, `lineCount`, `buildLineStarts`, `findMatches`, `Match`                                                                                                                                               | `FNT6`, `WRP*` (metrics), `FND2`, `NUM3`                                                                       |
| `sparkles:raylib-text`       | `FontSet`, `drawText`, `drawGrapheme`/`drawSolid`, `box.drawBox`                                                                                                                                                    | `FNT1/3/4/5`, `RND3`, `BOX*`                                                                                   |
| `sparkles:ghostty`           | off-screen VT (`ghostty_terminal_*`)                                                                                                                                                                                | `MDP12`                                                                                                        |
| `sparkles:core-cli`          | `ui.table.drawTableLines`, `args`, `key_input`, `term_caps`                                                                                                                                                         | `MDP10`, `CLI*` (general)                                                                                      |

→ [General requirements](./feature-requirements.md) · [Overview](./index.md)
