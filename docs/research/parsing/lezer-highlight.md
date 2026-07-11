# @lezer/highlight (JavaScript / CodeMirror)

The highlighting layer of the [Lezer][lezer] / CodeMirror 6 stack, and the survey's third answer to "how do you _name_ what you color": not [open dotted scope strings][sh-tm] (TextMate), not [capture-name strings][ts-highlight] (tree-sitter), but a **closed vocabulary of structured `Tag` objects** with a real subsumption lattice and an order-independent **modifier algebra** — walked over an incrementally maintained parse tree, **range-clipped to the viewport** on every redraw. One 748-line file, one dependency.

| Field                      | Value                                                                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | TypeScript (ESM); the entire package is `src/highlight.ts` (~748 lines)                                                                     |
| License                    | MIT                                                                                                                                         |
| Repository                 | [`lezer-parser/highlight`][repo] (GitHub mirror; canonical home moved to `code.haverbeke.berlin/lezer/highlight`)                           |
| Documentation              | [lezer.codemirror.net][docs]                                                                                                                |
| Key authors                | Marijn Haverbeke ([Lezer][lezer] / CodeMirror author)                                                                                       |
| Category                   | Syntax highlighting — tag-based layer over an incremental CST                                                                               |
| Algorithm / grammar class  | Tree walk over a [Lezer][lezer] `Tree`; classification via `NodeProp`-attached rules from `styleTags` path selectors                        |
| Lexing model               | n/a — consumes the parser's node types; no regex layer of its own                                                                           |
| Output                     | `putStyle(from, to, classes)` callbacks over a `[from, to)` range (viewport-clippable); `classHighlighter` emits stable `tok-*` CSS classes |
| Highlighting / theme model | **Closed tag vocabulary** (78 standard tags + 6 modifiers); highlighters resolve a tag via its precomputed specificity-ordered `set` chain  |
| Latest release             | `@lezer/highlight` `1.2.3` (pinned `8b4907f`, 2026-04-15); sole runtime dep `@lezer/common ^1.3.0`                                          |

> [!NOTE]
> This deep-dive surveys the `@lezer/highlight` package only — the tag system, `styleTags`, and `highlightTree`. The parser that feeds it is the existing [Lezer][lezer] deep-dive; `HighlightStyle` (tags → real CSS with theming) lives one level up in `@codemirror/language` and is described only as the intended consumer. Within [the cluster][sh] this page is the "structured labels" data point between TextMate scope strings and [LSP semantic tokens][lsp-st]' negotiated legend.

---

## Overview

### What it solves

Open scope-string systems have a coordination problem the README's sibling docs and the source state head-on: every language invents its own strings, so themes chase an unbounded vocabulary. The `Tag` class doc is the design thesis ([`highlight.ts:5-15`][highlight-ts]):

> _"Because syntax tree node types and highlight styles have to be able to talk the same language, CodeMirror uses a mostly **closed** vocabulary of syntax tags (as opposed to traditional open string-based systems, which make it hard for highlighting themes to cover all the tokens produced by the various languages)."_

The package's own README positions it in two lines ([`README.md`][readme]): Lezer _"is an incremental parser system intended for use in an editor or similar system"_, and _"@lezer/highlight provides a syntax highlighting framework for Lezer parse trees."_

### Design philosophy

1. **A closed vocabulary is a feature.** 78 standard tags + 6 modifiers, and the docs tell grammar authors to make do ([`highlight.ts:437-451`][highlight-ts]): _"A full ontology of syntactic constructs would fill a stack of books, and be impractical to write themes for. So try to make do with this set."_ — and, symmetrically, not to over-specify: _"if your grammar can't easily distinguish a certain type of element (such as a local variable), it is okay to style it as its more general variant (a variable)."_ Locally defined tags are possible but _"will not be picked up by regular highlighters (though you can derive them from standard tags to allow highlighters to fall back to those)"_.
2. **Subsumption is data, not string matching.** Every `Tag` carries its `set` — _"The set of this tag and all its parent tags, starting with this one itself and sorted in order of decreasing specificity"_ ([`highlight.ts:30-32`][highlight-ts]). Resolution is an array walk, not a dotted-prefix parse.
3. **Modifiers are algebra.** `Tag.defineModifier` guarantees interning and commutativity ([`highlight.ts:63-72`][highlight-ts]): _"Applying the same modifier to a twice tag will return the same value (`m1(t1) == m1(t1)`) and applying multiple modifiers will, regardless or order, produce the same tag (`m1(m2(t1)) == m2(m1(t1)))`"_ — with every smaller modifier subset registered as a parent (a power-set lattice), so `definition(variableName)` still matches a theme that only styles `variableName`. Dotted strings can only fake this by concatenation.

