# The D Landscape

What exists for formatting D today, what each thing is built on, and what a successor inherits.
Two real formatters — [`dfmt`][dfmt] and SDC's `sdfmt` — plus DMD's own declaration printer and
two layout engines already inside this repository.

**Last reviewed:** August 15, 2026

| Tool                     | Substrate                             | Paradigm                                          | Size  | Status                                              |
| ------------------------ | ------------------------------------- | ------------------------------------------------- | ----- | --------------------------------------------------- |
| [**dfmt**][dfmt]         | `libdparse` token stream + AST oracle | [capped best-first search][cost-search]           | 4,618 | The incumbent; "beta quality" by its README         |
| **sdfmt** (SDC)          | its own dedicated parser → `Chunk`s   | [search with memoized continuations][cost-search] | 5,534 | Ships with SDC; little used outside it              |
| **`dmd -H` / `hdrgen`**  | DMD AST                               | direct printer, no line breaking                  | —     | A header generator, not a formatter                 |
| **`signature_layout.d`** | `SignatureInfo` from hdrgen           | staged try-flat-then-break                        | 629   | In this repo; hover signatures only                 |
| **`prettyprint.d`**      | runtime D values                      | render-then-measure                               | —     | In this repo; a value printer, not a code formatter |

---

## dfmt — the incumbent

Covered in full in [its deep-dive][dfmt]. The three facts that matter for a successor:

- **Architecture: AST-as-oracle over a token spine.** Lex twice, parse once into ~24 sorted arrays
  of byte offsets, then format the token stream consulting them by binary search. It has **no
  comment attachment problem** and **formats files that do not parse** — both properties fall out
  of the token spine.
- **Citable quality ceilings.** The break search's state is a `uint` bitmask
  (`enum ALGORITHMIC_COMPLEXITY_SUCKS = uint.sizeof * 8;`), so only the first **32 tokens** of a
  line are considered, and the search stops after **1,000** queue pops, returning its best state
  _even when `_solved` is false_.
- **`.editorconfig` is the configuration surface** — 458 lines, ~10% of the tool. Any successor
  wanting dfmt's users must honour the `dfmt_*` keys.

## sdfmt — SDC's formatter

`$REPOS/dlang/sdc/src/format/` (5,534 lines), by Amaury Séchet. Independent of `libdparse` and of
DMD: **it has its own 3,201-line parser** written for formatting, so it does not share SDC's
compiler front end either.

The model is a **`Chunk`** — a single `ulong` bitfield plus a `Span` pointer:

```d
ChunkKind, "_kind", …          // Text, Block, List
Separator, "_separator", …     // None, Space, NewLine, TwoNewLines
bool, "_glued", 1,             // emit without padding/indentation
bool, "_continuation", 1,
bool, "_naturalBreak", 1,      // no penalty if the line starts past the previous one
uint, "_indentation", 10,
bool, "_startsUnwrappedLine", 1,
bool, "_startsBlock", 1,
bool, "_compactList", 1,
uint, "_length", 16,           // "The length of the line in graphemes"
```

— [`src/format/chunk.d`][sdfmt-chunk]

Two details are better than dfmt's:

- **`_startsUnwrappedLine`** — "This marks the boundary between unwrapped lines. Each unwrapped
  line can be formatted completely independently of other unwrapped lines." The same decomposition
  [clang-format][clang-format] uses and [scalafmt reaches for with
  `dequeueOnNewStatements`][cost-search], present in D already.
- **Length is counted in graphemes**, not bytes. dfmt counts bytes; sdfmt is the only D tool with a
  correct width model.

The solver (`writer.d`, `rulevalues.d`) is a genuinely sophisticated search — and a **sixth
independent instance of [the incompleteness budget][budget]**:

```d
// This algorithm is exponential in nature, so make sure to stop
// after some time, even if we haven't found an optimal solution.
attempts++;
```

