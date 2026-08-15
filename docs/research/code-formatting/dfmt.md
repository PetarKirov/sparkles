# dfmt (D)

The D ecosystem's incumbent formatter, and therefore the system any new D formatter is measured
against. Architecturally it is the **AST-informed token formatter**: lex the file, parse it once
to collect a table of structural facts keyed by byte offset, then format the _token stream_
consulting that table. The AST is an oracle, never a printer. That design gives dfmt two
properties a formatter built on DMD's AST would struggle to match — **it has no comment
attachment problem**, and **it formats files that do not parse** — and it is the single most
important architectural finding in this survey for [the D proposal][proposal].

|                     |                                                                                   |
| ------------------- | --------------------------------------------------------------------------------- |
| **Language**        | D                                                                                 |
| **License**         | Boost Software License 1.0                                                        |
| **Repository**      | [`dlang-community/dfmt`][repo] @ `c65d1c8a` (`v0.15.2-5-g…`, 2026-05-30)          |
| **Author**          | Brian Schott (Copyright 2015)                                                     |
| **Parser**          | [`libdparse`][libdparse] (vendored, 26,652 lines)                                 |
| **Size**            | **4,618 lines** across 9 modules — the smallest complete formatter in this survey |
| **Category**        | token stream · capped best-first search · `.editorconfig`-configured              |
| **Layout paradigm** | [cost-minimizing search][cost-search] (bounded)                                   |

---

## Overview

### What it solves

dfmt is D's answer to "we need _a_ formatter". Its README is a usage reference rather than a
design document, and the most design-revealing sentence in it is a warning:

> "**dfmt** is beta quality. Make backups of your files or use source control when using the
> **--inplace** option." — [`README.md`][readme]

The second-most revealing is an admission about the limits of a purely token-driven cost model,
given as the motivating example for the escape hatch:

> "dfmt has no way of knowing that 'getopt' is special, so it wraps the argument list normally"
> — [`README.md`][readme]

That is an accurate self-description: dfmt has **no semantic special-casing whatsoever**. Its
knowledge of D is a token table plus a fixed set of structural offsets, and where that is not
enough the answer is `// dfmt off`.

### Design philosophy

There is no written philosophy, so it must be read out of `format()`. The pipeline is eleven
lines and it states the whole architecture:

```d
auto parseTokens = getTokensForParser(buffer, parseConfig, &cache);
auto mod = parseModule(parseTokens, source_desc, &allocator);
auto visitor = new FormatVisitor(&astInformation);
visitor.visit(mod);
astInformation.cleanup();
auto tokenRange = byToken(buffer, config, &cache);
…
auto depths = generateDepthInfo(tokens);
auto tokenFormatter = TokenFormatter!OutputRange(buffer, tokens, depths,
        output, &astInformation, formatterConfig);
tokenFormatter.format();
```

— [`src/dfmt/formatter.d`][formatter], `format()`

The file is lexed **twice**: once with parser settings to build an AST, once with formatter
settings to produce the token array that is actually printed. The AST is consumed by a visitor
that populates `ASTInformation` and then **discarded**. Nothing downstream sees a tree.

And the contract in its own doc comment carries the property that matters most:

> "Returns: `true` if the formatting succeeded, `false` of a lexing error. **This function can
> return `true` if parsing failed.**" — [`src/dfmt/formatter.d`][formatter]

dfmt needs the file to _lex_, not to _parse_. A file with an unbalanced brace still gets
formatted, with the structural table simply less populated. For an editor formatting a buffer
mid-edit this is not a nicety; it is the difference between a formatter that works on every
keystroke and one that works only on valid files.

---

## How it works

### `ASTInformation`: the AST reduced to sorted offset arrays

The bridge between the two halves is one struct of **sorted `size_t[]` arrays of byte
locations** — roughly two dozen of them:

```d
/// Locations of end braces for struct bodies
size_t[] doubleNewlineLocations;
/// Locations of tokens where a space is needed (such as the '*' in a type)
size_t[] spaceAfterLocations;
/// Locations of unary operators
size_t[] unaryLocations;
```

— [`src/dfmt/ast_info.d`][ast-info]

