# `hue` gallery & multi-document navigation — Feature Requirements

_**Status:** planned · **Date:** 2026-07-29 · **Scope:** rendering a **set** of
documents rather than a single file — the static **HTML gallery** (`index.html` +
one page per file, with a prev/next header, a physical-line gutter and selection
domains) and the **interactive** equivalent in the GUI/TUI (prev/next, an index
view, a name+summary header). Replaces the branch-only JS preview harness
(`libs/twoslash/examples/render-html.mjs`)._

> [!NOTE]
> Every row starts `not started`; statuses flip as the milestones land. Status
> legend and IDs: see the [overview](./index.md). The **document set** itself is
> specified in the general spec ([`SRC4`–`SRC6`](./feature-requirements.md#source-acquisition-src)).

## Design & rationale

hue renders **one file** today: it reads `args[1]`, highlights it, and emits one
ANSI stream / HTML fragment / window. Everything needed to present a **collection**
— an index, prev/next links, a per-file header, a line-number gutter — lived
outside the app, in a Node dev script that shelled out to `hue --twoslash --html`
once per fixture and wrapped each fragment in a page shell it built in JavaScript.

That split is the problem this spec closes. The page shell is **hue's own output**,
so it belongs in hue: the repo's D-over-scripting rule ([AGENTS.md](../../guidelines/AGENTS.md))
makes the port the default, and doing it in D makes the shell **testable** (pure
string builders over the fragment) instead of eyeball-only, drops the node
dependency from the preview loop, and — because the same document set drives the
interactive backends — turns a dev-only HTML trick into a **feature of every
rendering mode**.

Two deliberate scope choices:

- **Any directory, not just fixtures.** The set is extension-filtered
  ([`SRC5`](./feature-requirements.md)), so a directory of `*.twoslash.json`
  fixtures yields the twoslash gallery and a directory of source files yields a
  highlighted-source gallery. The per-file **summary** (`GAL8`) is what
  specializes: a twoslash **node-kind tally**, else language + line count.
- **A thin substrate, not a rival to the planned components.** The document set is
  what the [tab view](./tab-view.md) `TBU1` turns into tabs and what
  [navigation](./navigation.md) `LNK3`/`LNK4` reuses to open and revisit files; the
  index view (`GAL5`) is a deliberately minimal list that the
  [file-tree explorer](./tree-view.md) `TVU1` replaces. This spec ships the least
  that makes a set navigable, shaped so those specs consume it.

## Document set & gallery (`GAL`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                           | Status      | Traces to                                                                                               |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------- |
| GAL1 | A **document set** must carry, per entry, the path, a display name (the file stem), and a **summary** (`GAL8`), in a stable order, plus the currently-selected index; it is acquired once ([`SRC5`](./feature-requirements.md)) and consumed by every mode ([`SRC6`](./feature-requirements.md)).                                                                                                     | not started | proposed `source_set.SourceSet`                                                                         |
| GAL2 | With `--html`, a directory target must write a **static gallery** to `--out` ([`CLI9`](./feature-requirements.md)): one standalone page per entry (`<name>.html`) plus an **`index.html`** listing every entry with its name and summary, each linking to its page.                                                                                                                                   | not started | proposed `gallery.writeGallery`/`galleryIndex`; [`HTM6`](./feature-requirements.md)                     |
| GAL3 | Each page must carry a **navigation header**: the entry name, its summary, **prev** and **next** links (disabled, not omitted, at the ends so the header does not reflow), and a link back to the **index**.                                                                                                                                                                                          | not started | proposed `gallery.pageShell`; [`HTM7`](./feature-requirements.md)                                       |
| GAL4 | Each page must number **physical (source) lines** in a gutter: every physical line wrapped in a `.ln` span whose number is a CSS `::before` counter — never selected or copied (`GAL7`). Below-line overlay annotations must carry **no** number and must not advance the counter; blank lines must keep their height and survive a copied selection; the gutter width must come from the line count. | not started | proposed `gallery.relayoutGutter`; [`HTM4`](./feature-requirements.md); [`NUM1`](./gui.md) parity       |
| GAL5 | Interactively, a directory target must open an **index view** — a selectable list of entries (name + summary) that opens the chosen one in the viewer. This is a minimal list, superseded by the file-tree explorer ([`tree-view.md` `TVU1`](./tree-view.md)) when it lands.                                                                                                                          | not started | proposed index view in `gui.d`/`previewer.d`; [`SRC4`](./feature-requirements.md)                       |
| GAL6 | A page must use exactly **one scroll container** — the code pane fills the remaining height, so no nested page + `<pre>` scrollbars appear — and its page background must match the theme's `.syn-root` background so the pane and the surround are one surface.                                                                                                                                      | not started | proposed `gallery.pageShell`; [`HTM7`](./feature-requirements.md)                                       |
| GAL7 | A page must implement **selection domains**: a drag must be confined to the domain it **starts in** — the code, or one overlay annotation — so a copy never mixes the two. Layers on the pure-CSS code-only default ([`TWH6`](./twoslash.md)). Known limits: hover-popup content is not independently selectable (it is hover-ephemeral), and `Ctrl/Cmd+A` uses the default state.                    | not started | proposed `gallery.pageShell` (selection CSS + `mousedown` handler); [`HTM8`](./feature-requirements.md) |
| GAL8 | Each entry must carry a one-line **summary**: for a twoslash payload the **node-kind tally** (each kind, `×n` when repeated — e.g. `hover×2 query`); for a plain source file the language and line count. An unreadable or empty entry must summarize as such, not fail the run.                                                                                                                      | not started | proposed `source_set.twoslashTally`/`plainTally`                                                        |
| GAL9 | Degradation: an empty set must produce an index saying so (not a crash or an empty directory); a file that fails to load must be reported and **skipped**, leaving the rest of the gallery intact; a directory in a piped non-`--html` mode must degrade per [`SRC4`](./feature-requirements.md).                                                                                                     | not started | totality; [`DEG`](./feature-requirements.md)                                                            |

## Interactive navigation (`GNV`)

The same set, navigated live. The single-file entry points keep their current
behavior when no set is supplied.

| ID   | Requirement                                                                                                                                                                                                                                                            | Status      | Traces to                                                             |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------- |
| GNV1 | The GUI and TUI must navigate the set **prev/next** (`[` / `]`, and the mouse back/forward buttons where available), reloading the newly-selected document in place — re-read, re-highlight, re-layout — without re-creating the window, font atlas, or grammar cache. | not started | proposed `SourceSet*` in `gui.runGui`/`runGuiTwoslash`, `TwoslashTui` |
| GNV2 | A **header bar** must show the current entry's name and summary plus its position in the set (`i/n`), in every interactive backend.                                                                                                                                    | not started | proposed header row in `gui.d`/`twoslash_tui.d`/`previewer.d`         |
| GNV3 | Navigation must preserve per-document view state sensibly: scroll position resets to the top of the newly-opened document, while user-level toggles (theme, line numbers, preview mode) persist across the move.                                                       | not started | proposed reload path                                                  |
| GNV4 | The twoslash overlay view must offer the same **physical-line gutter** as the raw/markdown view ([`NUM1`](./gui.md)), so the GUI, the TUI and the HTML gallery (`GAL4`) all number lines alike.                                                                        | not started | reuse `gui.gutterCols`/`drawPreview`; `gui_preview.PreviewLine`       |
| GNV5 | These keys and the reload path must be the primitive [navigation](./navigation.md) `LNK3` (open a linked file) and `LNK4` (back/forward history) build on — one document-open path, not two.                                                                           | not started | [navigation.md](./navigation.md) `LNK3`/`LNK4`                        |

## Milestones

| Milestone | Scope                                                                                                   | Status      | Requirements                          |
| --------- | ------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------- |
| G0        | Document set: directory → ordered filtered list + summaries; `--out`; reusable HTML-fragment functions  | not started | `GAL1`, `GAL8`, `SRC5`/`SRC6`, `CLI9` |
| G1        | Static HTML gallery: page shell (header/nav, single scroll, theme bg), gutter, selection domains, index | not started | `GAL2`–`GAL4`, `GAL6`, `GAL7`, `GAL9` |
| G2        | Interactive: prev/next + header + index view + twoslash gutter                                          | not started | `GNV1`–`GNV4`, `GAL5`                 |
| G3        | Retire the JS harness; the D gallery becomes the preview + docs-showcase path                           | not started | [`TWD3`](./twoslash.md)               |

## Relationship to existing specs

| Piece                                                                      | Role                                                                                     |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [feature-requirements.md](./feature-requirements.md) `SRC4`–`SRC6`, `CLI9` | the document set + the CLI surface this spec renders                                     |
| [feature-requirements.md](./feature-requirements.md) `HTM4`, `HTM6`–`HTM8` | the HTML-sink half (gutter, gallery, page shell, selection domains)                      |
| [gui.md](./gui.md) `NUM`, `SEL`, `RND2`                                    | the GUI gutter, selection model and single wrapped-line list this mirrors in HTML        |
| [twoslash.md](./twoslash.md) `TWH6`–`TWH8`, `TWD3`                         | the pure-CSS code-only selection this layers on; `TWD3` is the JS harness this replaces  |
| [tree-view.md](./tree-view.md) `TVU1`                                      | the richer file explorer that supersedes the minimal index view (`GAL5`)                 |
| [tab-view.md](./tab-view.md) `TBU1`                                        | turns the same document set into open-file tabs                                          |
| [navigation.md](./navigation.md) `LNK3`/`LNK4`                             | reuses the document-open/reload primitive (`GNV1`/`GNV5`) for link-following and history |

→ [Feature requirements](./feature-requirements.md) · [Twoslash](./twoslash.md) · [Tree / DAG view](./tree-view.md) · [Overview](./index.md)
