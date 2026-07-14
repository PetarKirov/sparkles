# syntect (Rust)

The native-ecosystem reference implementation of the **[TextMate highlighting model][sh-tm]**: a Rust library that interprets Sublime Text's `.sublime-syntax` grammars **one line at a time** over a pushdown stack of regex contexts, resolves the resulting scope stacks against `.tmTheme` themes, and exposes every layer of that machine — parse state, scope ops, highlight state — as public, cacheable API. It is the engine inside [bat], delta, and zola, and the survey's fast/approximate counterpart to [tree-sitter-highlight].

| Field                      | Value                                                                                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language                   | Rust (`src/parsing/` + `src/highlighting/` + `src/{easy,dumps,html}.rs`; ~17.7 kLOC)                                                                               |
| License                    | MIT                                                                                                                                                                |
| Repository                 | [`trishume/syntect`][repo]                                                                                                                                         |
| Documentation              | [docs.rs/syntect][docs-rs]                                                                                                                                         |
| Key authors                | Tristan Hume (creator; `Cargo.toml` `authors`); major contributors credited in the README incl. keith-hall, robinst                                                |
| Category                   | Syntax highlighting — TextMate-grammar engine                                                                                                                      |
| Algorithm / grammar class  | Stateful per-line regex machine over a stack of `.sublime-syntax` **contexts** — no CFG, no tree; state = context stack carried between lines                      |
| Lexing model               | Feature-gated regex engines: **oniguruma** (`regex-onig`, the default) or pure-Rust **`fancy-regex`** (`regex-fancy`); patterns compiled lazily                    |
| Output                     | Parse layer: per-line `(usize, ScopeStackOp)` ops · highlight layer: `Vec<(Style, &str)>` styled runs · plus HTML (`ClassedHTMLGenerator`) and 24-bit ANSI helpers |
| Highlighting / theme model | Packed 16-byte `Scope` atoms + `ScopeStack` → `.tmTheme` scope-selector scoring (`MatchPower`) → `Style { foreground, background, font_style }`                    |
| Latest release             | `v5.3.0` (2025-09-27); pinned checkout `4aa7803` (2026-04-28) is 119 commits past the tag                                                                          |

> [!NOTE]
> This deep-dive surveys the `syntect` crate at the pinned SHA: the parsing engine (`src/parsing/`), the theme/highlight layer (`src/highlighting/`), dump serialization (`src/dumps.rs`), and the output helpers. Sublime Text itself and the `sublimehq/Packages` grammar corpus are referenced, not catalogued; the [bat] deep-dive covers the product pipeline built on this engine, and the grammar _model_'s history and semantics live in the [cluster synthesis][sh-tm]. Where the pinned HEAD's API differs from the released `v5.3.0`, the text says so.

---

## Overview

### What it solves

The README positions it in two sentences ([`Readme.md`][readme]):

> _"`syntect` is a syntax highlighting library for Rust that uses Sublime Text syntax definitions. It aims to be a good solution for any Rust project that needs syntax highlighting, including deep integration with text editors written in Rust."_

The choice of grammar format _is_ the strategy: by implementing Sublime's `.sublime-syntax` (the YAML successor to TextMate's `.tmLanguage` plists) syntect inherits a mature, battle-tested grammar corpus for hundreds of languages instead of authoring any — the same corpus-reuse bet [Shiki][shiki] makes on VS Code's `.tmLanguage.json` collection. Compatibility is a stated, tested goal: _"Nearly complete compatibility with Sublime Text 3, including lots of edge cases. Passes nearly all of Sublime's syntax tests"_ ([`Readme.md`][readme]).

### Design philosophy

Two goals from the README's checklist define the architecture ([`Readme.md`][readme]):

> _"Expose internals of the parsing process so text editors can do things like cache parse states and use semantic info for code intelligence"_
>
> _"Include a compressed dump of all the default syntax definitions in the library binary so users don't have to manage a folder of syntaxes."_

