# Code Formatting

How other languages decide where a line breaks, what happens to your comments, and what a
formatter owes you in return for rewriting every line of your source. A survey of **twenty papers**
(1980–2023) and **thirteen production formatters**, read from pinned source trees, feeding a
concrete proposal for a D formatter on `sparkles:dmd-lsp`.

**Last reviewed:** August 15, 2026

The survey answers seven questions, each a dimension analyzed uniformly in every deep-dive (the
fixed spine) and synthesized in the [comparison][comparison]:

1. **What does the formatter read?** Token stream, full-fidelity CST, or a lossy AST — and what
   happens when the input does not parse. → [Concepts §3][concepts-lossless], [comparison §1][cmp1]
2. **How is the layout decided?** Six paradigms, from "reuse the author's newlines" to
   "shortest path over break states". → [`theory/`][theory], [comparison §2][cmp2]
3. **What happens to comments?** The problem with no general solution, and the three answers.
   → [Concepts §2][attachment], [layout preservation][layout-preserving]
4. **Who decides the style?** Zero options to 6,586 lines of them. → [comparison §5][cmp5]
5. **How does it prove it didn't break your code?** → [Verification][verification]
6. **What does it emit — a document or edits?** The axis that decides whether an editor can use it.
   → [comparison §6][cmp6]
7. **What should D build?** → [The D landscape][d-landscape] · [The substrate][baseline] ·
   [The proposal][proposal]

> [!IMPORTANT]
> **The central finding: the literature and the practice solve different halves of the problem.**
> [Hughes 1995 explicitly excludes code formatting][hughes-remark] — "not the harder problem of
> improving the layout of an existing text, such as a program … How should we handle comments?" —
> and the combinator and optimality families inherit the exclusion. Across the seven
> combinator/optimality papers held locally, "comment" appears **zero** times in four of them and
> only in the **acknowledgements** of two more. Meanwhile, in real formatters, comment handling
> costs _two to four times_ what the layout engine costs: prettier's printer is 578 lines and its
> JavaScript comment placement is 1,255; rustfmt's `comment.rs` is 2,149.
>
> The half the papers skip is solved in [one small, under-cited family][layout-preserving] published
> in a different research community — and, in practice, by simply **not throwing the tokens away**.

---

## Master catalog

One row per surveyed system, ordered by layout paradigm. **Paradigm** is the break-decision
mechanism (developed in [`theory/`][theory]); **input** is what the formatter reads;
**output contract** is document vs edits, the axis [the D decision turns on][cmp6].

| System                | Ecosystem         | Paradigm                           | Input                   | Output contract    | Deep-dive                    |
| --------------------- | ----------------- | ---------------------------------- | ----------------------- | ------------------ | ---------------------------- |
| gofmt                 | Go                | author's-breaks + elastic tabstops | AST + comment map       | document           | [gofmt][gofmt]               |
| zig fmt               | Zig               | source-hint (trailing comma)       | AST + token index       | document           | [zig fmt][zig-fmt]           |
| Roslyn                | C#/VB             | local rule chain                   | full-fidelity CST       | **`TextEdit[]`**   | [Roslyn][roslyn]             |
| prettier              | JS/TS/CSS/…       | combinator group/flat              | AST + attached comments | document           | [prettier][prettier]         |
| swift-format          | Swift             | combinator                         | SwiftSyntax CST         | document           | [swift-format][swift-format] |
| ocamlformat           | OCaml             | combinator                         | AST + attached comments | document           | [ocamlformat][ocamlformat]   |
| ruff / Biome / dprint | Python, JS, …     | combinator (ports)                 | AST                     | document           | [the Rust wave][rust-reimpl] |
| black                 | Python            | greedy + magic trailing comma      | AST                     | document           | [long tail][long-tail]       |
| google-java-format    | Java              | combinator (`Op` → `Doc`)          | AST                     | document           | [long tail][long-tail]       |
| rustfmt               | Rust              | heuristic budget (`Shape`)         | AST + source spans      | document           | [rustfmt][rustfmt]           |
| clang-format          | C/C++/…           | cost-minimizing search             | **token stream**        | **`Replacements`** | [clang-format][clang-format] |
| dfmt                  | **D**             | cost search, capped                | **token stream**        | document           | [dfmt][dfmt]                 |
| sdfmt                 | **D**             | cost search, memoized              | own parser → chunks     | document           | [D landscape][d-landscape]   |
| dart_style            | Dart              | n-way constraint solver            | AST → `Piece` tree      | document           | [dart_style][dart-style]     |
| scalafmt              | Scala             | best-first search                  | AST → `Split`s          | document           | [cost & search][cost-search] |
| topiary               | any (tree-sitter) | declarative from foreign CST       | tree-sitter CST         | document           | [topiary][topiary]           |

