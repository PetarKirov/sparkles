# `hue` navigation — Feature Requirements (link following & go-to)

_**Status:** planned · **Date:** 2026-07-23 · **Scope:** resolving a **reference**
at a position and jumping to its target — **intra-document** (markdown anchors,
same-file go-to-definition) and **inter-document** (markdown links to local files,
module/import paths, relative paths, doc-comment references, LSP go-to-definition).
Distinct from [`gui.md` `NAV`/`FND`](./gui.md) (scroll/search); cross-backend
(GUI/TUI/HTML)._

> [!NOTE]
> Forward-looking — every row is `not started` (the LSP go-to-definition rows are
> gated on `sparkles:dmd-lsp`, `researched` upstream). Today markdown links are
> **decorative** — [`gui.md` `MDP`](./gui.md) prefixes a `linkIcon` but the link
> is not followable; this feature makes references navigable. Status legend and
> IDs: see the [overview](./index.md).

## Design & rationale

Navigation is one seam: **reference providers** (`REF`) find navigable spans and
resolve each to a **target** (an anchor, a file, a file+position, a URL); the
**navigation model** (`LNK`) activates a target — scrolling within the current
document, or opening another — and remembers where you were. Two axes:

- **Intra-document** — the target is in the file already open: a markdown anchor
  (`#slug`), or a same-file go-to-definition. Resolves to a **scroll** (reusing
  [`gui.md` `NAV2`/goto](./gui.md)), auto-expanding enclosing
  [folds](./folding.md) (`FLD6`).
- **Inter-document** — the target is another local file: a relative markdown link,
  an import/module path, a relative path (e.g. Nix `./default.nix`), a doc-comment
  reference, or a cross-file definition. Resolves to **opening** that file
  (re-running read → highlight → layout), optionally scrolling to a position.

Reference spans use the same **source byte-span** discipline as
[selection](./gui.md) and [folding](./folding.md), so they are consistent across
the raw and preview views.

## Navigation model & interaction (`LNK`)

| ID   | Requirement                                                                                                                                                                                    | Status      | Traces to                                      |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------- |
| LNK1 | hue must detect **navigable references** (via `REF` providers) and let the user **activate** one to jump — intra-document (scroll) or inter-document (open another local file).                | not started | proposed navigation layer                      |
| LNK2 | An **intra-document** jump must scroll the current view to the target span (reusing [`NAV2`/goto](./gui.md)) and auto-expand any enclosing [folds](./folding.md) (`FLD6`).                     | not started | `NAV2`; `FLD6`                                 |
| LNK3 | An **inter-document** jump must **open the target file** in the viewer (read → highlight → layout), optionally scrolling to a target anchor / line / byte span within it.                      | not started | pipeline re-entry (`app.main`)                 |
| LNK4 | A **navigation history stack** (back/forward) must record jumps so the user can return; bound to keys and to mouse back/forward buttons.                                                       | not started | proposed nav stack                             |
| LNK5 | **Activation:** a navigable span must respond to a mouse click (GUI/TUI SGR mouse) and to a key on the span under the cursor — Enter to follow, `gd` go-to-definition, `gf` go-to-file.        | not started | `gui.d`/`previewer.d` input; [`TIN`](./tui.md) |
| LNK6 | Navigable spans must be **rendered as links** — underline/accent (GUI/TUI), an **OSC 8 hyperlink** where the terminal supports it (`core-cli` `ui.osc_link`), and a native `<a href>` in HTML. | not started | `core-cli.ui.osc_link`; `app.d` HTML branch    |
| LNK7 | An **unresolvable** reference (missing file, unknown anchor, no LSP backend) must be inert or show a status message — never a crash (totality).                                                | not started | resolution failure → no-op                     |

## Reference providers (`REF`)

Each provider finds navigable spans of one kind and resolves their targets.

