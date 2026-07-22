# `sparkles:twoslash` — render-side spec (issue #123)

**Status:** shipped (render-side). Backend (`sparkles:dmd-lsp`, #124) is future work.

`sparkles:twoslash` proves the **render surface** of a D-native Twoslash (umbrella
issue #120) by consuming the _existing_ TypeScript
[`twoslash`](https://github.com/twoslashes/twoslash) node model as **opaque data**
and rendering it as a type-annotation overlay over `sparkles:syntax` — in **HTML**,
**ANSI**, and the **raylib GUI** (`hue --gui`). Using the real, working TS twoslash
as the semantic source validates the renderer overlay (#120 §5) without waiting on
the D backend. Swapping the data source for `sparkles:dmd-lsp` later is a backend
substitution behind this proven seam.

## 1. Node model (consumed as data)

Ported from the reference `twoslash-protocol`. A `TwoslashReturn` is the trimmed
display `code` plus a flat `nodes[]`. Each node has `type`, byte `start`/`length`,
and 0-based `line`/`character`, with a per-`type` payload:

| `type`       | payload we use                                    | rendering                                  |
| ------------ | ------------------------------------------------- | ------------------------------------------ |
| `hover`      | `text` (type sig), `docs?`                        | inline dotted-underline token + popup      |
| `query`      | `text`, `docs?`                                   | below-line popup at the `^?` column        |
| `completion` | `completions[] {name,kind?}`, `completionsPrefix` | below-line list                            |
| `error`      | `text`, `level?`, `code?`, `id?`                  | inline wavy underline + below-line message |
| `highlight`  | —                                                 | inline highlighted box                     |
| `tag`        | `name`, `text?`                                   | below-line `// @name` annotation           |

**Modeling choice:** one flat `Node` POD with a `NodeType` discriminant, _not_ a
`SumType`. `sparkles:wired` decodes a sum by probing every variant, and twoslash
nodes overlap too much (shared `start`/`length`/`line`/`character`) to disambiguate
that way. A flat struct decodes uniformly (present fields fill, absent ones default
— every non-universal field is `@WireOptional`), wired ignores unknown JSON keys
(`target`, `tags`, `filename`, `meta`, `flags`, …), and the lowercase enum members
map the `type` strings verbatim under wired's default `CaseStyle.original`.

## 2. Overlay planner (`overlay.d`)

`planTwoslash` partitions `nodes` into two sorted work-lists shared by all three
backends:

- **inline decorations** (`hover`/`highlight`/`error`) — sorted `start` asc, `end`
  desc so an enclosing span opens before a nested one.
- **below-line blocks** (`error`/`query`/`completion`/`tag`) — sorted by line.

An `error` is _both_. `highlightSignature` re-highlights a popup type signature by
re-entering `sparkles:syntax` as TypeScript; on a missing grammar it degrades to
plain text, so the overlay never fails.

## 3. HTML overlay (`render_html.d`)

Matches the `@shikijs/twoslash` `.twoslash-*` class contract so `style-rich.css`
(ported in `style.d` / `views/twoslash.css`) transfers, with 100% CSS `:hover`
interactivity — no JS.

Key insight: `byStyledSpan` already flattens syntax to **non-overlapping
single-label runs**, and inline decorations are **line-scoped** (never cross a
`'\n'`). So nesting reduces to a sweep over {run edges, decoration edges, newlines}
with a decoration stack (outer) + one syntax `<span>` per segment (inner). Below-line
blocks are flushed at the newline seam (after tags close, before the next line) so
every output line stays valid markup — the same per-line-validity discipline as
`sparkles:syntax`'s `renderHtml`, which is called **reentrantly** to re-highlight
each popup type signature. Any below-blocks anchored _past_ the last code line are
flushed after the sweep — twoslash gives a trailing `@tag`/query (e.g. an
`// @annotate:` at the very end) a line index one past the end. The ANSI backend
applies the same trailing-flush.

Emitted markup (abridged):

```
<span class="twoslash-hover"><span class="twoslash-popup-container">
  <code class="twoslash-popup-code">{re-highlighted sig}</code>
  <div class="twoslash-popup-docs">{docs}</div>
  <div class="twoslash-popup-docs twoslash-popup-docs-tags">
    <span class="twoslash-popup-docs-tag"><span class="twoslash-popup-docs-tag-name">@param</span>
      <span class="twoslash-popup-docs-tag-value">{text}</span></span></div></span>{token}</span>
<span class="twoslash-highlighted">…</span>
<span class="twoslash-error twoslash-error-level-error">…</span>
<div class="twoslash-meta-line twoslash-error-line …">{message}</div>
<div class="twoslash-meta-line twoslash-query-line"><span class="twoslash-popup-container">
  <div class="twoslash-popup-arrow"></div>…popup…</span></div>
<ul class="twoslash-completion-list"><li>
  <span class="twoslash-completions-icon completions-{kind}">{svg}</span>
  <span><span class="twoslash-completions-matched">…</span><span class="twoslash-completions-unmatched">…</span></span></li></ul>
<div class="twoslash-tag-line twoslash-tag-{name}-line">
  <span class="twoslash-tag-icon tag-{name}-icon">{svg}</span>{text}</div>
```

This tracks the `@shikijs/twoslash` `rendererRich` contract: per-kind completion
**and** tag icons (the reference SVGs, string-imported; configurable to Unicode
glyphs or off), the matched/unmatched split wrapped so the flex gap never bisects
a candidate, a connector **arrow** on the popups (both hover and query — a
deliberate step past shiki, which arrows the query only), and JSDoc `@tag`
**chips**. The below-line query/completion popups are offset with
`margin-left:{character}ch` so they sit under their `^?`/`^|` caret column (the
completion list inherits the code font-size so `ch` tracks the monospace grid). A
token carrying both a `hover` and a `query` renders the query only (the planner
drops the redundant hover). `TwoslashHtmlOptions` also offers an opt-in
quickinfo-prefix strip (`(property) ` → ``). Output is content-only; the caller
wraps it in `<pre class="syn-root twoslash">`.

Fidelity is guarded by `examples/compare-shiki.mjs` (§6): it diffs our `.twoslash-*`
HTML-class vocabulary and CSS-selector coverage against Shiki's live `rendererRich`
output over the corpus, allowlisting the deliberate model differences (we render
queries/errors as below-line blocks, not Shiki's inline `query-persisted` popups).

## 4. ANSI overlay (`render_ansi.d`) — the differentiator

**Nobody ships terminal twoslash.** Line-oriented: each code line renders through
`renderAnsi` (per-line-valid SGR) with `highlight`/`error` spans bracketed in
reverse-video / underline, then below-line meta rows — a caret (`^^^` / `^?`) at the
column plus the error message (red/yellow by level), the re-highlighted query type,
the completion candidates, or the `// @tag` text. Hovers are silent by default and
expand to a dim `↳ type` line under `--verbose`-style `hovers`.

## 5. raylib GUI overlay (`apps/hue`, `runGuiTwoslash`)

The GPU counterpart, on the monospace grid: `x = pad + character·cellW`, `y`
accumulates (code line + interleaved annotation rows). Highlights → translucent tint
boxes; errors → red wavy underline + below-line message; query/completion/tag →
annotation rows; hovers → floating popup on mouse-over (the GPU analogue of CSS
`:hover`), with the re-highlighted signature. Reuses `gui.d`'s
`drawText`/`rl`/`mapStyle`/`cstrOf` and `sparkles:raylib-text`.

## 6. Data source & hermeticity

`libs/twoslash/examples/` holds twoslash-annotated sources in `src/*.ts(x)` — one
per feature (hover, `^?` query, `^|` completion, `@errors`, `^^^` highlight,
`@annotate` tag, generics, JSDoc, multi-file, `---cut---`, TSX, async), plus two
ported from the `@shikijs/twoslash` docs (its `rendererRich` showcase — a
`Readonly<T>` query + read-only error + completion in one snippet — and the
four custom-tag notations `@log`/`@error`/`@warn`/`@annotate`) — and the
committed `fixtures/*.twoslash.json` overlays generated from them (the trimmed
`{code, nodes}` slice the renderer reads). `examples/regen.sh` is a real,
developer-only generator: it `npm install`s the reference TypeScript `twoslash`
(+ `typescript`) and runs `regen.mjs` over every source. It is the **only** place
node is invoked — the sparkles build and `dub test` are **node-free** and consume
the committed JSON, so nothing downstream needs node. Because `nodes` is opaque
input, the same `{code, nodes}` shape comes from any twoslash-compatible source
(twoslash today, `sparkles:dmd-lsp` later).

Two dev-only checks live in the same node corner (never run at build time; run
them after touching the HTML renderer or the stylesheet):

- `examples/compare-shiki.mjs` — the **fidelity** check: renders each source
  through Shiki's `rendererRich` and through `hue --twoslash --html`, then compares
  the `.twoslash-*` class vocabulary and CSS-selector coverage (see §3).
- `examples/visual-check.mjs` — the **geometry** check: lays the rendered overlay
  out in headless Chromium and asserts the popup positioning invariants a markup
  diff can't see (below-line popups detach by a uniform ~1ch; the completion list
  anchors under the caret column − prefix). The devshell provides Chromium and
  exports `$CHROME_BIN`; the check skips cleanly if no browser is present.

## Deferred

- **Markdown in docs/tags** — hover/query `docs` and `@tag` values render as escaped
  text today. Rendering them as markdown (Shiki's `renderMarkdown`/`renderMarkdownInline`
  seam) awaits the reusable `MdDoc`/`extractMarkdown` model in `sparkles:syntax`
  (the `hue --gui` markdown-preview work); it slots in behind a new `MdDoc→HTML`
  emitter with no bespoke parser here.
- **Live VitePress swap** — depends on #122's VitePress highlighter seam (not built;
  the site still uses stock VitePress→Shiki with no `markdown.config` hook).
- **Analyzer / D-native backend** — #124 (`sparkles:dmd-lsp`); this issue treats
  nodes as opaque input.
