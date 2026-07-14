# Linguist (Ruby / GitHub)

The **language-detection** reference: GitHub's library for deciding what every file _is_ before anything highlights it — an ordered **strategy cascade** (modeline → filename → shebang → extension → XML → man page → content heuristics → statistical classifier) that only ever _narrows_ a candidate set, backed by a 815-language registry whose `tm_scope` field is the seam into TextMate-grammar highlighting. Detection is the half of the [bat]-clone problem no engine page covers; Linguist is how it looks at corpus scale.

| Field                      | Value                                                                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | Ruby (~3.9 kLOC `lib/`) + a flex-generated C tokenizer extension (`ext/linguist/`)                                                           |
| License                    | MIT (© GitHub)                                                                                                                               |
| Repository                 | [`github-linguist/linguist`][repo]                                                                                                           |
| Documentation              | In-repo `docs/` (`how-linguist-works.md`, `overrides.md`)                                                                                    |
| Key authors                | GitHub (open-sourced May 2011)                                                                                                               |
| Category                   | Language detection (feeding syntax highlighting + repo statistics)                                                                           |
| Algorithm / grammar class  | Strategy cascade with monotone candidate narrowing; content heuristics (ordered regex rules); nearest-centroid cosine classifier as tiebreak |
| Lexing model               | n/a — detection only; the C flex tokenizer feeds the classifier (strips strings/comments, keeps significant symbols)                         |
| Output                     | A `Language` (name, `tm_scope`, type, color, aliases, …) per blob; repo-level language statistics                                            |
| Highlighting / theme model | None of its own — `tm_scope` maps each language onto TextMate grammars (537 grammar submodules, 1 475 scopes in `grammars.yml`)              |
| Latest release             | `v9.6.0` (pinned `e9fe3c9f`, 2026-06-18, 5 commits past the tag)                                                                             |

> [!NOTE]
> This deep-dive surveys detection: the strategy chain, `languages.yml`, `heuristics.yml`, the classifier, and the exclusion/override machinery. Linguist does **not** highlight — it _names_ languages and hands highlighting to grammars via `tm_scope` (GitHub's current tree-sitter-based rendering lives elsewhere; this library remains TextMate-oriented). The content-first counter-design is [highlight.js][hljs]' relevance contest; the tool-sized versions of this problem are [bat]'s mapping layer and [tree-sitter's grammar metadata][ts-highlight].

---

## Overview

### What it solves

_"This library is used on GitHub.com to detect blob languages, ignore binary or vendored files, suppress generated files in diffs, and generate language breakdown graphs."_ ([`README.md:7`][readme]). At GitHub scale, detection is not a convenience — it decides which grammar highlights a file, which files count toward a repository's language statistics, and which files diffs bother rendering. The problem decomposes into exactly the layers a highlighting CLI meets in miniature: cheap metadata signals first, content analysis only when they disagree.

### Design philosophy

1. **A cascade that only narrows.** Strategies run in a fixed order; each either identifies the language, shrinks the candidate list (set intersection — `candidates & languages`), or passes it unchanged. The docs state it plainly ([`docs/how-linguist-works.md:8`][how-works]): _"The language of each remaining file is then determined using the following strategies, in order, with each step either identifying the precise language or reducing the number of likely languages passed down to the next strategy."_ Cheap and precise beats expensive and clever — statistics run **last**, over survivors only.
2. **The registry is the product.** `languages.yml` (815 languages, 9 452 lines) is the shared vocabulary: extensions, filenames, interpreters, aliases, colors — and `tm_scope`, documented as _"The TextMate scope that represents this programming language… Use 'none' if there is no TextMate grammar for this language."_ Detection and highlighting meet in that one field.
3. **User intent overrides everything.** `.gitattributes` (`linguist-language`, `linguist-vendored`, `linguist-generated`, `linguist-documentation`, `linguist-detectable`) lets repositories correct the machine — _"`.gitattributes` will be used to determine language statistics and will be used to syntax highlight files"_ ([`docs/overrides.md:7-8`][overrides]). The same lesson as [bat]'s user-precedence syntax mappings, at platform scale.

