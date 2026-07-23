# `hue --twoslash` / `hue --markdown` — Feature Requirements (planned · branch-only)

_**Status:** planned / **branch-only** · **Date:** 2026-07-23 · **Scope:** the
`hue` integration of `sparkles:twoslash` — the `--twoslash` and `--markdown`
rendering modes and the raylib twoslash overlay._

> [!IMPORTANT]
> Every requirement in this document is **implemented only on the
> `feat/syntax-twoslash` branch** (worktree `sparkles-syntax-twoslash`), which is
> **unpushed and not merged** into `feat/hue-preview-polish` (the branch the other
> hue specs describe). On the current branch there is no `libs/twoslash/` and no
> `twoslash`/`--markdown` code in `apps/hue/`. These rows are therefore **planned
> (branch-only)** relative to the shipped hue: the design and code exist and are
> green (`dub test :twoslash` ≈ 35 tests, `nix build .#hue`), but they land in hue
> only when `feat/syntax-twoslash` merges. The library-side requirements are
> owned by `docs/specs/twoslash/SPEC.md` (also on that branch); this doc covers
> the **hue surface** and references the library for internals.

Twoslash ([issue #120](https://github.com/PetarKirov/sparkles/issues/120)) makes
`hue` a D-native [Twoslash](https://twoslash.netlify.app/) renderer: it consumes a
TypeScript-`twoslash` node model (`{code, nodes[]}`) and overlays hovers, queries,
completions, errors, highlights, and custom tags onto the highlighted code, in
**three backends** — ANSI (terminal, the differentiator), HTML (Shiki
`.twoslash-*` fidelity, no JS), and the raylib GUI. Status legend and conventions:
see the [overview](./index.md).

## Twoslash CLI modes in hue (`TWM`)

`apps/hue/src/app.d` (branch `feat/syntax-twoslash`) — `runTwoslashMode` /
`runMarkdownMode`.

| ID   | Requirement                                                                                                                                                                  | Status                                        | Traces to                                    |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | -------------------------------------------- |
| TWM1 | `--twoslash <nodes.json>` must load the node model, highlight its `code` as TypeScript, and render the overlay; **ANSI is the default** backend.                             | planned/branch-only (`168c9cf8`)              | `app.runTwoslashMode`                        |
| TWM2 | `hue --twoslash --html` must emit a self-contained `<style>` + `<pre class="syn-root twoslash">` page (the Shiki `.twoslash-*` contract, pure CSS `:hover`).                 | planned/branch-only (`168c9cf8`)              | HTML branch → `libs/twoslash` `render_html`  |
| TWM3 | `hue --gui --twoslash` must open the raylib window and route to the GPU overlay (see `TWO`).                                                                                 | planned/branch-only (`1d29b675`)              | `app.d` → `gui.runGuiTwoslash`               |
| TWM4 | `--markdown <file.md>` must render any Markdown to HTML via the shared `sparkles:syntax` `MdDoc → HTML` emitter (no twoslash/theme) — a standalone exercise of that emitter. | planned/branch-only (`app.d runMarkdownMode`) | `app.runMarkdownMode`                        |
| TWM5 | The twoslash driver must live **only in `apps/hue`**; the reusable overlay logic stays in `libs/twoslash` (no standalone demo app).                                          | planned/branch-only (design)                  | decision (memory `twoslash-render-side-123`) |

## Twoslash raylib overlay (`TWO`)

`apps/hue/src/gui.d` (branch) — `runGuiTwoslash`, gated behind `version(HueGui)`;
depends on the [`--gui` backend](./gui.md) (#121) having landed.

| ID   | Requirement                                                                                                                                                                                                                                         | Status                           | Traces to                                                                       |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------- |
| TWO1 | The overlay must draw on the monospace grid: inline decorations at `x = pad + character·cellW`; annotation rows accumulate `y` (interleaved with code lines), not `line·cellH`.                                                                     | planned/branch-only (`1d29b675`) | `gui.runGuiTwoslash`                                                            |
| TWO2 | Visual mapping: highlight → translucent tint rect; error → red wavy underline + below-line message; query/completion/tag → annotation rows; hover → floating mouse-hover popup (GPU analogue of CSS `:hover`) with a re-highlighted type signature. | planned/branch-only (`1d29b675`) | `runGuiTwoslash` (uses `sparkles:twoslash` `planTwoslash`/`highlightSignature`) |
| TWO3 | The overlay must reuse `gui.d`'s `drawText`/`rl`/`mapStyle`/`cstrOf` + `sparkles:raylib-text`; no new render primitives.                                                                                                                            | planned/branch-only (`1d29b675`) | `runGuiTwoslash`                                                                |

## Library requirements hue drives (summary)

The full library contract is `docs/specs/twoslash/SPEC.md` (branch `feat/syntax-twoslash`).
hue drives these entry points (all **planned/branch-only**):

| Area                  | Requirement (hue-relevant)                                                                                                                                                                    | Traces to (`libs/twoslash`)           |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Node model / protocol | Flat `Node` POD (not `SumType`) with `NodeType` discriminant + `@WireOptional` payloads; `TwoslashReturn{code,nodes}`.                                                                        | `protocol.d`                          |
| Ingest                | Decode the JSON via `sparkles:wired`; **UTF-16 → UTF-8** offset remap (renderers index `code` as UTF-8 bytes).                                                                                | `ingest.d`                            |
| Overlay planner       | `planTwoslash` partitions nodes into inline decorations + below-line blocks; suppress hover when a query covers the token; `highlightSignature` re-highlights popup signatures as TypeScript. | `overlay.d`                           |
| HTML backend          | `.twoslash-*` class contract, 100% CSS `:hover`, completion/tag icons (`svg`/`glyph`/`none`), popup arrows, JSDoc `@tag` chips, `docs` rendered as markdown via the `MdDoc→HTML` emitter.     | `render_html.d`, `style.d`, `icons.d` |
| ANSI backend          | Terminal twoslash: per-line-valid SGR, caret meta-lines (`^^^`/`^?`) below code, error underline, hovers silent unless `opts.hovers`.                                                         | `render_ansi.d`                       |

## Backend: DMD-as-a-library (`DMD`, researched)

The current modes consume a **pre-parsed** node model (produced by the reference
TS `twoslash` at fixture-generation time). A future D-native backend
([issue #124](https://github.com/PetarKirov/sparkles/issues/124),
`sparkles:dmd-lsp`) would produce that node model from D source directly, swapping
in **behind the proven node-model seam** (no renderer change).

| ID   | Requirement                                                                                                                                                          | Status                                                                                                                                      | Traces to                                  |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ----------------------- |
| DMD1 | A D-native backend must produce the twoslash node model from D source (identifiers, hover-at-offset, completions, diagnostics).                                      | researched/not-started                                                                                                                      | design (memory `twoslash-d-native-design`) |
| DMD2 | The backend must be extracted as `sparkles:dmd-lsp` from VisualD's `dmdserver` (Boost-1.0), on the `rainers/dmd@dmdserver` fork; DCD is dropped (symbol-table only). | researched/not-started                                                                                                                      | design; issue #124                         |
| DMD3 | A notation parser (`// ^?`, `// ^                                                                                                                                    | `, `// ^^^`, `---cut---`, `@filename:`, `@errors:`) must turn annotated D into nodes; not yet implemented (#123 consumes pre-parsed nodes). | not started                                | design (analyzer layer) |

## Deferred twoslash sub-parts (`TWD`)

| ID   | Requirement                                                                                                                                         | Status               | Traces to                                              |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------------------------------------------------------ |
| TWD1 | Rendering hover/query `docs` (and `@tag` values) as **markdown** in the **ANSI and GUI** overlays (HTML does it today; ANSI/GUI show escaped text). | deferred/not-started | memory `twoslash-render-side-123` (optional follow-up) |
| TWD2 | Live **VitePress** swap (Shiki → `sparkles:syntax`+twoslash in the docs site) — blocked on the unbuilt #122 markdown-highlighter seam + playground. | deferred/not-started | issue #122; memory `twoslash-d-native-design`          |
| TWD3 | Independent selection domains in the twoslash HTML preview (popup content selectable separately; `Ctrl/Cmd+A` excluding annotations).               | researched           | plan (preview shell)                                   |

## Module coverage (twoslash surface)

| Source (branch `feat/syntax-twoslash`)                      | Requirements                                                                |
| ----------------------------------------------------------- | --------------------------------------------------------------------------- |
| `apps/hue/src/app.d` (`runTwoslashMode`, `runMarkdownMode`) | `TWM1`–`TWM5`                                                               |
| `apps/hue/src/gui.d` (`runGuiTwoslash`)                     | `TWO1`–`TWO3`                                                               |
| `libs/twoslash/src/sparkles/twoslash/*.d`                   | library summary (→ `docs/specs/twoslash/SPEC.md` on `feat/syntax-twoslash`) |
| `sparkles:dmd-lsp` (proposed)                               | `DMD1`–`DMD3`                                                               |

→ [General requirements](./feature-requirements.md) · [GUI requirements](./gui.md) · [Overview](./index.md)
