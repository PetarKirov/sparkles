# `hue` images & diagrams — Feature Requirements (raster, mermaid/graphviz, LaTeX)

_**Status:** planned · **Date:** 2026-07-23 · **Scope:** rendering **real media**
in the markdown preview — raster images (`![](…)`), **diagram** fences (mermaid,
graphviz/dot, …), and **LaTeX math** (inline + block) — across the interactive
backends. All three flow through one **media-block** mechanism in the wrapped-line
model, displayed per backend (GUI texture · terminal graphics protocol · HTML
`<img>`/`<svg>`)._

> [!NOTE]
> Forward-looking — every row is `not started`. Today an image inline renders as a
> **placeholder glyph** ([`gui.md` `MDP`](./gui.md) `󰥶`), no diagram/math fence is
> special-cased, and only ` ```ansi ` fences get non-code treatment
> ([`MDP12`](./gui.md)). Status legend and IDs: see the [overview](./index.md).

## Design & rationale

Images, diagrams, and math differ only in **how pixels are produced**; how they
are **placed and shown** is one shared mechanism:

- **Producers** turn a source into displayable pixels/markup: a raster **image**
  file is decoded (`IMG`); a **diagram** fence is rendered by an external engine to
  SVG/PNG (`DGM`); a **math** expression is typeset (`MTH`).
- The **media block** (`MDB`) places the result: it reserves N cell-rows in the
  wrapped `PreviewLine[]` ([`RND2`](./gui.md)) sized to the media's aspect at the
  available width, and each backend paints it — a raylib **texture** (GUI), a
  **terminal graphics protocol** (TUI), or native **`<img>`/`<svg>`** (HTML).

Everything degrades to **alt text + the source** (the totality law), and diagram
rendering — which shells out to external engines — is **opt-in** for security.

## Media block & display (`MDB`)

| ID   | Requirement                                                                                                                                                                                                       | Status      | Traces to                                                                      |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------ |
| MDB1 | Images / diagrams / block-math must be a **media block** in the wrapped `PreviewLine[]` — reserving N cell-rows sized to the media's aspect at the content width; it scrolls by visual row like any block.        | not started | proposed media block in `gui_preview.d`                                        |
| MDB2 | **GUI** — the decoded media must draw as a **raylib texture** over the reserved block, scaled to fit the content width (aspect preserved), loaded and cached on demand.                                           | not started | raylib `LoadTexture`/`DrawTexture` in `gui.d`                                  |
| MDB3 | **TUI** — media must display via a **terminal graphics protocol** (kitty graphics / sixel / iTerm2 inline images), detected at startup ([`tui.md` `TCP1`](./tui.md)); unsupported → a placeholder box + alt text. | not started | proposed graphics-protocol emitter; memory `terminal-image-protocol-detection` |
| MDB4 | **HTML** — media must emit native markup: `<img>` for raster, inline/linked `<svg>` for diagrams, KaTeX/MathJax (or pre-rendered) for math.                                                                       | not started | `app.d` HTML branch                                                            |
| MDB5 | Every media block must carry **alt text / a caption** and **degrade to it** (plus the source path/fence) when the media can't be decoded, rendered, or displayed — never a crash, never a blank (totality).       | not started | degradation (`RND5`)                                                           |
| MDB6 | Media must **reflow** on width/resize — recompute the block's cell-rows and re-scale — like the rest of the layout ([`WRP4`](./gui.md)).                                                                          | not started | `relayout` on width change                                                     |

## Raster images (`IMG`)

| ID   | Requirement                                                                                                                                                                                  | Status      | Traces to                                |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------- |
| IMG1 | Markdown `![alt](path)` and image files must load **local raster images** (PNG / JPG / GIF / WebP) and display via `MDB` — replacing today's placeholder glyph ([`gui.md` `MDP`](./gui.md)). | not started | `MdDoc` image inlines; raylib image load |
| IMG2 | **SVG** images must be **rasterized** (an SVG rasterizer) to pixels for the GUI/TUI at the display size; HTML uses the SVG directly.                                                         | not started | proposed SVG rasterizer                  |
| IMG3 | **Remote images** (`http(s)://`) must be **opt-in** (a flag, off by default) for privacy/security; the default shows alt text + the URL.                                                     | not started | proposed `--remote-images` gate          |
| IMG4 | A decode failure or unsupported format must fall back to alt text + path (`MDB5`).                                                                                                           | not started | decode failure → `MDB5`                  |

