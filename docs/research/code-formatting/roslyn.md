# Roslyn (C# / Visual Basic)

The formatter with no line breaker. Roslyn formats by running a **chain of rules that make
pairwise decisions between adjacent tokens** — how many newlines, how many spaces — over a
**full-fidelity syntax tree** in which every token owns its surrounding trivia. There is no
global objective, no width measurement, and no search. It is the industrial answer to
[the orthogonality problem][layout-preserving]: make linguistic and documentary structure
non-orthogonal by construction, so nothing ever needs attaching.

It is also the only wave-1 system designed from the start for **incremental, interactive**
formatting — format-on-type, format-selection, `TextEdit[]` output — because it exists to serve
an IDE rather than a CLI.

|                     |                                                                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Languages**       | C#, Visual Basic                                                                                                                   |
| **License**         | MIT                                                                                                                                |
| **Repository**      | [`dotnet/roslyn`][repo] @ `e42c3902` (2026-07-02)                                                                                  |
| **Engine**          | `src/Workspaces/SharedUtilitiesAndExtensions/Compiler/Core/Formatting/` (8,078) — `Engine/`, `Rules/`, `Context/`, `TriviaEngine/` |
| **C# rules**        | `.../Compiler/CSharp/Formatting/` (7,075)                                                                                          |
| **Category**        | full-fidelity CST · local rule chain · **`TextEdit[]`**                                                                            |
| **Layout paradigm** | local rule chain                                                                                                                   |

---

## Overview

### What it solves

An IDE formats constantly: on `;`, on `}`, on paste, on selection, on save. Each of those must be
fast, must produce a **minimal edit** (so the undo stack and the caret survive), and must work on
a file that is mid-edit and does not compile. A whole-document reprinting formatter cannot meet
any of those requirements.

Roslyn's answer starts one layer down, in the syntax tree.

### Design philosophy: the tree is the text

Roslyn's `SyntaxToken` owns its **leading** and **trailing trivia** — whitespace, comments,
preprocessor directives, disabled `#if` regions — so a Roslyn tree round-trips to the exact
original bytes. `SyntaxNodeOrToken` exposes `HasLeadingTrivia`, `GetLeadingTrivia()`,
`GetLeadingTriviaWidth()` and the trailing equivalents ([`SyntaxNodeOrToken.cs`][syntax-not]).

Because trivia is _owned_, [the attachment problem][attachment] does not arise: a comment already
belongs to a token by construction, decided once by the parser rather than repeatedly by the
formatter.

The refinement that makes this work for _generated_ code is **elastic trivia**:

> "Elastic trivia is usually in a manually constructed syntax tree to represent flexible
> whitespace elements. The trees returned by the parsers represent any whitespace literally as it
> was in the source code. Elastic whitespace lets generated trees suggest whitespace elements and
> ensure tokens are not immediately adjacent to each other. **Formatters and other tree processing
> tools can freely substitute, lengthen, or change the elastic whitespace in any way without
> breaking fidelity with an original code source.**" — [`docs/wiki/FAQ.md`][faq]

So a Roslyn tree distinguishes whitespace that _is in the file_ (preserve it) from whitespace that
is merely _suggested_ (rewrite it). Nothing else in this survey has that distinction, and it is
exactly what a formatter needs to know.

---

## How it works

### The rule chain

`AbstractFormattingRule` has six virtual members, each taking a `next` continuation — a
chain-of-responsibility over which every language- and option-specific rule composes:

```csharp
public virtual void AddSuppressOperations(ArrayBuilder<SuppressOperation> list, SyntaxNode node, in NextSuppressOperationAction nextOperation)
public virtual void AddAnchorIndentationOperations(List<AnchorIndentationOperation> list, SyntaxNode node, in NextAnchorIndentationOperationAction nextOperation)
public virtual void AddIndentBlockOperations(List<IndentBlockOperation> list, SyntaxNode node, in NextIndentBlockOperationAction nextOperation)
public virtual void AddAlignTokensOperations(List<AlignTokensOperation> list, SyntaxNode node, in NextAlignTokensOperationAction nextOperation)
public virtual AdjustNewLinesOperation? GetAdjustNewLinesOperation(in SyntaxToken previousToken, in SyntaxToken currentToken, in NextGetAdjustNewLinesOperation nextOperation)
public virtual AdjustSpacesOperation? GetAdjustSpacesOperation(in SyntaxToken previousToken, in SyntaxToken currentToken, in NextGetAdjustSpacesOperation nextOperation)
```