---

## How it works

### The strategy chain

The ordered list, verbatim ([`lib/linguist.rb:63-72`][linguist-rb]):

```ruby
STRATEGIES = [
  Linguist::Strategy::Modeline,
  Linguist::Strategy::Filename,
  Linguist::Shebang,
  Linguist::Strategy::Extension,
  Linguist::Strategy::XML,
  Linguist::Strategy::Manpage,
  Linguist::Heuristics,
  Linguist::Classifier
]
```

The driver bails early on binary/empty blobs, then runs each strategy over the surviving candidates: one candidate → done; several → intersect and continue; zero → keep the previous list and continue. Details per strategy: **Modeline** reads Vim/Emacs modelines in the first and last 5 lines — the highest-precedence signal because it is explicit user intent in the file. **Filename** catches exact names (`Makefile`, `Dockerfile`). **Shebang** resolves interpreters robustly (walks `/usr/bin/env`, strips versions — `python2.6` → `python2`). **Extension** intersects extension matches with prior candidates, skipping known-generic extensions. **XML** fires only when _nothing_ has matched (an `<?xml` sniff), **Manpage** catches roff sections. Then content takes over.

### `heuristics.yml`: the shared-extension tiebreakers

130 disambiguation blocks + 21 named patterns settle the classic collisions — evaluated in order, first match wins. The `.h` block is exemplary ([`heuristics.yml:384-390`][heuristics-yml]): Objective-C if the `objectivec` named pattern matches (`@interface|@protocol|#import …`), C++ on `cpp` patterns (`#include <cstdint|…>`, `template\s*<`), else **C as a pattern-less fallthrough**. `.m` disambiguates Objective-C / Mercury (`:- module`) / MATLAB (`^\s*%`) / and friends. The rule grammar supports `pattern`, `named_pattern`, `and`, `negative_pattern`; a regex timeout yields `[]` rather than an error. This file is the distilled, community-maintained answer key for extension ambiguity — directly liftable by any tool facing `.h`/`.m`/`.pl`/`.sql`.

### The classifier: "Bayesian" by reputation, nearest-centroid by code

The last-resort tiebreaker over remaining candidates. The docs (and the tokenizer's own comment — _"Tokens are designed for use in the language bayes classifier"_) say naive Bayes; **the code has moved on** ([`classifier.rb:123-150`][classifier-rb]): term frequencies are log-scaled (`1.0 + Math.log(freq)`), weighted by inverse class frequency, L2-normalized, and scored by **cosine similarity against per-language centroids** trained from `samples/` (3 310 files across 747 language directories) — a TF-ICF nearest-centroid classifier. It reads only the first **50 KB** (`CLASSIFIER_CONSIDER_BYTES`), tokenized by the flex-generated C extension that strips strings/comments and keeps significant symbols. A doc-vs-code discrepancy worth recording — and a design point: the statistical stage is _replaceable_ because the cascade quarantines it at the end.

### Exclusions and overrides

Language statistics are as much about what _not_ to count: `vendor.yml` (168 path regexps), `documentation.yml` (18), and `generated.rb` (~40 detectors — minified JS, source maps, lockfiles, `node_modules`, generated protobuf …) — _"Generated source code is suppressed in diffs and is ignored by language statistics."_ By default only `programming`/`markup` types count. Repositories override any of it via `.gitattributes`, including forcing a language (`linguist-language=<name>` — _"Highlighted and classified as name"_) or making data files detectable.

### The highlighting seam

Linguist ships **537 grammar submodules** under `vendor/grammars/`, catalogued in `grammars.yml` (1 475 scope entries), and every language's `tm_scope` points into that set — the pipeline that highlighted GitHub for a decade: detect with Linguist, highlight with the TextMate grammar its `tm_scope` names. (Tree-sitter is essentially absent from this repo; GitHub's current renderer consumes [tree-sitter-highlight][ts-highlight] in a separate service.) `languages.yml` also carries `ace_mode`/`codemirror_mode` — the registry serves every editor GitHub embeds.