with `max_attempts`, plus `isDeadSubTree` pruning, a `CheckPoints.isRedundant` dominance check, and
`pausedExpansions` — a `Continuation[RuleValues]` map that **memoizes partial expansions keyed by
the rule assignment**. That last one is [dart_style's `SolutionCache` idea][dart-style], arrived at
independently, in D. `RuleValues` itself is a hand-rolled small-size-optimized bitset.

**Why it is not the D formatter.** It is coupled to SDC, it carries its own parser to maintain, it
is not packaged for standalone use, and it has essentially no adoption outside its own repository.
But it is the strongest _engineering_ in D formatting, and its chunk model and grapheme width are
worth taking.

## DMD's own printer — `hdrgen`

`dmd.hdrgen` is the `-H` header generator: it prints declarations from the AST. As
[`signature_layout.d`'s module documentation][sig-layout] observes, it has **no notion of where a
line may break** — it produces flat text. It is a source of _text_, not layout, and its two
printing frames put attributes on opposite sides, which is why `signature.d` has to re-walk it to
recover structure at all.

It also cannot serve as a formatter for a further reason: it prints declarations, not bodies.

## The two layout engines already in this repository

**[`signature_layout.d`][sig-layout]** (629 lines) is a working, tested, staged line breaker:
`SigStage { flat, clauses, runtimeArgs, templateArgs }`, "try it flat; if that does not fit, break
progressively harder until it does" — a hand-rolled [`group`][combinators] under another name, with
the width function injected as a template parameter so the caller decides codepoints vs graphemes.
It emits **byte ranges, not text** ("Rows are a pure function of (layout, width)").

That is a small, correct, D-native prototype of the engine a formatter needs, already in the tree.
[The proposal][proposal] treats subsuming it as an explicit question rather than leaving the repo
with two layout engines.

**[`prettyprint.d`][prettyprint]** renders runtime values, not code. Its `softMaxWidth = 80` "try
single-line if output fits" is implemented by **rendering the flat form to a string and measuring
it** — the quadratic-retry strawman that [Oppen][oppen] and [Wadler][combinators] exist to avoid.
It is fine for its job and is not a formatter.

---

## What a D successor inherits

| From                     | Take                                                                                                          |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- |
| **dfmt**                 | AST-as-oracle over a token spine; sorted offset arrays; tolerate parse failure; `.editorconfig` compatibility |
| **sdfmt**                | The `Chunk` model; **grapheme** width; `_startsUnwrappedLine` decomposition; memoized continuations           |
| **`signature_layout.d`** | The staged-break engine and the injected width measurer — already written and tested                          |
| **hdrgen**               | Nothing directly; it is a text source, not a layout engine                                                    |

And the ceilings to beat, both citable rather than matters of opinion: dfmt's **32-token search
window** and its **silently unsolved output**.

---

## Sources

- [`dlang-community/dfmt`][dfmt-repo] @ `c65d1c8a` — see [the deep-dive][dfmt]
- [`snazzy-d/sdc`][sdc-repo] @ `611d70adcfcba0afbeae546bc8a5c52d655add69` (tag `0.0.15`, 2026-03-16):
  `src/format/{chunk,span,writer,rulevalues,parser,config}.d`
- `dmd.hdrgen`, via the pinned `dmd:frontend` fork `ea883751…`
- In-repo: [`libs/twoslash/src/sparkles/twoslash/signature_layout.d`][sig-layout],
  [`libs/base/src/sparkles/base/prettyprint.d`][prettyprint], `libs/dmd-lsp/src/sparkles/dmd_lsp/signature.d`

**Related deep-dives in this tree:**
[dfmt][dfmt] · [Cost & search][cost-search] · [dart_style][dart-style] · [clang-format][clang-format] ·
[The substrate baseline][baseline] · [The proposal][proposal]

<!-- References -->

[dfmt-repo]: https://github.com/dlang-community/dfmt/tree/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76
[sdc-repo]: https://github.com/snazzy-d/sdc/tree/611d70adcfcba0afbeae546bc8a5c52d655add69
[sdfmt-chunk]: https://github.com/snazzy-d/sdc/blob/611d70adcfcba0afbeae546bc8a5c52d655add69/src/format/chunk.d
[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d
[prettyprint]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/base/src/sparkles/base/prettyprint.d
[oppen]: ./theory/oppen.md
[combinators]: ./theory/combinators.md
[cost-search]: ./theory/cost-and-search.md
[budget]: ./theory/cost-and-search.md#the-incompleteness-budget
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md
[dfmt]: ./dfmt.md
[dart-style]: ./dart-style.md
[clang-format]: ./clang-format.md