| ID   | Requirement                                                                                                                                                                                                                                                          | Status                 | Traces to                                                       |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | --------------------------------------------------------------- |
| REF1 | **Markdown anchor links** — `[text](#slug)` must resolve to the heading whose slug matches (using the site's slugify; mind the VitePress-vs-GitHub slug differences) — an intra-document jump; heading auto-anchors are valid targets.                               | not started            | `MdDoc` link inlines; memory `vitepress-slugify-anchor-gotchas` |
| REF2 | **Markdown links to local files** — `[text](./other.md)` / `[text](../x.d)` must resolve the relative path against the current file and open it (inter-document); a trailing `#anchor` scrolls within the opened file.                                               | not started            | `MdDoc` link inlines; `LNK3`                                    |
| REF3 | **Relative path references** in code — path-like tokens (e.g. Nix `./default.nix`, `import ./foo.nix`, include paths) must resolve relative to the file and open the target.                                                                                         | not started            | proposed path provider                                          |
| REF4 | **Module / import paths** — import statements (D `import foo.bar;`, JS `import … from "./x"`, …) must resolve to the module file where the mapping is known (project layout / import roots); structural (grammar-based) where possible, semantic (`REF6`) otherwise. | not started            | CST import nodes; import-root resolution                        |
| REF5 | **Doc-comment references** — DDoc `$(REF module.symbol)` / `$(LREF …)` / `$(LINK url)` and JSDoc `{@link …}` / `@see` must be navigable (to a symbol, file, or URL).                                                                                                 | not started            | doc-comment scan (CST comments)                                 |
| REF6 | **LSP go-to-definition** — when a semantic overlay is available (`sparkles:dmd-lsp`'s `findDefinition`, the twoslash four-query backend), a symbol use must navigate to its definition, intra- or inter-document.                                                    | researched/not-started | [twoslash.md `DMD*`](./twoslash.md); `identifierTypes`          |
| REF7 | Reference spans must be **byte spans into the source** (like selection/folding), consistent across the raw and preview views.                                                                                                                                        | not started            | source-span discipline (`SEL`/`FSR4`)                           |

## Per-backend behavior (`LNB`)

| ID   | Requirement                                                                                                                                                                                                           | Status      | Traces to                                  |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------ |
| LNB1 | **GUI** — links accented/underlined; click or key follows; inter-document opens in the same window; back/forward via keys + mouse buttons.                                                                            | not started | [gui.md](./gui.md); `LNK4`                 |
| LNB2 | **TUI** — links as OSC 8 hyperlinks (terminal-clickable) **and** in-app activation via key / SGR mouse; inter-document opens in the previewer; back/forward keys.                                                     | not started | [tui.md](./tui.md); `core-cli.ui.osc_link` |
| LNB3 | **HTML** — native `<a href>`: `#slug` anchors and relative file links work in the browser with **no JS**; `REF6` definitions are baked as `<a>` to the def location when the semantic data is present at render time. | not started | `app.d` HTML branch                        |

## Milestones

| Milestone | Scope                                                                            | Status                 | Requirements            |
| --------- | -------------------------------------------------------------------------------- | ---------------------- | ----------------------- |
| N0        | Markdown anchors (`REF1`) + local-file links (`REF2`) + link rendering + history | not started            | `REF1`/`REF2`, `LNK*`   |
| N1        | Relative-path (`REF3`) + import-path (`REF4`) providers                          | not started            | `REF3`, `REF4`          |
| N2        | Doc-comment references (`REF5`)                                                  | not started            | `REF5`                  |
| N3        | LSP go-to-definition (`REF6`) — gated on `sparkles:dmd-lsp`                      | researched/not-started | `REF6`; twoslash `DMD*` |
| N4        | HTML native links + TUI OSC 8 (`LNB2`/`LNB3`)                                    | not started            | `LNB2`, `LNB3`          |

## Relationship to existing specs

| Piece                                                        | Role in navigation                                      |
| ------------------------------------------------------------ | ------------------------------------------------------- |
| [gui.md](./gui.md) `NAV2`/`FND`                              | the scroll/goto primitive an intra-document jump reuses |
| [folding.md](./folding.md) `FLD6`                            | auto-expand folds around a jump target                  |
| [twoslash.md](./twoslash.md) `DMD*` (`findDefinition`)       | the semantic source for `REF6` go-to-definition         |
| [tree-view.md](./tree-view.md) `TVU3` (file outline)         | symbol navigation companion (jump-to-symbol)            |
| `sparkles:syntax` `MdDoc` link inlines; CST imports/comments | reference detection for `REF1`–`REF5`                   |
| `sparkles:core-cli` `ui.osc_link`                            | OSC 8 terminal hyperlinks (`LNB2`)                      |

→ [GUI requirements](./gui.md) · [Content folding](./folding.md) · [Twoslash](./twoslash.md) · [Overview](./index.md)
