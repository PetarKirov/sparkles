# IntelliJ Platform highlighting (Java / Kotlin)

The **in-process IDE model**: highlighting as a pipeline of progressively slower, progressively smarter passes — a restartable integer-state lexer for instant token color, a full parser building a persistent PSI tree with inline error elements, then PSI-walking `Annotator`s (semantic, incremental) and lowest-priority `ExternalAnnotator`s in a background daemon — with colors resolving through a **fallback chain of `TextAttributesKey`s** into the active editor scheme. Where [LSP semantic tokens][lsp-st] put the semantic tier behind a protocol, IntelliJ runs the whole stack in one process over one syntax tree.

| Field                      | Value                                                                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Language                   | Java/Kotlin (the IntelliJ Platform); plugin lexers typically JFlex-generated                                                               |
| License                    | Apache 2.0 (IntelliJ Platform / Community edition; SDK docs likewise Apache 2.0)                                                           |
| Repository                 | Platform: [`JetBrains/intellij-community`][ij-community]; architecture grounded here in the official [`JetBrains/intellij-sdk-docs`][repo] |
| Documentation              | [plugins.jetbrains.com/docs/intellij][docs] (sources = the pinned SDK-docs repo)                                                           |
| Key authors                | JetBrains (IntelliJ IDEA shipped January 2001)                                                                                             |
| Category                   | Syntax highlighting — in-process IDE layered passes                                                                                        |
| Algorithm / grammar class  | Hand-written/JFlex lexer → recursive-descent `PsiBuilder` parser → AST + PSI (semantic tree); no grammar-as-data at runtime                |
| Lexing model               | **Incrementally restartable** lexer: full context in a single `int` state, resumable from any position via `Lexer.start(offset, state)`    |
| Output                     | Editor `TextAttributes` spans, layered from multiple passes; same highlighting drives export-to-HTML                                       |
| Highlighting / theme model | `TextAttributesKey` per item kind, resolving through **fallback-key chains** (`DefaultLanguageHighlighterColors`) into the color scheme    |
| Latest release             | Continuous (IntelliJ Platform releases); SDK-docs pin `e203227f` (2026-07-11)                                                              |

> [!NOTE]
> This deep-dive grounds the architecture in the **official SDK documentation** (the pinned `intellij-sdk-docs` checkout) — the plugin-author contract JetBrains commits to — rather than the multi-gigabyte `intellij-community` sources. That boundary is honest about one gap: the docs describe the public seams (`SyntaxHighlighter`, `Annotator`, `TextAttributesKey`, the daemon) but not internal pass classes or large-file thresholds; where the page notes platform behavior beyond the docs, it says so. The protocol-tiered alternative is [LSP semantic tokens][lsp-st]; the other editor consumption patterns are [Helix][helix] and [Vim & Emacs][vim-emacs].

---

## Overview

### What it solves

An IDE cannot choose between fast and smart highlighting — it needs the keystroke-latency token colors of a lexer _and_ the semantic judgments of a compiler front-end, in the same editor, updating live. IntelliJ's answer is architectural: don't pick one engine; **stack them by latency**, each refining the last. The SDK docs state the stack in one sentence ([`syntax_highlighting_and_error_highlighting.md:15`][ij-highlighting-md]):

> _"The syntax and error highlighting are performed on multiple levels: lexer, parser, and annotator / external annotator."_

### Design philosophy

1. **Everything stands on the lexer.** ([`implementing_lexer.md:8`][ij-lexer-md]): _"The lexer serves as a foundation for nearly all features of custom language plugins, from basic syntax highlighting to advanced code analysis features."_ Level 1 (`SyntaxHighlighter`) is pure lexer output — instant, syntactic, always available.
2. **Semantics is a _pass_, not a protocol.** Annotators run over the PSI tree in-process, in the background daemon, incrementally: _"Annotators can analyze not only the syntax, but also the semantics using PSI, and thus can provide much more complex syntax and error highlighting logic."_ ([`syntax_highlighting_and_error_highlighting.md:87`][ij-highlighting-md]). No wire format, no legend negotiation — the price is that everything must live in the IDE's process and object model.
3. **Slow work sinks to the bottom.** _"The `ExternalAnnotator` highlighting has the lowest priority and is invoked only after all other background processing has completed."_ ([`syntax_highlighting_and_error_highlighting.md:131`][ij-highlighting-md]) — the explicit latency ordering that makes the stack feel instant even when a whole-file external tool participates.