---

## Foundations (theory)

| Family                  | What it pins down                                   | Canonical results                                                                | Link                                     |
| ----------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------- |
| **Oppen one-pass**      | linear time, bounded space, consistent/inconsistent | Oppen 1980                                                                       | [oppen][oppen]                           |
| **Combinators**         | the `Doc` algebra; what ships in prettier           | Hughes 1995; Wadler 1998; Lindig 2000; Chitil 2005/2006; Swierstra & Chitil 2009 | [combinators][combinators]               |
| **Optimality**          | what "best" means, and its price in `W`             | Bernardy 2017; Yelland 2016; Podkopaev 2015; Porncharoenwase 2023                | [optimality][optimality]                 |
| **Cost & search**       | the industrial approximation, and its budget        | clang-format; Geirsson 2016                                                      | [cost & search][cost-search]             |
| **Layout preservation** | comments, and formatting text that already exists   | van den Brand & Visser 1996; de Jonge & Visser 2011                              | [layout preservation][layout-preserving] |

Plus [readability evidence][readability] — what the empirical literature does and (mostly) does not
support — kept deliberately **outside** `theory/`, because three of its four papers are dominated by
non-whitespace features.

---

## Taxonomies

### By layout paradigm

| Paradigm                     | What decides a break                                 | Theory                                                 | Systems                                                               |
| ---------------------------- | ---------------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------- |
| Author's-breaks-preserved    | the input's own newlines                             | —                                                      | gofmt, Roslyn                                                         |
| Source-hint                  | a one-bit author signal (trailing comma, blank line) | —                                                      | zig fmt, black, prettier (partly), topiary (`@append_input_softline`) |
| Oppen one-pass               | bounded lookahead, `O(width)` space                  | [oppen][oppen]                                         | `rustc_ast_pretty`, OCaml `Format`                                    |
| Combinator group/flat        | `fits` on the flattened group                        | [combinators][combinators]                             | prettier, swift-format, ocamlformat, google-java-format, ruff, Biome  |
| Cost-minimizing search       | shortest path / solver over break sets               | [cost & search][cost-search], [optimality][optimality] | clang-format, dfmt, scalafmt, dart_style, sdfmt                       |
| Declarative from foreign CST | grammar-attached formatting captures                 | [layout preservation][layout-preserving]               | topiary                                                               |

### By input model & fidelity

| Input model               | Round-trip | On unparseable input      | Who owns comments             | Systems                                            |
| ------------------------- | ---------- | ------------------------- | ----------------------------- | -------------------------------------------------- |
| Token stream              | exact      | **formats anyway**        | nobody — order is enough      | clang-format, dfmt                                 |
| Full-fidelity CST         | exact      | **formats around errors** | the token (trivia)            | Roslyn, swift-format, topiary, rust-analyzer       |
| AST + comment table/spans | no         | refuses                   | a heuristic attachment module | prettier, rustfmt, black, ocamlformat, dart_style  |
| AST + source line numbers | no         | refuses                   | a position-indexed map        | gofmt                                              |
| AST-only                  | no         | n/a                       | —                             | **DMD's frontend** — see [the substrate][baseline] |

### By output contract

| Contract                                  | Range formatting   | On-type | Cursor        | Systems              |
| ----------------------------------------- | ------------------ | ------- | ------------- | -------------------- |
| **Edits** (`Replacements` / `TextEdit[]`) | ✅                 | ✅      | ✅            | clang-format, Roslyn |
| Whole document + `--check`                | partial (prettier) | ❌      | prettier only | everyone else        |

**This is the axis [the D decision turns on][cmp6].** Two systems, opposite architectures, same
conclusion.

### By configuration posture

| Posture                      | Systems                                                                 |
| ---------------------------- | ----------------------------------------------------------------------- |
| Zero options                 | gofmt, zig fmt, dart_style, google-java-format                          |
| Tiny by policy               | black, prettier, swift-format                                           |
| Large + presets              | clang-format (6,586 lines of option docs), rustfmt (3,345), ocamlformat |
| Delegated to `.editorconfig` | **dfmt**, Roslyn                                                        |
| The queries _are_ the config | topiary                                                                 |

---

## Milestones