The first explains the layering (parse and highlight are separate, both states public and `Clone`); the second explains the `dumps` machinery [bat] later industrialized. A third statement sets expectations about evolution: _"I consider this project mostly complete, I still maintain it and review PRs, but it's not under heavy development."_ — the engine is finished infrastructure, like the grammar model it implements.

---

## How it works

### The `.sublime-syntax` format: contexts and match operations

A grammar is a set of named **contexts**, each a list of regex `match` rules. A rule fires, emits scopes for its captures, and performs a stack operation — the loaded form is literally an enum ([`syntax_definition.rs`][syntax-definition-rs]): `MatchOperation::{Push, Set { ctx_refs, pop_count }, Pop, None}` (at the pinned HEAD, `Set` carries an explicit `pop_count`; a plain `set:` is `pop_count == 1`). Context references (`ContextReference::Named`/`ByScope`/…) name other contexts in the same or _other_ syntaxes — `embed`/`escape` (nested languages with a guaranteed way out) resolve through `ByScope`, with a documented fallback to `Plain Text` when the referenced grammar is missing. `with_prototype` injects a pattern set into every pushed context (the mechanism behind Sublime's `prototype` context), and YAML `variables` are substituted into patterns at load time ([`yaml_load.rs`][yaml-load-rs]). This is the [TextMate model][sh-tm] in its most evolved dialect: regexes + an explicit context stack, richer than the original plist format (`embed`, `branch_point`, `version: 2`) but still line-local.

### One line at a time: `ParseState::parse_line`

The parse layer's contract is stated on its central method ([`parser.rs`][parser-rs]):

> _"Parses a single line of the file. Because of the way regex engines work you unfortunately have to pass in a single line contiguous in memory. This can be bad for really long lines. Sublime Text avoids this by just not highlighting lines that are too long (thousands of characters)."_

That sentence is the origin of every long-line guard in the cluster ([bat]'s 16 KiB cutoff, [Shiki][shiki]'s `tokenizeMaxLineLength`). The output is deliberately _differential_ — _"For efficiency reasons this returns only the changes to the current scope at each point in the line"_ — a vector of `(byte_offset, ScopeStackOp)` ops, ordered by offset and by pop-before-push at equal offsets, where ([`scope.rs`][scope-rs]):

```rust
pub enum ScopeStackOp {
    Push(Scope),
    Pop(usize),
    /// Used for the `clear_scopes` feature
    Clear(ClearAmount),
    /// Restores cleared scopes
    Restore,
    Noop,
}
```

`ParseState` itself is the between-lines state: the stack of active contexts (plus, at HEAD, buffered **branch points** for the `branch_point`/`fail` feature — speculative parses that can be _replayed_ when a cross-line branch resolves, surfacing as `ParseLineOutput { ops, replayed, warnings }`; the released `v5.3.0` returns the bare ops vector). Feeding lines in order is mandatory; skipping one desynchronizes the machine — the root cause of [bat]'s feed-every-line pipeline.

### Scopes: 16-byte packed atoms

Scope names (`punctuation.definition.string.begin.ruby`) are the classification vocabulary, and syntect's representation of them is its signature optimization ([`scope.rs`][scope-rs]):

> _"`syntect` uses an optimized format for storing these that allows super fast comparison and determining if one scope is a prefix of another. It also always takes 16 bytes of space. It accomplishes this by using a global repository to store string values and using bit-packed 16 bit numbers to represent and compare atoms."_

A `Scope` is two `u64`s holding up to **8 atoms** of 16 bits each, interned in a global `ScopeRepository` (scopes with more atoms _"are silently truncated"_); prefix testing — the primitive theme selectors hammer — is a few mask instructions (the README checklist: _"Determine if a scope is a prefix of another scope using bit manipulation in only a few instructions"_). A `ScopeStack` applies `ScopeStackOp`s to reconstruct the full stack at any point in a line.

### `SyntaxSet` linking and lazy regexes

_"A syntax set holds multiple syntaxes that have been linked together"_ ([`syntax_set.rs`][syntax-set-rs]): `SyntaxSetBuilder` loads grammar files, then `build()` resolves every cross-context and cross-syntax reference to **indexes**, so the hot path never does name lookups (README: _"Pre-link references between languages (e.g `<script>` tags) so there are no tree traversal string lookups in the hot-path"_). The linked set is immutable (convertible back via `into_builder`); `ParseState`s are only valid against the set (or an extension of it) that created them. Lookup API: `find_syntax_by_{name,extension,token,path}` plus `find_syntax_by_first_line` backed by a lazily built `FirstLineCache` — the shebang-detection primitive [bat] wires in as its fallback.

Regexes compile **lazily**: the `Regex` wrapper stores the pattern string and a `OnceLock`-compiled engine regex, so _"startup time isn't taken compiling a thousand regexes for Actionscript that nobody will use"_ ([`Readme.md`][readme], [`regex.rs`][regex-rs]) — and the wrapper is what makes grammar sets serializable (only pattern strings are dumped).

### Two regex engines: `onig` vs `fancy-regex`

The engine is a compile-time feature choice ([`Cargo.toml`][cargo-toml]: `default = ["default-onig"]`; `regex-fancy` swaps in the pure-Rust engine). The README frames the trade honestly ([`Readme.md`][readme]): `fancy-regex` exists because _"the `onig` crate … requires building and linking the Oniguruma C library. Many users experience difficulty building the `onig` crate, especially on Windows and Webassembly"_; correctness-wise _"As far as our tests can tell this new engine is just as correct, but it hasn't been tested as extensively in production"_; and it _"currently seems to be about **half the speed** of the default Oniguruma engine"_. This is the same engine-portability seam [Shiki][shiki] resolves with WASM + transpilation — and the residual-divergence hazard is real enough that [bat] maintains regression tests against it.

### From ops to colors: `Highlighter`, `HighlightState`, `HighlightLines`

The highlight layer folds parse ops into styles: `Highlighter` wraps a `Theme` (_"preparing it to be used for highlighting"_, with the stated intent of someday _"caching matches of the selectors of the theme on various scope paths"_, [`highlighter.rs`][highlighter-rs]); `HighlightState` _"Keeps a stack of scopes and styles as state between highlighting different lines"_; `HighlightIterator` zips ops with line text into `(Style, &str)` runs. Theme matching is `.tmTheme` **scope-selector scoring**: each `ThemeItem`'s `ScopeSelectors` are tested against the current scope stack, returning a `MatchPower` (specificity, computed from atom-prefix depth and stack position) that picks the winning style — the selector code is shared lineage with Sublime-ecosystem tooling ([`selector.rs`][selector-rs]).

The doc comment on `HighlightState` is, verbatim, the design sketch for a highlighting **pager** ([`highlighter.rs`][highlighter-rs]):

> _"…since it implements `Clone` you can actually cache these (probably along with a `ParseState`) and only re-start highlighting from the point of a change. You could also do something fancy like only highlight a bit past the end of a user's screen and resume highlighting when they scroll down on large files."_

That is the line-boundary **checkpointing** strategy — the escape from [bat]'s full-feed tax, offered by the engine itself but unused by its flagship consumer. `easy::HighlightLines` bundles `ParseState` + `HighlightState` + `Highlighter` into the one-liner API ([`easy.rs`][easy-rs]) that [bat] wraps per file.

### Binary dumps: `bincode` + `flate2`

The `dumps` module exists _"to allow fast startup times"_ ([`dumps.rs`][dumps-rs]): `SyntaxSet`s serialize to `.packdump` and `ThemeSet`s to `.themedump` via bincode (+ zlib), and the crate embeds pre-built dumps of the default Sublime packages behind `load_defaults_newlines()` / `load_defaults_nonewlines()`. The README quantifies the win: _"`~138ms` to load and link all the syntax definitions in the default Sublime package set … but only `~23ms` to load and link all the syntax definitions from an internal pre-made binary dump with lazy regex compilation."_ The two variants differ in whether lines passed to `parse_line` carry their trailing `\n` — the newlines mode _"works better"_ (grammars can anchor on the newline), which is why [bat] and the README examples use `LinesWithEndings`. The public `dump_to_file`/`from_dump_file` API is exactly what [bat] builds its `syntaxes.bin`/`themes.bin` assets and user cache on.

### HTML output: `ClassedHTMLGenerator` and `css_for_theme`

The `html` module makes syntect dual-backend out of the box: `ClassedHTMLGenerator` emits `<span>`s with **CSS classes derived from scopes** (`ClassStyle::Spaced` or the collision-safe `SpacedPrefixed`), and `css_for_theme_with_class_style` renders a `.tmTheme` into a stylesheet ([`html.rs`][html-rs]) — the class-based analogue of [Shiki][shiki]'s inline-styled output. There is also direct inline-styled HTML (`highlighted_html_for_string`) and the ANSI helper `as_24_bit_terminal_escaped` in `util` — the README's stated goal of _"Built-in output to coloured HTML `<pre>` tags or 24-bit colour ANSI terminal escape sequences"_. What the built-in ANSI path lacks (256-color/palette tiering) is precisely the part [bat] adds in `terminal.rs`.

---

## Algorithm & grammar class

- **Formalism.** A **deterministic pushdown machine driven by regexes**: state = the context stack (+ scope stack); transition = the leftmost-then-highest-priority regex match among the top context's rules; actions = push/pop/set contexts and emit scope ops. First-match-wins over ordered rules is the same _ordered choice_ discipline as [PEG][peg-packrat] — and like PEG it trades ambiguity handling for determinism. No grammar in the CFG sense exists; nesting is expressible (the stack) but unbounded cross-line constructs are modeled only as far as the stack encodes them.
- **Per-rule power.** Oniguruma-class regexes (lookaround, backrefs, `\G`) — each _rule_ recognizes more than a regular language, but classification remains **line-local**: no rule can inspect a previous line's text, only the stack it left behind. This is the model's precision ceiling, developed in the [synthesis][sh-tm].
- **Dialect.** `.sublime-syntax` `version: 2` semantics including `embed`/`escape`, `with_prototype`, `clear_scopes`, and (at HEAD) cross-line `branch_point` speculation with op replay — the most expressive TextMate dialect in the cluster ([Shiki][shiki]/vscode-textmate implement the older `begin`/`end`/`while` plist dialect).
- **Determinism caveat.** `branch_point` introduces bounded backtracking _across lines_ (buffered ops, pruned at 128 lines) — a Sublime extension that pushes past the classic model precisely because line-local determinism mis-parses some real languages.

## Interface & composition model

- **Three exposed layers, each cacheable:** parsing (`ParseState` → scope ops), scope algebra (`Scope`/`ScopeStack`, engine-independent), highlighting (`Highlighter` + `HighlightState` → styles). The layering is a stated goal (editors _"cache parse states and use semantic info"_), and every state type is `Clone` + serializable-adjacent — the API _invites_ checkpointing, windowed re-highlighting, and custom back-ends.
- **`easy` for the common case:** `HighlightLines` (line in, styled runs out) and `HighlightFile` cover the [bat]-shaped consumer in a dozen lines.
- **Feature-gated composition:** `default-features = false` + picking among `parsing`, `html`, `dump-load`, `regex-*` lets consumers drop the parser (bring-your-own tokenizer against the highlight layer), drop HTML, or swap engines — [bat] ships `features = ["parsing"]` plus an engine flag.
- **Grammar supply is external by design:** `SyntaxSetBuilder::add_from_folder` loads any Sublime package tree; the crate's own defaults are just a pre-dumped folder. Contrast [tree-sitter-highlight], where each language needs a compiled grammar artifact — here grammars are data files end to end.

## Performance

- **Posture: fast interpreter, honest about its place** — _"one of the faster syntax highlighting engines, but not the fastest"_ ([`Readme.md`][readme]). The README's measured numbers (2012-era hardware): 9 200 lines of jQuery in ~600 ms vs Sublime Text's own ~98 ms (same grammar), 50 000 lines/s on simple XML; complex JS grammars are the worst case. Sublime's 6× edge over the same grammar shows the interpreter-vs-hand-tuned-engine gap inherent in the model.
- **The optimization inventory** (README checklist, each implemented): pre-linked cross-syntax references (no name lookups in the hot path), 16-byte bit-packed scopes with instructions-not-loops prefix tests, **regex match caching** per line (_"reduce number of times oniguruma is asked to search a line"_ — match positions are cached and invalidated as the parse position advances), theme-selector lookup acceleration, and lazy regex compilation.
- **Startup: the dump story.** ~23 ms to load defaults from the embedded dump (vs ~138 ms from YAML), lazy regexes deferring the rest — the numbers behind [bat]'s asset design.
- **Long lines are the known pathology** — the `parse_line` doc names it and names Sublime's mitigation (don't highlight them); syntect itself ships **no guard**, delegating the policy to consumers (bat: 16 KiB; Shiki-equivalent time budgets: absent).
- **Parallelism:** the engine is single-threaded per stream, but states are `Send`/`Clone` and an arena refactor (README acknowledgments) enabled parallel highlighting across files/regions in consumers.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — full TextMate scope stacks,** reconstructed from differential ops. Unlike [tree-sitter-highlight]'s single resolved capture name per span, every point in a line has a _stack_ of dotted scopes (`source.rust meta.function.rust string.quoted.double.rust`), and themes match against the whole stack — ancestry is part of the vocabulary, not just the innermost label.
- **Inter-unit state — `ParseState` + `HighlightState`, explicitly cacheable.** The engine documents cloning both per line-boundary as the intended checkpoint/resume strategy (the pager quote above) — the capability [Shiki][shiki] productizes as `GrammarState` and [bat] leaves unused. Strictly forward-only, like every TextMate engine.
- **Theme resolution — `.tmTheme` scope selectors scored by `MatchPower`:** per theme item, selector-vs-stack matching with specificity from atom depth/position; the winning `StyleModifier`s fold into a concrete `Style { foreground, background, font_style }`. This is the original TextMate theme semantics, implemented over the packed-scope algebra; the [theme-format landscape][sh-themes] maps it against VS Code JSON and tree-sitter's name-keyed themes.
- **Rendering targets — both, in-crate:** 24-bit ANSI escapes (`as_24_bit_terminal_escaped`; palette tiering left to consumers) and HTML in two flavors — inline styles or **scope-derived CSS classes + `css_for_theme`** (the only engine in the cluster that renders a theme _to a stylesheet_). The dual-backend goal a [`sparkles:syntax`][sh-fit] needs is already native here.

