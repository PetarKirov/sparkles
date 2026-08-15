# clang-format (C/C++/Java/JS/JSON/Obj-C/C#/Protobuf/…)

The most capable and least documented formatter in the survey. Its line breaker is a **Dijkstra
shortest-path search over partial layout states** with a rich penalty model; its input is a
**token stream**, so it formats files that do not parse; and it is the only system here that
emits **edits rather than a document**, which is why it — alone — has real range formatting,
`--cursor`, and `git clang-format`. It is also the only one whose in-tree design document is a
stub reading `FIXME: Write up design.`

|                     |                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------- |
| **Languages**       | C, C++, Objective-C, Java, JavaScript/TypeScript, JSON, C#, Protobuf, TableGen, Verilog |
| **License**         | Apache-2.0 with LLVM Exceptions                                                         |
| **Repository**      | [`llvm/llvm-project`][repo] @ `73802c2e` (2026-06-04)                                   |
| **Implementation**  | `clang/lib/Format/` — **36,925 lines**                                                  |
| **Public API**      | `clang/include/clang/Format/Format.h` (6,586 lines, mostly option docs)                 |
| **Category**        | token stream · cost-minimizing search · `Replacements` output                           |
| **Layout paradigm** | [cost-minimizing search][cost-search]                                                   |

---

## Overview

### What it solves

Formatting C++ — a language whose grammar is context-dependent, whose macros can span
declarations, and whose files routinely fail to parse in isolation. clang-format's answers to all
three are the same: **don't parse; annotate tokens**.

`clang/docs/LibFormat.rst` is the design document, and its Design section is:

> "FIXME: Write up design." — [`clang/docs/LibFormat.rst`][libformat]

so the design must be read out of the source. The user-facing description is:

> "`ClangFormat` describes a set of tools that are built on top of LibFormat … clang-format is
> located in `clang/tools/clang-format` and can be used to format C/C++/Java/JavaScript/JSON/
> Objective-C/Protobuf/C# code." — [`clang/docs/ClangFormat.rst`][clangformat-rst]

### Design philosophy, reconstructed

Four passes, each a `TokenAnalyzer`:

1. **`FormatTokenLexer`** (1,620) — lex to `FormatToken`s, merging language-specific multi-token
   constructs.
2. **`UnwrappedLineParser`** (5,179) — group tokens into _unwrapped lines_: logical lines as they
   would be if width were unlimited.
3. **`TokenAnnotator`** (6,796) — assign each token a role, a `splitPenalty`, and
   `mustBreakBefore`/`canBreakBefore` flags. **This is the biggest file and the real intelligence.**
4. **`UnwrappedLineFormatter`** (1,797) + **`ContinuationIndenter`** (3,151) — search for the
   cheapest set of breaks; the indenter models the state at each token.

Then `WhitespaceManager` (1,754) turns the decisions into concrete whitespace replacements,
including all column alignment.

**The proportions are the finding.** The search everyone talks about is 1,797 lines; the
annotation that makes the search meaningful is 6,796. Choosing "we'll use Dijkstra" is choosing
the small part.

---

## How it works

### The search

```cpp
/// Analyze the entire solution space starting from \p InitialState.
///
/// This implements a variant of Dijkstra's algorithm on the graph that spans
/// the solution space (\c LineStates are the nodes). The algorithm tries to
/// find the shortest path (the one with lowest penalty) from \p InitialState
/// to a state where all tokens are placed. Returns the penalty.
```

— [`UnwrappedLineFormatter.cpp`][clang-uf]

The frontier is a `std::priority_queue` keyed on an `OrderedPenalty` — a `(penalty, count)` pair
whose tie-break encodes a style decision:

> "In case of equal penalties, we want to prefer states that were inserted first. During state
> generation we make sure that we insert states first that break the line as late as possible."

