# Concepts & Vocabulary

The operational glossary this survey runs on. Every term here is used with this meaning in
every deep-dive; where a system uses a different word for the same thing, the mapping is given.
The single most useful artifact on this page is [the layout-IR cross-naming
table](#the-layout-ir-cross-naming-table) — five systems, one set of primitives, five
vocabularies.

**Last reviewed:** August 15, 2026

> [!NOTE]
> This page defines terms. The **algorithms** behind them are in [`theory/`][theory]; the
> **systems** that implement them are the deep-dives listed in [the umbrella][umbrella].
> Where a definition is contested — and several are — the disagreement is stated rather than
> resolved.

---

## 1. What a formatter is, and its three jobs

A **code formatter** takes program text and returns program text with the same meaning and a
different appearance. That is already three distinct jobs, and systems differ on how many they
claim:

1. **Whitespace normalization** — spaces around operators, indentation units, blank-line runs.
   Every formatter does this.
2. **Line breaking** — deciding where to split a construct that does not fit. This is the hard
   one, and the whole of [`theory/`][theory] is about it. A formatter that does _not_ do it is
   called **line-preserving**; one that does is **line-breaking**.
3. **Non-whitespace rewriting** — sorting imports, reordering qualifiers, adding a trailing
   comma, normalizing numeric-literal case. This one is **contested**: it changes tokens, not
   just the space between them.

The third job is not a fringe case. clang-format ships seven passes that do it —
`SortJavaScriptImports`, `UsingDeclarationsSorter`, `QualifierAlignmentFixer`,
`NamespaceEndCommentsFixer`, `IntegerLiteralSeparatorFixer`, `NumericLiteralCaseFixer`,
`DefinitionBlockSeparator` — and rustfmt's `reorder_imports` is on by default. Whether a D
formatter does any of this is a policy question the [proposal][proposal] must answer, not an
implementation detail.

**Pretty-printing vs code formatting.** The literature uses these interchangeably; this survey
does not. Following [Hughes][hughes-remark] and [Yelland's footnote][yelland-fn]:

- **Pretty-printing** renders a data structure the program built. There is no prior text, so
  there are no comments and nothing to preserve.
- **Code formatting** re-renders text a human wrote. There _is_ prior text, it contains
  comments, and preserving the right parts of it is most of the work.

Nearly all of [`theory/`][theory] is about the first. [`libs/base/prettyprint.d`][prettyprint]
in this repository is a pretty-printer in the strict sense; a D formatter would not be.

---

## 2. Trivia and the attachment problem

**Trivia** (Roslyn's term; also _layout_, _documentary structure_, _extra-syntactic material_)
is everything in the source text that the grammar discards: whitespace, newlines, comments,
and — depending on the language — preprocessor directives.

De Jonge & Visser give the precise framing this survey adopts: source text has a **linguistic
structure** (the syntax tree) and a **documentary structure** (the trivia), and the two are
_orthogonal_ — "projecting documentary structure onto linguistic structure loses crucial
information" ([de Jonge & Visser 2011][dejonge], §1).

**The attachment problem** is the consequence: given a comment, which tree node does it belong
to? There is no general answer. The canonical statement, from 1996:

> "there is no unique and completely satisfactory method to determine to which node the comment
> should be attached. For instance, in `while x >= 0 (* as long as x positive *) do … od`,
> should the comment be attached to the syntax tree for the `0`, the condition, or the
> `while`-construct?" — [van den Brand & Visser 1996][box], §5

The three standard answers, each named after where it puts the decision:

| Answer                  | Mechanism                                                                    | Used by                                    |
| ----------------------- | ---------------------------------------------------------------------------- | ------------------------------------------ |
| **Own the trivia**      | Every token carries leading and trailing trivia; the tree _is_ the text      | Roslyn, SwiftSyntax, rust-analyzer/`rowan` |
| **Attach by heuristic** | Rules classify each comment as leading / trailing / own-line and pick a node | prettier, rustfmt, black                   |
| **Never attach**        | Place by original position, or don't reprint the region at all               | Box, de Jonge & Visser's text patching     |

Positions in the second scheme have standard names, used throughout this survey:

- **Leading / own-line** — the comment is alone on its line above a node.
- **Trailing / end-of-line** — the comment follows a node on the same line.
- **Remaining / dangling** — attached to neither, typically inside an empty construct
  (`{ /* nothing */ }`), and the case most likely to be lost.

**A comment that cannot be attached** is a real category, not an edge case. De Jonge & Visser
call it out explicitly: a commented-out statement "does not have a structural referent. It can
best be seen as lying between the surrounding code elements" (§5). Their [five binding
patterns][patterns] deliberately match nothing in that case, and the comment stays where it was.

**Elastic trivia** is Roslyn's distinctive refinement and worth stealing as vocabulary:

> "Elastic whitespace lets generated trees suggest whitespace elements and ensure tokens are not
> immediately adjacent to each other. Formatters and other tree processing tools can freely
> substitute, lengthen, or change the elastic whitespace in any way without breaking fidelity
> with an original code source." — [Roslyn FAQ][roslyn-faq]

So a Roslyn tree distinguishes whitespace that _is_ in the source (preserve it byte-for-byte)
from whitespace that is merely _suggested_ (rewrite freely). That distinction is exactly what a
formatter needs and almost nothing else has.

---

## 3. Lossless syntax trees

A **lossless** (or **full-fidelity**, or **concrete**) syntax tree is one from which the exact
original text can be reconstructed. rust-analyzer states the property as a design goal:

> "full-fidelity representation (\*any\* text can be precisely represented as a syntax tree)"
> — [`crates/syntax/src/lib.rs`][ra-syntax]

The three shapes a formatter can be built on, in decreasing order of what survives:

| Shape                        | Contains                                              | Round-trip | Examples                                        |
| ---------------------------- | ----------------------------------------------------- | ---------- | ----------------------------------------------- |
| **Token stream**             | every token including comments and whitespace         | ✅ exact   | dfmt (via `libdparse`), clang-format            |
| **CST / full-fidelity tree** | tokens + trivia + structure                           | ✅ exact   | Roslyn, SwiftSyntax, rust-analyzer, tree-sitter |
| **AST**                      | structure only; trivia discarded, literals normalized | ❌         | DMD's frontend, most compilers                  |

**Red-green trees** is the name for the Roslyn/rust-analyzer implementation of the CST: an
immutable, position-independent "green" node shared across the tree, wrapped by a "red" node
carrying absolute position and parent. It is how those systems make a full-fidelity tree cheap
enough to hold for a whole solution.

**Where D sits.** `sparkles:dmd-lsp` exposes `dmd.frontend`'s **AST**, which is lossy in exactly
the ways this section describes: it discards comments (except ddoc, which `dmd-lsp` deliberately
keeps alive by overriding `doDocComment`) and normalizes literals. **In the vocabulary above, DMD
gives you an AST, not a CST.**

But the AST is not the whole substrate. DMD's own **lexer** can emit comments (`TOK.comment`) and
whitespace (`TOK.whitespace`) as tokens, every `Token` carries a pointer into the source buffer,
and `Loc` exposes `fileOffset()` — so the _token stream_ row of the table above is available in D
today, without a new dependency. That finding, and what it means for the design, is
[the substrate baseline][baseline]; the choice it enables is [the proposal][proposal]'s.

---

## 4. The layout-IR cross-naming table

Every line-breaking formatter has an intermediate representation with the same handful of
primitives. They are named differently everywhere, which makes the literature harder to read
than it is. This table is the decoder ring.

| Concept                           | [Oppen 1980][oppen]       | [Wadler][combinators] / prettier | [Box 1996][box-ops] | clang-format                 | Roslyn                        |
| --------------------------------- | ------------------------- | -------------------------------- | ------------------- | ---------------------------- | ----------------------------- |
| Literal text                      | `String`                  | `text` / a JS string             | `"string"`          | `FormatToken`                | `SyntaxToken`                 |
| Concatenation                     | (stream order)            | `<>` / a JS array                | `H`                 | (token order)                | (tree order)                  |
| Always-break                      | —                         | `hardline`, `breakParent`        | `V`                 | `MustBreakBefore`            | a mandatory newline rule      |
| Optional break, space when flat   | `Blank(1)`                | `line`                           | (in `HV`/`HOV`)     | a break with a penalty       | an optional newline operation |
| Optional break, nothing when flat | `Blank(0)`                | `softline`                       | (in `HV`/`HOV`)     | ″                            | ″                             |
| **Break all of these, or none**   | `consistent`              | **`group`**                      | **`HOV`**           | (emerges from the search)    | (emerges from the rule chain) |
| **Break only where needed**       | `inconsistent`            | **`fill`**                       | **`HV`**            | ″                            | ″                             |
| Relative indent                   | `begin` offset            | `indent`                         | `I`                 | `ContinuationIndenter` state | indent operations             |
| Align to current column           | — (added by implementors) | `align`                          | `WD` (width-only)   | `AlignConsecutive*`          | alignment operations          |
| Choose among N candidates         | —                         | `conditionalGroup`               | —                   | (the search _is_ this)       | —                             |
| Text emitted only if broken       | —                         | `ifBreak`                        | —                   | (a penalty)                  | —                             |
| Deferred text (trailing comments) | (the length hack)         | `lineSuffix`                     | —                   | `BreakableToken`             | trailing trivia               |

Three things this table makes visible:

**The consistent/inconsistent flag was invented three times.** Oppen 1980, Box 1996 and
prettier all arrived at a two-valued distinction on a group, independently. prettier's own docs
define `fill` as "an alternative type of group which behaves like text layout: it's going to add
a break whenever the next element doesn't fit in the line anymore. The difference with `group`
is that it's not going to break all the separators, just the ones that are at the end of lines"
([`commands.md`][prettier-commands]) — which is [Oppen §4's definition][oppen-cons] in different
words. Three independent inventions is strong evidence that the distinction is a feature of the
problem, not of a design.

**Alignment is the primitive everyone had to add.** Oppen's `begin` offset is relative
indentation only; Wadler dropped Hughes' aligned concatenation for a cleaner algebra
([combinators][combinators]); prettier added `align`; clang-format has a whole
`WhitespaceManager` for it; gofmt delegates it to `text/tabwriter`. It is a separate engine in
every mature system, which is why [this survey makes it its own spine dimension][spine].

**N-way choice is where the complexity lives.** `group` is binary by construction. The moment a
system needs three candidate layouts it leaves the algebra — and prettier's docs say so
outright: `conditionalGroup` "should be used as **last resort** as it triggers an exponential
complexity when nested" ([`commands.md`][prettier-commands]). Systems that want N-way choice as
a first-class operation end up in [optimality][optimality] or [cost & search][cost-search].

---

## 5. Line-breaking vocabulary

- **Column limit / page width / print width** — the target maximum line length. `W` in the
  complexity results.
- **Soft vs hard limit.** A **hard** limit is a feasibility constraint (a layout exceeding it is
  invalid); a **soft** limit is a cost (exceeding it is penalized). dfmt has both:
  `dfmt_soft_max_line_length` adds cost, `max_line_length` sets `_solved = false`. Yelland argues
  for putting the width in the objective precisely so a soft margin becomes expressible
  ([optimality][optimality]).
- **Flat mode / break mode** — Lindig's two-valued `mode`, shipped in prettier as `MODE_FLAT` /
  `MODE_BREAK`. A group is measured in flat mode and printed in whichever mode the measurement
  chose.
- **`fits`** — the predicate that decides. Its defining property is that it stops at the first
  newline, which bounds it by the line width and is what makes greedy printing linear.
- **Continuation indent** — the extra indentation applied to the wrapped remainder of a
  construct, distinct from block indent.
- **Break penalty / split penalty** — the cost of choosing to break at a given point, in
  [cost-based systems][cost-search]. clang-format exposes ~10 as style options.
- **Magic trailing comma** — black's name for using a user-written trailing comma as an explicit
  signal to always explode a collection: "you can communicate that you don't want that by
  putting a trailing comma in the collection yourself. When you do, _Black_ will know to always
  explode your collection into one item per line" ([black docs][black-style]). A deliberate
  low-bandwidth channel from author to formatter, and one of the few places an otherwise
  "does not take existing formatting into account" formatter reads the input's layout.
- **Author's-breaks-preserved** — this survey's name for the paradigm where the input's own
  newlines are a layout _input_: gofmt's `linebreak(line, min, ws, newSection)` takes source line
  numbers; prettier keeps an object multi-line if the source had a newline after `{`; Roslyn
  preserves by default.

---

## 6. Width, columns, and measurement

"Does it fit in 80 columns" hides a decision. **What is a column?**

| Model                 | Counts                           | Wrong for                                     |
| --------------------- | -------------------------------- | --------------------------------------------- |
| Bytes                 | UTF-8 code units                 | any non-ASCII text                            |
| Code points           | Unicode scalars                  | combining marks, emoji sequences              |
| **Grapheme clusters** | user-perceived characters        | East-Asian wide characters (counts them as 1) |
| **Display columns**   | terminal cells (`wcwidth`-style) | proportional fonts                            |

Real systems differ: gofmt's `tabwriter` counts runes; clang-format has
`Encoding.h::columnWidthWithTabs`; prettier uses a `getStringWidth` that accounts for wide
characters. **Tab expansion** is a further wrinkle — a tab's width depends on the current column.

This repository already treats measurement as a parameter rather than a constant:
[`signature_layout.d`][sig-layout]'s width function is injected as a template parameter, on the
stated grounds that "the layout engine counts codepoints, a grapheme-correct caller counts
clusters, and this module must not decide which is right". Any D formatter should keep that
seam.

---

## 7. Idempotence, stability, convergence

- **Idempotent**: `format(format(x)) == format(x)`. The minimum bar. It is _not_ automatic —
  greedy decisions interact with the alignment and comment passes, and a formatter can oscillate.
- **Stable**: small input change ⇒ small output change. Not implied by idempotence, and the
  property that determines [diff churn][diff-review].
- **Convergent**: repeated formatting reaches a fixed point in bounded iterations.

ocamlformat treats non-convergence as a **reportable defect**, not a theoretical concern. Its
error type includes `Unstable {iteration; prev; next; input_name}`, it re-runs formatting up to
`max-iters`, and it emits either `"%s was not already formatted. ([max-iters = 1])"` or
`"Cannot process %S. Please report this bug"` ([`lib/Translation_unit.ml`][ocamlformat-tu]).
That is the strongest idempotence discipline in this survey and the model
[`verification.md`][verification] builds on.

---

## 8. Semantic preservation

The property a formatter must never violate: **the formatted program means what the original
meant**. Three checkable approximations, in increasing strength and cost:

1. **Token equality modulo whitespace** — lex both, compare the non-trivia token streams.
   Cheap, catches nearly everything, requires a lexer.
2. **AST equality on reparse** — `PARSE(FORMAT(s)) = PARSE(s)`. This is exactly
   [de Jonge & Visser's Correctness criterion][preservation] specialized to the identity
   transformation, and it is what ocamlformat and black enforce.
3. **Behavioural equivalence** — undecidable; nobody attempts it.

prettier states the obligation as its first requirement: "The first requirement of Prettier is
to output valid code that has the exact same behavior as before formatting"
([`docs/rationale.md`][prettier-rationale]).

**Where formatting can change meaning** — the cases a D formatter must treat as verbatim:
significant whitespace inside string literals and token strings, line-oriented constructs
(`#line`), anything inside `asm` blocks, and — subtly — a comment that a tool downstream parses
(ddoc, `// dfmt off`, lint directives). ocamlformat's `--no-comment-check` exists because
OCaml's `(** … *)` docstrings are semantically attached and a formatter can attach them
_differently from the compiler_; it refuses rather than guess.

---

## 9. Verbatim regions and escape hatches

Every formatter needs a way to become the identity function over a region. The directives are
near-universal in form and worth tabulating, because a D formatter will need one and should not
invent a new spelling:

| System       | Directive                                                                                       | Granularity                            |
| ------------ | ----------------------------------------------------------------------------------------------- | -------------------------------------- |
| clang-format | `// clang-format off` … `// clang-format on` (also `/* … */` form)                              | line range                             |
| dfmt         | `// dfmt off` … `// dfmt on`                                                                    | line range                             |
| SDC `sdfmt`  | `// sdfmt off`                                                                                  | line range                             |
| black        | `# fmt: off` / `# fmt:off` / `# yapf: disable`                                                  | line range                             |
| prettier     | `// prettier-ignore` — "will exclude the next node in the abstract syntax tree from formatting" | **one AST node**                       |
| rustfmt      | `#[rustfmt::skip]`                                                                              | one item (an attribute, not a comment) |

Note the axis: most are **line ranges** driven by comment scanning; prettier's and rustfmt's are
**node-scoped**. Node scoping is cleaner but requires the directive to survive to the point
where nodes are known — which for D means it must survive whatever trivia mechanism the
formatter uses.

**Verbatim regions that no directive marks** are the harder half: `asm` blocks, `q{}` token
strings, `q"EOS…EOS"` delimited strings, nested `/+ +/` comments, and string-literal `mixin`
bodies. The formatter must recognize these from the grammar and decline to touch them.

---

## 10. Embedded and foreign languages

A formatter's input frequently contains _another language_. prettier has an
`embeddedLanguageFormatting` option and a `multiparser.js`; clang-format has `RawStringFormats`
for formatting C++ raw string literals containing other languages.

For D this is on the critical path rather than a nicety: **DDoc** comments have their own
internal layout language (`Params:` sections, macros); `mixin` string literals contain D;
`q{}` token strings contain D tokens. Whether a D formatter reformats inside them is a policy
decision the [proposal][proposal] takes explicitly (v1: DDoc preserved verbatim, no reflow).

---

## 11. Opinionation and configuration

- **Opinionated** — few or no options, one output for one input. gofmt, `dart_style`, `zig fmt`
  have zero; black has a handful.
- **Style presets** — a named bundle of options (clang-format's `BasedOnStyle: LLVM | Google |
Chromium | Mozilla | WebKit | Microsoft`).
- **Configuration discovery** — how the tool finds its settings: a dotfile walked up from the
  target, `.editorconfig`, or a field in the project manifest. This is not a footnote: dfmt's
  `editorconfig.d` + `globmatch_editorconfig.d` are 458 lines, about 10% of the tool.
- **Language-version-aware formatting** — `dart_style` picks its style from the code's declared
  language version: "If the language version is 3.6 or lower, the code is formatted with the old
  style. If 3.7 or later, you get the new tall style" ([CHANGELOG][dart-changelog]). A migration
  mechanism worth knowing about.

The **"no options" argument** — that a formatter's value is ending style debate, and every
option reopens one — is prettier's and gofmt's position. The counter-argument is that a
formatter nobody adopts formats nothing; dfmt's `.editorconfig` support exists for that reason.
[The comparison][comparison] treats this as an axis rather than a settled question.

---

## 12. Diff behaviour

A formatter's output is read as diffs far more often than as files, which makes the following
first-class concerns rather than aesthetics:

- **Churn** — output changing more than the input did. Caused by non-local layout decisions
  ([search][cost-search] and [optimal][optimality] engines are structurally prone to it; greedy
  engines much less).
- **One-item-per-line** — layouts chosen so a one-element change is a one-line diff. This is a
  large part of why the magic trailing comma exists.
- **Blame damage** — a reformat-the-world commit rewrites authorship for every line; the
  standard mitigation is `.git-blame-ignore-revs`.
- **Version pinning** — a formatter version bump that changes output is a repo-wide diff, so CI
  must pin the exact version.

The consumer's-eye view of this — how a diff tool copes with formatting noise — is a separate
survey in this repository: [`docs/research/diff-review/`][diff-review].

---

## 13. Error recovery and partial formatting

- **Behaviour on unparseable input** is a real axis, not an edge case: for an LSP formatting on
  save or on keystroke, the buffer is _often_ mid-edit. gofmt refuses; clang-format formats
  anyway (it works on a token stream and never needs a valid parse); Roslyn formats around error
  nodes.
- **Range formatting** — format only a selection. Requires an engine that can start mid-document
  at an inherited indentation. clang-format's `AffectedRangeManager` exists for this; retrofitting
  it is expensive, which is why [the proposal][proposal] decides it in M0 rather than M6-in-spirit.
- **Format-on-type** — reformat after a single keystroke, typically a `;` or `}`.
- **Cursor preservation** — mapping the caret's offset through the reformat. `clang-format
--cursor` returns the new position; Roslyn tracks it. Ignored by most batch formatters and
  user-visible in an editor.
- **Output contract** — whether the tool returns **a whole document** or a set of **`TextEdit`s**
  / `tooling::Replacements`. This determines whether range formatting, on-type formatting and
  minimal diffs are possible at all, and it is [the axis the D decision turns on][spine].

---

## The landscape at a glance

Every surveyed system on the five vocabulary axes defined above. Rows link to their deep-dives.

| System                       | Input model             | Break paradigm                  | Width policy      | Config surface            | Output contract    |
| ---------------------------- | ----------------------- | ------------------------------- | ----------------- | ------------------------- | ------------------ |
| [prettier][prettier]         | AST + attached comments | combinator group/flat (greedy)  | hard `printWidth` | tiny, opinionated         | document           |
| [clang-format][clang-format] | token stream            | cost-minimizing search          | penalty + limit   | very large + presets      | **`Replacements`** |
| [rustfmt][rustfmt]           | AST + comment spans     | heuristic budget (`Shape`)      | hard `max_width`  | large (`rustfmt.toml`)    | document           |
| [gofmt][gofmt]               | AST + comment map       | **author's breaks** + tabwriter | **none**          | **zero options**          | document           |
| [zig fmt][zig-fmt]           | full AST                | source-hint (trailing comma)    | soft              | **zero options**          | document           |
| [dfmt][dfmt]                 | token stream            | capped best-first search        | soft + hard       | `.editorconfig`           | document           |
| [Roslyn][roslyn]             | full-fidelity CST       | local rule chain                | (mostly none)     | large                     | **`TextEdit[]`**   |
| [dart_style][dart-style]     | AST                     | explicit constraint solver      | hard              | **zero options**          | document           |
| [topiary][topiary]           | tree-sitter CST         | declarative from foreign CST    | soft              | queries + `languages.ncl` | document           |
| [ocamlformat][ocamlformat]   | AST + comment attach    | combinator                      | hard              | large + profiles          | document           |
| [swift-format][swift-format] | SwiftSyntax CST         | combinator                      | hard              | small JSON                | document           |
| [black][black]               | AST                     | greedy + magic trailing comma   | hard              | **tiny by policy**        | document           |
| [SDC `sdfmt`][d-landscape]   | own AST → chunks        | solver over rule values         | hard              | minimal                   | document           |

<sub>Rows are filled from each deep-dive; cells for pages not yet written are provisional and
are flagged in this tree's internal grounding ledgers.</sub>

---

## Sources

Primary sources for each definition are cited inline and re-cited in the deep-dive that owns the
concept. The papers are archived under `$REPOS/papers/code-formatting/`; the source trees are
pinned by SHA in this tree's internal `grounding/_sources.md`.

**Related deep-dives in this tree:**
[Theory][theory] · [Oppen][oppen] · [Combinators][combinators] · [Optimality][optimality] ·
[Cost & search][cost-search] · [Layout preservation][layout-preserving] ·
[Verification][verification] · [Comparison][comparison] · [The D landscape][d-landscape] ·
[The substrate baseline][baseline]

<!-- References -->

<!-- Papers & external -->

[box]: https://eelcovisser.org/publications/1996/BrandV96.pdf
[dejonge]: https://eelcovisser.org/publications/2011/JongeV11.pdf

<!-- Source trees -->

[prettier-commands]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/commands.md
[prettier-rationale]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/rationale.md
[black-style]: https://github.com/psf/black/blob/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3/docs/the_black_code_style/current_style.md
[ocamlformat-tu]: https://github.com/ocaml-ppx/ocamlformat/blob/20c4543119c82a51c2f3a9bf81620a7f31fe0e50/lib/Translation_unit.ml
[ra-syntax]: https://github.com/rust-lang/rust-analyzer/blob/3033d4fac8aab3f1725aa9c9d6293436aeceb0a5/crates/syntax/src/lib.rs
[roslyn-faq]: https://github.com/dotnet/roslyn/blob/e42c3902b0c0f922771e06b5222dadee92fb0e2e/docs/wiki/FAQ.md
[dart-changelog]: https://github.com/dart-lang/dart_style/blob/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79/CHANGELOG.md
[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d
[prettyprint]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/base/src/sparkles/base/prettyprint.d

<!-- Theory docs -->

[theory]: ./theory/index.md
[oppen]: ./theory/oppen.md
[oppen-cons]: ./theory/oppen.md#consistent-vs-inconsistent-breaking
[combinators]: ./theory/combinators.md
[hughes-remark]: ./theory/combinators.md#the-remark-that-defines-this-surveys-gap
[optimality]: ./theory/optimality.md
[yelland-fn]: ./theory/optimality.md#power--limits
[cost-search]: ./theory/cost-and-search.md
[layout-preserving]: ./theory/layout-preserving.md
[box-ops]: ./theory/layout-preserving.md#box-a-layout-algebra-generated-from-a-grammar
[patterns]: ./theory/layout-preserving.md#the-comment-heuristics-in-full
[preservation]: ./theory/layout-preserving.md#preservation-as-a-pair-of-equations

<!-- Tree-level docs -->

[umbrella]: ./index.md
[spine]: ./index.md#taxonomies
[comparison]: ./comparison.md
[verification]: ./verification.md
[d-landscape]: ./d-landscape.md
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md

<!-- System deep-dives -->

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
[black]: ./long-tail.md#black

<!-- Other research trees -->

[diff-review]: ../diff-review/index.md
