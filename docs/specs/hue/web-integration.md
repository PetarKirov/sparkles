# `hue` web integration — `@sparkles/hue` npm package (SPA / SSR / SSG)

_**Status:** planned · **Date:** 2026-07-23 · **Scope:** a JavaScript/TypeScript
npm package, **`@sparkles/hue`**, that makes hue's highlighter (`sparkles:syntax`)
a **drop-in [Shiki](https://shiki.style/) replacement** for web frameworks —
usable in SSG, SSR, and (later) client-side SPA rendering. Generalizes the
render-side substrate ([twoslash.md `RS1`–`RS3`](./twoslash.md), issue
[#122](https://github.com/PetarKirov/sparkles/issues/122)) into a distributable,
multi-framework package._

> [!NOTE]
> Forward-looking — every row is `not started`, on the `RS1` substrate (which is
> `partial`: `apps/hue --html` already emits `cssClasses` HTML). This doc owns the
> **JS package + framework integration + backend selection**; the D-side HTML
> contract stays in [twoslash.md `RS1`](./twoslash.md). Status legend and IDs: see
> the [overview](./index.md).

## Design & rationale

Sites highlight code with [Shiki](https://shiki.style/) today; the goal is to let
them **swap Shiki for `@sparkles/hue`** and get `sparkles:syntax`'s precise
tree-sitter highlighting instead — with the same authoring surface. One JS API,
two engine backends behind it:

- **Shell-out backend** (ship first) — the JS package invokes the D
  `hue --html` binary ([`RS1`](./twoslash.md)) as a subprocess and reads back the
  HTML fragment. Covers **SSG** (build-time) and, secondarily, **SSR**
  (request-time). No new engine work — it wraps the shipped `--html` path.
- **Wasm backend** (future) — `sparkles:syntax` compiled to **wasm** (the LDC WASI
  fork already demonstrated — the docs cell-explorer widget) highlights
  **client-side** in the browser (SPA), and can also serve **SSR** in a JS/edge
  runtime with no native binary.

The existing [`RS3`](./twoslash.md) (VitePress) becomes **one framework
integration** here (`FWK1`); the playground ([`RS2`](./twoslash.md)) consumes the
same package.

## The npm package (`PKG`)

| ID   | Requirement                                                                                                                                                                                                                                   | Status      | Traces to                                   |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------- |
| PKG1 | Publish **`@sparkles/hue`** — a JS/TS package exposing a **Shiki-compatible** highlighting API (`codeToHtml` / `codeToHast` + `createHighlighter`, language + theme selection) so a site swaps Shiki for `@sparkles/hue` with minimal change. | not started | proposed npm package                        |
| PKG2 | Output must match the [`RS1`](./twoslash.md) HTML contract — `cssClasses` (with a once-emitted stylesheet), `inlineStyles`, and the CSS-variable **multi-theme** (dark/light) mode — so existing themes and markup transfer.                  | not started | `RS1`; `apps/hue --html`                    |
| PKG3 | The package must port Shiki's **`languageAlias`** map, cover the target sites' language set (the `ts-grammars` bundle), and fall back to plain text for unbundled grammars (the totality law).                                                | not started | `RS1` alias map; `sparkles:syntax` grammars |
| PKG4 | The API must be **backend-pluggable** — the same surface dispatches to the shell-out backend (`SHL`) or the wasm backend (`WSM`); the consumer selects per environment (build vs browser vs edge).                                            | not started | `SHL*`/`WSM*`                               |
| PKG5 | The package **may** expose the twoslash overlay ([twoslash.md `TWM2`](./twoslash.md), the `.twoslash-*` HTML) as an optional transform, so `@sparkles/hue` can also replace `@shikijs/twoslash`.                                              | not started | [twoslash.md](./twoslash.md) `TWM2`         |

## Shell-out backend (`SHL`) — SSG/SSR, shipped first

| ID   | Requirement                                                                                                                                                                                          | Status      | Traces to                    |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------- |
| SHL1 | An SSG/SSR backend must invoke the D **`hue --html`** binary as a subprocess — passing code + language + theme, reading back the HTML fragment. This is the first shipped backend.                   | not started | `apps/hue --html` (`RS1`)    |
| SHL2 | It must **amortize process spawns** — a long-lived highlighter process / request pipe (a batch or streaming protocol), not one spawn per snippet; build-time SSG is the primary path, SSR secondary. | not started | proposed batch/pipe protocol |
| SHL3 | The binary must be **resolvable** — prebuilt per-platform binaries shipped with (or fetched by) the package, or a configured path; a clear error if absent, never a silent failure.                  | not started | package binary resolution    |

## Wasm backend (`WSM`) — client-side / edge, future

| ID   | Requirement                                                                                                                                                                                                  | Status      | Traces to                                                              |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ---------------------------------------------------------------------- |
| WSM1 | A future backend must compile `sparkles:syntax` to **wasm** (the LDC WASI fork, already demonstrated by the docs cell-explorer widget) and highlight **client-side** in the browser (SPA) with no shell-out. | not started | `sparkles:syntax` wasm (LDC WASI); memory `ldc-wasm-stduni-infeasible` |
| WSM2 | The wasm backend must expose the **same `PKG` API** so it drops in behind the same package; it may also serve **SSR** in a JS/edge runtime (no native binary).                                               | not started | `PKG4`                                                                 |
| WSM3 | It must ship the grammar/theme data the wasm engine needs (tree-sitter grammars as wasm or data); document the **payload-size trade-off** vs the shell-out backend.                                          | not started | bundling concern                                                       |

## Framework integrations (`FWK`)

| ID   | Requirement                                                                                                                                  | Status      | Traces to                           |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------- |
| FWK1 | **VitePress / Vue** — replace Shiki via `markdown.highlight` (this **absorbs** [twoslash.md `RS3`](./twoslash.md)); light/dark theme parity. | not started | `docs/.vitepress/config.mts`; `RS3` |
| FWK2 | **Next.js** — a rehype / MDX integration (the `rehype-pretty-code` shape) over `@sparkles/hue`; SSG + RSC/SSR.                               | not started | proposed rehype plugin              |
| FWK3 | **Solid Start** — a highlighter component/primitive; SSG + SSR.                                                                              | not started | proposed Solid integration          |
| FWK4 | A **generic** framework-agnostic adapter (a bare `codeToHtml` + a rehype plugin) so other frameworks integrate without bespoke code.         | not started | proposed generic adapter            |

## Milestones

| Milestone | Scope                                                                   | Status      | Requirements                  |
| --------- | ----------------------------------------------------------------------- | ----------- | ----------------------------- |
| W0        | The [`RS1`](./twoslash.md) SSG code→HTML contract (the substrate)       | partial     | `RS1` (twoslash.md)           |
| W1        | `@sparkles/hue` package + shell-out SSG backend + VitePress integration | not started | `PKG*`, `SHL1`/`SHL3`, `FWK1` |
| W2        | Next.js + Solid Start + the generic rehype adapter                      | not started | `FWK2`–`FWK4`                 |
| W3        | SSR via shell-out (long-lived process / pipe)                           | not started | `SHL2`                        |
| W4        | Wasm client-side backend (LDC WASI) behind the same API                 | not started | `WSM1`/`WSM2`                 |
| W5        | Wasm SSR + the optional twoslash overlay transform                      | not started | `WSM2`, `PKG5`                |

## Relationship to existing specs

| Piece                                                    | Role                                                            |
| -------------------------------------------------------- | --------------------------------------------------------------- |
| [twoslash.md `RS1`](./twoslash.md) (`apps/hue --html`)   | the SSG code→HTML contract the shell-out backend wraps (`SHL1`) |
| [twoslash.md `RS2`](./twoslash.md) (playground)          | a consumer of this package (SSG-prerendered, then wasm)         |
| [twoslash.md `RS3`](./twoslash.md) (VitePress)           | subsumed as framework integration `FWK1`                        |
| [twoslash.md `TWM2`](./twoslash.md) (`.twoslash-*` HTML) | the optional overlay transform (`PKG5`)                         |
| `sparkles:syntax` wasm (LDC WASI)                        | the wasm backend engine (`WSM1`)                                |
| **proposed `@sparkles/hue`** npm package                 | the JS layer these compose into                                 |

→ [Twoslash requirements](./twoslash.md) · [General requirements](./feature-requirements.md) · [Overview](./index.md)
