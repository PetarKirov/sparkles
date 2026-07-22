# `sparkles:twoslash` — render-side spec (issue #123)

**Status:** shipped (render-side). Backend (`sparkles:dmd-lsp`, #124) is future work.

`sparkles:twoslash` proves the **render surface** of a D-native Twoslash (umbrella
issue #120) by consuming the *existing* TypeScript
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

| `type`       | payload we use                        | rendering |
| ------------ | ------------------------------------- | --------- |
| `hover`      | `text` (type sig), `docs?`            | inline dotted-underline token + popup |
| `query`      | `text`, `docs?`                       | below-line popup at the `^?` column |
| `completion` | `completions[] {name,kind?}`, `completionsPrefix` | below-line list |
| `error`      | `text`, `level?`, `code?`, `id?`      | inline wavy underline + below-line message |
| `highlight`  | —                                     | inline highlighted box |
| `tag`        | `name`, `text?`                       | below-line `// @name` annotation |

**Modeling choice:** one flat `Node` POD with a `NodeType` discriminant, *not* a
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

An `error` is *both*. `highlightSignature` re-highlights a popup type signature by
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
each popup type signature.

Emitted markup (abridged):

```
<span class="twoslash-hover"><span class="twoslash-popup-container">
  <code class="twoslash-popup-code">{re-highlighted sig}</code>
  <div class="twoslash-popup-docs">{docs}</div></span>{token}</span>
<span class="twoslash-highlighted">…</span>
<span class="twoslash-error twoslash-error-level-error">…</span>
<div class="twoslash-error-line …">{message}</div>
<div class="twoslash-meta-line twoslash-query-line">…popup…</div>
<ul class="twoslash-completion-list"><li>…matched/unmatched…</li></ul>
<div class="twoslash-tag-line twoslash-tag-{name}-line">{text}</div>
```

Output is content-only; the caller wraps it in `<pre class="syn-root twoslash">`.

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

Fixtures under `libs/twoslash/examples/fixtures/*.twoslash.json` are committed
(reduced from the upstream twoslash test corpus to `{code, nodes}`). The build and
`dub test` are **node-free**; `regen.sh` documents developer-only regeneration.

## Deferred

- **Live VitePress swap** — depends on #122's VitePress highlighter seam (not built;
  the site still uses stock VitePress→Shiki with no `markdown.config` hook).
- **Analyzer / D-native backend** — #124 (`sparkles:dmd-lsp`); this issue treats
  nodes as opaque input.