---

## How it works

### Level 1 — the restartable lexer

`SyntaxHighlighter` maps each lexer token type to `TextAttributesKey`s ([`syntax_highlighting_and_error_highlighting.md:52`][ij-highlighting-md]); invalid characters get `HighlighterColors.BAD_CHARACTER`. The contract that makes it _incremental_ is the platform's signature move ([`implementing_lexer.md:27-37`][ij-lexer-md]):

> _"The lexer used for syntax highlighting can be invoked incrementally to process only the file's changed part."_ … _"An essential requirement for a syntax highlighting lexer is that its state must be represented by a single integer number returned from `Lexer.getState()`. That state will be passed to the `Lexer.start()` method, along with the start offset of the fragment to process, when lexing is resumed from the middle of a file."_

The whole lexing context — string? comment? nested template? — must compress into one `int` per position, so the platform can snapshot states and **restart the lexer mid-file** after an edit, relexing only the damaged span. This is the same state-checkpointing idea as [syntect]'s cloneable `ParseState` and [Shiki][shiki]'s `GrammarState`, imposed as a hard API contract (and it also solves the _mid-file window_ problem [Vim solves heuristically with `:syn sync`][vim-emacs]). Two more lexer laws: no gaps and no giving up — _"Lexers … must always match the entire contents of the file, without any gaps between tokens, and generate special tokens for characters which are not valid at their location. Lexers must never abort prematurely because of an invalid character."_ ([`implementing_lexer.md:51-52`][ij-lexer-md]) — the cluster's [degrade-gracefully posture][sh] written into the contract. JFlex is the documented default implementation route.

### Level 2 — parser and PSI

Parsing is two-step ([`implementing_parser_and_psi.md:7-18`][ij-parser-md]): a `PsiBuilder`-driven parser builds an AST whose _"nodes have a direct mapping to text ranges in the underlying document"_, and a **PSI** (Program Structure Interface) tree on top adds semantics. Grammar errors become `PsiErrorElement`s _inside_ the tree — _"When it encounters a syntax error, like an unexpected token, a `PsiErrorElement` is created and added to the PSI tree … the IDE visits every PSI element in the tree, and when a `PsiErrorElement` is encountered, information about it is collected and used while highlighting the code"_ ([`syntax_errors.md:9-11`][ij-syntax-errors-md]) — the same recovered-tree philosophy as [tree-sitter][ts-highlight]'s `ERROR` nodes, a decade earlier and with the parser obligated to consume every token _"even if the tokens are not valid according to the language syntax"_. Reparsing has incremental paths of its own (block-level `IReparseableElementType` reparse; the platform's XML parser is documented as fully incremental).

### Levels 3–5 — the daemon: annotators, external annotators, inspections

The background **code-analysis daemon** re-runs analysis passes as you type. `Annotator`s walk PSI and attach highlights/errors — incrementally: _"When the file is changed, the annotator is called incrementally to process only changed elements in the PSI tree."_ ([`syntax_highlighting_and_error_highlighting.md:89`][ij-highlighting-md]). `ExternalAnnotator` wraps slow whole-file tools at the documented lowest priority. **Inspections** (`LocalInspectionTool`) are the fifth mechanism — _"run on a full PSI tree and report found problems"_, overlapping Annotators by design, with the docs noting the Annotator _"provides better performance (because it supports incremental analysis)"_ ([`code_inspections_and_intentions.md:19-32`][ij-inspections-md]). Since 2024.1 the passes parallelized: _"Inspections and annotators do not run sequentially on each `PsiElement` anymore. Instead, they're run in parallel on all relevant PSI independently"_ — with the guidance to annotate the narrowest possible element. During indexing ("**dumb mode**"), _"all IDE features are restricted to the ones that don't require indexes"_ — semantic passes wait; lexer colors don't. A `RainbowVisitor` layer adds per-symbol "semantic highlighting" (distinct colors for parameters/locals) on top.