---

## How it works

### The tag lattice

`Tag.define(name?, parent?)` builds subsumption at definition time: the new tag's `set` is itself followed by the parent's entire `set`, so _"highlighters that don't mention this tag will try to fall back to the parent tag (or grandparent tag, etc)"_ ([`highlight.ts:46-61`][highlight-ts]). The standard vocabulary (`export const tags`, [`highlight.ts:455-663`][highlight-ts]) spans comments (4), names (10: `variableName`, `typeName`, `tagName`, `propertyName`, …), literals (13), keywords (10), operators (10), punctuation (7), prose content (17: headings, emphasis, links — Lezer highlights Markdown too), change-tracking (4: `inserted`, `deleted`, `changed`, `invalid`) and meta (4). The six modifiers: `definition, constant, function, standard, local, special`.

### `styleTags`: path selectors from nodes to tags

Grammars attach tags to node types with a selector mini-language over node _paths_ — the tree-shaped analogue of TextMate's scope selectors ([`highlight.ts:124-142`][highlight-ts]):

> _"Such a path can be a node name, or multiple node names (or `*` wildcards) separated by slash characters, as in `"Block/Declaration/VariableName"`. Such a path matches the final node but only if its direct parent nodes are the other nodes mentioned. … A path can be ended with `/...` to indicate that the tag assigned to the node should also apply to all child nodes … When a path ends in `!`, as in `Attribute!`, no further matching happens for the node's child nodes, and the entire node gets the given style."_

The three suffix modes compile to `Mode.{Opaque, Inherit, Normal}` rules stored on a `NodeProp`; deeper context wins via rule depth ordering. Compare [tree-sitter's `highlights.scm`][ts-highlight]: same structural matching idea, but the result of a match is a structured `Tag`, not a capture-name string.

### `highlightTree`: a range-clipped tree walk

The engine is one function ([`highlight.ts:300-315`][highlight-ts]):

```ts
export function highlightTree(
  tree: Tree,
  highlighter: Highlighter | readonly Highlighter[],
  // "Assign styling to a region of the text. Will be called, in order
  //  of position, for any ranges where more than zero classes apply."
  putStyle: (from: number, to: number, classes: string) => void,
  from = 0, // "The start of the range to highlight."
  to = tree.length, // "The end of the range."
);
```

The `from`/`to` parameters are the **viewport contract**: CodeMirror calls this per redraw with the visible range, and the recursive walk clips every descent to `[from, to)`, coalescing same-class spans. The tree itself is maintained _incrementally_ by [Lezer][lezer] (fragment reuse per edit), so the steady-state cost of an edit is a bounded reparse plus a viewport-sized walk — the architecture [tree-sitter-highlight]'s batch API lacks and editors like [Helix][helix] rebuild by hand. Mixed-language documents work through mounted overlay trees, with highlighters re-selected per language via the optional `scope(node)` predicate on the `Highlighter` interface ([`highlight.ts:240-249`][highlight-ts]).

### Highlighters: from tags to classes

`tagHighlighter(pairs, options)` builds the resolution table; specificity is the `tag.set` walk — _"Classes associated with more specific tags will take precedence"_ ([`highlight.ts:251-253`][highlight-ts]). Two stock consumers: `classHighlighter` — _"a highlighter that adds stable, predictable classes to tokens, for styling with external CSS"_ ([`highlight.ts:670-671`][highlight-ts]) — maps standard tags to `tok-*` classes (`definition(variableName)` → `"tok-variableName tok-definition"`), and `@codemirror/language`'s `HighlightStyle` (out of scope here) maps tags to generated CSS for themes. `highlightCode` (added in 1.2.0) is a convenience fold for emitting highlighted text outside an editor.

---

## Algorithm & grammar class

- **A pure function over a CST:** no regexes, no state machine — classification is entirely the parser's node types filtered through `styleTags` rules; the package's algorithmic content is the rule-matching (path selectors + depth precedence) and the range-clipped walk.
- **Same family as [CST queries][ts-highlight], different binding:** tree-sitter binds structural patterns to capture-name _strings_ resolved by longest-dot-match; Lezer binds path selectors to `Tag` _values_ resolved by a precomputed lattice. Both inherit their parser's error recovery (Lezer's `Err` nodes just get no tags, or `tags.invalid` where grammars assign it).
- **Expressiveness boundary:** selectors see ancestry (`Block/Declaration/VariableName`) but not siblings or predicates — less powerful than tree-sitter's full query language (no `#eq?`, no locals system); scope-consistent variable coloring is out of scope at this layer.