## Error handling & recovery

- **Input text can never fail.** There is no syntax error: unmatched text simply accumulates the enclosing contexts' scopes, and a "wrong" parse is just a mis-scoped one. The failure surface is entirely **load-time and misuse**: `LoadingError` (bad YAML/plist, missing files), `ParsingError` (e.g. `MissingMainContext`, or using a `ParseState` against the wrong `SyntaxSet` — a documented panic/incorrectness hazard), regex compile errors on unvetted patterns.
- **Degradation shape.** The classic TextMate failure mode applies: a missed `end`-equivalent (a context never popped) mis-scopes everything to end-of-file — recovery is positional (the next line that happens to match a pop), not structural. Contrast [tree-sitter-highlight], whose parser localizes damage around `ERROR` nodes.
- **Cross-line speculation is bounded:** HEAD's `branch_point` buffering prunes branch points older than 128 lines and surfaces `warnings` instead of failing — even the model-stretching feature keeps the never-fail contract.
- **Engine divergence as a correctness risk:** onig-vs-fancy differences don't error; they _mis-highlight or hang differently_ — which is why consumers ([bat]) regression-test grammar corpora rather than trusting engine equivalence.

## Ecosystem & maturity

- **Adoption:** the default highlighting engine of the Rust CLI ecosystem — [bat], delta, zola, mdBook (via a wrapper era), cursive/syntect TUI integrations, and _"used in production by at least two companies"_ per the README. Where a Rust program prints highlighted code, syntect is the near-universal answer.
- **Status:** self-described _"mostly complete"_ — maintained (v5.3.0, 2025-09-27; active post-tag commits at the pin) but deliberately not evolving fast. The grammar corpus (`sublimehq/Packages` and Package Control) evolves independently; syntect consumers refresh grammars, not engine.
- **The grammar supply chain is the moat and the risk:** Sublime's ecosystem provides quality grammars for free, but its future activity is tied to Sublime Text's; the VS Code corpus (consumed by [Shiki][shiki]) is the more actively maintained sibling — one reason a new tool might target _both_ dialects.
- **Reach limits:** WASM builds need `fancy-regex` (no C oniguruma), one of the documented motivations for that engine.

