# Pygments (Python)

The patriarch of server-side highlighting and the reference for the cluster's third corpus strategy: **lexers as code** — 601 lexers written as Python `RegexLexer` subclasses whose `tokens` dict is a regex state machine over the **whole text** (not per line), emitting tokens from a hierarchical **token taxonomy** whose short names (`k`, `s2`, `cp`) became the de-facto CSS interchange standard. Since October 2006 it has highlighted much of the web's documentation (Sphinx, older GitHub, countless wikis), and its lexer corpus is portable enough that [Chroma][chroma] machine-translates it into Go.

| Field                      | Value                                                                                                                                     |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | Python (~128 kLOC incl. bundled lexers)                                                                                                   |
| License                    | BSD-2-Clause; author Georg Brandl (project status "Mature")                                                                               |
| Repository                 | [`pygments/pygments`][repo]                                                                                                               |
| Documentation              | [pygments.org][docs]                                                                                                                      |
| Key authors                | Georg Brandl (creator, 2006, Pocoo); Tim Hatch, Matthäus Chajdas, Jean Abou-Samra (maintainers)                                           |
| Category                   | Syntax highlighting — lexers as code (batch/server-side)                                                                                  |
| Algorithm / grammar class  | Per-lexer regex **state machine** (`tokens` dict: state → `(regex, tokentype, new_state)` rules over a state stack); whole-text scan      |
| Lexing model               | CPython `re`, `re.MULTILINE`; position-anchored `match` at `pos`; callbacks (`bygroups`, `using`) and `ExtendedRegexLexer` escape hatches |
| Output                     | `(index, TokenType, value)` stream → 14 formatters (HTML, LaTeX, RTF, SVG, image, terminal 8/16, terminal256, …)                          |
| Highlighting / theme model | Hierarchical `Token` singletons; `STANDARD_TYPES` short CSS names; `Style` classes with implicit parent inheritance                       |
| Latest release             | `2.20.0` (pinned `f1a91515`, 2026-07-09); 601 `LEXERS` entries / 263 modules / 47 styles                                                  |

> [!NOTE]
> This deep-dive surveys the library at the pinned checkout: the lexer machinery (`pygments/lexer.py`), token taxonomy (`token.py`), detection (`lexers/__init__.py`), and the formatter/style split. Individual language lexers are the corpus, not the subject. The compiled-language port of this exact design is [Chroma][chroma]; the _grammar-as-data_ alternatives are the [TextMate engines][sh-tm]; the model landscape is mapped in [the synthesis][sh].

---

## Overview

### What it solves

Batch highlighting for documents: _"It is a generic syntax highlighter for general use in all kinds of software such as forum systems, wikis or other applications that need to prettify source code."_ ([`pygments/__init__.py:7-9`][init-py]). No editor, no incrementality, no viewport — text in, styled markup out, for over 500 languages, with output targets from HTML to LaTeX to ANSI. The docs are candid about the mechanism: _"most languages use a simple regex-based lexing mechanism"_ ([`doc/index.rst`][docs]).

### Design philosophy