— [`AbstractFormattingRule.cs`][abstract-rule]

The split is the design:

- Four **node-scoped** `Add*Operations` methods gather _structural_ facts: which spans to leave
  alone (`Suppress`), where indentation anchors, which blocks indent, which tokens align.
- Two **token-pair-scoped** `Get*Operation` methods answer the only questions that produce output:
  given `previousToken` and `currentToken`, **how many newlines** and **how many spaces** go
  between them.

Every layout decision Roslyn makes is a local function of an adjacent token pair plus the gathered
operations. **There is no place in this architecture where a width could be consulted**, which is
why Roslyn does not wrap lines — the capability is not missing, it is unrepresentable.

### Why this is the right shape for an IDE

- **Incremental:** re-running the rules over a token range is cheap and local; nothing depends on
  the rest of the document.
- **Minimal edits:** each `AdjustSpaces`/`AdjustNewLines` result is a change to one trivia gap, so
  the natural output is a set of `TextEdit`s, not a document.
- **Robust:** the tree parses with error nodes, and the rules run over whatever tokens exist.
- **Suppression is first-class:** `SuppressOperation` marks spans where formatting must not
  happen, which is how `#region`, disabled preprocessor branches and user selections are honoured
  without a comment directive.

---

## 1. Input model & fidelity

**Full-fidelity CST (red-green trees).** Exact round-trip is a guaranteed property, not a test
result. `SyntaxTrivia` covers whitespace, comments, directives and **disabled text** — the
contents of an inactive `#if` branch are retained as trivia rather than discarded, which is how
Roslyn formats code it did not even compile.

**Behaviour on unparseable input:** formats around error nodes. The parser always produces a tree.

## 2. Layout IR & break decision

**Paradigm: local rule chain.** No IR, no measurement, no search. Width policy: **effectively
none** — Roslyn preserves the author's line structure and adjusts the whitespace within and
between lines.

This is the same _outcome_ as [gofmt][gofmt] (line-preserving) reached by a completely different
mechanism, and the pairing is instructive: line-preservation is achievable either by carrying
source line numbers into the printer (gofmt) or by never having a printer at all (Roslyn).

## 3. Alignment, indentation & vertical rhythm

`AddIndentBlockOperations` and `AddAlignTokensOperations` are dedicated members of the rule
interface — alignment is a first-class operation kind, not a post-pass. `AddAnchorIndentationOperations`
handles the case where continuation lines anchor to a token's column rather than a block level.

## 4. Comments, trivia & preservation

Owned by tokens; nothing to attach. Comment _interiors_ are not reflowed. Preprocessor directives
and disabled regions are trivia and survive verbatim.

## 5. Configurability, opinionation & config discovery

Large: `.editorconfig` keys (`csharp_new_line_before_open_brace`, `csharp_space_after_cast`,
`csharp_indent_case_contents`, …) plus IDE settings. Roslyn is the reference example of
**`.editorconfig` as the formatter's real configuration surface**, which is the posture
[dfmt][dfmt] also takes.

## 6. Integration surface & output contract

**`TextEdit[]`/`Replacements`-equivalent** — the strongest integration story in wave 1 alongside
[clang-format][clang-format]:

- **Format selection** — run the rules over a token range.
- **Format on type** — trigger on `;`, `}`, newline.
- **Cursor preservation** — the IDE tracks positions through the edits.
- **No CLI-first design at all**; `dotnet format` is layered on top.

---

## Strengths

- **No attachment problem.** Owned trivia removes the survey's hardest recurring difficulty by
  construction.
- **Elastic trivia** — a genuinely novel distinction between literal and suggested whitespace.
- **Built for incremental, interactive use**: minimal edits, ranges, on-type, cursor.
- **Formats broken and even disabled code** — inactive `#if` branches are preserved as trivia.
- **Composable rules** with a clean `next`-continuation interface, so options and languages layer
  cleanly.
- **`.editorconfig`-native.**

## Weaknesses

- **No line breaking at all.** Long lines stay long; the architecture cannot express a width
  constraint.