---

## Strengths

- **The whole TextMate machine, properly layered:** parse/scope/highlight as separate public, cacheable stages — the only engine in the cluster whose API is _designed_ for checkpointed, windowed, resumable highlighting.
- **Corpus for free:** hundreds of production-quality Sublime grammars + `.tmTheme` themes, loadable as plain files; near-complete Sublime compatibility, test-verified.
- **Serious performance engineering** for an interpreter: packed 16-byte scopes, pre-linked syntax sets, regex match caching, lazy compilation, ~23 ms dump startup.
- **Dual rendering built in:** ANSI and HTML (inline _or_ class-based with generated CSS) from one token stream.
- **Portable engine seam:** pure-Rust `fancy-regex` mode unlocks Windows-friendly and WASM builds without C.
- **Small, stable, finished:** ~17.7 kLOC, "mostly complete" and maintained — a dependable foundation (eight years of [bat] on top proves it).

## Weaknesses

- **All the [TextMate model's][sh-tm] limits:** line-local approximate classification, no structural context, no def/use consistency, EOF-scope-bleed failure mode — precise-mode features are out of reach by construction.
- **Interpreter overhead:** ~6× slower than Sublime's own engine on the same grammar; regex scanning dominates and complex grammars (JS, Rust) are slow.
- **No built-in guards:** the documented long-line pathology is left entirely to consumers; no length or time budget exists in the engine.
- **Global scope repository:** scope interning goes through a global mutex-guarded `ScopeRepository` — convenient, but a shared-state wart for heavily concurrent embedders (and 8-atom scopes silently truncate).
- **Engine duality is a compatibility liability:** onig (C build pain) vs fancy-regex (half speed, less production-tested) — consumers must pick a divergence to live with.
- **`.tmTheme` only:** no VS Code JSON theme support; the newer theme ecosystem needs conversion (the same boundary [bat] documents for its users).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                                | Trade-off                                                                                           |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Implement Sublime's `.sublime-syntax`, not a new format**      | Inherit a huge tested grammar corpus + Sublime's syntax-test suite; users bring editor grammars as files | Bound to the TextMate model's ceiling and to Sublime's dialect evolution                            |
| **Per-line differential ops** (`ScopeStackOp`) as parse output   | Minimal allocation; consumers reconstruct exactly the stacks they need; layers stay decoupled            | Consumers must fold ops correctly (pop-before-push ordering); whole-stack views cost reconstruction |
| **16-byte packed `Scope` atoms + global repository**             | Copy/compare/prefix-test in a few instructions — the hot path of theme matching                          | 8-atom cap (silent truncation); global mutex on intern; strings are slow to extract                 |
| **Pre-linked immutable `SyntaxSet`**                             | No name lookups in the hot path; embed/include across syntaxes resolved once                             | `ParseState` validity tied to its set; extending requires rebuild (`into_builder`)                  |
| **Lazy regex compilation + serializable pattern strings**        | ~23 ms startup on the full corpus; dumps stay small and engine-independent                               | First-use latency blips; patterns validated only when first hit                                     |
| **Public, `Clone`-able `ParseState`/`HighlightState`**           | Editors/pagers can checkpoint per line and resume mid-file (the documented screen-window strategy)       | API surface exposes internals it must keep stable; correct caching is on the consumer               |
| **Feature-gated engines (`onig` default, `fancy-regex` opt-in)** | C-free builds (Windows/WASM) without abandoning the battle-tested default                                | Two behavior profiles to test; fancy mode ~½ speed and less production-hardened                     |
| **Embedded compressed dumps** (`bincode` + `flate2`)             | Zero-setup default experience; consumers cache their own compiled sets with the same API                 | Dump format couples to bincode/serde layout; corpus updates mean regenerating dumps                 |
| **No built-in pathology guards**                                 | Engine stays policy-free; the doc names the problem and Sublime's answer                                 | Every consumer re-invents the long-line cutoff ([bat]) or omits it and stalls                       |

---

## Sources

- [`Readme.md`][readme] — positioning, goals checklist, Sublime-compat claim, performance checklist + measured numbers, `fancy-regex` mode rationale/caveats, "mostly complete" status
- [`src/parsing/parser.rs`][parser-rs] — `ParseState::parse_line` doc (single-line constraint, Sublime's long-line policy, differential ops), `ParseLineOutput` (HEAD), branch-point pruning
- [`src/parsing/scope.rs`][scope-rs] — `Scope` packing doc (16 bytes, global repository, 8-atom truncation), `ScopeStack`, `ScopeStackOp`
- [`src/parsing/syntax_set.rs`][syntax-set-rs] — linked-set doc, `SyntaxSetBuilder`, `find_syntax_by_first_line` + `FirstLineCache`; [`src/parsing/syntax_definition.rs`][syntax-definition-rs] + [`yaml_load.rs`][yaml-load-rs] — `MatchOperation`, `ContextReference`, `with_prototype`, variables
- [`src/parsing/regex.rs`][regex-rs] — lazy `OnceLock` compilation, serializable patterns; [`Cargo.toml`][cargo-toml] — `regex-onig`/`regex-fancy` features
- [`src/highlighting/highlighter.rs`][highlighter-rs] — `Highlighter`, `HighlightState` caching doc (the pager quote), `HighlightIterator`; [`src/highlighting/selector.rs`][selector-rs] — `ScopeSelector`/`MatchPower`
- [`src/easy.rs`][easy-rs] — `HighlightLines` canonical example; [`src/dumps.rs`][dumps-rs] — dump module doc, `load_defaults_*`; [`src/html.rs`][html-rs] — `ClassedHTMLGenerator`, `css_for_theme_with_class_style`
- Related deep-dives: [bat] (the product layer on this engine) · [Shiki][shiki] (same model, web ecosystem) · [tree-sitter-highlight] (the precise counterpart) · [the highlighting synthesis][sh] · [PEG / ordered choice][peg-packrat]

<!-- References -->

[repo]: https://github.com/trishume/syntect
[docs-rs]: https://docs.rs/syntect
[readme]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/Readme.md
[parser-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/parsing/parser.rs
[scope-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/parsing/scope.rs
[syntax-set-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/parsing/syntax_set.rs
[syntax-definition-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/parsing/syntax_definition.rs
[yaml-load-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/parsing/yaml_load.rs
[regex-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/parsing/regex.rs
[highlighter-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/highlighting/highlighter.rs
[selector-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/highlighting/selector.rs
[easy-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/easy.rs
[dumps-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/dumps.rs
[html-rs]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/src/html.rs
[cargo-toml]: https://github.com/trishume/syntect/blob/4aa78031e93ebd3e0be7278120d0bd9d2508b1a3/Cargo.toml
[bat]: ./bat.md
[shiki]: ./shiki.md
[tree-sitter-highlight]: ./tree-sitter-highlight.md
[peg-packrat]: ./theory/peg-packrat.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
[sh-themes]: ./syntax-highlighting.md#the-theme-format-landscape
[sh-fit]: ./syntax-highlighting.md#where-sparkles-syntax-fits