Successors are binary (break / don't break) and the path is recovered by `reconstructPath`.

**The budget.** Two caps, analysed in full under [cost & search][cost-search]:
at `Count > 50'000` the comparator degrades (`IgnoreStackForComparison = true`, merging states
that differ only in their indent stack — the search silently becomes approximate); at
`Count > 25'000'000` it returns 0. If the queue empties without a solution,
`// FIXME: Add diagnostic?`.

### Penalties as a public API

Twelve `Penalty*` options are exposed in `Format.h`: `PenaltyBreakAssignment`,
`PenaltyBreakBeforeFirstCallParameter`, `PenaltyBreakBeforeMemberAccess`, `PenaltyBreakComment`,
`PenaltyBreakFirstLessLess`, `PenaltyBreakOpenParenthesis`, `PenaltyBreakScopeResolution`,
`PenaltyBreakString`, `PenaltyBreakTemplateDeclaration`, `PenaltyExcessCharacter`,
`PenaltyIndentedWhitespace`, `PenaltyReturnTypeOnItsOwnLine`.

`PenaltyExcessCharacter` is the [soft-margin][concepts-break] knob: overflow is priced rather
than forbidden, which is what lets clang-format produce _something_ for a line that cannot fit.

### The other half: seven non-whitespace passes

clang-format does [job three][three-jobs] — it changes tokens, not just spaces:
`SortJavaScriptImports` (598), `QualifierAlignmentFixer` (651), `NamespaceEndCommentsFixer`
(381), `DefinitionBlockSeparator` (271), `UsingDeclarationsSorter` (246),
`IntegerLiteralSeparatorFixer` (242), `NumericLiteralCaseFixer` (177), plus `sortCppIncludes` in
`Format.cpp`. Together these are ~2,600 lines — more than the line breaker.

### Macros

`MacroExpander` (242) and `MacroCallReconstructor` (590) let clang-format format code where a
macro spans a construct: expand, format, then reconstruct the call. Nothing else in this survey
attempts this, and it exists because C++ requires it.

---

## 1. Input model & fidelity

**Token stream, annotated.** No AST, no parse. `UnwrappedLineParser` recovers as much structure
as it can from tokens alone.

**Round-trip:** not guaranteed or checked. There is no equivalence verifier; correctness rests on
an extremely large regression suite.

**Behaviour on unparseable input: formats anyway** — the lenient end of the axis, and the
architectural reason `git clang-format` can format a diff hunk in a file with conflict markers
elsewhere.

## 2. Layout IR & break decision

**Paradigm: [cost-minimizing search][cost-search].** No `Doc`; the "IR" is the annotated token
sequence plus `ContinuationIndenter`'s `LineState`. Width policy: `ColumnLimit` as a
constraint plus `PenaltyExcessCharacter` as a cost — both, unusually.

## 3. Alignment, indentation & vertical rhythm

The strongest of any system here. `WhitespaceManager` implements `AlignConsecutiveAssignments`,
`AlignConsecutiveDeclarations`, `AlignConsecutiveBitFields`, `AlignConsecutiveMacros`,
`AlignTrailingComments`, `AlignEscapedNewlines`, `AlignAfterOpenBracket`, `AlignOperands` —
alignment as a distinct engine with its own option family, exactly as
[the spine predicts][spine]. Width is measured by `Encoding.h::columnWidthWithTabs`, a real
display-width model.

## 4. Comments, trivia & preservation

`BreakableToken` (1,162) **reflows comment interiors and splits string literals** — the only
system in wave 1 that rewraps prose inside a comment. `ReflowComments`,
`PenaltyBreakComment`, and `AlignTrailingComments` are the user-facing surface.

Attachment is not a problem: comments are tokens. Escape hatch is a **line range**:

> "The code between a comment `// clang-format off` or `/* clang-format off */` up to a comment
> `// clang-format on` or `/* clang-format on */` will not be formatted."
> — [`ClangFormatStyleOptions.rst`][style-options]

## 5. Configurability, opinionation & config discovery

**The largest option surface in the survey** — `Format.h` is 6,586 lines and is the authoritative
option documentation; `ClangFormatStyleOptions.rst` (8,004 lines) is generated from it by
`docs/tools/dump_format_style.py`.

Eight presets: `getLLVMStyle`, `getGoogleStyle`, `getChromiumStyle`, `getMozillaStyle`,
`getWebKitStyle`, `getGNUStyle`, `getMicrosoftStyle`, `getClangFormatStyle`, selected with
`BasedOnStyle`. Discovery walks up for `.clang-format`.

**The cost of this surface** is that options interact _through a search_: changing one penalty
has non-local effects that cannot be reasoned about, only measured.

## 6. Integration surface & output contract

**The best in the survey, and the reason to study it.**

- **Output is `tooling::Replacements`** — a set of edits, not a document.
- **Affected ranges**: `AffectedRangeManager` (156 lines) restricts work to lines touched by a
  requested range, which is how `-lines=`/`-offset=`/`-length=` and `git clang-format` work.
- **`--cursor`** returns the caret's new offset after reformatting.
- **`--dry-run`/`-n`** with `--Werror` for CI.
- Editor integrations shipped in-tree: `clang-format.py`, `clang-format.el`,
  `clang-format-diff.py`, `git-clang-format`, plus BBEdit and Sublime.

`AffectedRangeManager` being only 156 lines is misleading — it is small _because_ the output
contract is edits and the input is a token stream. Retrofitting the same capability onto a
document-output, tree-reprinting formatter is what makes range formatting expensive elsewhere.

---

## Strengths

- **Formats broken code** — the decisive property for editor integration.
- **Edits, not documents**, giving real range/on-type/cursor support essentially for free.
- **Very high layout quality** on hard constructs, from a genuine cost model.
- **The most complete alignment engine** anywhere.
- **Comment reflow and string splitting**, which nothing else in wave 1 does.
- **Handles macros** spanning constructs.
- **Multi-language** from one token-based core.

## Weaknesses

- **No design documentation** — `FIXME: Write up design.` after a decade.
- **Silently incomplete** — two hard-coded caps, no diagnostic when either bites.
- **Option interactions are unpredictable** because they resolve through a search.
- **36,925 lines** — not comprehensible as a whole; even the "core" is ~7,000.
- **No semantic-equivalence verification.**
- **Style decisions hidden in tie-breaks** (e.g. "break as late as possible") that no option
  reaches.

---

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                  | Trade-off                                                                                   |
| ----------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Annotate tokens, never parse**                            | C++ often will not parse in isolation; editors need broken files formatted | All structure must be re-derived heuristically — hence a 6,796-line annotator               |
| Layout as **Dijkstra over `LineState`s**                    | Directly expresses "cheapest set of breaks"                                | Exponential state space; needs two hard-coded caps                                          |
| **Twelve penalties as public options**                      | Style becomes data, tunable per project                                    | Non-local, empirically-tuned semantics; no way to predict a change without running a corpus |
| Both a **`ColumnLimit`** and a **`PenaltyExcessCharacter`** | Unfittable lines still get a best-effort layout                            | Two mechanisms for one concept; users conflate them                                         |
| Output **`Replacements`**, not a document                   | Enables range formatting, cursor tracking, `git clang-format`              | Every consumer must apply edits; the API is heavier than "string in, string out"            |
| **`AffectedRangeManager`** from the start                   | Range formatting designed in rather than retrofitted                       | Every pass must respect affected ranges — a cross-cutting constraint                        |
| Ship **seven token-changing fixers**                        | Include order, qualifier order, namespace comments are real style rules    | The tool changes tokens, so "formatting" is no longer whitespace-only — a policy surprise   |
| **Reflow comment interiors** (`BreakableToken`)             | Long comments are a real readability problem                               | Rewriting prose is risky; needs `ReflowComments` to disable                                 |
| Degrade the comparator at **50k states**                    | Keep searching rather than abort                                           | May return a non-optimal layout precisely when the search mattered, with no signal          |
| **Macro expansion + reconstruction**                        | C++ macros span constructs                                                 | ~800 lines of machinery for a language-specific problem                                     |

---

## What a D formatter should take

**Take, above everything else: the output contract.** `Replacements` + `AffectedRangeManager` is
why clang-format has range formatting, on-type formatting and cursor preservation while
prettier/gofmt/dfmt do not. It is cheap when designed in and expensive when retrofitted — which
is why [the proposal][proposal] decides it at M0 and ships it at M5, not later.

**Take:** the soft-margin penalty (`PenaltyExcessCharacter`); tolerating unparseable input;
alignment as a separate post-pass; `--dry-run --Werror` as the CI idiom.

**Take as a warning:** the annotation/search proportion (6,796 vs 1,797). Anyone budgeting a
search-based D formatter should budget the annotator, not the search. And the incompleteness
budget: if D adopts search, the cap must be _reported_, not silent.

**Leave:** the option surface. 6,586 lines of option documentation is a maintenance burden D
cannot carry, and [the comparison][comparison] argues that dfmt's `.editorconfig` delegation plus
a small option set is the right posture.

---

## Sources

- [`llvm/llvm-project`][repo] @ `73802c2e9d102a4fb646bc039754779fca3ea476`, `clang/lib/Format/`:
  `UnwrappedLineFormatter.cpp` (1,797) · `ContinuationIndenter.cpp` (3,151) ·
  `TokenAnnotator.cpp` (6,796) · `UnwrappedLineParser.cpp` (5,179) · `WhitespaceManager.cpp` (1,754) ·
  `FormatTokenLexer.cpp` (1,620) · `BreakableToken.cpp` (1,162) · `AffectedRangeManager.cpp` (156) ·
  `Format.cpp` (4,869) · the seven fixers · `MacroExpander.cpp` / `MacroCallReconstructor.cpp`
- `clang/include/clang/Format/Format.h` (6,586) — the authoritative option reference
- [`clang/docs/LibFormat.rst`][libformat] · [`ClangFormat.rst`][clangformat-rst] ·
  [`ClangFormatStyleOptions.rst`][style-options]

**Related deep-dives in this tree:**
[Cost & search][cost-search] · [Optimality][optimality] · [Concepts][concepts] · [dfmt][dfmt] ·
[prettier][prettier] · [Roslyn][roslyn] · [Comparison][comparison] · [The proposal][proposal]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[clang-uf]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/clang/lib/Format/UnwrappedLineFormatter.cpp
[libformat]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/clang/docs/LibFormat.rst
[clangformat-rst]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/clang/docs/ClangFormat.rst
[style-options]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/clang/docs/ClangFormatStyleOptions.rst

<!-- Theory docs -->

[cost-search]: ./theory/cost-and-search.md
[optimality]: ./theory/optimality.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[concepts-break]: ./concepts.md#5-line-breaking-vocabulary
[three-jobs]: ./concepts.md#1-what-a-formatter-is-and-its-three-jobs
[spine]: ./index.md#taxonomies
[comparison]: ./comparison.md
[proposal]: ./dmd-fmt-proposal.md

<!-- System deep-dives -->

[dfmt]: ./dfmt.md
[prettier]: ./prettier.md
[roslyn]: ./roslyn.md
