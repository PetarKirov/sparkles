# highlight.js (JavaScript)

The web's most-deployed client-side highlighter, and the survey's **content-first detection** data point: grammars are JS mode objects whose matches accumulate a **relevance** score, `highlightAuto` runs _every_ grammar over the text and the highest score wins, and an `illegal` regex lets each grammar **disqualify itself** early. Created by Ivan Sagalaev in 2006, zero-dependency, CDN-first, ~190 languages and 258 themes.

| Field                      | Value                                                                                                                          |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language                   | JavaScript (browser + Node + workers); core engine ~2.6 kLOC (`src/highlight.js` = 1 051), 55.6 kLOC with grammars             |
| License                    | BSD-3-Clause (© 2006, Ivan Sagalaev)                                                                                           |
| Repository                 | [`highlightjs/highlight.js`][repo]                                                                                             |
| Documentation              | [highlightjs.readthedocs.io][docs] (in-repo `docs/`)                                                                           |
| Key authors                | Ivan Sagalaev (creator, 2006); Josh Goebel (lead maintainer, v10+)                                                             |
| Category                   | Syntax highlighting — client-side web (grammar objects + relevance auto-detection)                                             |
| Algorithm / grammar class  | Nested-mode regex machine over the whole text (`begin`/`end`/`contains` mode trees, compiled per language)                     |
| Lexing model               | Native JS `RegExp`, per-language compiled composite matchers; case/unicode handling at compile time                            |
| Output                     | HTML with `hljs-`-prefixed CSS classes (compound scopes → multiple classes); themes are plain CSS files                        |
| Highlighting / theme model | Named scopes from a documented class reference (`keyword`, `built_in`, `title.function`, …) → 258 stylesheet themes            |
| Latest release             | `11.11.2` (pinned `d4623998`, 2026-07-09, 46 commits past); 192 grammar files (~"over 180 languages"), 34 in the common subset |

> [!NOTE]
> This deep-dive surveys the engine (`src/highlight.js`, `src/lib/`), the grammar model, and — its distinctive contribution — relevance-scored auto-detection with `illegal` early rejection. The metadata-first counter-design is [Linguist][linguist]; the other regex-family engines are mapped in [the synthesis][sh]. highlight.js both detects _and_ renders (unlike Linguist), directly in the browser.

---

## Overview

### What it solves

_"Highlight.js is a syntax highlighter written in JavaScript. It works in the browser as well as on the server. It can work with pretty much any markup, doesn't depend on any other frameworks, and has automatic language detection."_ ([`README.md:26-29`][readme]). The scenario is a page full of `<pre><code>` blocks of unknown provenance — no filenames, no metadata, just text — highlighted client-side with one script tag. **Automatic language detection from content alone** is therefore not a feature but the founding constraint.

### Design philosophy

1. **Detection by competitive highlighting.** The design doc states the whole idea ([`docs/language-guide.rst:214-217`][lang-guide]): _"Highlight.js tries to automatically detect the language of a code fragment. The heuristics is essentially simple: it tries to highlight a fragment with all the language definitions and the one that yields most specific modes and keywords wins. The job of a language definition is to help this heuristics by hinting relative relevance (or irrelevance) of modes."_ Detection and highlighting are the _same computation_ — the inverse of [Linguist][linguist]'s detect-then-delegate cascade.
2. **Grammar authors tune the detector.** Relevance conventions are documented ([`language-guide.rst:242-247`][lang-guide]): _"The default value for relevance is always 1. When setting an explicit value typically either 10 or 0 is used. A 0 means this match should not be considered for language detection purposes… A 10 means 'this is almost guaranteed to be XYZ code'. 10 should be used sparingly."_ — keywords carry weights (`'nonlocal|10'`), common words score 0.
3. **Grammars can say "not me".** ([`language-guide.rst:261-266`][lang-guide]): _"Another way to improve language detection is to define illegal symbols for a mode. For example, in Python the first line of a class definition (`class MyClass(object):`) cannot contain the symbol `{` or a newline. The presence of these symbols clearly shows that the language is not Python, and the parser can drop this attempt early."_ Negative evidence as a first-class grammar feature — unique in the survey.

---

## How it works

### Grammars as mode trees

A grammar is a JS function returning a mode object: `keywords`, `contains: [...]` sub-modes, each mode with `begin`/`end` regexes, a `scope`, optional `illegal`, `relevance`. `compileLanguage` compiles the tree into per-language composite matchers (case-insensitivity and unicode handled at compile time). Keywords compile to `[scopeName, score]` pairs — a pipe overrides the score (`while|5`), `COMMON_KEYWORDS` (`of and for in not or if then …`) default to 0, everything else to 1. Modes nest (sub-languages embed via `subLanguage`), giving a recursive scan over the **whole text** — like [Pygments][pygments] a stateful whole-text machine, structured as a mode tree rather than a state-stack table.

### `highlightAuto`: the relevance contest