### Colors: `TextAttributesKey` fallback chains

Every distinct item kind gets a `TextAttributesKey`; keys **layer** (_"one key may define an item's boldness and another one its color"_) and — the theming innovation — resolve through **fallback chains** ([`color_scheme_management.md:19-28`][ij-colors-md]):

> _"The color scheme manager will search first for text attributes specified by the `MY_KEYWORD` key. If those are not defined explicitly or if all the attributes are empty (undefined), it will search them using the `DEFAULT_KEYWORD` key. If neither is defined, it will further fall back to a default scheme."_

The rationale is a lesson every theme system relearns ([`color_scheme_management.md:7-11`][ij-colors-md]): schemes must _"look equally well for different programming languages even if not designed specifically for these languages. Previously, language plugins were using fixed default colors incompatible, for example, with dark schemes."_ — hence _"A use of fixed default attributes is strongly discouraged."_ Language keys chain to `DefaultLanguageHighlighterColors`, so a theme that styles the ~40 platform defaults covers every plugin language — functionally the same completeness guarantee [`@lezer/highlight`][lezer-hl] gets from a closed tag vocabulary, achieved by _inheritance_ over an open key set instead.

---

## Algorithm & grammar class

- **No grammar-as-data:** each language ships _code_ — a (usually JFlex-generated) lexer and a hand-written `PsiBuilder` recursive-descent parser — the [lexers-as-code strategy][pygments] at IDE scale, with the platform contributing the incremental machinery around it.
- **Two trees:** AST (text-faithful, range-mapped) + PSI (semantic view) — the red/green-adjacent split this survey knows from [Roslyn][roslyn]/[rust-analyzer], applied to live highlighting: the same PSI answers navigation, refactoring, and Annotator queries.
- **Precision spans all tiers in one process:** lexer (syntactic) → PsiErrorElements (grammatical) → Annotators with index-backed resolution (fully semantic). It is the only system in the cluster where all three [precision tiers][sh] share one tree and one scheduler.

## Interface & composition model

- **Extension points as the composition mechanism:** `SyntaxHighlighter`, `ParserDefinition`, `Annotator`, `ExternalAnnotator`, inspections — a plugin adds passes; the platform owns scheduling, incrementality, and merge. Contrast [LSP][lsp-st]'s one-server-per-language protocol seam.
- **Interned token types** (`IElementType` — _"The same `IElementType` instance should be returned every time"_) and single-`int` lexer states are the data-shape contracts that make platform-side caching possible — the same interning discipline as [syntect]'s packed scopes and [`@lezer/highlight`][lezer-hl]'s tags.
- **One highlighting, many surfaces:** the same key-resolved attributes drive the editor and export-to-HTML; `ColorSettingsPage` exposes every key to user theming.

## Performance

