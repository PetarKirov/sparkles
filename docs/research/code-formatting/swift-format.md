# swift-format (Swift)

The architecture a D formatter would want if it could choose its substrate: a formatter built on
**SwiftSyntax**, a full-fidelity syntax tree _maintained by the compiler project itself_. Where
[Roslyn][roslyn] gets the same property inside an IDE, swift-format gets it as a **standalone tool
consuming the compiler's own tree** — which is exactly the relationship
[`sparkles:dmd-fmt` would have to `sparkles:dmd-lsp`][baseline]. Its layout engine is an
[Oppen/Wadler hybrid][combinators] with a token stream built by a syntax visitor.

|                     |                                                                                                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**        | Swift                                                                                                                                                            |
| **License**         | Apache-2.0                                                                                                                                                       |
| **Repository**      | [`swiftlang/swift-format`][repo] @ `4be9f3a1` (2026-08-06)                                                                                                       |
| **Engine**          | `Sources/SwiftFormat/PrettyPrint/` — `PrettyPrint.swift`, `TokenStreamCreator.swift`, `Token.swift`, `Comment.swift`, `Verbatim.swift`, `WhitespaceLinter.swift` |
| **Substrate**       | [SwiftSyntax][swiftsyntax] — full-fidelity, compiler-maintained                                                                                                  |
| **Category**        | full-fidelity CST → token stream · combinator · small config                                                                                                     |
| **Layout paradigm** | [combinator group/flat][combinators]                                                                                                                             |

---

## Overview

### What it solves

Formatting Swift _without reimplementing Swift_. SwiftSyntax is a full-fidelity tree — every byte
of the source is representable, trivia included — and it is produced and versioned by the
compiler project. swift-format is therefore a thin tool over a substrate someone else keeps
correct.

That relationship is why this deep-dive matters here. Its influence is visible elsewhere in the
survey: rust-analyzer's own syntax library records that its "current implementation is inspired by
the [Swift] one" ([`crates/syntax/src/lib.rs`][ra-syntax]). SwiftSyntax is the reference design for
compiler-maintained full-fidelity trees.

### The token model

