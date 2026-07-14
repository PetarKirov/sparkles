# LSP Semantic Tokens (protocol)

The **semantic tier** of the highlighting stack, standardized: a Language Server Protocol request family (since LSP 3.16, December 2020) that lets a compiler-grade out-of-process server attach _symbol-aware_ labels (`parameter`, `readonly`, `defaultLibrary`) to ranges a syntactic highlighter cannot classify — delivered as **integer-encoded, delta-updatable token arrays** and, in the reference client (VS Code), rendered as an **overlay on a TextMate base**. Within [the highlighting cluster][sh] this is the tier above both the [TextMate model][sh-tm] and [CST queries][ts-highlight]; it is a wire protocol, not an engine.

| Field                      | Value                                                                                                                                          |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | Protocol specification (JSON-RPC; markdown spec sources)                                                                                       |
| License                    | Spec repository: Creative Commons / MIT mix per Microsoft OSS practice (see repo); protocol itself is an open standard                         |
| Repository                 | [`microsoft/language-server-protocol`][repo] (`_specifications/lsp/3.17/language/semanticTokens.md`)                                           |
| Documentation              | [LSP specification][spec-site]                                                                                                                 |
| Key authors                | Microsoft (VS Code / LSP team); Dirk Bäumer et al.                                                                                             |
| Category                   | Syntax highlighting — semantic tier (protocol)                                                                                                 |
| Algorithm / grammar class  | None — a transport for server-computed classifications; the server runs a real front-end (name resolution, types)                              |
| Lexing model               | n/a — tokens arrive pre-classified; positions are UTF-16 line/character pairs, relative-encoded                                                |
| Output                     | `SemanticTokens { resultId?, data: uinteger[] }` — 5 integers per token; full, `full/delta`, and `range` request variants + a `refresh` signal |
| Highlighting / theme model | A negotiated **legend**: predefined 23 token types + 10 modifiers (3.17), extensible; clients map legend entries to theme rules                |
| Latest release             | LSP 3.17 (stable; `decorator` type added); 3.18 draft adds `label`; pinned spec checkout `25005c8` (2026-07-09)                                |

> [!NOTE]
> This deep-dive surveys the `semanticTokens` request family as specified in the pinned LSP spec sources (3.17 file, with 3.16 introduction and 3.18 draft noted) plus the client-side merge semantics that make it a _tier_ rather than a replacement. Server implementations (rust-analyzer, clangd, the TypeScript server) and VS Code's renderer internals are referenced, not catalogued; the in-process IDE alternative to this design is the [IntelliJ Platform][intellij] page, and the syntactic tiers it layers onto are the rest of [the cluster][sh].

---

## Overview

### What it solves

Syntactic highlighters — [TextMate engines][sh-tm], [CST queries][ts-highlight] — classify what text _is_ structurally; they cannot know what it _refers to_. Is this identifier a parameter or a global? Is that method `static`, `async`, `deprecated`? Answering requires name resolution and type information, which lives in a language server. The spec states the purpose and its defining engineering constraint in one paragraph ([`semanticTokens.md:5`][spec-317]):

> _"Semantic tokens are used to add additional color information to a file that depends on language specific symbol information. A semantic token request usually produces a large result. The protocol therefore supports encoding tokens with numbers. In addition optional support for deltas is available."_

### Design philosophy