1. **The lexer is a Python class; the corpus is a library.** Where [TextMate grammars][sh-tm] are data files and [tree-sitter grammars][ts-highlight] are compiled artifacts, a Pygments lexer is _code_: a `RegexLexer` subclass whose `tokens` dict is interpreted by the engine, with arbitrary Python callbacks where regexes run out. Maximum expressiveness, zero sandboxing, corpus tied to the Python runtime.
2. **One taxonomy to rule the themes.** Token types are hierarchical singletons (`Token.Keyword.Reserved`) with fixed short names; styles inherit along the hierarchy automatically. Every theme covers every language because the vocabulary is shared and subsuming — the same completeness goal [`@lezer/highlight`][lezer-hl] reaches with closed tags and [IntelliJ][intellij] with key fallback chains.
3. **Whole-text scanning, not lines.** The engine matches at a running `pos` across the entire input; `re.MULTILINE` only affects `^`/`$` anchors. State spans lines natively — no carried line-state, no sync problem, and none of the [TextMate model's][sh-tm] line-locality. The price: no checkpointing story at all, and the whole text must be in memory.

---

## How it works

### The `tokens` state machine

The authoritative description is the `RegexLexer` docstring ([`lexer.py:678-700`][lexer-py]): _"At all time there is a stack of states. Initially, the stack contains a single state 'root'."_ Each state maps to rules of _"`{'state': [(regex, tokentype, new_state), ...], ...}`"_ where `new_state` _"can be `'#pop'` to signify going back one step in the state stack, or `'#push'` to push the current state on the stack again"_ — plus tuple pushes, `'#pop:2'`, integer multi-pops, `include(...)` for rule reuse, `default(...)` for match-free transitions, and `inherit` for subclassing lexers. Helpers cover the awkward cases: `bygroups(...)` (_"yields multiple actions for each group"_), `using(other)` (_"processes the match with a different lexer"_ — delegation for embedded languages), `this`, `words(...)`. `ExtendedRegexLexer` threads a mutable `LexerContext` for lexers that must manipulate `pos`/stack directly (Ragel-style), and `DelegatingLexer` runs one lexer over another's `Other` tokens (_"First everything is scanned using the language lexer, afterwards all `Other` tokens are lexed using the root lexer"_) — template languages as composition.

The core loop ([`lexer.py:708-745`][lexer-py]) is a position-anchored scan: `m = rexmatch(text, pos)` per rule of the top state, first match wins, `pos = m.end()` — ordered choice over a pushdown stack, the same discipline as [syntect]'s context machine but over the **whole text** in one pass.

### The token taxonomy

`Token` types are tuple-derived singletons built on attribute access (`Token.Keyword.Reserved`), memoized, with subsumption as a prefix test ([`token.py:28-32`][token-py]): `val in Keyword` iff `val[:len(Keyword)] == Keyword` — the docs note _"tokens are singletons so you can use the `is` operator"_. **`STANDARD_TYPES`** ([`token.py:123-214`][token-py]) maps the hierarchy to short CSS class names — `Keyword: 'k'`, `Keyword.Reserved: 'kr'`, `String.Double: 's2'`, `Comment.Preproc: 'cp'`, `Generic.Deleted: 'gd'` — the vocabulary that outlived the library: `.highlight .k { … }` stylesheets are recognizable across a decade of static-site generators, and [Chroma][chroma] re-encodes the same hierarchy as integer ranges.

### Formatters and styles

The `Style`/`Formatter` split mirrors the token/theme split: a `Style` class maps token types to style strings (`Keyword: "bold #008000"`), and `StyleMeta` fills every standard type with `''` so **undefined types inherit from their parent** implicitly. Formatters render the token stream per target: `HtmlFormatter` walks a non-standard token's parents until it finds a `STANDARD_TYPES` class and can emit a full stylesheet (`get_style_defs`); `Terminal256Formatter` downsamples RGB styles to the xterm palette by **squared-Euclidean nearest color** ([`terminal256.py:188-203`][terminal256-py]) — cruder than the redmean metric [Chroma][chroma] uses or the `ansi256_from_rgb` tables in [bat] and the [tree-sitter CLI][ts-highlight], but the same tiering problem. Fourteen formatters ship, from HTML and LaTeX to IRC and Pango markup — the widest backend fan-out in the cluster.

### Detection: modeline → filename → scored content

Three layers ([`lexers/__init__.py`][lexers-init]): `guess_lexer` checks a Vim modeline first; filename lookup glob-matches `LEXERS` patterns with explicit (non-`*`) patterns ranked `+0.5`; and content analysis calls every lexer's **`analyse_text(text)`**, a per-lexer scoring function returning `0..1` (Python's: shebang match or `'import '` in the first 1000 chars), short-circuiting at `1.0` and otherwise keeping the max. The `make_analysator` wrapper clamps to `[0,1]` and **swallows exceptions to `0.0`** — scoring must never break detection. This lexer-authored-scoring design sits between [Linguist][linguist]'s centralized strategy cascade and [highlight.js][hljs]'s highlight-with-everything relevance contest.

### Error handling: the one-char skip

When no rule matches ([`lexer.py:747-761`][lexer-py]): at a newline, **reset the state stack to `['root']`** and continue — _"error-tolerant highlighting for erroneous input"_ line-level recovery; otherwise emit a single `Token.Error` for one character and advance. Never throws on content. [Chroma][chroma] copies this verbatim (with a "From Pygments :\\" attribution comment).

---

## Algorithm & grammar class

