---
status: accepted
owner: sparkles:twoslash
---

# `sparkles:twoslash` — render-side spec (issue #123)

## Abstract

`sparkles:twoslash` draws compiler-verified type information over
highlighted source code: hover signatures, queried types, completion lists,
compiler errors, highlighted spans, and annotation lines, each placed at the
characters it describes. It renders one annotated snippet three ways from a
single shared plan of what sits inside each line and what goes beneath it:
as static HTML whose popups need no script, as colored terminal text, and as
a widget tree that a GPU window or an interactive terminal paints. It takes
the annotations as data from any Twoslash-compatible producer and never runs
a compiler itself, so analysis and rendering evolve separately, and a build
that only renders needs none of the analyzer's toolchain.

## Introduction

Documentation for a typed language is more convincing when its examples
show what the compiler actually concluded: the inferred type under a cursor,
the error a line provokes, the members a completion would offer.
[Twoslash](https://github.com/twoslashes/twoslash) is the established answer
in the TypeScript world. Comments in a snippet, such as a `^?` caret under an
identifier, ask the compiler questions. The tool answers with a flat list of
positioned results, called _nodes_, which a highlighter then draws over the
code.

That rendering half is tied to its ecosystem. The reference renderer is a
plugin for the [Shiki](https://shiki.style) highlighter, produces HTML only,
and expects a TypeScript toolchain in the build. Sparkles highlights code
with its own engine, [`sparkles:syntax`](../../libs/syntax/index.md), and
shows code in terminals and native windows as well as on the web. It also
aims to annotate D, not only TypeScript. The overlay must therefore work
wherever Sparkles shows code, and it must be buildable and testable without
waiting for any particular analyzer.

This library reads the nodes as data, never re-deriving them from the code,
and separates analysis from rendering at that seam. One planner splits the
nodes into [inline decorations](../../glossary.md#inline-decoration), which
mark a span within a line, and
[below-line blocks](../../glossary.md#below-line-block), which add rows
beneath the line they annotate. An error is both: its span is underlined and
its message printed beneath the line. The plan fixes only this line-level
structure; each backend sets its own geometry.

The HTML, terminal, and GUI backends all draw that one plan over the
highlighting that `sparkles:syntax` produces. The HTML output follows the
reference renderer's markup closely enough that its stylesheet carries over.
A popup whose grammar is missing degrades to plain text instead of failing.
Because the TypeScript tool already produces correct nodes, it serves as the
data source that proves the renderer, and a D producer fills the same seam.

Analysis is out of scope: this library never parses notation comments or
type-checks code. The node model and its JSON decoding live in the separate
`sparkles:twoslash-protocol` package, so a producer depends on neither the
renderer nor its highlighter. TypeScript nodes come from a generator whose
committed output the build reads. That generator and the checks against the
reference renderer are developer-only tools, so building and testing need no
JavaScript runtime. The D-native producer, which emits the same node shape,
is specified with [`sparkles:dmd-lsp`](../dmd-lsp/index.md). How hue, the
Sparkles code viewer, presents the overlay belongs to
[hue's Twoslash requirements](../hue/twoslash.md). Serving the overlay on the
documentation site is out of scope here; the [Deferred](#deferred) section
records it.

§1 defines the node model and the fields the renderers read, and §2 the
overlay planner they share. §3 and §4 specify the HTML and terminal
backends, and §5 the widget view that hue's GUI paints. §6 covers the
example corpus, its generator, and the developer-only checks of fidelity and
geometry against the reference renderer. The usage guide and API overview live in the
[library documentation](../../libs/twoslash/index.md).

## 1. Node model (consumed as data)

The model is not part of this package. It lives in
`sparkles:twoslash-protocol` (`libs/twoslash-protocol`), whose modules
`sparkles.twoslash.protocol` (the types) and `sparkles.twoslash.ingest` (JSON
decoding) depend only on `sparkles:wired`; `sparkles.twoslash` re-exports both.
It is ported from the reference `twoslash-protocol`. A `TwoslashReturn` is the
trimmed display `code` plus a flat `nodes[]`, with an optional `language` (the
highlighting language of `code`; absent means TypeScript) and an optional
`offsetEncoding`. Each node has `type`, `start`/`length`, and 0-based
`line`/`character`, with a per-`type` payload:

| `type`       | payload we use                                    | rendering                                  |
| ------------ | ------------------------------------------------- | ------------------------------------------ |
| `hover`      | `text` (type sig), `docs?`, `tags?`, `signature?` | inline dotted-underline token + popup      |
| `query`      | `text`, `docs?`, `tags?`, `signature?`            | below-line popup at the `^?` column        |
| `completion` | `completions[] {name,kind?}`, `completionsPrefix` | below-line list                            |
| `error`      | `text`, `level?`, `code?`, `id?`                  | inline wavy underline + below-line message |
| `highlight`  | —                                                 | inline highlighted box                     |
| `tag`        | `name`, `text?`                                   | below-line `// @name` annotation           |

`tags` holds a popup's JSDoc tags as `[name, text]` pairs, and `signature` a
structured `SignatureLayout` (break points, collapsible runs, effects,
contracts) that a backend may use to wrap or abbreviate the signature; a
backend that ignores it prints `text` unchanged. A hover whose `text`, `docs`
and `tags` are all empty is a _lazy_ span: renderers mark it but show no
popup until a live producer fills it in.

The renderers read `start`/`length` as UTF-8 byte offsets into `code`. The
reference tool emits UTF-16 offsets, so `fromTwoslashJson` converts them on
ingest unless the payload declares `offsetEncoding: "utf-8"`, as a D producer
does.

**Modeling choice:** one flat `Node` POD with a `NodeType` discriminant, _not_ a
`SumType`. `sparkles:wired` decodes a sum by probing every variant, and twoslash
nodes overlap too much (shared `start`/`length`/`line`/`character`) to disambiguate
that way. A flat struct decodes uniformly (present fields fill, absent ones default
— every non-universal field is `@WireOptional`), wired ignores unknown JSON keys
(`target`, `filename`, `meta`, `flags`, …), and the lowercase enum members
map the `type` strings verbatim under wired's default `CaseStyle.original`.

## 2. Overlay planner (`overlay.d`)

`planTwoslash` partitions `nodes` into two sorted work-lists shared by all three
backends:

- **inline decorations** (`hover`/`highlight`/`error`) — sorted `start` asc, `end`
  desc so an enclosing span opens before a nested one.
- **below-line blocks** (`error`/`query`/`completion`/`tag`) — sorted by line.

An `error` is _both_. `highlightSignature` re-highlights a popup type signature by
re-entering `sparkles:syntax` in the payload's language
(`TwoslashReturn.effectiveLanguage`: `language`, or TypeScript when it is
absent); on a missing grammar it degrades to plain text, so the overlay never
fails.

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
drops the redundant hover). Hover/query `docs` and each JSDoc `@tag` value render
as **markdown** (the block and inline `MdDoc → HTML` emitters in `sparkles:syntax`
— Shiki's `renderMarkdown`/`renderMarkdownInline` seam), degrading to escaped text
without a grammar bundle; `TwoslashHtmlOptions` gates it (`renderDocsMarkdown`,
default on) alongside an opt-in quickinfo-prefix strip (`(property) ` → ``).
Output is content-only; the caller wraps it in `<pre class="syn-root twoslash">`.

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

## 5. Widget view and GUI overlay (`render_widgets.d`)

The GUI rendering of the plan is not a byte stream but a
[`sparkles:ui`](../ui/index.md) `WidgetTree`, which every canvas backend lays
out and paints the same way. hue's GUI window and its interactive terminal
both draw twoslash through it.

- `viewTwoslashDocument` (and `viewTwoslashDocumentInto`, which appends to an
  existing `Builder`) builds the whole document: each code line is a rich row
  of theme-colored spans that keep their source byte offsets, and each
  below-line block sits directly under its line.
- `decorateCodeRow` layers one line's inline decorations onto a code row the
  caller built: a highlight is a tinted box beneath the text, a hover a
  permanent dotted underline beneath it, and an error a wavy line over it,
  colored as a warning for the non-fatal levels (`errIsWarning`). Because the
  caller names the line, the same seam decorates the rows of a diff.
- `viewBelowBlock` and `viewTwoslash` build one below-line block, or all of
  them as a column: an error message, a `^?` query signature, a completion
  list with per-kind icon glyphs, or a `// @tag` line, each indented to its
  source column.
- `viewHoverPopup` builds the floating hover/query popup: a bordered surface
  with the signature over its docs and `@tag` chips. Given a
  `GrammarRegistry`, it renders the docs as markdown; without one, as plain
  lines. A lazy hover, whose text, docs and tags are all empty, yields an
  empty tree. `HoverViewOptions` carries what only the backend knows: the
  width available at the anchor, the syntax-colored signature spans
  (`signatureSpans`), and which collapsible runs of a structured signature
  are expanded.

Widgets name semantic `Slot`s and leave colors to the twoslash palette, so
every backend resolves them from one source. A widget derived from node `i`
carries `hitId == i + 1`, which lets a backend map a pointer back to its node.

In hue's GUI, `sparkles:doc-view`'s `ViewerModel` builds the document with
`viewTwoslashDocumentInto` and the raylib canvas paints it on the monospace
grid. Hovering a marked token opens the popup from `viewHoverPopup`, which
`gui.drawPopup` paints at the token — the GPU analogue of CSS `:hover`.

## 6. Data source & hermeticity

`libs/twoslash/examples/` holds twoslash-annotated sources in `src/*.ts(x)` — one
per feature (hover, `^?` query, `^|` completion, `@errors`, `^^^` highlight,
`@annotate` tag, generics, JSDoc, multi-file, `---cut---`, TSX, async), plus two
ported from the `@shikijs/twoslash` docs (its `rendererRich` showcase — a
`Readonly<T>` query + read-only error + completion in one snippet — and the
four custom-tag notations `@log`/`@error`/`@warn`/`@annotate`) and a
`15-markdown-docs` showcase whose JSDoc uses **bold**, inline `code`, a list, a
fenced block, a link, and tags — so the docs/tags markdown path (§3) renders
something visibly non-trivial — and the
committed `fixtures/*.twoslash.json` overlays generated from them (the trimmed
`{code, nodes}` slice the renderer reads). `examples/regen.sh` is a real,
developer-only generator: it installs the reference TypeScript `twoslash` (+
`typescript`) with Yarn and runs `regen.mjs` over every source. It and the two
checks below are the only places node runs — the sparkles build and `dub test`
are **node-free** and consume the committed JSON, so nothing downstream needs
node. Because `nodes` is opaque input, the same `{code, nodes}` shape comes
from any twoslash-compatible source: the TypeScript `twoslash` for this
corpus, and `twoslash-extract` (over `sparkles:twoslash-d`) for D.

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

- **Live VitePress swap** — depends on #122's VitePress highlighter seam, which
  is not built: the site's `markdown.config` hook adds plugins but leaves code
  fences to stock VitePress→Shiki. The site shows the overlay only as a static
  gallery of `hue --twoslash --html` pages, generated at docs build time by
  `docs/scripts/build-twoslash-showcase.sh`.
- **Analyzer / D-native backend** — the D producer exists outside this library
  (#124): `sparkles:twoslash-d` parses the notation and assembles nodes from one
  `sparkles:dmd-lsp` analysis, `twoslash-extract` writes the payloads, and hue
  requests lazy payloads from it live. Its contract is specified with
  [`sparkles:dmd-lsp`](../dmd-lsp/index.md); this library still treats nodes as
  opaque input and gains no analyzer dependency.