plus `attributeDeclarationLines`, `caseEndLocations`, `structInitStartLocations` /
`…EndLocations`, `funLitStartLocations` / `…EndLocations`, `conditionalWithElseLocations`,
`arrayStartLocations`, `assocArrayStartLocations`, `contractLocations`, `constraintLocations`,
`constructorDestructorLocations`, `ufcsHintLocations`, `ternaryColonLocations`,
`namedArgumentColonLocations`, and two arrays sorted by `endLocation` carrying richer
`indentInfo`/`structInfo` records.

`cleanup()` sorts every array precisely "so that binary search will work on them" — so at format
time a structural question ("is this `*` a pointer or a multiply?", "does this `if` have an
`else`?") is an `O(log n)` lookup on an offset, not a tree walk.

**This is the transferable idea.** The semantic pass and the printing pass are decoupled by a
flat, position-keyed table. A D formatter on `sparkles:dmd-lsp` could populate exactly such a
table from the DMD AST — where DMD's `Loc` limitations bite far less, because a _start_ offset
is all an entry needs — and then never consult the AST again. See
[the substrate baseline][baseline], Q-c.

### Comments: no attachment, because none is needed

dfmt does not solve [the attachment problem][attachment]; it does not _have_ it. Comments are
ordinary tokens in the array being formatted, so their position in the output is their position
in the input:

```d
if (currentIs(tok!"comment"))
    formatComment();
```

with the policy expressed as local decisions about the surrounding tokens — "The comment appears
on its own line, keep it there" ([`formatter.d`][formatter]). There is no leading/trailing
classification, no owning node, no heuristic table like [de Jonge & Visser's][patterns], because
the token order already encodes everything those mechanisms exist to recover.

This is the concrete payoff of the token-spine architecture and it is worth stating plainly:
**the hardest problem in the survey disappears if the formatter's input is a token stream rather
than a tree.**

### The escape hatch

`// dfmt off` / `// dfmt on` is implemented by scanning comment text in the formatter loop:

```d
void formatComment()
{
    if (commentText(index) == "dfmt off")
    …
```

with `commentText()` stripping `//` or `/* */` and trimming. It is a **line-range** hatch, not
node-scoped — see [the escape-hatch table][hatches].

### The break search

Covered in full in [cost & search][cost-search]. In brief: `chooseLineBreakTokens` runs a
best-first search over a `uint` bitmask of break positions, with `State`'s cost built from two
constants — `remainingCharsMultiplier = 25` for overflow past the soft limit, `newlinePenalty =
480` per break, scaled by nesting depth — and a hard limit that sets `_solved = false` rather
than adding cost. The budget is a 32-token window (`ALGORITHMIC_COMPLEXITY_SUCKS = uint.sizeof

- 8`) and 1,000 queue pops, after which it returns the best state seen **even if unsolved**.

---

## 1. Input model & fidelity

**Token stream, from `libdparse`.** Both lexer configurations set
`stringBehavior = StringBehavior.source`, so string literals are carried through exactly as
written — the verbatim guarantee for the one construct where a byte change is a semantic change.
`whitespaceBehavior = WhitespaceBehavior.skip` drops whitespace tokens; whitespace is
_regenerated_, comments are _preserved as tokens_.

**Round-trip guarantee:** none is stated or tested. dfmt has no equivalence checker, no
idempotence harness, and no `--check` semantics beyond exit status. Compare
[ocamlformat's instability detector][verification].

**Behaviour on unparseable input:** **formats anyway.** Lexing must succeed; parsing need not.
This is the same posture as [clang-format][clang-format] and the opposite of
[gofmt][gofmt], and it is the single most LSP-friendly property in the design.

## 2. Layout IR & break decision

**Paradigm: [cost-minimizing search][cost-search], bounded.** There is no `Doc` IR. The
"document" is the token array plus a parallel `depths` array; the search's state is a 32-bit
break bitmask, and `opEquals`/`toHash` are defined on that bitmask alone.

**Width policy: soft and hard.** `dfmt_soft_max_line_length` (default 80) is a cost;
`max_line_length` is a feasibility constraint. This two-threshold design is the crude
independent ancestor of the "soft margin" [Yelland argues for][optimality] — reached without
the theory and without the vocabulary.

## 3. Alignment, indentation & vertical rhythm

`IndentStack` (`indentation.d`, 333 lines) maintains the indentation state, with
`wrapIndents` distinguishing continuation indents from block indents and a `Details` record
per entry. `dfmt_single_indent` controls whether a wrapped parenthesized list gets one or two
levels.

**Alignment proper is weak.** `dfmt_align_switch_statements` is the only alignment feature; there
is nothing corresponding to clang-format's `AlignConsecutive*` or gofmt's `tabwriter`. Column
alignment of consecutive declarations, assignments or trailing comments is not offered.

**Width measurement**: `tokenLength` in `tokens.d` sums token lengths in **bytes/characters**,
with no grapheme or East-Asian width model. A line of CJK identifiers will be mis-measured.

## 4. Comments, trivia & preservation

Comments are tokens; position is preserved by construction (above). Blank-line policy is
handled by `doubleNewlineLocations` and local rules — runs of blank lines are collapsed, and
struct/class bodies get a forced double newline after the closing brace.

**No reflow.** dfmt never rewraps the interior of a comment. Given that its measurement model is
byte-based and it has no ddoc awareness, that is the right call.

**DDoc is not special-cased.** A `///` or `/** */` comment is formatted as any other comment.

## 5. Configurability, opinionation & config discovery

**Delegated to `.editorconfig`** — the distinguishing choice, and 458 of dfmt's 4,618 lines
(`editorconfig.d` + `globmatch_editorconfig.d`, ~10%):

> "**dfmt** uses EditorConfig configuration files. **dfmt**-specific properties are prefixed
> with \_dfmt\_\_." — [`README.md`][readme]

The option surface (`config.d`) is ~20 knobs: `dfmt_brace_style` (default `allman`),
`dfmt_soft_max_line_length` (80), `dfmt_align_switch_statements`, `dfmt_outdent_attributes`,
`dfmt_space_after_cast`, `dfmt_space_after_keywords`, `dfmt_split_operator_at_line_end`,
`dfmt_template_constraint_style`, `dfmt_keep_line_breaks`, `dfmt_single_indent`,
`dfmt_reflow_property_chains`, `dfmt_compact_labeled_statements`, and a handful of
space-before/after toggles. Mid-sized: far below [clang-format][clang-format], far above
[gofmt][gofmt]'s zero.

**Migration consequence:** any successor that wants dfmt's users must read `.editorconfig` and
honour the `dfmt_*` keys, or accept that every project re-configures. This is the concrete
content of the proposal's Q-f.

## 6. Integration surface & output contract

**Output contract: a whole document.** `format()` writes to an output range; there is no
`TextEdit[]`, no `Replacements`, no minimal diff.

**No range formatting.** No `--lines`, no `--offset`/`--length`. A formatter integrated into an
editor via dfmt can only replace the entire buffer.

**No cursor preservation.**

**CLI:** `--inplace`, stdin/stdout by default; `main.d` is 375 lines including EditorConfig
resolution.

**Latency:** unmeasured here, but bounded by construction — the search cap is per line and
unconditional, so dfmt cannot exhibit the pathological pauses [scalafmt documents][cost-search].
It buys that bound by giving up on long lines entirely.

---

## Strengths

- **The architecture is right.** AST-as-oracle over a token spine gives comment preservation for
  free and format-broken-files for free. Both are properties an AST-printing formatter has to
  work very hard to recover.
- **Small and readable.** 4,618 lines; the cost model is 60 lines and the search is 40. It can be
  understood completely in an afternoon, which is not true of anything else in wave 1.
- **`.editorconfig` integration** is genuinely good ecosystem citizenship and is the reason it is
  adopted.
- **Bounded worst case.** Unusual among search-based formatters, and valuable.
- **Verbatim string literals** by lexer configuration rather than by special-casing.

## Weaknesses

- **The 32-token window is a quality ceiling, not a tuning parameter.** The state _is_ a `uint`,
  so long lines — exactly the ones that need breaking — are the ones the search cannot address.
- **Silently unsolved output.** Returning `lowest` when `_solved` is false means dfmt knowingly
  emits lines over `max_line_length` with no diagnostic.
- **No verification of any kind** — no idempotence test, no token-equality check, no corpus
  differential. "Make backups of your files" is the documented mitigation.
- **No range or on-type formatting, no cursor** — the whole-document contract rules out good LSP
  integration.
- **No alignment engine** and a byte-based width model.
- **No semantic knowledge at all**, by design; `// dfmt off` is the answer to every case where
  that is not enough.
- **Beta quality by its own description**, ten years after the copyright date.

---

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                        | Trade-off                                                                                             |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Format the **token stream**, use the AST only as an oracle | Comments survive by construction; broken files still format                      | No decision can depend on anything not pre-recorded as an offset — hence `// dfmt off` for `getopt`   |
| Reduce the AST to **sorted offset arrays**                 | Structural queries become binary searches; the tree is not needed at format time | The set of recorded facts is fixed at ~24 arrays; a new rule means a new array and a new visitor pass |
| **Lex twice**, with different configurations               | Parser and formatter want different token streams (whitespace, string handling)  | The file is scanned twice; the two streams must stay in correspondence by offset                      |
| Tolerate **parse failure**                                 | An editor buffer is often invalid                                                | Structural facts are missing exactly when the file is malformed, so output quality degrades silently  |
| State = a **`uint` break bitmask**                         | `opEquals`/`toHash` are free; the frontier is a cheap `RedBlackTree`             | Hard-caps the search window at 32 tokens                                                              |
| **Soft and hard** line limits                              | A too-long line should still get the best available layout                       | Two thresholds to explain; unsolved output is emitted without a diagnostic                            |
| Configuration via **`.editorconfig`**                      | No new config format; per-directory overrides come free                          | 10% of the codebase is config plumbing; the `dfmt_*` keys become a compatibility surface              |
| **No comment reflow, no ddoc awareness**                   | Keeps the formatter honest about what it can measure                             | DDoc's internal layout is never improved — but also never damaged                                     |
| **No verification harness**                                | Simplicity                                                                       | Correctness rests on the test suite and on users keeping backups                                      |

---

## What a D successor should take, and leave

**Take:** the AST-as-oracle-over-tokens architecture; the sorted-offset-array bridge; tolerating
parse failure; `.editorconfig` compatibility for migration; soft-vs-hard limits.

**Leave:** the 32-token window; silent unsolved output; the absence of any verification; the
whole-document output contract.

**Beat, measurably:** dfmt's defects are _citable_ — a bitmask-bounded search window and a
1,000-pop cap are concrete numbers a successor can be measured against on a corpus. That is the
content of the proposal's M8, and it is a rare luxury: a baseline whose limitations are in the
source rather than in opinion.

---

## Sources

- [`dlang-community/dfmt`][repo] @ `c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76`, read in full:
  `src/dfmt/formatter.d` (2,402) · `ast_info.d` (503) · `main.d` (375) · `indentation.d` (333) ·
  `tokens.d` (243) · `globmatch_editorconfig.d` (239) · `editorconfig.d` (219) ·
  `wrapping.d` (182) · `config.d` (122)
- [`README.md`][readme] — usage and EditorConfig properties
- [`libdparse`][libdparse] — the vendored lexer/parser, 26,652 lines

**Related deep-dives in this tree:**
[Cost & search][cost-search] · [Layout preservation][layout-preserving] · [Concepts][concepts] ·
[clang-format][clang-format] · [gofmt][gofmt] · [The D landscape][d-landscape] ·
[The substrate baseline][baseline] · [The proposal][proposal]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/dlang-community/dfmt/tree/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76
[formatter]: https://github.com/dlang-community/dfmt/blob/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76/src/dfmt/formatter.d
[ast-info]: https://github.com/dlang-community/dfmt/blob/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76/src/dfmt/ast_info.d
[readme]: https://github.com/dlang-community/dfmt/blob/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76/README.md
[libdparse]: https://github.com/dlang-community/libdparse

<!-- Theory docs -->

[cost-search]: ./theory/cost-and-search.md
[optimality]: ./theory/optimality.md
[layout-preserving]: ./theory/layout-preserving.md
[patterns]: ./theory/layout-preserving.md#the-comment-heuristics-in-full

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[hatches]: ./concepts.md#9-verbatim-regions-and-escape-hatches
[verification]: ./verification.md
[d-landscape]: ./d-landscape.md
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md

<!-- System deep-dives -->

[clang-format]: ./clang-format.md
[gofmt]: ./gofmt.md