`highlightAuto(code, languageSubset?)` ([`src/highlight.js:685-722`][highlight-js-src]) runs `_highlight` with every eligible grammar (grammars can opt out via `disableAutodetect`), **always including plaintext as a candidate**, sorts by descending relevance — ties broken by `supersetOf` relationships (C++ beats its Arduino superset) then registration order — and returns the winner plus a `secondBest`. Relevance accumulates during the scan: each keyword hit adds its score **capped at `MAX_KEYWORD_HITS = 7`** per keyword (so `print print print…` can't fake Python), entering a mode adds the mode's relevance, and embedded sub-language results add theirs only when the host mode's relevance isn't zeroed (the Markdown-embeds-XML case).

### `illegal`: fail-fast per candidate

During a candidate scan, a match of the mode's `illegal` regex throws internally; the catch returns `{ illegal: true, relevance: 0, value: escaped }` ([`src/highlight.js:620-635`][highlight-js-src]) — the candidate's score is zeroed and it drops out of the contest. Crucially, **explicit** single-language highlighting passes `ignoreIllegals: true`, so a grammar's negative evidence prunes auto-detection without breaking requested highlighting. This is the survey's cleanest formulation of _rejection as signal_: [Linguist][linguist]'s heuristics express positive evidence; `illegal` expresses the complement.

### Output and guards

Rendering emits `hljs-`-prefixed classes (`scopeToCSSClass`; compound scopes like `title.function` → `hljs-title hljs-function_`) against a documented class reference; **258 theme CSS files** ship (82 + 176 base16 variants). The engine is defensively wrapped: **`SAFE_MODE`** (default on — _"providing the most reliable experience for production usage"_) converts non-illegal engine errors into escaped plaintext with `relevance: 0` instead of throwing; an **infinite-loop guard** bails after excessive iterations (`iterations > 100000 && iterations > match.index * 3`); a zero-width-match guard force-advances; and `highlightElement` warns on (optionally throws for) unescaped HTML inside code blocks (`HTMLInjectionError`) — an XSS posture none of the server-side engines need. There is no size guard; block-level opt-out (`nohighlight`) is the escape hatch.

---

## Algorithm & grammar class

- **A nested-mode regex machine over the whole text** — same family as [Pygments][pygments]/[syntect] (ordered regex alternatives, stateful nesting), organized as a compiled mode tree per language with native `RegExp` as the engine.
- **The detection algorithm is the highlighting algorithm run N times** — O(languages × text) on auto-detect, mitigated by the common-subset default (34 languages), `illegal` early exits, and `languageSubset` hints.
- **Precision class: line-agnostic regex approximation,** below the [TextMate scope-stack model][sh-tm] in structure (no scope stacks, coarser scopes) and well below [CST queries][ts-highlight] — its value to the survey is the detection design, not classification fidelity.

## Interface & composition model

- **One global object, three verbs:** `highlight(code, {language})`, `highlightAuto(code)`, `highlightElement(el)` — plus `registerLanguage` for grammars-as-modules (CDN builds bundle the common 34; ~190 registerable; third-party grammars documented).
- **Themes are literally CSS files** — the loosest theme coupling in the survey: no engine involvement, swap a stylesheet.
- **Plugin hooks** (`before:`/`after:highlightElement`) and wrapper ecosystems (Vue plugin, line-numbers) — DOM-era composition, contrast [Shiki][shiki]'s hast pipeline.

## Performance

- **Client-side economics:** the cost that matters is bundle size and per-block latency in the browser; the common-34 default build and per-language modules are the levers (the same axis [Shiki][shiki] attacks with fine-grained bundles).
- **Auto-detection is inherently N-times work** — acceptable per code block, unthinkable per keystroke; this is a batch/decorate-once design.
- **Guards bound damage, not cost:** loop/zero-width guards prevent hangs; no time or length budget exists ([Shiki][shiki]'s 500 ms/line and [bat]'s 16 KiB have no equivalent), so a pathological regex still costs what it costs until the iteration guard trips.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — a documented flat-ish scope list** (`keyword`, `built_in`, `string`, `title.function`, …): smaller than TextMate's namespace, bigger than [LSP][lsp-st]'s legend; compound dotted scopes render as multiple classes.
- **Inter-unit state — none across blocks;** whole-text scan per block, mode stack internal to a call (the [Pygments][pygments] posture).
- **Theme resolution — pure CSS:** class names are the entire contract; specificity and cascading are the browser's. 258 themes exist _because_ the barrier is a stylesheet.
- **Rendering targets — HTML only,** browser-first; and uniquely, **relevance doubles as a detection output** — the token stream and the language decision come from one pass.

## Error handling & recovery

- **`SAFE_MODE` is the philosophy:** engine bugs, bad grammars, weird input → escaped plaintext, never a broken page; `illegal` errors are _expected_ control flow for auto-detect and suppressed (`ignoreIllegals`) for explicit requests.
- **Unmatched text flows through unstyled;** unknown languages fall back to plaintext or auto-detection.
- **The XSS guards** (unescaped-HTML warnings/`throwUnescapedHTML`) address the one failure mode unique to running inside someone else's DOM.

## Ecosystem & maturity

- **2006 → today, from Sagalaev's Russian-language beta to the default `<pre><code>` highlighter of the web** — CDN-first distribution (cdnjs/jsDelivr/unpkg + a dedicated build repo), Node support, web workers for big blocks.
- **Corpus:** 192 in-tree grammars plus a documented third-party ecosystem; 258 themes; the `hljs-` class vocabulary is recognized by countless stylesheets.
- **Actively maintained** (v10+ modernization under Josh Goebel; `11.11.2` at the pin) with grammar quality and autodetect tuning as the perennial work.

---

## Strengths

- **The only engine surveyed with content-only detection built in** — relevance + `illegal` is a genuinely clever, grammar-author-tunable design, and `secondBest` exposes uncertainty.
- **Negative evidence as a feature** (`illegal`) — cheap, expressive, and reusable by any detection scheme.
- **Zero-dependency, CDN-deployable, themes-as-CSS** — the lowest integration cost in the cluster.
- **Production-grade defensiveness:** SAFE_MODE, loop guards, XSS posture — hardened by two decades of hostile-web deployment.
- **Keyword-hit capping** (`MAX_KEYWORD_HITS = 7`) — a small, transferable anti-gaming idea for any scoring detector.

## Weaknesses

- **Classification fidelity is the price of simplicity:** coarse scopes, no scope stacks, no structure — visibly weaker highlighting than [TextMate engines][sh-tm] on complex languages.
- **Auto-detection accuracy is corpus-tuning-bound** and famously fussy on short snippets; relevance weights are hand-set per grammar.
- **N-grammar scans for detection** — fine per block, unusable as a general detector at scale (contrast [Linguist][linguist]'s cascade reaching statistics only as tiebreak).
- **No cost budgets** (time/length) — guards stop hangs, not slowness.
- **HTML/browser only** — no ANSI story, DOM-era architecture.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                  | Trade-off                                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| **Detection = highlighting with everything, best score wins** | No metadata needed (the browser has none); detection quality improves with grammar quality | O(N grammars) per block; accuracy depends on hand-tuned weights                        |
| **Relevance weights in grammars** (0/1/10 + keyword scores)   | The language expert encodes distinctiveness where it lives                                 | Inconsistent tuning across 190 grammars; gaming needs the hit cap                      |
| **`illegal` early rejection**                                 | Negative evidence prunes candidates fast and sharpens detection                            | A too-eager `illegal` breaks legitimate code — hence `ignoreIllegals` for explicit use |
| **Grammars as JS objects**                                    | No parser/DSL; grammars are modules; compile step optimizes at load                        | Code-corpus portability limits (the [Pygments][pygments] problem, in JS)               |
| **Themes as plain CSS**                                       | 258 themes because anyone can write one; zero engine coupling                              | No theme-side logic (no palette tiers, no light-dark pairing in-engine)                |
| **SAFE_MODE default**                                         | A highlighter must never break the host page                                               | Real grammar bugs surface as silently-unstyled blocks                                  |

---

## Sources

- [`docs/language-guide.rst`][lang-guide] — the auto-detection design statement, relevance conventions, `illegal` rationale; `docs/css-classes-reference.rst` — the scope/class vocabulary; `docs/api.rst` — SAFE_MODE
- [`src/highlight.js`][highlight-js-src] — `highlightAuto` (contest, plaintext candidate, `supersetOf` ties, `secondBest`), relevance accumulation + `MAX_KEYWORD_HITS = 7`, `illegal` throw/catch to `relevance: 0`, SAFE_MODE, loop/zero-width guards, unescaped-HTML handling; `src/lib/mode_compiler.js` + `compile_keywords.js` — mode/keyword compilation and scoring
- [`README.md`][readme] + [`LICENSE`][repo] — positioning, BSD-3 © 2006 Ivan Sagalaev, language/theme counts, CDN/worker deployment
- Related deep-dives: [Linguist][linguist] (metadata-first detection) · [Pygments][pygments] (the other whole-text code-grammar engine, with per-lexer scoring) · [Shiki][shiki] (the modern web alternative for fidelity) · [the synthesis][sh]

<!-- References -->

[repo]: https://github.com/highlightjs/highlight.js
[docs]: https://highlightjs.readthedocs.io/
[readme]: https://github.com/highlightjs/highlight.js/blob/b353518e12d45d2bde57125ec6c0af4928545be7/README.md
[lang-guide]: https://github.com/highlightjs/highlight.js/blob/b353518e12d45d2bde57125ec6c0af4928545be7/docs/language-guide.rst
[highlight-js-src]: https://github.com/highlightjs/highlight.js/blob/b353518e12d45d2bde57125ec6c0af4928545be7/src/highlight.js
[linguist]: ./linguist.md
[pygments]: ./pygments.md
[syntect]: ./syntect.md
[shiki]: ./shiki.md
[bat]: ./bat.md
[lsp-st]: ./lsp-semantic-tokens.md
[ts-highlight]: ./tree-sitter-highlight.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