## Diagrams (`DGM`)

| ID   | Requirement                                                                                                                                                                                                                               | Status      | Traces to                                      |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------- |
| DGM1 | Fenced **diagram** blocks — ` ```mermaid `, ` ```dot `/graphviz, ` ```plantuml `, … — must render to an image/SVG via a diagram engine and display via `MDB`.                                                                             | not started | fence dispatch (cf. `MDP12`)                   |
| DGM2 | Rendering must be **cached**, keyed by `(language, content, size)`, so re-layout/scroll never re-renders; each expensive render happens once.                                                                                             | not started | proposed render cache                          |
| DGM3 | Diagram engines are **external processes** (mermaid-cli, graphviz `dot`, …); invoking them on document content is a trust boundary, so it must be **opt-in** (a flag / allowlist), off by default, with a resolvable engine per language. | not started | proposed `--diagrams` gate + engine resolution |
| DGM4 | An unknown/unsupported diagram language, a missing engine, or a render error must fall back to an ordinary **highlighted code block** (today's behavior), not an error.                                                                   | not started | fallback → code fence                          |

## Math / LaTeX (`MTH`)

| ID   | Requirement                                                                                                                                    | Status      | Traces to                  |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------- |
| MTH1 | **Block math** — ` ```math ` fences and `$$…$$` — must typeset to a math image/SVG (a KaTeX/TeX engine) and display via `MDB`.                 | not started | math engine → `MDB`        |
| MTH2 | **Inline math** — `$…$` — must render inline (a small inline image/box within the text line) or fall back to the raw LaTeX with light styling. | not started | inline media in a text run |
| MTH3 | **HTML** must use KaTeX/MathJax markup (or pre-rendered) rather than a raster where practical; GUI/TUI use the rasterized result.              | not started | `MDB4`; HTML branch        |

## Milestones

| Milestone | Scope                                           | Status      | Requirements                   |
| --------- | ----------------------------------------------- | ----------- | ------------------------------ |
| I0        | Media-block model + GUI raster images           | not started | `MDB1`/`MDB2`/`MDB5/6`, `IMG1` |
| I1        | SVG rasterization + remote-image opt-in         | not started | `IMG2`, `IMG3`                 |
| I2        | TUI terminal graphics protocol                  | not started | `MDB3`                         |
| I3        | Diagrams (mermaid/dot) — cache + opt-in engines | not started | `DGM*`                         |
| I4        | Math (block + inline)                           | not started | `MTH*`                         |
| I5        | HTML native `<img>`/`<svg>`/KaTeX               | not started | `MDB4`, `MTH3`                 |

## Relationship to existing specs

| Piece                                                                     | Role                                                            |
| ------------------------------------------------------------------------- | --------------------------------------------------------------- |
| [gui.md](./gui.md) `MDP` (image `󰥶` placeholder), `FNT7`/`DEF8`           | today's placeholder; the color-emoji rasterizer gap is adjacent |
| [gui.md](./gui.md) `MDP12` (` ```ansi ` fence decode)                     | precedent for special-casing a fence — diagrams/math extend it  |
| [tui.md](./tui.md) `TCP1` (caps)                                          | detects the terminal graphics protocol (`MDB3`)                 |
| `apps/terminal` image support; memory `terminal-image-protocol-detection` | protocol grounding for `MDB3`                                   |
| `sparkles:syntax` `MdDoc` (image inlines, fence blocks)                   | media source detection                                          |

→ [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [Overview](./index.md)
