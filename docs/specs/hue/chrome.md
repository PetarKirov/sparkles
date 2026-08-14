# `hue` document chrome — Feature Requirements (`STY`/`CHW`/`CHG`)

_**Status:** design · **Date:** 2026-08-08 · **Scope:** the decorations hue draws
**around** a document's content — the file header, the grid border, the
between-file rule, the snip separator, the line-number gutter and the git change
column — the composable `--style` set that selects them, and the `sparkles:ui`
widgets they are made of. The content itself is specified in
[feature-requirements.md](./feature-requirements.md); this page owns the frame._

## Why this exists

Two observations, one from hue and one from [bat](https://github.com/sharkdp/bat).

**hue paints the same gutter three times.** The line-number gutter exists as
[`NUM`](./gui.md) in the raylib window, as [`TSL`](./tui.md) in the terminal, and
as [`HTM4`](./feature-requirements.md) in HTML — three implementations, three
independently-evolving notions of what a continuation line looks like, and no
shared vocabulary for "the stuff to the left of the text". Adding a second column
(git changes) to that arrangement means writing it three more times. This is the
same shape of duplication the markdown preview had before `viewMarkdown` became
one widget view, and it wants the same fix.

**bat's decorations cannot leave the terminal.** bat's `decorations.rs` defines a
`Decoration` trait whose `generate` returns a `DecorationText { width, text }` —
a pre-styled ANSI string. That is the right decomposition (ordered columns, each
with a width and a per-line producer) trapped in the wrong medium: it can only
ever be printed. hue's toolkit is canvas-first, so the identical decomposition
expressed as widgets renders to ANSI, to a cell grid, to a GPU window and to
HTML from one description. **The interesting thing to copy from bat is the model,
not the implementation.**

So: hue takes bat's `--style` component set — which is a genuinely good CLI
design, composable and memorable — and implements it one level lower, as
`sparkles:ui` widgets, where it is worth more than it is to bat.

## Design & rationale

### Chrome is a widget set (`CHW1`)

A new `libs/ui/src/sparkles/ui/components/chrome.d` holds the frame components.
The document body stays whatever widget the content kind produced (`viewMarkdown`,
the highlighted-source view, the diff view); chrome **wraps** it rather than
being woven into it, so a content kind never learns about line numbers.

### Gutter columns compose left to right (`CHW2`)

The gutter is an **ordered list of columns**, each a widget with a fixed cell
width and a per-visual-line cell producer:

```
[changes][numbers][grid] │ content
    1        4       1
```

A column is asked for a cell run given `(physicalLine, isContinuation)` — the
two inputs bat's `Decoration::generate` takes, and the only two it needs. A
continuation line (from wrapping, or an overlay annotation) yields blanks of the
same width, which is what keeps a wrapped document's text edge straight.

This is what lets `--style` be a **set** rather than a cascade of booleans: the
column list is derived from the set, and everything downstream — total gutter
width, the content's available width, the HTML `::before` counters — falls out
of it.

### Only the content is selectable (`CHW3`)

Chrome is decoration, never source. Every backend already has a way to say so
and they must all use it: HTML emits `user-select: none` ([`HTM3`](./feature-requirements.md)),
and the GUI/TUI selection machinery ([`SEL`](./gui.md)) resolves a drag to source
offsets, which chrome cells have none of. Making chrome one widget set is what
makes this a single rule instead of three conventions.

### The git change column is a diff, not a new mechanism (`CHG1`)

bat computes its change markers with a bespoke `gix` blob diff in `diff.rs`. hue
must not grow a second diff engine beside `sparkles:diff`: the change column is
`sparkles:diff` run over the index side and the worktree side, acquired through
the **existing** [`DVS3`](./diff-view.md) `git show` acquisition, reduced to a
per-line classification. One engine, one acquisition layer, one place where
"what counts as a change" is decided — so the gutter and the diff view can never
disagree about a file.

### Deliberate omissions

Taken from bat because they are cheap and good; the rest is out of scope:

| Not doing                        | Why                                                                                                                                                                                                                        |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| bat's three-layer style cascade  | bat resolves `--style` across config file → `BAT_STYLE` → CLI with its own precedence rules. hue already layers **every** setting that way ([`CFG2`](./config.md)); `--style` is one more field, not a parallel mechanism. |
| Per-component color options      | Colors come from the theme's slots ([`THM`](../ui/index.md)), not from flags.                                                                                                                                              |
| `--style=header` legacy aliasing | One spelling per component plus bat's `header` → `header-filename` alias, because scripts in the wild use it.                                                                                                              |

## Style components (`STY`)

Selected by `--style`, a comma-separated list. Registered as
[`CLI16`](./feature-requirements.md).

| ID   | Requirement                                                                                                                                                                                                                                                                                         | Status      | Traces to                                      |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------- |
| STY1 | `--style` must accept the component set `changes`, `numbers`, `grid`, `rule`, `snip`, `header-filename`, `header-filesize` (with `header` an alias for `header-filename`), and the presets `default`, `full`, `plain`, `auto`.                                                                      | not started | proposed `style.d` `StyleComponents`           |
| STY2 | A component prefixed `+` or `-` must **modify** the set in force rather than replace it; a list containing any unprefixed component replaces it. So a configured `full` plus a CLI `--style=-grid` yields full-without-grid.                                                                        | not started | `StyleComponentList.apply`                     |
| STY3 | `default` must be `changes,grid,header-filename,numbers,snip`; `full` must be every component; `plain` none; `auto` must resolve to `default` when the sink is interactive and `plain` when it is piped.                                                                                            | not started | `StyleComponents.preset`                       |
| STY4 | `--decorations=auto\|never\|always` must gate the whole set independently of `--style`: `never` suppresses chrome even when `--style` names it, `always` keeps it when piped. `auto` (default) is chrome iff the sink is interactive.                                                               | not started | `DecorationPolicy`                             |
| STY5 | The short aliases must exist: `-p`/`--plain` = `--style=plain`, repeated `-pp` additionally `--paging=never` ([`PAG1`](./pager.md)); `-n`/`--number` = `--style=numbers`; `-f`/`--force-colorization` = `--decorations=always --color=always`.                                                      | not started | `CliParams`; `sparkles:core-cli` short aliases |
| STY6 | hue's existing `--line-numbers` / `--code-line-numbers` must keep working as overrides onto the `numbers` component (they are per-context, which `--style` is not): `--line-numbers=false` removes the document gutter, `--code-line-numbers` governs numbering **inside** fenced code blocks only. | not started | `CliParams.lineNumbers`/`codeLineNumbers`      |
| STY7 | The resolved set must be one value carried on the `Document`'s render options, read identically by all four sinks — no sink may consult a flag directly.                                                                                                                                            | not started | `viewer_model.RenderOptions`                   |

## Chrome widgets (`CHW`)

The `sparkles:ui` component set the styles select. Cross-referenced from
[docs/specs/ui](../ui/index.md) `WGT`.

| ID   | Requirement                                                                                                                                                                                                                                                                    | Status      | Traces to                                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ---------------------------------------------------------- |
| CHW1 | `sparkles:ui` must ship a document-chrome component set — header, gutter, grid border, rule, snip — as widget builders over the toolkit's `Slot`/`Palette` style layer, with no backend in their signatures.                                                                   | not started | proposed `libs/ui/src/sparkles/ui/components/chrome.d`     |
| CHW2 | The gutter must be an **ordered column list**; each column declares a cell width and produces a cell run from `(physicalLine, isContinuation)`. Continuation lines must produce a blank run of the same width. Total gutter width must be the sum, computed once per relayout. | not started | `chrome.GutterColumn`; `chrome.gutterWidth`                |
| CHW3 | Chrome cells must carry **no source offset**, so a selection can never include them: HTML emits them `user-select: none` ([`HTM3`](./feature-requirements.md)) and the GUI/TUI hit-tests resolve them to no offset ([`SEL`](./gui.md)).                                        | not started | `chrome.d`; `viewer_model` offset mapping                  |
| CHW4 | The header must render the document's title and, with `header-filesize`, its byte size; for a stdin or URL input the title is the one `--file-name` supplied ([`CAT3`](./feature-requirements.md)), else the input kind.                                                       | not started | `chrome.header`; `source_set.SourceEntry`                  |
| CHW5 | Grid, rule and snip glyphs must come from the active `Theme`'s glyph set, so a terminal without unicode support ([`term_caps`](../../libs/base/index.md)) degrades to ASCII rather than to mojibake — the same fallback the box components already make.                       | not started | `Theme.glyphs`; `sparkles:ui` `components/box.d` precedent |
| CHW6 | The snip separator must be drawn between **disjoint visible ranges** ([`RNG5`](./feature-requirements.md)) and must state the number of elided lines, so a truncated view never silently reads as a whole file.                                                                | not started | `chrome.snip`                                              |
| CHW7 | The migration order must be ANSI sink → HTML → TUI → GUI, each backend's bespoke gutter deleted as it moves — the sequencing `viewMarkdown` used. No backend may keep a private gutter once it has moved.                                                                      | not started | [ui/migration.md](../ui/migration.md)                      |

## Git change column (`CHG`)

The `changes` component. Registered as [`CLI17`](./feature-requirements.md).

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                    | Status      | Traces to                                         |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------- |
| CHG1 | The change column must classify each physical line as added, modified, removed-above or removed-below with respect to the **git index**, computed by `sparkles:diff` over the index and worktree sides acquired through [`DVS3`](./diff-view.md) — never a second diff engine.                                                                                 | not started | proposed `git_changes.d`; `sparkles:diff`; `DVS3` |
| CHG2 | The markers must be `+` (added), `~` (modified), `‾` (removed above this line) and `_` (removed below), colored from the theme's diff slots so they match the diff view's added/removed colors.                                                                                                                                                                | not started | `chrome.changesColumn`; theme diff slots          |
| CHG3 | Computation must be **off the first-paint path**: a worker refresh with a TTL cache, as `git_status.d` already does for the explorer's badges. A missing repository, an untracked file or a slow `git` must degrade to an empty column, never to a stall or an error.                                                                                          | not started | `git_status.GitStatusCache` pattern reused        |
| CHG4 | `--changes-only[=N]` must restrict the visible lines to changed lines plus `N` lines of context (default 2) by producing a [`LineSelection`](./feature-requirements.md) — so it composes with `--line-range` and renders through the same snip separators, rather than being a mode. _(bat spells this `-d/--diff`, which hue cannot use: `--diff` is taken.)_ | not started | `RNG2` `LineSelection`; `CHG1` change map         |
| CHG5 | The interactive sinks should navigate the change map — next/previous changed hunk on the diff-view bindings ([`KEY`](./lantern.md)) — since the map is already computed for the column.                                                                                                                                                                        | not started | `keymap.d`; `CHG1`                                |

## Module coverage

| Source (proposed)                     | Key symbols                                                | Requirements          |
| ------------------------------------- | ---------------------------------------------------------- | --------------------- |
| `libs/ui/src/.../components/chrome.d` | `GutterColumn`, `gutter`, `header`, `grid`, `rule`, `snip` | `CHW1`–`CHW6`         |
| `apps/hue/src/style.d`                | `StyleComponent`, `StyleComponents`, `DecorationPolicy`    | `STY1`–`STY5`, `STY7` |
| `apps/hue/src/git_changes.d`          | `LineChange`, `changeMap`, the TTL refresh                 | `CHG1`–`CHG3`, `CHG5` |
| `apps/hue/src/viewer_model.d`         | `RenderOptions` carrying the resolved set                  | `STY7`, `CHW2`        |

→ [Feature requirements](./feature-requirements.md) · [Pager & streaming](./pager.md) · [Overview](./index.md)
