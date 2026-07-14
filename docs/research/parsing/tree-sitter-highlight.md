# tree-sitter-highlight (Rust / C)

The reference implementation of **precise, structure-driven syntax highlighting**: a Rust crate in the [tree-sitter] monorepo that runs the three `.scm` query files (`highlights` / `injections` / `locals`) over a full [GLR][bottom-up]-recovered CST and emits a **streaming event sequence** of styled spans — the model where colors come from _parse structure_, at the price of a whole-buffer parse. Within [this survey's highlighting cluster][sh] it is the **precise mode** counterpart to the line-local TextMate engines ([syntect], [Shiki][shiki]).

| Field                      | Value                                                                                                                                                     |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | Rust (`crates/highlight/src/highlight.rs`) over the `pure C11` [tree-sitter] runtime; C FFI + HTML driver in `src/c_lib.rs`                               |
| License                    | MIT                                                                                                                                                       |
| Repository                 | [`tree-sitter/tree-sitter`][repo] (`crates/highlight`)                                                                                                    |
| Documentation              | [docs.rs/tree-sitter-highlight][docs-rs] · [Syntax Highlighting chapter][highlight-md] of the tree-sitter docs                                            |
| Key authors                | Max Brunsfeld and the `tree-sitter` org (same monorepo/maintainers as the runtime)                                                                        |
| Category                   | Syntax highlighting — CST-query engine (precise mode)                                                                                                     |
| Algorithm / grammar class  | Full [GLR][bottom-up] CST ([tree-sitter]) + one merged S-expression query compiled from `highlights.scm` / `injections.scm` / `locals.scm`                |
| Lexing model               | Inherited from the grammar — the highlighter consumes **nodes**, not bytes; unmatched source passes through as plain `Source` spans                       |
| Output                     | Streaming `HighlightEvent { Source \| HighlightStart(Highlight) \| HighlightEnd }` iterator; `HtmlRenderer` (per-line-valid HTML) and CLI ANSI downstream |
| Highlighting / theme model | Capture names resolved against a user-supplied list by **longest dot-separated match**; theming is external (CLI theme carries `ansi` + `css` per style)  |
| Latest release             | Workspace `0.27.0` at the pinned checkout (`ee0847d6`, 2026-07-11); published as the `tree-sitter-highlight` crate                                        |

> [!NOTE]
> This deep-dive surveys the **highlight crate** (`crates/highlight`) plus the theme/rendering layer of the `tree-sitter` CLI (`crates/cli/src/highlight.rs`) and grammar loader (`crates/loader`). The parser, CST, queries-in-general, and error recovery are the existing [tree-sitter] deep-dive — which deliberately scoped highlighting out; this page picks up exactly where its one-sentence mention of the `highlights.scm`/`injections.scm`/`locals.scm` conventions left off. Editor _re-implementations_ of query-driven highlighting (Neovim, Helix, Zed) consume the same query files through their own engines and are referenced, not catalogued.

---

## Overview

### What it solves

A [TextMate-model][sh-tm] highlighter sees a file as independent lines and colors it with regexes; it cannot know that _this_ `identifier` is a parameter defined three scopes up, or that the string it is looking at is really embedded JavaScript. `tree-sitter-highlight` answers the same "colors, not trees" contract from the opposite direction: parse the whole buffer into a [lossless CST][tree-sitter] (error-recovering, so broken files still parse), then let declarative **queries** attach highlight names to structural patterns. The docs state the positioning — and the flagship deployment — up front ([`3-syntax-highlighting.md`][highlight-md]):

> _"Tree-sitter has built-in support for syntax highlighting via the `tree-sitter-highlight` library, which is now used on GitHub.com for highlighting code written in several languages."_

The engine is driven by exactly three query files, one concern each ([`3-syntax-highlighting.md`][highlight-md]):

> _"Syntax highlighting is controlled by **three** different types of query files that are usually included in the `queries` folder. The default names for the query files use the `.scm` file. We chose this extension because it is commonly used for files written in Scheme, a popular dialect of Lisp, and these query files use a Lisp-like syntax."_

- **`highlights.scm`** — the core mapping: _"The highlights query uses **captures** to assign arbitrary **highlight names** to different nodes in the tree"_ (dot-separated, e.g. `function.builtin`).
- **`injections.scm`** — embedded-language regions (JS inside HTML `<script>`, SQL inside a Ruby heredoc).
- **`locals.scm`** — scope-aware consistency: definitions and their references get the same color.

### Design philosophy

Three commitments shape the crate:

1. **Highlighting is a _query_ concern, not a parser concern.** The grammar knows nothing about colors; a `highlights.scm` file pattern-matches the CST (the [S-expression query language][ts-queries] of the runtime) and tags nodes with names. Grammar and theme evolve independently, and every editor sharing the query files gets identical classification.
2. **The output is a stream, not a document.** The public API returns a lazy iterator of `HighlightEvent`s — byte-range `Source` spans bracketed by `HighlightStart`/`HighlightEnd` — so a renderer (ANSI, HTML, anything) folds events as they arrive and can stop early. Nothing is materialized up front.
3. **Names are resolved by the consumer, to the consumer's vocabulary.** The library hard-codes no theme; the application supplies its list of recognized highlight names and the crate maps each capture to the _closest_ recognized name (the [longest-dot-match rule](#configure-longest-dot-match-capture-resolution)). Notably, the vocabulary itself is borrowed from the older ecosystem — the grammar metadata's `scope` key says so verbatim ([`3-syntax-highlighting.md`][highlight-md]):

   > _"`scope` (required) — A string like `"source.js"` that identifies the language. We strive to match the scope names used by popular TextMate grammars and by the Linguist library."_

   This deliberate name-compatibility with [TextMate scopes][sh-tm] is what makes a **shared theme layer across both highlighting models** feasible — the load-bearing fact for a two-engine design like [`sparkles:syntax`][sh-fit].

---

## How it works

### One merged query, three sections

`HighlightConfiguration::new(language, name, highlights_query, injection_query, locals_query)` compiles the three query files into **one** `Query`, recording where each section's patterns start ([`highlight.rs`][highlight-rs]):

> _"Construct a single query by concatenating the three query strings, but record the range of pattern indices that belong to each individual string."_ — [`highlight.rs`][highlight-rs]

The concatenation order is injections → locals → highlights; the recorded `locals_pattern_index` / `highlights_pattern_index` boundaries later tell the iterator which section a match came from. Patterns carrying the `injection.combined` property are split out into a separate `combined_injections_query` (they must run **eagerly** over the whole tree — see [injections](#layers-and-injections) below) and disabled in the main query. The constructor also caches the capture ids of the six _special_ capture names (`injection.content`, `injection.language`, `local.scope`, `local.definition`, `local.definition-value`, `local.reference`), and precomputes, per pattern, whether it carries the `(#is-not? local)` predicate (`non_local_variable_patterns`). The result _"is immutable and can be shared between threads"_ ([`highlight.rs`][highlight-rs]).

### `configure()`: longest-dot-match capture resolution

The application declares its vocabulary once — e.g. the 26-name list in the crate README — and `configure()` maps every capture name in the query onto it. The resolution rule is documented on the method ([`highlight.rs`][highlight-rs]):

> _"Tree-sitter syntax-highlighting queries specify highlights in the form of dot-separated highlight names like `punctuation.bracket` and `function.method.builtin`. Consumers of these queries can choose to recognize highlights with different levels of specificity. For example, the string `function.builtin` will match against `function.method.builtin` and `function.builtin.constructor`, but will not match `function.method`."_

Implementation: split both names on `.`; a recognized name _matches_ if **all** its parts occur in the capture's parts, and the recognized name with the most parts wins (`best_match_len`). The winner's index becomes a `Highlight(usize)` — the integer that later appears in `HighlightStart` events, indexing straight back into the user's name list (and hence their theme). A grammar can thus be _more_ specific than a theme without breaking it, and unrecognized captures resolve to `None` (uncolored). A curated `STANDARD_CAPTURE_NAMES` set (50+ names, `keyword.*`, `markup.*`, …) backs the CLI's `--check` lint for query authors.

### The `HighlightEvent` stream

The whole output model is three variants ([`highlight.rs`][highlight-rs]):

```rust
/// Represents a single step in rendering a syntax-highlighted document.
pub enum HighlightEvent {
    Source { start: usize, end: usize },
    HighlightStart(Highlight),
    HighlightEnd,
}
```

`Highlighter::highlight(config, source, encoding, cancellation_flag, injection_callback)` returns `Result<impl Iterator<Item = Result<HighlightEvent, Error>>>` — a **pull** iterator; parsing of the top layer happens at construction, but query iteration and event assembly are lazy. Highlights **nest**: renderers keep a stack, pushing on `HighlightStart` and popping on `HighlightEnd`, and style each `Source` span by the stack top. The `Highlighter` itself owns a `Parser` plus a pool of reusable `QueryCursor`s, and the doc comment sets the reuse contract: _"For the best performance `Highlighter` values should be reused between syntax highlighting calls. A separate highlighter is needed for each thread that is performing highlighting."_ ([`highlight.rs`][highlight-rs]).

### Layers and injections

Each language context is a `HighlightIterLayer`: one parse `Tree`, a `QueryCursor` over the merged query, a `highlight_end_stack`, a locals `scope_stack`, the layer's included `ranges`, and a `depth`. The top layer parses the whole buffer; **injections spawn child layers**. The README explains the hook ([`README.md`][crate-readme]):

> _"The last parameter to `highlight` is a **language injection** callback. This allows other languages to be retrieved when Tree-sitter detects an embedded document (for example, a piece of JavaScript code inside a `script` tag within HTML)."_

Two injection regimes coexist:

- **Simple injections are lazy** — when the iterator reaches an `@injection.content` capture, it resolves the language (via `@injection.language` text, a hard-coded `injection.language` property, `injection.self`, or `injection.parent`), asks the callback for that language's `HighlightConfiguration`, computes the byte/point sub-ranges with `intersect_ranges`, and parses a new layer through `Parser::set_included_ranges` — the same [included-ranges mechanism][tree-sitter-injection] the runtime exposes.
- **Combined injections are eager** — patterns marked `injection.combined` (_"indicates that **all** the matching nodes in the tree should have their content parsed as **one** nested document"_, [`3-syntax-highlighting.md`][highlight-md]) run over the whole tree up front via the separate `combined_injections_query`, so e.g. every `<?php … ?>` fragment in a template parses as one PHP document.

By default an injection covers only the captured node's own text: _"By default, injections do not include the **children** of an `injection.content` node - only the ranges that belong to the node itself. This can be changed using a `#set!` predicate that sets the `injection.include-children` key."_ ([`highlight.rs`][highlight-rs]). Layers are kept sorted by `sort_key` — at equal byte offsets, ends before starts, deeper layers first — and a shallower layer's highlight is skipped when a deeper layer already emitted one for the same range (`last_highlight_range`), so the _innermost_ language wins.

### Locals: scope-aware coloring

The `locals.scm` section uses a **fixed** capture vocabulary (unlike the arbitrary names of `highlights.scm`): `@local.scope`, `@local.definition` (+ `@local.definition-value`), `@local.reference`, plus `@ignore`. The iterator maintains a per-layer stack of `LocalScope`s, each holding its `LocalDef { name, value_range, highlight }` entries; `local.scope-inherits` controls whether a scope sees its parent's definitions. The promise, per the docs ([`3-syntax-highlighting.md`][highlight-md]):

> _"When processing a syntax node that is captured as a `local.reference`, Tree-sitter will try to find a definition for a name that matches the node's text. If it finds a match, Tree-sitter will ensure that the **reference**, and the **definition** are colored the same."_

A reference walks the scope stack in reverse, textually matches definition names, and _reuses the definition's `Highlight`_ — so a `variable.parameter` stays parameter-colored at every use site, something a line-local regex engine cannot express. The inverse hook: a highlights pattern annotated `(#is-not? local)` is suppressed for nodes already identified as locals (`non_local_variable_patterns`), preventing a generic `(identifier) @variable` rule from overriding the locals result.

### Cancellation

Highlighting a large file is priced as interruptible work, not a transaction. The knob is an `Option<&AtomicUsize>` threaded through both phases: during **parsing** it is checked from a `progress_callback` (returning `ControlFlow::Break` aborts the parse), and during **query iteration** the event loop re-checks it every `CANCELLATION_CHECK_INTERVAL = 100` iterations ([`highlight.rs`][highlight-rs]), yielding `Err(Error::Cancelled)`. The Rust `Error` enum is minimal (`Cancelled` / `InvalidLanguage` / `Unknown`); the C API widens it (`TSHighlightError`: `UnknownScope`, `Timeout`, `InvalidLanguage`, `InvalidUtf8`, `InvalidRegex`, `InvalidQuery`) and maps `Error::Cancelled | Error::Unknown` to `Timeout` ([`c_lib.rs`][c-lib-rs]). There is **no wall-clock timeout** in the Rust layer — the host owns the clock and flips the flag (contrast [Shiki][shiki]'s built-in per-line `tokenizeTimeLimit`).

### Rendering: `HtmlRenderer` and the CLI's ANSI theme

The crate ships one renderer; the CLI adds the terminal path — together they demonstrate exactly the **dual ANSI + HTML backend** a [`sparkles:syntax`][sh-fit] needs:

- **`HtmlRenderer`** (`highlight.rs`) folds events into `html: Vec<u8>` plus `line_offsets: Vec<u32>`. The key move happens at newlines — _"At line boundaries, close and re-open all of the open tags"_ ([`highlight.rs`][highlight-rs]) — so **every output line is independently valid HTML**: a pager or scroll window can splice out lines `[m, n)` without dangling `<span>`s. Attributes come from a callback (inline `style='…'` or `class='…'` — the CLI's `--css-classes` flag picks the latter, deriving class names from the dotted capture names).
- **The CLI ANSI path** ([`cli/src/highlight.rs`][cli-highlight-rs]) is the minimal event-fold: a `style_stack: Vec<anstyle::Style>` seeded with the theme default; `HighlightStart` pushes `theme.styles[highlight.0].ansi`, `HighlightEnd` pops, and each `Source` span is written as `{style}…{style:#}` (SGR set/reset around the raw bytes).
- **The CLI theme** is a JSON map in `~/.config/tree-sitter/config.json` from highlight names to styles, where each parsed `Style` carries **both** an `anstyle::Style` _and_ an optional CSS string — one theme drives both backends. RGB colors are downsampled to the 256-color cube via `ansi256_from_rgb` unless `$COLORTERM` is `truecolor`/`24bit` (`terminal_supports_truecolor`, [`cli/src/highlight.rs`][cli-highlight-rs]) — the same tiering [bat] implements for [syntect] styles.

The loader half (`crates/loader`) is a ready-made model for language detection in a CLI: each grammar's `tree-sitter.json` declares `file-types`, `first-line-regex`, `content-regex`, and `injection-regex`; `highlight_config_for_injection_string` resolves an injection name by testing it against each grammar's `injection-regex` and lazily building that grammar's `HighlightConfiguration` ([`loader.rs`][loader-rs]).

---

## Algorithm & grammar class

- **Formalism.** No algorithm of its own: classification is **pattern matching over a CST** produced by the [tree-sitter] table-driven [GLR][bottom-up] runtime. The "grammar" of the highlighter is the three `.scm` query files — declarative tree patterns with captures, compiled at load time into a single merged `Query`.
- **What the queries can express.** Anything the CST exposes structurally: ancestor context (`(call_expression function: (identifier) @function)`), field names, predicates (`#eq?`, `#match?`, `#is-not? local`), properties (`#set!` for injection keys). This is strictly richer than the [regular-language line patterns][sh-tm] of the TextMate model — captures see the _parse_, not a line buffer.
- **Precision boundary.** Classification is still **syntactic**, not semantic: the locals system textually matches names within query-declared scopes (no real name resolution, no types). It sits between TextMate regexes and full [semantic highlighting][sh] from a compiler front-end like [rust-analyzer].
- **Grammar supply chain.** Each language needs a tree-sitter grammar **and** maintained query files; queries are written per grammar (node names differ per grammar), unlike TextMate scopes which are portable across grammar collections.

## Interface & composition model

- **Library shape.** Three public types — `HighlightConfiguration` (immutable, shareable, one per language), `Highlighter` (stateful, one per thread, owns `Parser` + cursor pool), `HighlightEvent` (the output vocabulary) — plus `HtmlRenderer`. The composition point is the **injection callback** `FnMut(&str) -> Option<&HighlightConfiguration>`: the host decides how languages are discovered, loaded, and cached; the crate only asks for them by name.
- **Consumer-owned vocabulary.** `configure(recognized_names)` inverts the usual theme dependency: the _application_ declares what it can render, and the engine resolves down to it. `Highlight(usize)` indexes into the app's own list — no string comparisons on the hot path.
- **C seam.** `c_lib.rs` + `include/tree_sitter/highlight.h` expose `ts_highlighter_add_language` / `ts_highlighter_highlight` writing into a `TSHighlightBuffer`; the C surface renders **HTML only**, so non-Rust hosts wanting ANSI re-implement the event fold (as every editor does anyway). The C `TSHighlighter` resolves injections internally by regex-matching each registered language's `injection_regex` — a compact registry model worth copying.
- **Composition across languages** is the layer system: injections recursively spawn full highlight layers with their own queries, locals, and further injections, coordinated only by byte ranges and depth ordering.

## Performance

- **The headline constraint: whole-buffer parse.** `HighlightIterLayer::new` parses the **entire** source (per layer) before any event is produced — there is no line-range parse; you cannot highlight lines 100–120 of a cold file without parsing the whole file. Query iteration and event assembly are lazy, so _rendering_ can stop early, but the parse cost is paid up front. This is the structural opposite of the [TextMate model][sh-tm], which pays per line and carries only a stack between lines.
- **Streaming after the parse.** Events are pulled on demand; `HtmlRenderer` reserves buffers (`BUFFER_HTML_RESERVE_CAPACITY = 10 * 1024`) and renders line-at-a-time. A pager that parses once and renders viewports incrementally fits the API naturally.
- **Reuse contracts.** `HighlightConfiguration` is built once per language (query compilation is the expensive part) and shared across threads; `Highlighter` is reused across files per thread (parser + cursor pool). These are the same singleton economics [Shiki][shiki] documents for its highlighter instance and [bat] implements with lazy asset loading.
- **Incremental potential, batch reality.** The underlying runtime is [incremental][incremental] (`ts_tree_edit` + reparse reuses subtrees, and `ts_tree_get_changed_ranges` bounds re-highlighting), but `tree-sitter-highlight` itself exposes a **batch** API — each `highlight()` call parses fresh. Editors that highlight incrementally (Neovim, Helix, Zed) drive the runtime + queries directly rather than through this crate.
- **Cost shape.** Linear-ish in buffer size for the deterministic-grammar case (parse) plus query-match volume; cancellation (every 100 iterations) bounds latency damage on pathological inputs rather than preventing them.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh], and where the CST-query model differs most sharply from its TextMate siblings:

- **Label vocabulary — capture names, resolved by longest dot-match.** Text is labeled with dot-separated highlight names (`function.method.builtin`) attached by query captures. Unlike a [TextMate scope stack][sh-tm] (which accumulates the whole ancestry, e.g. `source.js meta.function string.quoted`), a span gets the _query-chosen_ name; nesting exists in the event stream (`HighlightStart`/`End` nest) rather than in the label. Resolution to the consumer's vocabulary is the documented specificity rule: `function.builtin` matches `function.method.builtin` but never `function.method`.
- **Inter-unit state — a layer stack over one parse, not per-line state.** Everything the highlighter "remembers" (open highlights, local scopes, injection layers) derives from the tree; there is no serialized between-lines state at all. Consequence: any edit or window move is answered from the tree (precise), but the tree must exist (whole-buffer parse) — the exact inversion of [syntect]'s `ParseState`-per-line model.
- **Theme resolution — external, consumer-side.** The crate maps captures → `Highlight(usize)` indices into the app's name list; what an index _looks like_ is entirely the app's business. The CLI's theme (JSON name → `Style { ansi, css }`) shows the intended shape: one named-slot theme, two rendering backends. Because capture names deliberately track TextMate scope names, a theme keyed on names like `string`, `keyword`, `function.builtin` can serve **both** engines of a dual-mode tool.
- **Rendering targets — both first-class, both line-safe.** ANSI via the CLI's style-stack fold with truecolor→256 downsampling; HTML via `HtmlRenderer` with tags closed/reopened at every newline so each line renders standalone. Per-line validity is the property a pager, a diff view, and an HTML `<table>` of numbered lines all rely on.

## Error handling & recovery

- **Input can never fail highlighting.** Malformed source parses into a recovered CST with [`ERROR`/`MISSING` nodes][tree-sitter-recovery]; queries simply match what they match, and unmatched bytes flow through as plain `Source` events. Grammars commonly ship an `(ERROR) @error` pattern to render broken regions visibly. Worst case is _uncolored or oddly colored_ text — the [degrade-gracefully posture][sh] shared by the whole highlighting cluster, inverted from parser error recovery.
- **Failures are configuration-time.** What _can_ fail: a bad query (`QueryError` at `HighlightConfiguration::new`, with byte offsets into the concatenated source), an unknown injected language (callback returns `None` — region stays plain), invalid UTF-8/regex/scope (C API codes). The split is clean: authors see errors when building configs; end users never do.
- **Cancellation as the runtime failure mode.** The only runtime "error" a well-configured pipeline produces is `Error::Cancelled` via the atomic flag — a **host-policy** decision (deadline, user scroll, editor keystroke), not an engine panic. The C API's naming (`TSHighlightTimeout`) documents the intended use.
- **Robustness inheritance.** Because recovery lives in the parser, highlighting quality degrades _locally_ around a syntax error (the error subtree loses its structure; siblings keep theirs) — better than TextMate's failure mode, where a missed `end` pattern can mis-scope the entire rest of the file.

## Ecosystem & maturity

- **Deployment.** The docs' headline adopter is **GitHub.com** server-side highlighting (_"now used on GitHub.com for highlighting code written in several languages"_, [`3-syntax-highlighting.md`][highlight-md]); the CLI (`tree-sitter highlight`, alias `hi`) provides ANSI/HTML output, `--check` query linting, and per-language timing.
- **The query-file convention outgrew the crate.** `highlights.scm` / `injections.scm` / `locals.scm` are the shared contract across Neovim, Helix, Zed, and the broader grammar ecosystem — each editor ships its own query-driven engine but consumes (dialects of) the same files. The crate is the _reference semantics_; the convention is the durable artifact. (Dialect drift between editors' query extensions is real, and a known integration cost.)
- **Maintenance.** Lives in the tree-sitter monorepo, versioned with the workspace (`0.27.0` at the pinned checkout), same MIT license and maintainers as the runtime — it moves in lockstep with query-language evolution.
- **Grammar/query supply.** Every supported language needs grammar + queries; the loader's `tree-sitter.json` metadata (`file-types`, `first-line-regex`, `injection-regex`) standardizes discovery. Query quality varies by grammar — the practical ceiling on highlight fidelity is usually the queries, not the engine.

---

## Strengths

- **Structural precision:** captures see the parse — ancestor context, fields, locals — so classification reaches where [line-local regexes][sh-tm] cannot (parameters vs. globals, injected languages, context-dependent tokens).
- **Scope-aware consistency:** the locals system colors a definition and all its references identically — a visible quality jump no TextMate engine offers.
- **Clean streaming output contract:** three event variants; renderers are trivial folds; ANSI and HTML backends demonstrably share one theme.
- **Per-line-valid HTML:** `HtmlRenderer` closes/reopens tags at newlines — lines splice safely into pagers, tables, diffs.
- **Robust on broken code:** inherits GLR error recovery; a syntax error degrades highlighting locally, never catastrophically.
- **First-class multi-language documents:** lazy + combined injection layers with innermost-wins ordering handle HTML/JS/CSS, templates, heredocs.
- **Host-controlled cancellation** threads through both parse and query phases — the right primitive for interactive tools.

## Weaknesses

- **Whole-buffer parse required:** no cold-start window highlighting; a `bat`-style tool pays full parse cost even for `--line-range=1:50` of a huge file.
- **Batch API over an incremental engine:** the crate itself re-parses per call; getting edit-local re-highlighting means bypassing it for the raw runtime + queries.
- **Double supply chain:** each language needs a compiled grammar (native/WASM artifact) _plus_ maintained query files — far heavier distribution than [shipping `.tmLanguage`/`.sublime-syntax` text files][syntect].
- **Query dialect drift:** the `.scm` convention is shared but not standardized; Neovim/Helix extensions diverge from the reference crate's semantics.
- **No built-in theme:** consumer must invent the name-list + theme layer (the CLI's is illustrative, not reusable as a library).
- **Locals are textual, not semantic:** same-name shadowing across scopes is handled, but no real name resolution or type information — [semantic highlighting][sh] remains a compiler-frontend feature.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                        | Trade-off                                                                                      |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| **Queries over the CST** (not lexer hooks or regexes)         | Declarative, grammar-decoupled, structurally precise; one query file serves every consumer       | Needs the full parse tree — whole-buffer cost before the first colored byte                    |
| **One merged query** (injections + locals + highlights)       | Single compiled `Query`, one cursor pass per layer; section boundaries recorded by pattern index | Constructor complexity; combined-injection patterns must be split out and disabled selectively |
| **Streaming `HighlightEvent` iterator**                       | Renderer-agnostic, early-exit friendly, no materialized spans                                    | Consumers must maintain a nesting stack; random access needs an external index                 |
| **Consumer-resolved names** (`configure` + longest dot-match) | Themes and grammars evolve independently; integer `Highlight` on the hot path                    | Every application re-invents the name-list/theme layer; no canonical theme format              |
| **Injection via callback + included ranges**                  | Host owns language discovery/caching; nested layers reuse the whole engine recursively           | Cross-layer coordination (sorting, dedup, depth rules) is subtle engine code                   |
| **Locals as textual scope tracking**                          | Big visible quality win (consistent variable colors) with zero semantic infrastructure           | Not real name resolution; correctness bounded by query authors' scope modeling                 |
| **Cancellation flag, no built-in timeout**                    | Host owns latency policy; flag checked in both parse and query loops                             | Every embedder must remember to wire it; nothing bounds a single degenerate operation          |
| **C API renders HTML only**                                   | Small stable FFI; HTML is the common denominator for embedding                                   | Native non-Rust hosts wanting ANSI/custom output re-implement the event fold                   |

---

## Sources

- [`crates/highlight/src/highlight.rs`][highlight-rs] — `HighlightConfiguration::new` (merged query, special captures), `configure` (longest dot-match doc + implementation), `HighlightEvent`, `Highlighter` reuse contract, `HighlightIterLayer`, `injection_for_match` (directive comments), `CANCELLATION_CHECK_INTERVAL = 100`, `HtmlRenderer` line-boundary handling
- [`crates/highlight/README.md`][crate-readme] — usage flow, recognized-names list, injection-callback explanation
- [`crates/highlight/src/c_lib.rs`][c-lib-rs] + [`include/tree_sitter/highlight.h`][highlight-h] — C API, `TSHighlightError`, HTML-only buffer surface
- [`crates/cli/src/highlight.rs`][cli-highlight-rs] — `Theme`/`Style { ansi, css }`, ANSI style-stack fold, `terminal_supports_truecolor` + `ansi256_from_rgb` downsampling
- [`crates/loader/src/loader.rs`][loader-rs] — `injection_regex`, `highlight_config_for_injection_string`, grammar metadata detection keys
- [Syntax Highlighting chapter][highlight-md] (`docs/src/3-syntax-highlighting.md`) — GitHub.com adoption, the three query files, highlights/locals/injections semantics, TextMate/Linguist scope-name alignment, `tree-sitter highlight` CLI
- Related deep-dives: [tree-sitter] (the runtime this consumes) · [syntect] + [bat] (the fast/approximate counterpart) · [Shiki][shiki] (the web TextMate engine) · [the highlighting synthesis][sh] · [theory: incremental][incremental]

<!-- References -->

[repo]: https://github.com/tree-sitter/tree-sitter
[docs-rs]: https://docs.rs/tree-sitter-highlight
[highlight-rs]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/crates/highlight/src/highlight.rs
[crate-readme]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/crates/highlight/README.md
[c-lib-rs]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/crates/highlight/src/c_lib.rs
[highlight-h]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/crates/highlight/include/tree_sitter/highlight.h
[cli-highlight-rs]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/crates/cli/src/highlight.rs
[loader-rs]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/crates/loader/src/loader.rs
[highlight-md]: https://github.com/tree-sitter/tree-sitter/blob/da2838c39c15885963094317edb0adb451755979/docs/src/3-syntax-highlighting.md
[tree-sitter]: ./tree-sitter.md
[ts-queries]: ./tree-sitter.md#the-s-expression-query-language
[tree-sitter-injection]: ./tree-sitter.md#interface-composition-model
[tree-sitter-recovery]: ./tree-sitter.md#error-handling-recovery
[incremental]: ./theory/incremental.md
[rust-analyzer]: ./rust-analyzer.md
[syntect]: ./syntect.md
[bat]: ./bat.md
[shiki]: ./shiki.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
[sh-fit]: ./syntax-highlighting.md#where-sparkles-syntax-fits
