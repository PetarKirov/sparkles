# `hue` overlays — Feature Requirements (pluggable annotation overlays)

_**Status:** planned (framework: researched) · **Date:** 2026-07-23 · **Scope:**
the pluggable **overlay** layer of `hue` — a backend-agnostic seam that paints
extra annotations over the highlighted source. Covers the framework and the
registered overlay kinds. [Twoslash](./twoslash.md) is the first overlay of this
kind and is specified in its own document; the others are specified here._

> [!NOTE]
> Everything in this document is **forward-looking design**. The only overlay
> with an implementation is **twoslash**, and even that is **branch-only**
> (`feat/syntax-twoslash`, see [twoslash.md](./twoslash.md)). The framework
> requirements (`OVL`) are `researched` — the seam is proven by twoslash but not
> yet generalized in code; every non-twoslash overlay kind is `not started`
> (the tree-sitter inspector is `researched`, since it needs no external data —
> `sparkles:syntax` already builds the tree it reads). Status legend and ID
> conventions: see the [overview](./index.md).

## Design & rationale

An **overlay** is a producer of _decorations_ over hue's existing
`(source, highlight events)` model; a backend-agnostic renderer paints those
decorations. Twoslash proved the seam
([twoslash.md § Architecture](./twoslash.md#architecture-issue-120)): a decoration
is just an **extra `(start, length)` push/pop pair** fed alongside the highlight
events (`byStyledSpan` already flattens overlapping ranges), plus **below-line
annotation blocks** and **hover popups** — no per-overlay token-splitting engine,
and the ANSI / HTML / GPU backends already know how to draw all of it.

The generalization: keep that decoration model and renderer contract, and make the
**producer** and its **data source** the only things an overlay supplies. Twoslash's
producer is a semantic backend answering the four-query contract; a coverage
overlay's producer is an `.lst`/lcov parser; a tree-sitter inspector's producer is
the parse tree itself. The renderer never learns which overlay it is drawing.

```
(source, highlight events, tree)  ─┐
                                    ├─▶  OverlayProducer  ─▶  OverlayModel  ─▶  renderer (ANSI / HTML / GUI)
overlay-specific data artifact    ─┘     (per kind)          (uniform)         (overlay-agnostic; = twoslash TWO*/backends)
```

## The overlay framework (`OVL`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                              | Status                 | Traces to                                                     |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------- |
| OVL1 | A uniform **`OverlayModel`** must carry four decoration channels: **inline span** decorations (tint / underline / badge over a byte `(start,length)`), **line/gutter** decorations (per-line marker, tint, or count), **below-line annotation blocks** (meta-lines), and **hover popups** (rich content anchored at an offset). It generalizes twoslash's overlay plan (`libs/twoslash` `overlay.d`) to a shared, overlay-neutral shape. | researched/not-started | generalizes `twoslash` `planTwoslash`; proposed shared module |
| OVL2 | The renderers must be **overlay-agnostic**: ANSI, HTML, and the raylib GUI must paint any `OverlayModel` through the existing twoslash render primitives ([`TWO*`](./twoslash.md#twoslash-raylib-overlay-two), `render_ansi`/`render_html`). Adding an overlay adds a **producer**, never new render code.                                                                                                                               | researched/not-started | reuse `TWO*` + `libs/twoslash` backends                       |
| OVL3 | Each overlay is a **producer** over `(source, highlight events, tree)` plus at most one overlay-specific **data artifact** (source-map / coverage / trace / size report). The tree-sitter inspector needs **no** external artifact; hue treats every other artifact as opaque input (as it already does the twoslash node JSON).                                                                                                         | researched/not-started | proposed `OverlayProducer` seam                               |
| OVL4 | The CLI must select an overlay with `--overlay <kind>[=<artifact>]` (`--list-overlays` enumerates the registered kinds); an overlay must be available across the ANSI / HTML / GUI backends per the `OVL2` contract, subject to each kind's own backend support notes.                                                                                                                                                                   | not started            | `app.d` (proposed `--overlay` dispatch)                       |
| OVL5 | Overlays must **compose** when their decoration channels don't collide (e.g. coverage's gutter + tracing's inline badges); a genuine channel conflict must be **reported**, not silently dropped. v1 may restrict to one overlay at a time and defer composition.                                                                                                                                                                        | not started            | `app.d` (proposed)                                            |
| OVL6 | A missing or unparseable data artifact must **warn and render the plain highlighted file** (the totality law from the [syntax spec](../syntax/index.md) / [`gui.md` `RND5`](./gui.md)); an overlay must never abort the render.                                                                                                                                                                                                          | not started            | degradation (cf. general [`DEG*`](./feature-requirements.md)) |
| OVL7 | The **line/gutter** decoration channel is new relative to twoslash (which uses inline + below-line only). It must share the GUI's existing gutter column region ([`gui.md` `NUM*`](./gui.md#line-numbers-num)) — coverage / size / tracing render a marker or count in the gutter next to (or in place of) the line number.                                                                                                              | not started            | proposed gutter channel; `gui.d` gutter (`NUM*`)              |

## Registered overlays

The overlay registry. Twoslash is kind #1 (owned by its own doc); the rest are
specified in the sections below.

| #   | Kind                      | Area          | Data source                                                             | Annotates                                               | Status              |
| --- | ------------------------- | ------------- | ----------------------------------------------------------------------- | ------------------------------------------------------- | ------------------- |
| 1   | **twoslash**              | `TWO` / `TWM` | semantic backend (`sparkles:dmd-lsp`) or a TS-twoslash node JSON        | inferred types, hovers, completions, errors, tags       | planned/branch-only |
| 2   | **source map**            | `SMP`         | a Source Map v3 (`.map`) — alternative to twoslash                      | provenance: which original file/position a span maps to | not started         |
| 3   | **code coverage**         | `COV`         | D `-cov` `.lst` listings, lcov `.info`                                  | per-line/region hit counts (covered / uncovered)        | not started         |
| 4   | **tracing / profiling**   | `TRC`         | a trace/profile JSON in the `sparkles:test-runner` metric-catalog shape | per-function call count + wall-clock decomposition      | not started         |
| 5   | **tree-sitter inspector** | `TSI`         | the tree-sitter parse tree itself (no external artifact)                | node type / field / S-expression at the cursor          | researched          |
| 6   | **function code size**    | `CSZ`         | native symbol-size report (nm/bloaty/linker map) or a JS bundle report  | bytes per function (`.text` segment, or minified size)  | not started         |

## Source-map overlay (`SMP`) — provenance, an alternative to twoslash

Where twoslash answers "what is the _type_ here", the source-map overlay answers
"where did this code _come from_" — it consumes a
[Source Map v3](https://tc39.es/source-map/) and maps positions between a
generated/minified artifact and its originals.

| ID   | Requirement                                                                                                                                                                                      | Status      | Traces to                       |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ------------------------------- |
| SMP1 | The producer must parse a Source Map v3 (`version`, `sources`, `sourcesContent`, `names`, VLQ `mappings`) — resolved from `--overlay source-map=<file.map>` or an inline `//# sourceMappingURL`. | not started | proposed `overlay/source_map.d` |
| SMP2 | Over a shown **generated** file, each mapped region must be tinted by its originating source, with the original `file:line:col` (and mapped `name`) shown on hover (an inline + hover overlay).  | not started | `SMP` producer → `OverlayModel` |
| SMP3 | Over a shown **original** file, the overlay must indicate which spans survive into the generated artifact and where (the inverse direction), and mark spans that were dropped.                   | not started | `SMP` producer (inverse index)  |

## Coverage overlay (`COV`)

Per-line / per-region execution coverage — the familiar green/red gutter.

| ID   | Requirement                                                                                                                                                                      | Status      | Traces to                          |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------- |
| COV1 | The producer must ingest coverage data — D `-cov` `.lst` listings (leading per-line hit counts) and lcov `.info` — mapping hit counts to source lines/regions.                   | not started | proposed `overlay/coverage.d`      |
| COV2 | Covered / uncovered / partial lines must render as a **gutter tint** (`OVL7`) plus an inline hit-count badge; branch or region partials are shown where the format carries them. | not started | `COV` producer → gutter + inline   |
| COV3 | A file-level summary annotation must report the covered-line percentage (matching `-cov`'s trailing summary line).                                                               | not started | `COV` producer → below-line/header |

## Tracing overlay (`TRC`)

Per-function runtime cost, drawn from a profile. Its data model reuses the
`sparkles:test-runner` **metric catalog** ([SPEC § 5](../test-runner/SPEC.md)) —
call count, a wall-clock decomposition into on-CPU vs attributable wait, average /
total, allocations — so a trace and a `--bench` result render through the same
`Unit`/`Mode` vocabulary.

| ID   | Requirement                                                                                                                                                                                                                                  | Status      | Traces to                                    |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------- |
| TRC1 | The producer must ingest a per-function (or per-line) trace: **call count**, wall-clock decomposition (on-CPU / attributable wait), average + total time, and allocations — the metric-catalog shape (`docs/specs/test-runner/SPEC.md` § 5). | not started | proposed `overlay/tracing.d`                 |
| TRC2 | Each function definition must carry an inline badge (`×N`, `~µs avg`), heat-tinted by total time; a hover popup must show the full per-function metric breakdown, rendered through the catalog `Unit`/`Mode` formatting.                     | not started | `TRC` producer → inline + hover              |
| TRC3 | The trace artifact (JSON, e.g. from a profiler or a `sparkles:test-runner` `--workload`/`--bench-json` run) is **opaque input** — hue maps its symbols/positions onto the source, as it does the twoslash node JSON.                         | not started | `TRC` producer; `test-runner` `--bench-json` |

## Tree-sitter inspector overlay (`TSI`)

A debugging overlay — the tree-sitter-playground inspector, in hue. Unique among
the overlays in needing **no external artifact**: it reads the parse tree that
`sparkles:syntax` / `sparkles:tree-sitter` already build for highlighting.

| ID   | Requirement                                                                                                                                                                                              | Status      | Traces to                                                 |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------- |
| TSI1 | The producer must read the tree-sitter tree directly (no data file); hovering (or moving the cursor onto) a token must show its **node type**, **field name**, and named-ancestor **S-expression path**. | researched  | `sparkles:tree-sitter` `TSNode`; `sparkles:syntax` engine |
| TSI2 | The hovered node's **byte extent** must be outlined/tinted; a toggle must reveal anonymous nodes and mark `ERROR`/`MISSING` nodes distinctly.                                                            | not started | `TSI` producer → inline span + gutter                     |
| TSI3 | A panel/annotation must render the S-expression for the current line or selection (the playground's tree view).                                                                                          | not started | `TSI` producer → below-line block                         |

## Function-code-size overlay (`CSZ`)

Per-function size — "how big did this compile to". Native and JS have different
data sources, unified behind one overlay.

| ID   | Requirement                                                                                                                                                                                    | Status      | Traces to                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------- |
| CSZ1 | For **native** languages, the producer must map each function to its compiled `.text` segment size via a symbol-size report (nm / bloaty / linker map), keyed by symbol → source span.         | not started | proposed `overlay/code_size.d`   |
| CSZ2 | For **JS/TS**, the producer must map each function to its byte contribution in a **minified bundle**, via the bundle's source map (`SMP1`) plus a size report.                                 | not started | `CSZ` producer (+ reuses `SMP1`) |
| CSZ3 | Each function definition must carry an inline byte badge, heat-tinted by size, with a per-function breakdown on hover and a file total; the ordering must make the largest functions findable. | not started | `CSZ` producer → inline + hover  |

## Milestones

The overlay framework is a design; there is no committed track yet. A sensible
order once twoslash merges: **O0** generalize twoslash's overlay plan into the
shared `OverlayModel` + producer seam (`OVL1`–`OVL3`); **O1** the `--overlay`
dispatch + `--list-overlays` + degradation (`OVL4`/`OVL6`); **O2** the two
self-contained / file-free wins — the tree-sitter inspector (`TSI`, no data
source) and coverage (`COV`, ubiquitous `-cov`/lcov formats); **O3** source-map
and code-size (`SMP`/`CSZ`, share the source-map parser); **O4** tracing (`TRC`,
once a trace artifact format is settled with `sparkles:test-runner`); **O5**
composition (`OVL5`).

## Module coverage (overlays)

Proposed layout — no code on this branch yet; twoslash's overlay is the only
existing instance (branch-only).

| Source (proposed / branch)                                     | Requirements                                |
| -------------------------------------------------------------- | ------------------------------------------- |
| shared `OverlayModel` + producer seam (proposed)               | `OVL1`–`OVL3`                               |
| `apps/hue/src/app.d` (`--overlay` dispatch, proposed)          | `OVL4`, `OVL5`, `OVL6`                      |
| `apps/hue/src/gui.d` gutter channel (proposed, cf. `NUM*`)     | `OVL7`                                      |
| `libs/twoslash` `overlay.d` + backends (branch)                | overlay #1 (→ [twoslash.md](./twoslash.md)) |
| `overlay/{source_map,coverage,tracing,code_size}.d` (proposed) | `SMP*`, `COV*`, `TRC*`, `CSZ*`              |
| `sparkles:tree-sitter` / `sparkles:syntax` tree (existing)     | `TSI*`                                      |

→ [Twoslash requirements](./twoslash.md) · [GUI requirements](./gui.md) · [General requirements](./feature-requirements.md) · [Overview](./index.md)