| Year    | Theory                                                                                   | Practice                                            |
| ------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------- |
| 1973    | Goldstein's LISP survey; the "recursive re-predictor"                                    | GRINDEF                                             |
| 1980    | **[Oppen, TOPLAS][oppen]** — O(n) time, O(m) space                                       | Karlton's Mesa printer                              |
| 1981    | Knuth & Plass ([covered in `ui-layout`][knuth-plass])                                    | TeX                                                 |
| 1995    | **[Hughes][combinators]** — and [the scope disclaimer][hughes-remark]                    | Haskell `pretty`                                    |
| 1996    | **[van den Brand & Visser][layout-preserving]** — Box; comments by position              | ASF+SDF                                             |
| 1998    | **[Wadler][combinators]** — one associative concatenation                                |                                                     |
| 2000    | **[Lindig][combinators]** — the strict form **prettier actually ships**                  |                                                     |
| 2005–09 | **[Chitil][combinators]**, **[Swierstra & Chitil][combinators]** — Oppen's bound, purely |                                                     |
| 2009    |                                                                                          | **gofmt**                                           |
| 2011    | **[de Jonge & Visser][layout-preserving]** — text patching, comment patterns             |                                                     |
| 2013\*  |                                                                                          | **clang-format**                                    |
| 2015    | Podkopaev & Boulytchev — arbitrary choice made polynomial                                | **dfmt**                                            |
| 2016    | **[Yelland][optimality]** (`rfmt`), **[Geirsson][cost-search]** (scalafmt thesis)        |                                                     |
| 2017    | **[Bernardy][optimality]** — greed provably insufficient                                 | **prettier 1.0** (2017-04-13)                       |
| 2018    |                                                                                          | **black**                                           |
| 2023    | **[Porncharoenwase et al.][optimality]** — Π_e, Lean-verified                            | Racket `fmt`                                        |
| 2023–24 |                                                                                          | ruff-format, Biome; **dart_style 3.0** tall style\* |

<sub>\* Not datable from this survey's evidence: `llvm-project` and `dart_style` are pinned as
depth-1 clones. See [the theory index's footnote](./theory/index.md#milestones).</sub>

---

## Suggested reading paths

**"I want to understand the field."**
[Oppen][oppen] → [combinators][combinators] → [optimality][optimality] → [comparison][comparison].

**"I am building a formatter."**
[Concepts][concepts] → [layout preservation][layout-preserving] (the half the papers skip) →
[dfmt][dfmt] and [clang-format][clang-format] (token-spine architecture) →
[verification][verification] → [the incompleteness budget][budget].

**"I am designing the D formatter."**
[The substrate][baseline] first — it changes the assumptions — then
[the D landscape][d-landscape], [comparison's delta table][delta], and
[the proposal][proposal].

**"I have five minutes."**
[The Hughes remark][hughes-remark], [the incompleteness budget][budget], and
[comparison §4][cmp4] (what comments actually cost).

---

## Sources

Twenty papers, seventeen archived under `$REPOS/papers/code-formatting/` with `pdftotext`
extractions for locator-precise citation; three are paywalled (Podkopaev & Boulytchev 2015;
Mi et al. 2018 and 2022) and are marked 🌐 wherever used. Source trees pinned by SHA in
this tree's internal `grounding/_sources.md`.

Every page has a claim-by-claim internal grounding ledger recording what was
verified against a local artifact, what is this survey's own synthesis, and what could not be
checked.

<!-- References -->

[theory]: ./theory/index.md
[oppen]: ./theory/oppen.md
[combinators]: ./theory/combinators.md
[hughes-remark]: ./theory/combinators.md#the-remark-that-defines-this-surveys-gap
[optimality]: ./theory/optimality.md
[cost-search]: ./theory/cost-and-search.md
[budget]: ./theory/cost-and-search.md#the-incompleteness-budget
[layout-preserving]: ./theory/layout-preserving.md
[concepts]: ./concepts.md
[concepts-lossless]: ./concepts.md#3-lossless-syntax-trees
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[verification]: ./verification.md
[readability]: ./readability-evidence.md
[comparison]: ./comparison.md
[cmp1]: ./comparison.md#1-input-model--fidelity
[cmp2]: ./comparison.md#2-layout-ir--break-decision
[cmp4]: ./comparison.md#4-comments-trivia--preservation
[cmp5]: ./comparison.md#5-configurability-opinionation--config-discovery
[cmp6]: ./comparison.md#6-integration-surface--output-contract
[delta]: ./comparison.md#where-d-stands--the-delta-table
[d-landscape]: ./d-landscape.md
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md
[prettier]: ./prettier.md
[clang-format]: ./clang-format.md
[rustfmt]: ./rustfmt.md
[gofmt]: ./gofmt.md
[zig-fmt]: ./zig-fmt.md
[dfmt]: ./dfmt.md
[roslyn]: ./roslyn.md
[dart-style]: ./dart-style.md
[topiary]: ./topiary.md
[ocamlformat]: ./ocamlformat.md
[swift-format]: ./swift-format.md
[rust-reimpl]: ./rust-reimplementations.md
[long-tail]: ./long-tail.md
[knuth-plass]: ../ui-layout/tex-knuth-plass.md