`TokenStreamCreator` walks the syntax tree and emits a flat stream of layout tokens; `PrettyPrint`
consumes it. The token type is a compact hybrid of [Oppen's][oppen] and
[Wadler's][combinators] vocabularies plus two additions:

```swift
enum Token {
  case syntax(String)
  case open(GroupBreakStyle)
  case close
  case `break`(BreakKind, size: Int, newlines: NewlineBehavior)
  case space(size: Int, flexible: Bool)
  case comment(Comment, wasEndOfLine: Bool)
  case verbatim(Verbatim)
  case printerControl(kind: PrinterControlKind)

  /// Marks the beginning of a comma delimited collection, where a trailing comma should be inserted
  /// at `commaDelimitedRegionEnd` if and only if the collection spans multiple lines.
  case commaDelimitedRegionStart
```

— [`Sources/SwiftFormat/PrettyPrint/Token.swift`][token]

Four things worth naming:

- **`open(GroupBreakStyle)` / `close`** is [Oppen's `begin`/`end` with a consistency flag][oppen-cons]
  — the same two-valued distinction, a fourth independent naming after Oppen, Box and prettier.
- **`comment(Comment, wasEndOfLine: Bool)`** makes comments _first-class layout tokens_ carrying
  the one bit of documentary structure that matters for placement. This is the middle path between
  [dfmt][dfmt]'s "comments are just tokens" and [prettier][prettier]'s 1,255-line attachment
  module: comments enter the layout stream, but with a classification already attached by the
  visitor that had the tree.
- **`verbatim(Verbatim)`** is a first-class token for regions copied byte-for-byte.
- **`commaDelimitedRegionStart`** _inserts_ a trailing comma when a collection breaks — the
  inverse of [black's magic trailing comma][concepts-break]. Black reads the author's comma as a
  signal; swift-format writes one as an aid to future diffs. Both are about
  [diff behaviour][diff-review], from opposite directions.

`WhitespaceLinter.swift` is a separate mode that _reports_ whitespace problems rather than fixing
them — formatting and linting as two views of one model.

---

## 1. Input model & fidelity

**Full-fidelity SwiftSyntax CST.** Exact round-trip is a property of the substrate, not of
swift-format. Trivia (comments, whitespace) is owned by tokens as in [Roslyn][roslyn].

**Behaviour on unparseable input:** SwiftSyntax always yields a tree with error nodes; swift-format
is conservative about formatting them.

## 2. Layout IR & break decision

**Paradigm: [combinator][combinators]** — `open`/`close` groups with a break style,
`break(BreakKind, size:, newlines:)` for the break points, greedy fit testing. Hard line length
(default 100).

## 3. Alignment, indentation & vertical rhythm

`Indent+Length.swift`; `PrintercontrolKind` can suspend/resume the printer for regions.
`NewlineBehavior` on each break gives per-break control over how many newlines are permitted,
which is how blank-line policy is expressed inside the token stream rather than as a separate
pass.

## 4. Comments, trivia & preservation

`Comment.swift` plus the `comment(_, wasEndOfLine:)` token; `Verbatim.swift` for untouched
regions. Because the substrate is full-fidelity, nothing is _lost_ — the only question is
placement, and `wasEndOfLine` carries the decisive bit.

## 5. Configurability, opinionation & config discovery

Small JSON `.swift-format` file (line length, indentation, a handful of rules). Far closer to
[black][long-tail] than to [clang-format][clang-format].

## 6. Integration surface & output contract

Whole document; `--mode lint` for reporting; used by Xcode and SourceKit-LSP through the library
API rather than the CLI.

---

## Strengths

- **Compiler-maintained full-fidelity substrate** — the formatter does not own a parser, a lexer,
  or a trivia model, and does not drift from the language.
- **Comments as classified layout tokens** — a cheap middle path that avoids both blunt
  token-order placement and a large attachment module.
- **`verbatim` and printer control as first-class tokens**, so verbatim regions are part of the
  IR rather than a pre-pass.
- **Trailing-comma insertion on break** — a deliberate diff-quality feature.
- **Formatting and linting share one model.**
- **Small configuration surface.**

## Weaknesses

- **Entirely dependent on SwiftSyntax's release cadence** — a substrate you do not control is a
  substrate that can break you.
- **Greedy**, with the usual [combinator][combinators] ceiling.
- **Whole-document output**; no range formatting or cursor in the CLI.
- **Conservative on malformed input**, so the full-fidelity tree's error tolerance is not
  exploited.

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                    | Trade-off                                                                       |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Build on the **compiler's own full-fidelity tree**     | No parser to maintain; no drift from the language                            | Coupled to the compiler project's API and release cadence                       |
| **Flatten the tree to a token stream** before printing | The printer is simple and language-agnostic; the visitor holds the knowledge | Two-stage design; the visitor must decide everything the printer cannot revisit |
| **`comment(_, wasEndOfLine:)`** as a layout token      | Carries the one bit placement needs, decided where the tree is available     | Still a classification — the hard cases collapse to one boolean                 |
| **`verbatim` as a token**                              | Untouched regions participate in the stream rather than bypassing it         | The visitor must identify them correctly up front                               |
| **Insert trailing commas when multi-line**             | Future diffs touch one line instead of two                                   | Changes tokens, not just whitespace — [job three][three-jobs] again             |
| **`NewlineBehavior` per break**                        | Blank-line policy lives with the break rather than in a separate pass        | More state per token                                                            |
| **Lint mode over the same model**                      | One implementation, two products                                             | Lint findings are constrained to what the formatter models                      |

---

## What this means for D

swift-format is the **existence proof for the architecture the D proposal is aiming at**: a
formatter as a separate package consuming a compiler-maintained syntax tree, with the language
knowledge in a visitor and the layout in a small printer.

The gap is precisely the substrate. SwiftSyntax is full-fidelity by design; **`sparkles:dmd-lsp`
exposes DMD's AST, which is not** — no trivia, no token stream, `Loc` without end positions
([baseline][baseline], Q-a/Q-b). The two ways to close that gap are the proposal's real fork:
build a token spine beside the AST (dfmt's answer), or adopt a foreign full-fidelity tree
([tree-sitter][topiary]'s answer). swift-format shows what is available on the far side once the
substrate question is settled — including the token model, which is worth copying almost verbatim.

---

## Sources

- [`swiftlang/swift-format`][repo] @ `4be9f3a16d429df692694ab17744b1014b0ac7af`:
  `Sources/SwiftFormat/PrettyPrint/{Token,PrettyPrint,TokenStreamCreator,Comment,Verbatim,PrettyPrintBuffer,Indent+Length,WhitespaceLinter}.swift`
- [`rust-lang/rust-analyzer`][ra-syntax] — for the attestation that its syntax library is
  "inspired by the [Swift] one"

**Related deep-dives in this tree:**
[Combinators][combinators] · [Layout preservation][layout-preserving] · [Concepts][concepts] ·
[Roslyn][roslyn] · [dfmt][dfmt] · [topiary][topiary] · [The substrate baseline][baseline] ·
[The proposal][proposal]

<!-- References -->

[repo]: https://github.com/swiftlang/swift-format/tree/4be9f3a16d429df692694ab17744b1014b0ac7af
[token]: https://github.com/swiftlang/swift-format/blob/4be9f3a16d429df692694ab17744b1014b0ac7af/Sources/SwiftFormat/PrettyPrint/Token.swift
[swiftsyntax]: https://github.com/swiftlang/swift-syntax
[ra-syntax]: https://github.com/rust-lang/rust-analyzer/blob/3033d4fac8aab3f1725aa9c9d6293436aeceb0a5/crates/syntax/src/lib.rs
[oppen]: ./theory/oppen.md
[oppen-cons]: ./theory/oppen.md#consistent-vs-inconsistent-breaking
[combinators]: ./theory/combinators.md
[layout-preserving]: ./theory/layout-preserving.md
[concepts]: ./concepts.md
[concepts-break]: ./concepts.md#5-line-breaking-vocabulary
[three-jobs]: ./concepts.md#1-what-a-formatter-is-and-its-three-jobs
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md
[roslyn]: ./roslyn.md
[dfmt]: ./dfmt.md
[prettier]: ./prettier.md
[clang-format]: ./clang-format.md
[topiary]: ./topiary.md
[long-tail]: ./long-tail.md
[diff-review]: ../diff-review/index.md