- **No global quality objective** — every decision is pairwise, so nothing coordinates.
- **Very large** (~15,000 lines across core + C#) for what it does, because rule chains grow one
  rule at a time.
- **Not usable as a library outside .NET**, so its ideas travel better than its code.
- **No comment reflow.**

---

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                          | Trade-off                                                                                  |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| **Tokens own their trivia** (full-fidelity CST)       | Exact round-trip; the attachment problem disappears                                | The tree is much larger than an AST; every consumer sees trivia whether it wants to or not |
| **Elastic trivia** for generated nodes                | Distinguishes "this whitespace is in the file" from "this whitespace is suggested" | A second whitespace concept every tool must understand                                     |
| **Pairwise `GetAdjust*Operation`** as the only output | Decisions are local ⇒ incremental, minimal-edit, cheap                             | A width constraint is unrepresentable — no line breaking, ever                             |
| **Node-scoped `Add*Operations`** for structure        | Separates gathering structural facts from emitting whitespace                      | Four operation kinds to understand before writing one rule                                 |
| **Chain of responsibility** with `next` continuations | Options and languages compose without a central switch                             | Rule _order_ becomes semantically significant and is hard to reason about                  |
| **`SuppressOperation`** as a first-class operation    | Ranges, `#region`, disabled code and selections all use one mechanism              | Suppression must be computed for the whole document even when formatting a small range     |
| **Emit `TextEdit[]`**                                 | The IDE requirement: minimal diff, stable caret, cheap undo                        | No "format this string" convenience API; every caller applies edits                        |
| **`.editorconfig` as the option surface**             | Shared with the rest of the .NET tooling; per-directory overrides free             | A very large key space, and keys are stringly-typed                                        |

---

## What a D formatter should take

**Take, as the model for the output contract:** Roslyn and [clang-format][clang-format] agree,
from opposite architectures, that a formatter serving an editor must emit **edits**. Two
independent arrivals at the same conclusion is the strongest signal in the survey on this point,
and it is why [the proposal][proposal] fixes the output contract at M0.

**Take, as vocabulary:** _elastic trivia_. A D formatter on a token spine can mark regenerated
whitespace as elastic and author-written whitespace as literal, which makes "preserve the author's
blank lines" and "reformat this gap" a data distinction rather than a pile of special cases.

**Take:** `SuppressOperation` as the single mechanism behind range formatting, `dfmt off`, verbatim
regions (`asm`, `q{}`) and disabled `version` blocks — one concept instead of four.

**Leave:** the absence of line breaking. Roslyn can decline the problem because Visual Studio's
users format-on-type in a live editor; a D CLI formatter replacing dfmt cannot.

---

## Sources

- [`dotnet/roslyn`][repo] @ `e42c3902b0c0f922771e06b5222dadee92fb0e2e`:
  `src/Workspaces/SharedUtilitiesAndExtensions/Compiler/Core/Formatting/` (`Engine/`, `Rules/`,
  `Context/`, `TriviaEngine/`; 8,078 lines) · `.../Compiler/CSharp/Formatting/` (7,075) ·
  `src/Compilers/Core/Portable/Syntax/SyntaxNodeOrToken.cs`
- [`docs/wiki/FAQ.md`][faq] — trivia, elastic trivia, structured trivia

**Related deep-dives in this tree:**
[Layout preservation][layout-preserving] · [Concepts][concepts] · [clang-format][clang-format] ·
[gofmt][gofmt] · [dfmt][dfmt] · [Comparison][comparison] · [The proposal][proposal]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/dotnet/roslyn/tree/e42c3902b0c0f922771e06b5222dadee92fb0e2e
[abstract-rule]: https://github.com/dotnet/roslyn/blob/e42c3902b0c0f922771e06b5222dadee92fb0e2e/src/Workspaces/SharedUtilitiesAndExtensions/Compiler/Core/Formatting/Rules/AbstractFormattingRule.cs
[syntax-not]: https://github.com/dotnet/roslyn/blob/e42c3902b0c0f922771e06b5222dadee92fb0e2e/src/Compilers/Core/Portable/Syntax/SyntaxNodeOrToken.cs
[faq]: https://github.com/dotnet/roslyn/blob/e42c3902b0c0f922771e06b5222dadee92fb0e2e/docs/wiki/FAQ.md

<!-- Theory docs -->

[layout-preserving]: ./theory/layout-preserving.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[comparison]: ./comparison.md
[proposal]: ./dmd-fmt-proposal.md

<!-- System deep-dives -->

[clang-format]: ./clang-format.md
[gofmt]: ./gofmt.md
[dfmt]: ./dfmt.md