1. **A tier, not a replacement.** The protocol assumes a fast syntactic base already painted the file; semantic tokens _refine_ it. The client capability that encodes this is explicit ([`semanticTokens.md:261-273`][spec-317]): _"Whether the client uses semantic tokens to augment existing syntax tokens. If set to `true` client side created syntax tokens and semantic tokens are both used for colorization. If set to `false` the client only uses the returned semantic tokens for colorization."_ (`augmentsSyntaxTokens`, `@since 3.17`). VS Code's shipping behavior — TextMate base, semantic overlay, blended per theme rules — is the two-layer architecture in production; it turned semantic highlighting on for TypeScript/JavaScript in v1.43 (February 2020 release).
2. **The wire format is shaped by scale.** _"A semantic token request usually produces a large result"_ — so tokens are integers, not objects; positions are relative, not absolute; and updates are array edits, not re-sends. Every choice follows from the size of the payload.
3. **Vocabulary is negotiated, not fixed.** Token types/modifiers are strings in a **legend** declared by the server and matched against client capabilities: _"The protocol defines a set of token types and modifiers but clients are allowed to extend these and announce the values they support in the corresponding client capability."_ ([`semanticTokens.md:9`][spec-317]) — a middle path between [TextMate's open scope strings][sh-tm] and [`@lezer/highlight`][lezer-hl]'s closed tag set.

---

## How it works

### The legend: 23 types × 10 modifiers

A token is _"one token type combined with n token modifiers"_ ([`semanticTokens.md:9`][spec-317]). The predefined `SemanticTokenTypes` (3.17, 23 entries — `decorator` arrived in 3.17, the 3.18 draft adds `label` for a 24th): `namespace, type, class, enum, interface, struct, typeParameter, parameter, variable, property, enumMember, event, function, method, macro, keyword, modifier, comment, string, number, regexp, operator, decorator` — with `type` documented as _"a fallback for types which can't be mapped to a specific type like class or enum"_. The 10 `SemanticTokenModifiers`: `declaration, definition, readonly, static, deprecated, abstract, async, modification, documentation, defaultLibrary`. Servers declare which subset they emit in a `SemanticTokensLegend`; the integers on the wire index into it.

### Five integers per token, relative

The encoding rationale is stated outright ([`semanticTokens.md:100`][spec-317]):

> _"The protocol for the token format `relative` uses relative positions, because most tokens remain stable relative to each other when edits are made in a file. This simplifies the computation of a delta if a server supports it. So each token is represented using 5 integers."_

Per token `i`: `deltaLine` (line, relative to the previous token), `deltaStart` (start character, relative to the previous token's start when on the same line), `length`, `tokenType` (legend index; _"We currently ask that `tokenType` < 65536"_), `tokenModifiers` (a **bitset** over the modifier legend — _"a `tokenModifier` value of `3` is first viewed as binary `0b00000011`, which means `[tokenModifiers[0], tokenModifiers[1]]`"_, [`semanticTokens.md:97-98`][spec-317]). A whole file is one flat `uinteger[]` — cache-friendly, alloc-light, and language-neutral.

### Full, delta, range, refresh

Four verbs cover the lifecycle:

- **`textDocument/semanticTokens/full`** — the whole file; the response may carry a `resultId`: _"If provided and clients support delta updating the client will include the result id in the next semantic token request. A server can then instead of computing all semantic tokens again simply send a delta."_
- **`full/delta`** — the client sends `previousResultId`; the server answers with `SemanticTokensEdit { start, deleteCount, data? }` operations **on the raw integer array**: _"The delta is now expressed on these number arrays without any form of interpretation what these numbers mean"_ ([`semanticTokens.md:172`][spec-317]) — relative positions make most of the array survive an edit unchanged. Clients _"must not assume that they are sorted"_ and should apply edits back-to-front.
- **`range`** — the viewport tier, with two spec'd use cases ([`semanticTokens.md:460-463`][spec-317]): faster first paint _"when a user opens a file"_, and as the _only_ offering _"if computing semantic tokens for a full document is too expensive"_. The server may answer with a broader range than requested.
- **`workspace/semanticTokens/refresh`** — server→client: re-request everything (e.g. after _"a project wide configuration change"_).

### Merge semantics and rendering constraints

Two client capabilities bound what servers may emit: `multilineTokenSupport` (_"If multiline tokens are not supported and a tokens length takes it past the end of the line, it should be treated as if the token ends at the end of the line and will not wrap onto the next line"_) and `overlappingTokenSupport` — by default tokens are single-line and non-overlapping, i.e. exactly the shape a line-oriented renderer (or [Shiki][shiki]-style token list) already handles. The overlay itself is theme-driven: in VS Code, semantic token rules sit beside TextMate scope rules in the theme, and where a semantic token exists it wins (or blends) over the syntactic base — the practical answer to "how do two highlighting tiers coexist without flicker": the base paints instantly, the semantic pass **re-paints asynchronously** when the server catches up.

---

## Algorithm & grammar class

- **No algorithm — a contract.** All classification intelligence lives server-side, behind a real front-end (rust-analyzer's HIR, clangd's AST, tsserver's checker). The protocol only standardizes _labels, positions, encoding, and update discipline_. This is the survey's cleanest separation of classification from rendering.
- **Precision class: true semantics.** Everything below this tier is context-free: [TextMate][sh-tm] sees a line + stack; [tree-sitter queries][ts-highlight] see the parse tree; locals-tracking approximates scoping textually. Semantic tokens see _the program_ — resolved names, types, modifiers — the only tier that can color `parameter` vs `variable` vs `property` correctly in every case.
- **Latency class: asynchronous by design.** The server may be slow; the protocol embraces it (deltas, range-first, refresh) rather than pretending otherwise. Highlighting becomes eventually-consistent — a fundamental UX contrast with the synchronous tiers.

## Interface & composition model

- **Composition is the whole point:** `augmentsSyntaxTokens` codifies the two-layer stack — syntactic base (any engine) + semantic overlay (any server) — with the _theme_ as the merge point. A tool with its own fast tier keeps it; the semantic layer is additive.
- **Legend negotiation** decouples vocabularies: servers can extend types/modifiers, clients declare what they understand, unknown labels degrade to nothing (never an error).
- **Transport-agnostic classifications:** because tokens are (range, type, modifiers) triples with no engine coupling, _any_ consumer — an editor, a [bat]-style CLI talking to a language server, an HTML renderer — can fold them over its own token stream; the encoding is deliberately trivial to decode.
- **The request family is the API surface:** full/delta/range/refresh map exactly onto editor lifecycle events (open, edit, scroll, config change) — a ready-made checklist for any client implementation.

## Performance

- **Payload engineering:** flat integer arrays (no JSON object per token), relative positions, `< 65536` type indices — the spec's own numbers-first framing. A 10k-line file's tokens fit in one compact array.
- **Deltas amortize edits:** relative encoding means an edit shifts only nearby tokens' deltas; the `resultId` + array-edit protocol re-sends only the changed slice.
- **`range` bounds first paint** — semantic highlighting for the viewport before the whole file is analyzed; the same viewport-first discipline as [Helix][helix]'s windowed queries and Emacs' [jit-lock][vim-emacs], expressed at the protocol level.
- **The unavoidable cost is server latency:** classification quality is bought with an out-of-process round-trip and whatever analysis time the server needs; the base tier exists precisely to hide it.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — a negotiated legend** of type + modifier-bitset tuples: structured like [`@lezer/highlight`][lezer-hl]'s tags (not free-form strings), extensible like [TextMate scopes][sh-tm] (unlike Lezer's closed set), and deliberately small (23+10) because themes must cover it.
- **Inter-unit state — `resultId` chains:** the client holds the previous array; the server diffs against it. State is _per document per server_, checkpointed at every response — the semantic tier's analogue of [grammar-state checkpointing][sh].
- **Theme resolution — client-side, layered:** legend entries resolve through theme rules that coexist with (and outrank) the syntactic base's rules; `augmentsSyntaxTokens` decides blend-vs-replace. No theme format is specified — the protocol stops at labels.
- **Rendering targets — whatever the client renders:** by default single-line, non-overlapping tokens (the capabilities gate anything richer), so the output contract matches every line-oriented backend in this survey, ANSI included.

## Error handling & recovery

- **Degrades to the base tier.** No server, slow server, or an error → the syntactic base simply remains; semantic color is progressive enhancement by construction. This is the strongest never-fail story in the cluster because failure is _invisible_.
- **Stale-result discipline:** deltas are only valid against the exact `previousResultId`; on mismatch the server returns a full result. `refresh` handles world-changes (config, dependencies).
- **Spec'd edge behavior** (truncate-at-EOL for multiline, no overlap by default) keeps malformed emissions renderable rather than erroneous.

## Ecosystem & maturity

- **Introduced in LSP 3.16** (December 14, 2020 — _"Add semantic token support"_ in the spec changelog), extended in 3.17 (`decorator`, server-cancelable, `augmentsSyntaxTokens`), still growing in the 3.18 draft (`label`).
- **Server support is broad:** rust-analyzer, clangd, tsserver (via VS Code), gopls, jdtls — semantic tokens are now table stakes for serious language servers; client support spans VS Code, Neovim (built-in LSP), Helix, Eclipse, and editors beyond.
- **The de-facto merge reference is VS Code:** default-on for TS/JS since v1.43 (with the 1.43.1 walk-back scoping it to themes that opt in) — the practical proof that a TextMate base + semantic overlay is deployable at scale.
- **For a D tool,** this tier is the eventual bridge to compiler-grade highlighting (DMD-as-a-library / DCD-style analysis) without abandoning the fast tiers — implement the _client_ fold now, gain semantics whenever a server exists.

---

## Strengths

- **The only true-semantics tier** — colors what syntax cannot know (parameter vs variable, `readonly`, `deprecated`, `defaultLibrary`), from real name resolution.
- **Engine-agnostic layering:** composes over any syntactic base via `augmentsSyntaxTokens`; failure is invisible degradation.
- **Payload discipline:** integer arrays + relative positions + array-level deltas + viewport ranges — a complete, spec'd answer to "semantic data is big and edits are constant".
- **Negotiated vocabulary** with sane defaults: small enough to theme, extensible enough for real languages.
- **Protocol, not product:** every editor and server interoperates; classifications outlive any single engine.

## Weaknesses

- **Not self-sufficient:** needs a language server per language and a syntactic base underneath — it is the _third_ tier, never the only one.
- **Eventually consistent:** colors arrive after analysis; themes/users must tolerate the repaint (and the 1.43.1 walk-back shows even the reference client tread carefully).
- **UTF-16 positions** (LSP legacy) — a persistent mismatch tax for byte-oriented implementations.
- **Coarse vocabulary:** 23 types + 10 modifiers is far below TextMate's scope granularity; fine distinctions need non-standard legend extensions, which themes won't know.
- **No theme/merge standardization:** blend behavior beyond the one boolean is client-defined — cross-editor rendering differs.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                     | Trade-off                                                                  |
| --------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **Overlay tier, not standalone** (`augmentsSyntaxTokens`) | Instant syntactic paint + eventual semantic refinement; failure invisible     | Two systems to theme coherently; repaint visible on slow servers           |
| **Integer legend encoding**                               | _"usually produces a large result"_ — compact, alloc-light, language-neutral  | Opaque on the wire; debugging needs the legend; type index capped at 65536 |
| **Relative positions**                                    | Token deltas stay stable under edits → cheap diffs                            | Random access requires a prefix scan; absolute formats never materialized  |
| **Array-level deltas + `resultId`**                       | Re-send only changed slices, uninterpreted                                    | Client must hold previous arrays and apply unsorted edits back-to-front    |
| **`range` request**                                       | Viewport-first paint; an escape hatch when full analysis is too expensive     | Server may over-answer; clients must reconcile range and full results      |
| **Negotiated, extensible legend**                         | Real languages outgrow 23 types; capability handshake keeps both sides honest | Extensions are invisible to themes that don't know them                    |
| **Single-line, non-overlapping by default**               | Matches every line-oriented renderer; richer shapes are opt-in capabilities   | Multiline constructs (raw strings) get clipped on conservative clients     |

---

## Sources

- [`_specifications/lsp/3.17/language/semanticTokens.md`][spec-317] (pinned repo) — motivation, legend enums, encoding + rationale, request family, capabilities (`augmentsSyntaxTokens`, `multilineTokenSupport`, `overlappingTokenSupport`)
- `_specifications/specification-3-16.md` + 3.18 spec changelogs — 3.16 introduction ("Add semantic token support", 2020-12-14), 3.17/3.18 additions
- [VS Code v1.43 release notes][vscode-143] — semantic highlighting default-on for TS/JS (walked back to theme-opt-in in 1.43.1)
- Related deep-dives: [IntelliJ Platform][intellij] (the in-process alternative to protocol-tiered semantics) · [tree-sitter-highlight][ts-highlight] + [syntect] ([the syntactic tiers][sh] this overlays) · [`@lezer/highlight`][lezer-hl] (the other structured-vocabulary design) · [the highlighting synthesis][sh]

<!-- References -->

[repo]: https://github.com/microsoft/language-server-protocol
[spec-site]: https://microsoft.github.io/language-server-protocol/
[spec-317]: https://github.com/microsoft/language-server-protocol/blob/25005c80d9ec5e366c51108a4981ef264fe058e7/_specifications/lsp/3.17/language/semanticTokens.md
[vscode-143]: https://code.visualstudio.com/updates/v1_43
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
[ts-highlight]: ./tree-sitter-highlight.md
[syntect]: ./syntect.md
[shiki]: ./shiki.md
[bat]: ./bat.md
[lezer-hl]: ./lezer-highlight.md
[helix]: ./helix.md
[intellij]: ./intellij-highlighting.md
[vim-emacs]: ./vim-emacs-syntax.md