- **Latency-layered by construction:** relex-only-the-change (integer states) gives instant token colors; parse and PSI update next; daemon passes trickle in; external tools last. The user-visible invariant is _something_ is always correctly colored — staleness is bounded per tier, never global.
- **Incrementality at every level:** restartable lexing, block reparse (`IReparseableElementType`), incremental Annotator invocation on changed PSI, and (2024.1) parallel independent passes across PSI elements.
- **Dumb mode** trades semantic passes for responsiveness during indexing — an explicit "degrade the top tier, keep the bottom" switch; power-save mode generalizes it.
- **Honest gap:** the SDK docs document no file-size thresholds; the platform's large-file degradation (falling back to plain/lexer-only highlighting above internal limits) is real product behavior grounded only in the `intellij-community` sources, not the docs — flagged rather than asserted here.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — open keys with mandatory fallback:** `TextAttributesKey`s per language, chained to `DefaultLanguageHighlighterColors` — an open set made theme-coverable by inheritance (the third solution to the vocabulary problem, beside [TextMate's open strings][sh-tm] and [Lezer's closed tags][lezer-hl]).
- **Inter-unit state — the integer lexer state,** checkpointed by the platform per position; everything above the lexer derives from the persistent PSI tree (no carried state at all — the [tree-derived model][ts-highlight] with a real incremental tree).
- **Theme resolution — chain lookup with all-or-nothing steps:** first key in the chain with _any_ attributes set wins entirely (_"All attributes from the base element are ignored"_) — predictable, but a documented sharp edge.
- **Rendering targets — the editor, and HTML export from the same pass.** No terminal story (it's an IDE); the transferable design is the pass pipeline and the key-fallback theme layer, not a renderer.

## Error handling & recovery

- **Errors are tree citizens:** `PsiErrorElement`s carry the message inline; the daemon surfaces them — highlighting and diagnostics are the _same_ pipeline, not parallel ones.
- **The lexer cannot fail** (no-gaps/never-abort contract; `BAD_CHARACTER` for garbage) and the parser must consume everything — recovery obligations are pushed onto every language implementation as API law.
- **Pass isolation:** a slow or crashing external annotator degrades only its own layer (lowest priority); dumb mode suspends index-dependent passes wholesale. Per-tier degradation, never whole-editor failure.

## Ecosystem & maturity

- **Twenty-five years of production** (IDEA 1.0, January 2001) across the JetBrains IDE family and thousands of language plugins; the SDK docs and `intellij-community` (Apache 2.0) make the whole model inspectable.
- **The architecture predates and parallels the cluster's other answers:** restartable lexers before TextMate popularized grammar-as-data, PSI error elements before tree-sitter's recovered CSTs, in-process semantic passes before LSP standardized the tier — the strongest evidence that the _layering_, not any single engine, is the durable design.
- **Cost of admission:** the model assumes the IDE's process, scheduler, indexes, and object model — nothing here is a reusable library; it is a reference architecture.

---

## Strengths

- **The reference layered architecture:** fast-to-smart passes with explicit priorities, per-tier incrementality, and bounded staleness — the pattern every multi-mode tool (including a [two-engine `sparkles:syntax`][sh]) reinvents in miniature.
- **Restartable integer-state lexing** — mid-file resumability as a hard contract, solving cold-window highlighting exactly.
- **Errors in the tree, analysis in one process:** no protocol hop, no vocabulary negotiation; semantics is just another pass over PSI.
- **Fallback-chain theming** — open vocabulary with guaranteed theme coverage, and an explicit rationale born from real dark-scheme pain.
- **Battle-tested at extreme scale** — decades, dozens of languages, millions of users.

## Weaknesses

- **Nothing is extractable:** the model is welded to the platform (PSI, daemon, indexes); you can copy the architecture, not the code.
- **Per-language cost is high:** a real lexer + parser + annotators in code for every language — no community grammar corpus to import (contrast every grammar-as-data system in [the cluster][sh]).
- **Docs stop at the public seams:** internal pass scheduling and large-file limits are unspecified — the architecture is documented, the engineering envelope isn't.
- **Single-`int` lexer state is procrustean** for deeply contextual languages (heredocs-in-templates), pushing complexity into state-encoding tricks.
- **In-process semantics doesn't compose across tools:** the analysis serves one IDE; [LSP][lsp-st] trades latency for reuse across every client.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                            | Trade-off                                                                    |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| **Layered passes ordered by latency**                       | Instant lexer colors + eventual semantics; slow tools can't block fast tiers         | Multiple mechanisms overlap (Annotator vs inspection); staleness per tier    |
| **Lexer state = one `int`, restartable anywhere**           | Platform-managed incremental relexing and mid-file resume                            | All lexical context must compress into an integer; complex languages contort |
| **No-gaps / never-abort lexer + consume-everything parser** | Recovery guaranteed at every tier; highlighting never blank                          | Every language implementation carries the recovery burden itself             |
| **PSI as the single semantic substrate**                    | One tree serves highlighting, navigation, refactoring; Annotators get real semantics | Welded to the platform; memory/complexity cost of a persistent semantic tree |
| **`TextAttributesKey` fallback chains**                     | Open per-language keys, yet any scheme covers all languages via defaults             | All-or-nothing chain steps surprise theme authors; key proliferation         |
| **In-process semantics (vs a protocol)**                    | No wire format, no latency negotiation, incremental to the PSI element               | Zero reuse outside the IDE; every JetBrains IDE ships the whole platform     |
| **ExternalAnnotator at lowest priority**                    | Whole-file external tools integrate without hurting interactivity                    | Their results always arrive last; duplicated diagnostics need deduping       |

---

## Sources

- [`topics/reference_guide/custom_language_support/syntax_highlighting_and_error_highlighting.md`][ij-highlighting-md] (pinned SDK docs) — the levels thesis (:15), lexer level (:52), annotator semantics (:87), incremental annotation (:89), ExternalAnnotator priority (:131), 2024.1 parallel passes (:149-155), rainbow/semantic visitor (:65-71)
- [`topics/reference_guide/custom_language_support/implementing_lexer.md`][ij-lexer-md] — foundation quote (:8), incremental invocation (:27-28), integer-state restartability (:32-37), JFlex route (:41-46), no-gaps/never-abort (:51-52), `IElementType` interning (:66)
- [`topics/reference_guide/custom_language_support/implementing_parser_and_psi.md`][ij-parser-md] — two-step AST/PSI (:7-18), consume-all-tokens (:46); [`topics/tutorials/syntax_errors.md`][ij-syntax-errors-md] — `PsiErrorElement` + daemon (:9-11)
- [`topics/reference_guide/color_scheme_management.md`][ij-colors-md] — fallback chains (:19-28), rationale (:7-11), fixed-colors discouraged (:39), all-or-nothing (:113-114)
- `topics/reference_guide/custom_language_support/code_inspections_and_intentions.md` — inspections vs annotators (:19-32); `topics/basics/indexing_and_psi_stubs.md` — dumb mode (:29-34)
- Related deep-dives: [LSP semantic tokens][lsp-st] (the protocol-tiered alternative) · [Helix][helix] + [Vim & Emacs][vim-emacs] (other editor engines) · [Roslyn][roslyn] (the sibling compiler-as-a-service tree design) · [the highlighting synthesis][sh]

<!-- References -->

[repo]: https://github.com/JetBrains/intellij-sdk-docs
[docs]: https://plugins.jetbrains.com/docs/intellij/
[ij-community]: https://github.com/JetBrains/intellij-community
[ij-highlighting-md]: https://github.com/JetBrains/intellij-sdk-docs/blob/main/topics/reference_guide/custom_language_support/syntax_highlighting_and_error_highlighting.md
[ij-lexer-md]: https://github.com/JetBrains/intellij-sdk-docs/blob/main/topics/reference_guide/custom_language_support/implementing_lexer.md
[ij-parser-md]: https://github.com/JetBrains/intellij-sdk-docs/blob/main/topics/reference_guide/custom_language_support/implementing_parser_and_psi.md
[ij-syntax-errors-md]: https://github.com/JetBrains/intellij-sdk-docs/blob/main/topics/tutorials/syntax_errors.md
[ij-colors-md]: https://github.com/JetBrains/intellij-sdk-docs/blob/main/topics/reference_guide/color_scheme_management.md
[lsp-st]: ./lsp-semantic-tokens.md
[lezer-hl]: ./lezer-highlight.md
[helix]: ./helix.md
[vim-emacs]: ./vim-emacs-syntax.md
[ts-highlight]: ./tree-sitter-highlight.md
[syntect]: ./syntect.md
[shiki]: ./shiki.md
[pygments]: ./pygments.md
[roslyn]: ./roslyn.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
