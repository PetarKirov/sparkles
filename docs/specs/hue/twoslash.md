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
> green (`dub test :twoslash` ≈ 37 tests, `nix build .#hue`), but they land in hue
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

> [!NOTE]
> Twoslash is the **first overlay** of hue's pluggable overlay layer. The
> decoration model and renderer contract it establishes here — decorations as
> extra `(start,length)` spans + below-line blocks + hover popups, painted by an
> overlay-agnostic renderer — are generalized in
> [overlays.md](./overlays.md) (`OVL*`), which specifies the additional overlay
> kinds (source map, coverage, tracing, tree-sitter inspector, code size) built
> on the same seam. This document remains the source of truth for the twoslash
> overlay itself.

## Architecture (issue [#120](https://github.com/PetarKirov/sparkles/issues/120))

Twoslash copies the reference stack's clean layer separation — this is the single
most important design property:

| Layer                | Reference package             | Responsibility                                                 | sparkles equivalent                                                    |
| -------------------- | ----------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **Protocol**         | `twoslash-protocol`           | Backend-agnostic positional node model — no backend dependency | `sparkles:twoslash` `protocol.d` (`Node`/`TwoslashReturn`)             |
| **Analyzer**         | `twoslash`                    | Parse notations → drive a semantic backend → emit nodes        | notation parser + `sparkles:dmd-lsp` (see `DMD`)                       |
| **Renderer**         | `@shikijs/twoslash`           | Overlay nodes onto highlighted code (HTML/ANSI/GPU)            | overlay over `sparkles:syntax` (`render_html`/`render_ansi`) + hue GUI |
| **Host integration** | `@shikijs/vitepress-twoslash` | Build-time fenced-block transform + client tooltips            | markdown lib (#45) + VitePress (see `RS1`)                             |

Because the analyzer is decoupled from any one backend, **any backend that answers
four queries over a buffer plugs into the same node model** — the seam
`sparkles:dmd-lsp` sits behind:

1. identifier spans, 2. hover-at-offset, 3. completions-at-offset, 4. diagnostics-per-file.

Boundary note: the notation parser and `sparkles:syntax` work in **byte offsets**;
`sparkles:dmd-lsp` reports **line/column** — the analyzer converts at the seam.
Positions are two-phase: build nodes with `start`/`length`, apply `---cut---`
removals, then resolve `line`/`character` against the post-cut text.

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

## Twoslash HTML overlay: chrome, docs, selection (`TWH`)

`hue --twoslash --html` emits the Shiki `.twoslash-*` contract with pure-CSS
`:hover` (`TWM2`); this section pins the overlay's concrete **chrome**, its
**markdown-rendered docs**, and its VSCode-like **selection/copy** behaviour — the
render-fidelity and selection work of [#123](https://github.com/PetarKirov/sparkles/issues/123).
Library internals are in `docs/specs/twoslash/SPEC.md`; the rows below are the
hue-observable surface. All **planned/branch-only**.

**Chrome & docs.**

| ID   | Requirement                                                                                                                                                                                                                                                                                                                    | Status                                       | Traces to                                                                                                    |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| TWH1 | Completion-kind and custom-tag **icons** must be configurable — `svg` (the reference Shiki SVGs, string-imported) / `glyph` (a Unicode glyph per kind) / `none` — plus a custom per-kind delegate; an unknown kind falls back to `property`.                                                                                   | planned/branch-only (`0d9e062b`, `ff403ff3`) | `libs/twoslash` `render_html.d`, `icons.d`, `views/icons/**`                                                 |
| TWH2 | Both the hover and the query popup must carry a connector **arrow**; the completion list's arrow must point at the caret column (a deliberate step past Shiki, which arrows the query only).                                                                                                                                   | planned/branch-only (`5e06c2d6`, `7f5277c7`) | `render_html.d`, `views/twoslash.css`                                                                        |
| TWH3 | JSDoc `@tag` values must render as **chips** (`@name` + optional value span); inline `` `code` `` must get a code surface; and links (`[text](url)` and `<url>` autolinks) must render as styled links.                                                                                                                        | planned/branch-only (`27cb50d4`, `c51377a8`) | `render_html.d`, `views/twoslash.css` (+ `<url>` autolink fix in `sparkles:syntax` `md/model.d`, `41bae140`) |
| TWH4 | Hover/query `docs` (block) and each `@tag` value (inline) must render as **markdown** via the shared `sparkles:syntax` `MdDoc → HTML` emitter (`renderMarkdownHtml` / `renderMarkdownInlineHtml`), gated by `TwoslashHtmlOptions.renderDocsMarkdown` (default on) and degrading to escaped text without the markdown grammars. | planned/branch-only (`66ba52a8`, `bf8fac9e`) | `render_html.d`; syntax `md/render_html.d` (`DEF3`)                                                          |
| TWH5 | An opt-in **quickinfo-prefix strip** must remove a leading `(property) `/`(parameter) `/… from popup signatures; the default keeps it.                                                                                                                                                                                         | planned/branch-only (`bf6f40ac`)             | `overlay.withoutQuickinfoPrefix`                                                                             |

**Selection & copy** — the HTML analogue of the GUI's [`SEL`](./gui.md); realizes
the "decorations excluded" half of
[`HTM3`](./feature-requirements.md#html-output-htm) for the overlay, in pure CSS:

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                             | Status                           | Traces to            |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | -------------------- |
| TWH6 | **Code-only selection:** the annotation surfaces (`.twoslash-meta-line`, `.twoslash-completion-list`, `.twoslash-tag-line`, `.twoslash-popup-container`) must be `user-select: none`, so a browser copy of the code yields **only the code** — for every consumer (hue `--html`, VitePress, the preview). Inline decoration spans wrapping code tokens stay selectable. | planned/branch-only (`8092af01`) | `views/twoslash.css` |
| TWH7 | Hover popups must be hidden with **`display: none`** (not `opacity: 0`), so a hidden popup adds no layout: a copied code selection carries no popup-injected newlines and there is no hidden-popup horizontal scrollbar. (Trades Shiki's opacity fade for a clean copy.)                                                                                                | planned/branch-only (`ab3abfc6`) | `views/twoslash.css` |
| TWH8 | Full-width below-line blocks (`.twoslash-error-line`, `.twoslash-tag-line`, `min-width: 100%`) must set `box-sizing: border-box`, so their padding + border stay inside the line — self-contained (no host CSS reset needed; no stray horizontal scrollbar).                                                                                                            | planned/branch-only (`ef6e0aa1`) | `views/twoslash.css` |

> [!NOTE]
> The **UTF-16 → UTF-8** offset remap (`ingest.d`, `1c6f9079`) and the
> **query-suppresses-hover** rule (`overlay.planTwoslash`) from the library summary
> are shared by all three backends, but they are what let the HTML overlay position
> decorations correctly on non-ASCII code and drop a redundant hover popup.

## Verification & preview tooling (branch-only)

The HTML overlay is guarded by dev-only harnesses in `libs/twoslash/examples/`
(node + Chromium; the sparkles build itself stays node-free):

- **`render-html.mjs`** (`npm run render`) — renders every fixture through
  `hue --twoslash --html` into a git-ignored `html/` gallery: a full-height code
  pane, a non-selectable physical-line **gutter**, prev/next nav, and the `TWD3`
  **selection domains**.
- **`compare-shiki.mjs`** — asserts our `.twoslash-*` **class vocabulary** and
  **CSS-selector coverage** ⊇ Shiki `rendererRich` over the same corpus
  (allowlisting the deliberate model differences).
- **`visual-check.mjs`** — lays the overlay out in **headless Chrome** and asserts
  popup **geometry** (below-line gaps, caret-aligned completion column) a markup
  diff can't see.

`hue --markdown <file.md>` (`TWM4`) is the standalone exercise of the same
`MdDoc → HTML` emitter (`TWH4`), with no twoslash involved.

## Notation syntax (`NOT`, issue [#120](https://github.com/PetarKirov/sparkles/issues/120) §3)

The D-native analyzer (the notation parser that turns annotated D into the node
model) is **not built** — the shipped modes consume a pre-parsed node model
produced by the reference TS twoslash. The notation grammar (markers point at the
line above, aligned by caret column) it must reproduce:

| ID   | Marker                                                | Meaning                                                                                                         | Status      |
| ---- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ----------- |
| NOT1 | `// ^?`                                               | Query: inferred type of the identifier above the `^`.                                                           | not started |
| NOT2 | `// ^\|`                                              | Completions at the `^` position.                                                                                | not started |
| NOT3 | `// ^^^`                                              | Highlight the caret-spanned range (optional annotation).                                                        | not started |
| NOT4 | `// ---cut---` / `---cut-{before,after,start,end}---` | Drop code from the shown output (still compiled).                                                               | not started |
| NOT5 | `// @errors: <patterns>` / `// @noErrors`             | Expected diagnostics as a contract — **matched by message/`{{_}}` glob** (D has no stable numeric error codes). | not started |
| NOT6 | `// @filename: <name>`                                | Multi-file split (kept in output).                                                                              | not started |
| NOT7 | `// @dflags:` / `// @import:` / `// @dub:`            | D project config for the sample's analysis (compiler flags, import path, dub dep).                              | not started |
| NOT8 | `// @<tag>: …`                                        | Custom tags (`annotate`/`log`/`warn`/`error`).                                                                  | not started |

## Render-side 1/2 — `sparkles:syntax` as a Shiki replacement (`RS1`, issue [#122](https://github.com/PetarKirov/sparkles/issues/122))

The render-side substrate (independent of any D backend) that twoslash builds on.

| ID  | Requirement                                                                                                                                                                                           | Status      | Traces to                                                                             |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------- |
| RS1 | An SSG "code → HTML" mode (the `codeToHtml` equivalent): `cssClasses` + `inlineStyles` + the reserved CSS-variable multi-theme mode, over the docs' language set + the VitePress `languageAlias` map. | partial     | `apps/hue --html` `cssClasses` exists; `inlineStyles`/multi-theme + alias map pending |
| RS2 | A grammar/theme **playground** (the TextMate-playground equivalent): SSG-prerendered first, then an optional wasm client-side renderer (LDC WASI).                                                    | not started | issue #122 §2                                                                         |
| RS3 | **VitePress integration**: replace Shiki with `sparkles:syntax` in `docs/.vitepress/config.mts` (custom `markdown.highlight`), porting the `languageAlias` set and light/dark parity.                 | not started | issue #122 §3                                                                         |

> [!NOTE]
> `RS1`–`RS3` are the D-side render substrate. Their distribution as a **JS npm
> package** (`@sparkles/hue`, a Shiki drop-in for VitePress / Next / Solid Start,
> shell-out then wasm) is specified in
> [web-integration.md](./web-integration.md) — where `RS1` is the shell-out
> target, `RS2`'s playground is a consumer, and `RS3` (VitePress) is absorbed as
> framework integration `FWK1`.

## Backend: DMD-as-a-library (`DMD`, researched)

The current modes consume a **pre-parsed** node model (produced by the reference
TS `twoslash` at fixture-generation time). A future D-native backend
([issue #124](https://github.com/PetarKirov/sparkles/issues/124),
`sparkles:dmd-lsp`) would produce that node model from D source directly, swapping
in **behind the proven node-model seam** (no renderer change).

| ID   | Requirement                                                                                                                                                                                                                                 | Status                 | Traces to                                                 |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | --------------------------------------------------------- |
| DMD1 | A D-native backend must answer the four-query contract over a buffer (identifier spans, hover-at-offset, completions-at-offset, diagnostics) from **one** semantic pass.                                                                    | researched/not-started | design (memory `twoslash-d-native-design`); issue #120 §4 |
| DMD2 | The backend must be **DMD-as-a-library** (DCD dropped — symbol-table only, no inference), extracted as `sparkles:dmd-lsp` from VisualD's `dmdserver` (`semvisitor.d` `findTip`/`tipDataForObject` → resolved `Expression.type`), Boost-1.0. | researched/not-started | issue #120 §4; issue #124                                 |
| DMD3 | It must vendor/pin the `rainers/dmd@dmdserver` LanguageServer fork via Nix (mainline `dmd.frontend` is reduced-fidelity); the `dmdinit.d` mangled-`static` reset is the standing per-DMD-version maintenance cost.                          | researched/not-started | issue #120 §4                                             |
| DMD4 | An optional zero-dependency fallback (`pragma(msg, typeof(expr).stringof)` prober) may answer `^?` on named expressions without the fork — behind the backend seam, never the primary path.                                                 | researched/not-started | issue #120 §4                                             |

## Deferred twoslash sub-parts (`TWD`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                               | Status                                            | Traces to                                              |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------ |
| TWD1 | Rendering hover/query `docs` (and `@tag` values) as **markdown** in the **ANSI and GUI** overlays (HTML does it today; ANSI/GUI show escaped text).                                                                                                                                                                                                                                                                                       | deferred/not-started                              | memory `twoslash-render-side-123` (optional follow-up) |
| TWD2 | Live **VitePress** swap (Shiki → `sparkles:syntax`+twoslash in the docs site) — blocked on the unbuilt #122 markdown-highlighter seam + playground.                                                                                                                                                                                                                                                                                       | deferred/not-started                              | issue #122; memory `twoslash-d-native-design`          |
| TWD3 | The dev **preview** (`render-html.mjs`) implements VSCode-like **selection domains** — a `mousedown` handler confines a drag to the domain it starts in (code-only, or one contained annotation), layered on `TWH6`; plus a physical-line **gutter** (non-selectable numbers) that preserves blank lines in the copy. Limits: hover-popup content is not independently selectable (hover-ephemeral); `Ctrl/Cmd+A` uses the default state. | full (branch; `87ee7e62`, `21d722b4`, `3fa8324d`) | `libs/twoslash/examples/render-html.mjs`               |

## Non-goals (v1, issue [#120](https://github.com/PetarKirov/sparkles/issues/120) §7)

- **Multi-language** — D only (the seam stays generic; one backend ships).
- **A full incremental/async LSP server** — `sparkles:dmd-lsp` v1 is a **batch**
  core (analyze once, query at markers); a JSON-RPC server is a later milestone.
- **DCD** — explicitly not used (symbol-table only, no inference).
- **JS emit / `@showEmit`** — no JS target (may later reinterpret as `dmd -H` / `pragma(msg)` output).
- **Framework SFC adapters, remote/CDN backends, automatic type acquisition** — reference packages we don't need.
- **Interactive web client** — deferred; pure-CSS `:hover` popups first.
- **Stable numeric error codes** — D has none; `@errors:` matches messages/globs.

## Milestones (issue [#120](https://github.com/PetarKirov/sparkles/issues/120) §8)

Two tracks. The renderers (M1/M5/M6 + hue GUI) were proven against the reference
TS twoslash as the data source (`#123`); the `dmd-lsp` backend (`#124`) swaps in
behind the node-model seam later.

**`sparkles:twoslash` track:**

| Milestone | Scope                                                          | Status                                            |
| --------- | -------------------------------------------------------------- | ------------------------------------------------- |
| M0        | Design spec (`docs/specs/twoslash/`, `dmd-lsp/`)               | done (branch)                                     |
| M1        | Node model + ingest (notation parser deferred — see `NOT`)     | done (branch; parser not built)                   |
| M2–M4     | Diagnostics / hovers / completions **from a backend**          | not started (needs `DMD*`)                        |
| M5        | Rich HTML renderer (`.twoslash-*` contract)                    | done (branch)                                     |
| M6        | ANSI / terminal renderer (meta-lines) + hue GUI overlay        | done (branch; `TWO*`)                             |
| M7        | Markdown/docs integration (#45) + `apps/ci --verify` + caching | partial (fixtures; CI verify + VitePress pending) |
| M8        | _(optional)_ Interactive web client for VitePress              | not started                                       |

**`sparkles:dmd-lsp` track (`#124`):** D1 fork + build + analysis driver · D2
type oracle (`findTip`/`findDefinition`) · D3 completions + semantic tokens + refs
— all **not started** (see `DMD*`).

## Module coverage (twoslash surface)

| Source (branch `feat/syntax-twoslash`)                                                                                          | Requirements                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `apps/hue/src/app.d` (`runTwoslashMode`, `runMarkdownMode`)                                                                     | `TWM1`–`TWM5`                                                                              |
| `apps/hue/src/gui.d` (`runGuiTwoslash`)                                                                                         | `TWO1`–`TWO3`                                                                              |
| `libs/twoslash/src/sparkles/twoslash/*.d` (`render_html.d`, `style.d`/`views/twoslash.css`, `icons.d`, `ingest.d`, `overlay.d`) | `TWH1`–`TWH8`; library summary (→ `docs/specs/twoslash/SPEC.md` on `feat/syntax-twoslash`) |
| `libs/twoslash/examples/` (`render-html.mjs`, `compare-shiki.mjs`, `visual-check.mjs`)                                          | `TWD3`; verification & preview tooling                                                     |
| `sparkles:dmd-lsp` (proposed)                                                                                                   | `DMD1`–`DMD3`                                                                              |

→ [General requirements](./feature-requirements.md) · [GUI requirements](./gui.md) · [Overview](./index.md)
