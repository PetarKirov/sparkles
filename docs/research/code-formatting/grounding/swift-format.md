# Grounding ledger — swift-format.md

Verification against `$REPOS/swift/swift-format` @ `4be9f3a16d429df692694ab17744b1014b0ac7af`
(**depth-1 clone**).

## Verified verbatim (✓)

| Claim                                                                                                                                                                                         | Source                                                    |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| The `enum Token` cases, incl. `open(GroupBreakStyle)`, `break(BreakKind, size:, newlines:)`, `comment(Comment, wasEndOfLine:)`, `verbatim(Verbatim)`, `printerControl(kind:)`                 | `Sources/SwiftFormat/PrettyPrint/Token.swift:181-190`     |
| `commaDelimitedRegionStart` and its doc comment ("a trailing comma should be inserted … if and only if the collection spans multiple lines")                                                  | `Token.swift:191-193`                                     |
| The `PrettyPrint/` file list (`PrettyPrint.swift`, `TokenStreamCreator.swift`, `Comment.swift`, `Verbatim.swift`, `WhitespaceLinter.swift`, `Indent+Length.swift`, `PrettyPrintBuffer.swift`) | `ls`                                                      |
| rust-analyzer's "inspired by the [Swift] one" attestation                                                                                                                                     | `$REPOS/rust/rust-analyzer/crates/syntax/src/lib.rs:9-10` |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                           | Status | Note                                                                                                     |
| --- | ----------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------- |
| 1   | "`TokenStreamCreator` walks the syntax tree and emits a flat stream; `PrettyPrint` consumes it" | ⚠      | Inferred from the two file names; **neither file was read**                                              |
| 2   | "`open(GroupBreakStyle)`/`close` is Oppen's `begin`/`end` with a consistency flag"              | ◯      | The survey's identification; `GroupBreakStyle`'s cases were **not** inspected                            |
| 3   | "SwiftSyntax is full-fidelity … trivia owned by tokens"                                         | 🌐     | SwiftSyntax is **not cloned**. General knowledge, corroborated indirectly by rust-analyzer's attestation |
| 4   | "Exact round-trip is a property of the substrate"                                               | 🌐     | Follows from row 3                                                                                       |
| 5   | "Behaviour on unparseable input: conservative"                                                  | 🌐     | Not verified                                                                                             |
| 6   | "`WhitespaceLinter.swift` is a separate mode that _reports_ rather than fixes"                  | ⚠      | Inferred from the file name                                                                              |
| 7   | "hard line length (default 100)"; "small JSON `.swift-format` file"                             | 🌐     | Not verified                                                                                             |
| 8   | "used by Xcode and SourceKit-LSP through the library API"                                       | 🌐     | Not verified                                                                                             |
| 9   | "`NewlineBehavior` … how blank-line policy is expressed inside the token stream"                | ◯      | Inferred from the `break` case's associated value                                                        |
| 10  | The "What this means for D" section                                                             | ◯      | Editorial, and the survey's main use of this page                                                        |

> [!WARNING]
> **Only one source file was read** (`Token.swift`, and only its `enum Token`). This page's value
> is the token model, which is solidly verified; everything about _behaviour_ is inference. The
> substrate claims (row 3) matter to [the proposal](../dmd-fmt-proposal.md)'s framing and rest on
> general knowledge plus one indirect attestation.

## Not verified here

- Every file except `Token.swift`; the whole SwiftSyntax project.
