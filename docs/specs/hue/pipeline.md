# `hue` transformer pipeline — Architecture Requirements

_**Status:** architecture · researched · **Date:** 2026-07-23 · **Scope:** the
**pluggable transformer pipeline** hue's document processing is (or becomes) —
parse → transform → compile, modeled on [unified.js](https://unifiedjs.com/),
markdown-it, and babel. Existing features (highlighting, injections, overlays,
folding, navigation, media, twoslash, semantic refinement) are **transform
plugins**; the ANSI / HTML / GUI / TUI renderers are **compilers**. Likely a
`sparkles:syntax`-hosted (or sibling) processor layer; hue is the first consumer._

> [!NOTE]
> Forward-looking architecture — `researched`/`not started`. hue **already has an
> implicit pipeline**: parse (`highlightInjected` + the markdown model) → an
> event/model → render (ANSI/HTML/GUI consume the identical stream,
> [`ENG3`](./feature-requirements.md)). This spec makes that a **plugin seam** so
> the growing feature set composes instead of accreting. Status legend and IDs:
> see the [overview](./index.md).

## Design & rationale

The prior art converges on one shape — a **three-stage pipeline with a plugin
chain in the middle**:

| Stage         | unified.js           | markdown-it                 | babel           | hue                                             |
| ------------- | -------------------- | --------------------------- | --------------- | ----------------------------------------------- |
| **Parse**     | `parse` → mdast/hast | block/inline rules → tokens | `parse` → AST   | tree-sitter CST + markdown model + event stream |
| **Transform** | transformer plugins  | core ruler + plugins        | visitor plugins | **`XFM` plugins** (this spec)                   |
| **Compile**   | `stringify`/compiler | renderer rules              | generator       | **`CMP` compilers** (ANSI/HTML/GUI/TUI)         |

hue's feature set has been growing as a set of separate concerns that each read
the model and add something — decorations, fold ranges, reference targets, media
blocks, semantic kinds. That **is** a transform chain; naming it one makes the
concerns compose (ordered, dependency-aware) rather than accrete as ad-hoc passes.

## The pipeline (`PIP`)

| ID   | Requirement                                                                                                                                                                                                                       | Status                 | Traces to                                               |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------- |
| PIP1 | hue's document processing must be a **pluggable pipeline** — parse → transform → compile — modeled on unified.js / markdown-it / babel; each stage extensible by plugins composed into a **processor**.                           | researched/not-started | proposed processor layer (`sparkles:syntax` or sibling) |
| PIP2 | The stages operate over a shared **document model** — the tree-sitter CST + the markdown model + the offset-based highlight-event stream; the model is the contract between stages.                                               | partial                | `sparkles:syntax` engine + `md/model.d` (`ENG3`)        |
| PIP3 | A **processor** is configured by attaching plugins in order (parsers, transformers, compilers) plus shared **data/options**; the same processor runs across every backend — the backend is a compiler choice.                     | researched/not-started | proposed processor API                                  |
| PIP4 | Plugins must **compose and order deterministically** — a plugin may depend on an earlier plugin's output (e.g. semantic refinement after base highlighting); ordering is explicit, not incidental.                                | researched/not-started | proposed ordering contract                              |
| PIP5 | The pipeline must be the **single seam** existing features plug into: highlighting, injections, overlays, folding, navigation, media, twoslash, semantic refinement are **`XFM` plugins**; the renderers are **`CMP` compilers**. | researched/not-started | this spec (unifying claim)                              |
| PIP6 | **Interop** — the pipeline should map onto the **unified / rehype / remark** ecosystem so the [web integration](./web-integration.md) can expose a unified-compatible processor / Shiki transformer.                              | researched/not-started | [web-integration.md](./web-integration.md) `PKG5`       |

## Parse stage (`PRS`)

| ID   | Requirement                                                                                                                                                                                                                | Status  | Traces to                                             |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ----------------------------------------------------- |
| PRS1 | Parsing must be **pluggable per language/format** — the tree-sitter engine (code), the markdown structural parser (`MdDoc`) — producing the shared model; an unbundled grammar/format falls back to plain text (totality). | partial | `canonicalLanguage`/`highlightInjected`; `md/model.d` |
| PRS2 | The parse stage must expose **both** the offset-based **event stream** and the structural **tree**, so transformers can work in whichever representation fits (spans vs nodes).                                            | partial | `HighlightEvent` stream; CST/`MdDoc`                  |

## Transform stage (`XFM`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                | Status                 | Traces to                                                                                                          |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------ |
| XFM1 | A **transformer** is a plugin `model → model` that annotates, rewrites, injects, or decorates; it runs in the processor's order over the shared model.                                                                                                                                                                     | researched/not-started | proposed transformer contract                                                                                      |
| XFM2 | Transformers must be able to add **decorations/overlays** (the [overlays](./overlays.md) `OVL` model), **derived data** (fold ranges [`FSR`](./folding.md), reference targets [`REF`](./navigation.md), media blocks [`MDB`](./media.md)), and **node rewrites** (injections, the twoslash node overlay) — all as plugins. | researched/not-started | [overlays.md](./overlays.md); [folding.md](./folding.md); [navigation.md](./navigation.md); [media.md](./media.md) |
| XFM3 | A transformer may run a **nested pipeline** — highlight a fenced block in another language, re-highlight a twoslash popup signature — the reentrancy [injections](./feature-requirements.md) (`ENG1`) and twoslash already need.                                                                                           | partial                | `highlightInjected`; twoslash `highlightSignature`                                                                 |
| XFM4 | A **semantic** transformer may enrich the model from an external analyzer (`sparkles:dmd-lsp` — semantic tokens, definitions) **after** the syntactic transformers (`PIP4` ordering).                                                                                                                                      | researched/not-started | [twoslash.md `DMD*`](./twoslash.md); `SEM1`                                                                        |

## Compile stage (`CMP`)

| ID   | Requirement                                                                                                                                                                                                              | Status                 | Traces to                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- | ---------------------------------------------------- |
| CMP1 | Compiling must be **pluggable per target** — ANSI, HTML, GUI (raylib), TUI (cells) — each a compiler consuming the transformed model; adding a backend adds a compiler, not touching parse/transform.                    | partial                | `renderAnsi`/`renderHtml`; GUI/TUI painters (`ENG3`) |
| CMP2 | Per-construct **render rules** must be overridable/extensible by plugins (the markdown-it renderer-rules / unified handlers pattern) — e.g. how a callout, a media block, or a twoslash popup renders in a given target. | researched/not-started | proposed render-rule registry                        |
| CMP3 | Every compiler must satisfy the **totality law** — an unknown construct degrades to a plain rendering, never a crash ([`gui.md` `RND5`](./gui.md)).                                                                      | full (`74d8f6a3`)      | `RND5`/`ENG4` (existing renderers)                   |

## Milestones

| Milestone | Scope                                                                                    | Status                 | Requirements          |
| --------- | ---------------------------------------------------------------------------------------- | ---------------------- | --------------------- |
| P0        | Formalize the current implicit parse→transform→compile flow as an explicit processor API | researched/not-started | `PIP1`–`PIP3`, `PRS*` |
| P1        | The `XFM` transformer seam — land overlays / folding / navigation / media as plugins     | not started            | `XFM1`, `XFM2`        |
| P2        | Overridable compiler render rules                                                        | not started            | `CMP2`                |
| P3        | Formalized nested-pipeline reentrancy + semantic transformer ordering                    | not started            | `XFM3`, `XFM4`        |
| P4        | unified / rehype interop for the web package                                             | not started            | `PIP6`                |

## Feature → stage map

Every hue feature lands on a pipeline stage — the concrete payoff of naming the seam:

| Feature                                                                                       | Stage                         |
| --------------------------------------------------------------------------------------------- | ----------------------------- |
| Highlighting, grammar loading ([`ENG`](./feature-requirements.md))                            | `PRS` (parse) → base `XFM`    |
| Injections ([`ENG1`](./feature-requirements.md))                                              | `XFM3` (nested pipeline)      |
| Overlays — twoslash / coverage / tracing / TSI / CSZ / source-map ([overlays](./overlays.md)) | `XFM2` (decorations)          |
| Content folding fold ranges ([folding](./folding.md) `FSR`)                                   | `XFM2` (derived data)         |
| Navigation reference targets ([navigation](./navigation.md) `REF`)                            | `XFM2` (derived data)         |
| Images / diagrams / math ([media](./media.md) `MDB`)                                          | `XFM2` (media blocks) → `CMP` |
| Semantic refinement (`sparkles:dmd-lsp`, [`SEM1`](./gui.md))                                  | `XFM4` (semantic)             |
| ANSI / HTML / GUI / TUI renderers                                                             | `CMP` (compilers)             |
| `@sparkles/hue` unified/rehype interop ([web](./web-integration.md))                          | `PIP6`                        |

→ [UI architecture](./ui-architecture.md) · [Overlays](./overlays.md) · [Web integration](./web-integration.md) · [General requirements](./feature-requirements.md) · [Overview](./index.md)