- **A regex pushdown interpreter per language,** authored as code: ordered-choice rules over a state stack, position-anchored across the whole text — the same machine family as [syntect]/[TextMate][sh-tm] minus the line boundary, plus arbitrary host-language callbacks.
- **Expressiveness is unbounded** (callbacks, delegation, context manipulation) — which is exactly why the corpus resists full mechanical translation ([Chroma][chroma]'s stated porting caveat) and why grammar-as-data formats deliberately gave that power up.
- **No parse tree, no structure:** classification is flat tokens; everything structural (nesting-aware color, def/use) is out of reach, as for all regex-family engines.

## Interface & composition model

- **`get_tokens(text)` streams `(index, type, value)`** — the simplest engine API in the cluster; lexers, formatters, styles, and filters compose as independent axes, each pluggable via setuptools entry points (`pygments.lexers`, `pygments.styles`, …).
- **The corpus is importable code:** 601 lexers in one package, extended by subclassing (`inherit`), delegation, or third-party plugins; `pygmentize` is the CLI face.
- **Formatter fan-out** decouples one token stream from 14 targets — the architectural proof that token-stream → renderer is the right seam (the same seam [`sparkles:syntax`][sh-fit] places between engines and backends).

## Performance

- **Posture: adequate for batch, unguarded for adversaries.** The FAQ claims _"parsing and formatting is fast"_; there are **no guards at all** — no regex timeout, no line-length cap, no backtracking bound. Catastrophic backtracking in a lexer regex hangs the process — the sharpest contrast with [Chroma][chroma]'s 250 ms `MatchTimeout`, [bat]'s 16 KiB cutoff, and [Shiki][shiki]'s time budget, and a direct cautionary datum for any new engine.
- **Whole-text in memory,** one pass, no incrementality or checkpointing — batch by construction.
- **CPython `re` is the engine:** per-rule compiled patterns, first-match-wins over each state's rule list; cost is grammar-quality-dependent and unbounded in principle.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — the hierarchical `Token` taxonomy** with `STANDARD_TYPES` short names: an open hierarchy (lexers may invent subtypes) made theme-complete by **parent-walking** — unknown subtypes render as their nearest standard ancestor. The fourth solution to the vocabulary problem, and historically the most copied.
- **Inter-unit state — none exposed:** the state stack lives inside one `get_tokens` call over the whole text; there is no resume/checkpoint API (the model that makes Pygments simple also makes it strictly batch).
- **Theme resolution — class-level inheritance:** `Style` dicts sparse-populate the taxonomy; `StyleMeta` fills gaps from parents. Themes are Python classes, shareable across every formatter.
- **Rendering targets — the widest set surveyed:** HTML (classes + generated stylesheet), ANSI 8/16 and 256 (Euclidean downsample), LaTeX, RTF, SVG, images, IRC — one taxonomy feeding them all.

## Error handling & recovery

- **Content never fails:** `Token.Error` + one-char advance; newline resets to `root` (line-level resync of a whole-text engine — a miniature of [Vim's sync problem][vim-emacs] solved by fiat).
- **Detection never fails:** `analyse_text` exceptions are swallowed to `0.0` by the wrapper.
- **The failure mode that remains is pathological cost,** not wrong output — unguarded regex backtracking (see Performance).

## Ecosystem & maturity

- **Twenty years of being the default:** Sphinx and the Python docs, pre-2014 GitHub (via pygments.rb), MkDocs, Pelican, Doxygen filters, LaTeX `minted` — Pygments _is_ documentation highlighting for much of the ecosystem; first public release v0.5 ("PyKleur"), 30 October 2006.
- **The corpus is the asset:** 601 lexers under BSD-2 with a stable authoring model attract contributions and downstream ports — [Chroma][chroma] (Go) machine-translates it; Rouge (Ruby) reimplements it API-compatibly; the token taxonomy and `.highlight .k`-style CSS transcend the implementation.
- **Mature and explicit about it** (PyPI status "Mature"): steady releases, new lexers continuously, core engine essentially frozen.

---

## Strengths

- **The proven corpus-as-code model:** 601 lexers, one authoring pattern, twenty years of contributions — with expressiveness (callbacks, delegation) no data format matches.
- **The taxonomy that became a standard:** hierarchical tokens + short CSS names + parent-inheritance = themes that cover everything, portable beyond the library itself.
- **Whole-text state machine:** multiline constructs are natural, no line-boundary contortions, no sync heuristics.
- **Widest output fan-out in the survey** — fourteen formatters over one stream.
- **Simple, layered detection** with per-lexer content scoring, exception-proofed.

## Weaknesses

- **No pathological-input guards whatsoever** — a hostile or unlucky input can hang the regex engine; every downstream consumer must add its own bounds.
- **Strictly batch:** no incrementality, no checkpointing, no viewport story; unsuited to editors by design.
- **Corpus welded to CPython:** lexers-as-code means porting requires either a Python runtime (pygments.rb's original approach) or translation with fidelity loss ([Chroma][chroma]'s documented caveats).
- **Python-speed scanning** of every byte through interpreted rule loops — fine for docs builds, uncompetitive for a pager hot path.
- **Flat tokens only** — no structural or semantic precision tier above the regex machine.

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                                                 | Trade-off                                                                      |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Lexers as Python classes** (code, not data)        | Unbounded expressiveness; callbacks/delegation handle what regex formats can't            | Corpus tied to Python; mechanical porting lossy; grammars are unsandboxed code |
| **Whole-text scan with a state stack**               | Multiline constructs natural; no line-boundary model; simplest possible engine loop       | No checkpoint/resume; whole text in memory; batch-only                         |
| **Hierarchical token singletons + `STANDARD_TYPES`** | Themes complete via parent-walk; `is`/`in` tests are pointer/prefix ops; CSS names stable | Open hierarchy still needs curation; short names are cryptic by design         |
| **Style classes with implicit inheritance**          | Sparse themes work everywhere; one theme serves 14 formatters                             | All-Python theming; no external theme format                                   |
| **Per-lexer `analyse_text` scoring**                 | Detection knowledge lives with the language expert; clamped and exception-proofed         | Quality varies wildly per lexer; every-lexer scans on ambiguous input          |
| **`Error` + one-char skip, newline→root reset**      | Never fail on content; line-level resync limits damage                                    | Mis-scoped regions until the next newline; no structural recovery              |
| **No input guards**                                  | Engine simplicity; trusts grammar authors                                                 | Catastrophic backtracking = hung process; consumers must guard externally      |

---

## Sources

- [`pygments/lexer.py`][lexer-py] — `RegexLexer` docstring (state stack, `#push`/`#pop`), core loop (whole-text `rexmatch(text, pos)`), helpers (`bygroups`, `using`, `default`, `include`), `ExtendedRegexLexer`/`LexerContext`, `DelegatingLexer`, the error fallback (newline→root reset, one-char `Error` skip)
- [`pygments/token.py`][token-py] — `_TokenType` singletons, `__contains__` subsumption, `STANDARD_TYPES`
- [`pygments/lexers/__init__.py`][lexers-init] + `pygments/util.py` — `guess_lexer` (modeline first), filename rating, `make_analysator` clamp/swallow; `pygments/lexers/_mapping.py` — the generated 601-entry `LEXERS` map
- [`pygments/formatters/terminal256.py`][terminal256-py] — xterm palette + `_closest_color` Euclidean downsample; `pygments/style.py` — `StyleMeta` inheritance; `pygments/plugin.py` — entry-point groups
- [`pygments/__init__.py`][init-py] + `README.rst` + `doc/` — positioning, "simple regex-based lexing mechanism", FAQ speed claim
- Related deep-dives: [Chroma][chroma] (this corpus, ported) · [syntect] / [Shiki][shiki] ([grammar-as-data][sh-tm] alternatives) · [highlight.js][hljs] + [Linguist][linguist] (the other detection designs) · [the synthesis][sh]

<!-- References -->

[repo]: https://github.com/pygments/pygments
[docs]: https://pygments.org/
[init-py]: https://github.com/pygments/pygments/blob/d0588828dc613bdaed6f7ad687610097c94c88d2/pygments/__init__.py
[lexer-py]: https://github.com/pygments/pygments/blob/d0588828dc613bdaed6f7ad687610097c94c88d2/pygments/lexer.py
[token-py]: https://github.com/pygments/pygments/blob/d0588828dc613bdaed6f7ad687610097c94c88d2/pygments/token.py
[lexers-init]: https://github.com/pygments/pygments/blob/d0588828dc613bdaed6f7ad687610097c94c88d2/pygments/lexers/__init__.py
[terminal256-py]: https://github.com/pygments/pygments/blob/d0588828dc613bdaed6f7ad687610097c94c88d2/pygments/formatters/terminal256.py
[chroma]: ./chroma.md
[syntect]: ./syntect.md
[shiki]: ./shiki.md
[bat]: ./bat.md
[hljs]: ./highlight-js.md
[linguist]: ./linguist.md
[lezer-hl]: ./lezer-highlight.md
[intellij]: ./intellij-highlighting.md
[vim-emacs]: ./vim-emacs-syntax.md
[ts-highlight]: ./tree-sitter-highlight.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
[sh-fit]: ./syntax-highlighting.md#where-sparkles-syntax-fits