---

## Algorithm & grammar class

- **A monotone filter pipeline:** candidates only shrink, strategies are pure functions of (blob, candidates), and the expensive stages see only survivors — a textbook staged-classifier architecture with a total order of signal cost.
- **Heuristics are ordered regex rules with fallthrough** — deterministic and auditable; the statistical stage is deliberately last and replaceable.
- **Precision framing:** detection is a _classification_ problem, not a parsing one — no grammar class applies; the interesting structure is the cascade itself and the registry schema.

## Interface & composition model

- **`languages.yml` is the API:** downstream tools (GitHub features, editors, static-site generators) consume the registry as data — names, extensions, colors, scopes. The schema (required `type`, `ace_mode`, `language_id`, `tm_scope`; optional `group`, `interpreters`, …) is the field list any tool's language registry converges on.
- **Strategies are pluggable classes** with one call signature; heuristics and samples are data — contribution scales because adding a language rarely means writing Ruby.
- **Detection composes with highlighting by name** (`tm_scope`), not by coupling — the registry pattern that lets one detector serve N renderers.

## Performance

- **Cost-ordered by construction:** metadata strategies are O(1) lookups; heuristics run few regexes over one file; the classifier tokenizes at most 50 KB in C — and most files never reach it.
- **Binary/vendored/generated short-circuits** keep the pipeline off files nobody wants highlighted — as important at scale as the detection itself.
- **The flex C tokenizer** is the one hot-path concession in an otherwise Ruby codebase.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh] — for a detection library it reads as _what it hands the highlighter_:

- **Label vocabulary — language names + `tm_scope`:** the registry maps every detected language onto the [TextMate scope][sh-tm] namespace (or `none`), making grammars addressable by detection result.
- **Inter-unit state — none:** per-blob classification; repo statistics aggregate over blobs.
- **Theme resolution — delegated entirely:** Linguist colors nothing; its `color` field paints the _language bar_, not code.
- **Rendering targets — none;** the deliverable is the decision. The transferable design is the cascade + registry + overrides triple.

## Error handling & recovery

- **No strategy may fail the pipeline:** heuristic regex timeouts return empty; the classifier is clamped to candidates; zero-match strategies pass candidates through. Worst case is _wrong_, never _broken_ — the detection twin of the cluster's [degrade-gracefully][sh] posture.
- **Ambiguity resolves to the safest earlier signal** (extension order, heuristic fallthroughs like `.h` → C), and user overrides trump all of it.
- **Unknown languages are a supported outcome** (`tm_scope: none`, undetectable types) rather than an error.

## Ecosystem & maturity

- **Fifteen years of production at GitHub scale** (open-sourced May 2011; `v9.6.0` at the pin), with the registry maintained by a large contributor community — adding/fixing languages is GitHub's most-trafficked detection workflow.
- **The de-facto registry:** `languages.yml` data (names, colors, extensions) is consumed far beyond GitHub — editors, linters, statistics tools — much as [Pygments][pygments]' token names outgrew Pygments.
- **Boundary:** Ruby + C, gem-shaped, GitHub-workflow-flavored (git blobs, `.gitattributes`); tools elsewhere lift the _data and the design_, not the gem.

---

## Strengths

- **The reference detection architecture:** cost-ordered, monotone-narrowing, auditable, with statistics quarantined to last place — directly transplantable to a CLI.
- **The registry and the heuristics file are liftable data assets** — 815 languages and the community-curated answer key for every classic extension collision.
- **Override machinery as a first-class feature** — user intent beats inference at every level.
- **Exclusion intelligence** (vendored/generated/documentation) — the unglamorous half of "what should we highlight?" solved in data.
- **Detection decoupled from rendering** via `tm_scope` — one detector, any highlighter.