## Interface & composition model

- **Three-piece contract:** grammars ship `styleTags` rules (via `NodeProp`), the engine walks (`highlightTree`), consumers implement `Highlighter { style(tags), scope?(node) }`. Each piece is replaceable; the tags are the stable interface between them — exactly the role [TextMate scope names][sh-tm] play across that ecosystem, here with a type system.
- **Callback output** (`putStyle(from, to, classes)`) — no materialized token array; the consumer decides representation. An ANSI fold is as natural as a DOM decorator.
- **One file, one dependency** — the smallest engine in the survey by an order of magnitude; the complexity lives in the vocabulary design, not the code.

## Performance

- **Viewport-proportional by API design:** the `from`/`to` clip makes redraw cost scale with the window, not the document — the survey's cleanest expression of the [windowed-rendering discipline][sh] (Emacs' [jit-lock][vim-emacs] does it with hooks; [Helix][helix] with range-limited query execution; here it's just two parameters).
- **Edit cost is the parser's:** [Lezer][lezer]'s fragment reuse bounds reparse; the highlight layer holds no state to invalidate (tags resolve per walk; interning makes tag identity comparisons pointer-equal).
- **Resolution is array walks over interned values** — no string splitting or hashing on the hot path (contrast dotted-name matching in [tree-sitter-highlight] and selector scoring in [syntect]).

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — closed, structured, latticed:** 78 tags + 6 modifiers as interned objects with precomputed specificity chains. The unique position in the cluster: [TextMate][sh-tm] is open strings, [LSP][lsp-st] is a negotiated 23+10 legend, Lezer is closed-with-derivation — themes can be _complete_ by construction.
- **Inter-unit state — none at this layer:** all state is the parse tree; any range can be highlighted at any time given the tree (the inverse of [syntect]'s carried line state, sharing [tree-sitter-highlight]'s tree-derived model but with the incremental tree actually maintained by its ecosystem).
- **Theme resolution — the `set` walk:** most-specific-first through the tag's parent chain (and modifier power-set), first styled ancestor wins; per-language theming via `scope`.
- **Rendering targets — class-based HTML natively** (`classHighlighter`'s stable `tok-*` classes; `HighlightStyle` for generated CSS upstream), with the callback output making any backend a fold. No ANSI path ships; the D-relevant takeaway is the _vocabulary design_, not a renderer.

## Error handling & recovery

- **Nothing to fail:** unstyled nodes produce no callbacks; unknown/local tags resolve to `null` and render unclassed; error nodes from the recovering parser flow through like any node (`tags.invalid` exists for grammars that mark them). The [degrade-gracefully][sh] posture with the smallest possible failure surface.
- **Author-time errors only:** malformed `styleTags` selectors throw at grammar-definition time (`RangeError` on bad paths), never at highlight time.

## Ecosystem & maturity

- **The CodeMirror 6 substrate:** every CM6 language package ships `styleTags` rules; themes (One Dark, etc.) are `HighlightStyle`s over the standard tags. Adoption is CodeMirror's adoption — in-browser editors, docs playgrounds, notebooks.
- **Versioning:** extracted as `@lezer/highlight` 0.16.0 in April 2022 (1.0.0 June 2022) when the Lezer packages were reorganized; `1.2.3` at the pin — small, stable, Haverbeke-maintained, same repo-mirroring arrangement as the parser.
- **Boundary:** JS-only, editor-shaped; standalone use exists (`highlightCode`) but the ecosystem's grammars-with-styleTags are where the value is.

---

## Strengths

- **The best-designed label vocabulary in the survey:** closed, complete-for-themes, subsumption as data, modifiers as a commutative interned algebra — the design a new library should study before inventing names.
- **Viewport-clipped by API** — windowed rendering is two parameters, not an architecture.
- **Stateless over an incremental tree:** no checkpoints, no carried stacks; the parser's incrementality is inherited for free.
- **Tiny and auditable:** ~748 lines, one dependency, every mechanism documented inline.
- **Structural selectors with graceful fallback** (`!`, `/...`, `*`, depth precedence) — expressive enough for real grammars without a query engine.

## Weaknesses

- **Bound to Lezer trees:** the tag system is portable in principle, but `styleTags`/`highlightTree` only speak `@lezer/common` — no grammars, no highlighting.
- **No locals/def-use consistency** and no query predicates — structurally weaker than [tree-sitter-highlight]'s locals system.
- **Closed vocabulary cuts both ways:** exotic constructs must squeeze into 78 tags or define local ones that mainstream themes ignore.
- **JS-only, editor-first:** no ANSI backend, no standalone corpus; reuse for a CLI means reimplementing the ideas, not linking the package.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                 | Trade-off                                                                     |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **Closed tag vocabulary** (78+6)                                | Themes can cover _everything_; languages stop inventing incompatible strings              | Exotic constructs under-described; local tags invisible to standard themes    |
| **Subsumption as precomputed `set` arrays**                     | Fallback resolution is an array walk over interned values — no string ops on the hot path | Lattice fixed at definition time; vocabulary evolution is a library release   |
| **Modifier algebra** (interned, commutative, power-set parents) | `definition(variableName)` composes orthogonally and still matches `variableName` themes  | Power-set registration cost per modifier combination (bounded by low counts)  |
| **Path-selector `styleTags`** (`!`, `/...`, `*`)                | Structural context without a query engine; rules live with the grammar                    | No predicates, siblings, or locals — less expressive than `.scm` queries      |
| **`highlightTree(from, to)` callbacks**                         | Viewport costs, consumer-owned output representation                                      | No materialized tokens; every consumer writes its own fold                    |
| **Stateless layer over the incremental parser**                 | Zero invalidation logic; any range, any time                                              | Wholly dependent on the host maintaining the tree ([Lezer][lezer]/CodeMirror) |

---

## Sources

- [`src/highlight.ts`][highlight-ts] (the whole package; pinned `8b4907f`) — `Tag` docs (closed-vocabulary thesis, `set`, `define`/`defineModifier` algebra), the standard `tags` vocabulary + "make do with this set" guidance, `styleTags` selector docs, `Highlighter`/`tagHighlighter`, `highlightTree` signature (`from`/`to`), `classHighlighter`
- [`README.md`][readme] + [`package.json`][repo] — positioning, version `1.2.3`, MIT, `@lezer/common` dependency
- Related deep-dives: [Lezer][lezer] (the parser underneath) · [tree-sitter-highlight][ts-highlight] (structural matching with string captures) · [LSP semantic tokens][lsp-st] (the other structured-vocabulary design) · [the highlighting synthesis][sh]

<!-- References -->

[repo]: https://github.com/lezer-parser/highlight
[docs]: https://lezer.codemirror.net/
[readme]: https://github.com/lezer-parser/highlight/blob/main/README.md
[highlight-ts]: https://github.com/lezer-parser/highlight/blob/main/src/highlight.ts
[lezer]: ./lezer.md
[ts-highlight]: ./tree-sitter-highlight.md
[syntect]: ./syntect.md
[lsp-st]: ./lsp-semantic-tokens.md
[helix]: ./helix.md
[vim-emacs]: ./vim-emacs-syntax.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