## Weaknesses

- **No confidence signal:** the cascade returns a language, not a probability; downstream can't distinguish "certain by shebang" from "centroid tiebreak".
- **Docs lag code** (the "Bayesian" classifier is nearest-centroid now) — a caution for anyone citing its design secondhand.
- **Content stages are corpus-bound:** heuristics and samples cover what contributors hit; new/rare languages detect poorly until the data catches up.
- **Repo-workflow shape:** blob/gitattributes assumptions make direct reuse outside a VCS context awkward — the _design_ travels, the gem doesn't.
- **TextMate-era seam:** `tm_scope` binds the registry to grammar tech GitHub itself has partly moved past.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                            | Trade-off                                                                        |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| **Ordered cascade, monotone narrowing**                | Cheap precise signals first; expensive stages see only survivors; behavior auditable | No probabilities; early wrong narrowing can't be undone downstream               |
| **Registry as data (`languages.yml`)**                 | Community-scalable; consumed as data by the whole ecosystem                          | 9 452 lines of YAML to govern; schema changes ripple everywhere                  |
| **Heuristics as ordered regex rules with fallthrough** | Deterministic tiebreaks for shared extensions; contributions are data                | Rule order is load-bearing; regex quality varies; timeout = silent skip          |
| **Classifier last, over candidates only**              | Statistics as tiebreak, not oracle; bounded (50 KB, C tokenizer)                     | Sample-corpus bias; "Bayes" docs vs centroid code drift                          |
| **`.gitattributes` overrides**                         | User intent is ground truth; fixes propagate without library releases                | Per-repo configuration surface; overrides can lie                                |
| **Detection ↔ highlighting via `tm_scope`**            | One detector serves any renderer; grammars swappable                                 | Welds the registry to TextMate's namespace; `none` languages get no highlighting |

---

## Sources

- [`lib/linguist.rb`][linguist-rb] — the `STRATEGIES` array + driver loop; `lib/linguist/strategy/*.rb` + `shebang.rb`, `heuristics.rb` — per-strategy mechanics, intersection narrowing, regex-timeout behavior
- [`lib/linguist/languages.yml`][languages-yml] — field documentation (incl. `tm_scope`), 815 entries; [`lib/linguist/heuristics.yml`][heuristics-yml] — 130 blocks + 21 named patterns (`.h`/`.m` exemplars)
- [`lib/linguist/classifier.rb`][classifier-rb] — TF-ICF centroid/cosine implementation (vs the "bayes" docs), 50 KB window; `lib/linguist/tokenizer.rb` + `ext/linguist/` — the flex C tokenizer; `samples/` — 3 310 training files
- `lib/linguist/generated.rb`, `vendor.yml`, `documentation.yml` — exclusion machinery; [`docs/overrides.md`][overrides] + [`docs/how-linguist-works.md`][how-works] — the cascade description and `.gitattributes` contract; [`README.md`][readme] — positioning
- Related deep-dives: [highlight.js][hljs] (content-first detection by relevance) · [Pygments][pygments] (per-lexer `analyse_text` scoring) · [bat] (the CLI-sized mapping layer) · [tree-sitter-highlight][ts-highlight] (grammar-side detection metadata) · [the synthesis][sh]

<!-- References -->

[repo]: https://github.com/github-linguist/linguist
[readme]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/README.md
[linguist-rb]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/lib/linguist.rb
[languages-yml]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/lib/linguist/languages.yml
[heuristics-yml]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/lib/linguist/heuristics.yml
[classifier-rb]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/lib/linguist/classifier.rb
[how-works]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/docs/how-linguist-works.md
[overrides]: https://github.com/github-linguist/linguist/blob/e9fe3c9f230cd9220afcd057f75702de4d7700c9/docs/overrides.md
[hljs]: ./highlight-js.md
[pygments]: ./pygments.md
[bat]: ./bat.md
[ts-highlight]: ./tree-sitter-highlight.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
