# Grounding ledger — roslyn.md

Verification against `$REPOS/dotnet/roslyn` @ `e42c3902b0c0f922771e06b5222dadee92fb0e2e`.

## Verified verbatim (✓)

| Claim                                                                                                                                                                    | Source                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| The six `AbstractFormattingRule` virtual members, with signatures — four node-scoped `Add*Operations`, two token-pair `Get*Operation`, each taking a `next` continuation | `src/Workspaces/SharedUtilitiesAndExtensions/Compiler/Core/Formatting/Rules/AbstractFormattingRule.cs:23-53` |
| `HasLeadingTrivia`, `GetLeadingTrivia()`, `GetLeadingTriviaWidth()` on `SyntaxNodeOrToken`                                                                               | `src/Compilers/Core/Portable/Syntax/SyntaxNodeOrToken.cs:258, 353, 359-368`                                  |
| The **elastic trivia** definition, quoted in full                                                                                                                        | `docs/wiki/FAQ.md:308-309`                                                                                   |
| The `Rules/` directory contents (`Next*Action` continuation types, `NoOpFormattingRule`, `BaseIndentationFormattingRule`, `Operations/`)                                 | `ls .../Formatting/Rules/`                                                                                   |
| Directory line counts (Core `Formatting/` 8,078; CSharp `Formatting/` 7,075)                                                                                             | `wc -l`                                                                                                      |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                                     | Status | Note                                                                                                                                                                            |
| --- | --------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "**There is no place in this architecture where a width could be consulted**"                             | ◯⚠     | The survey's central claim about Roslyn, inferred from the six-member interface. `Engine/` was **not read**; a width-aware rule could in principle exist. Strong but not proven |
| 2   | "Roslyn does not wrap lines … the capability is not missing, it is unrepresentable"                       | ◯      | Same inference as row 1, stated more strongly                                                                                                                                   |
| 3   | "Output is `TextEdit[]`"                                                                                  | ⚠      | Consistent with the operation model and with IDE use; **the emit path was not read**                                                                                            |
| 4   | "Format selection / format on type / cursor preservation"                                                 | 🌐     | Well-known Visual Studio behaviour; **not verified in this repo**                                                                                                               |
| 5   | "`SyntaxTrivia` covers … **disabled text** — the contents of an inactive `#if` branch"                    | 🌐     | Roslyn design knowledge; not verified against source in this pass                                                                                                               |
| 6   | "red-green trees"                                                                                         | 🌐     | Not verified here; the term does not appear in the files read                                                                                                                   |
| 7   | "`SuppressOperation` … is how `#region`, disabled preprocessor branches and user selections are honoured" | ◯⚠     | `AddSuppressOperations` is verified; **what it is used for is inferred**                                                                                                        |
| 8   | "`.editorconfig` keys (`csharp_new_line_before_open_brace`, …)"                                           | 🌐     | Key names from general knowledge; not verified in-repo                                                                                                                          |
| 9   | "the same _outcome_ as gofmt reached by a completely different mechanism"                                 | ◯      | The survey's pairing                                                                                                                                                            |
| 10  | "~15,000 lines across core + C#"                                                                          | ✓      | 8,078 + 7,075 = 15,153                                                                                                                                                          |
| 11  | The three "What a D formatter should take" recommendations                                                | ◯      | Editorial                                                                                                                                                                       |

> [!WARNING]
> **This is the least source-verified deep-dive in wave 1.** Two files were read
> (`AbstractFormattingRule.cs`, `SyntaxNodeOrToken.cs`) plus one FAQ. The rule-chain interface and
> elastic trivia — the two ideas the page is really about — are solidly verified; almost everything
> else is inference or general knowledge. Rows 3–6 and 8 should be verified or softened before the
> tree is treated as complete.

## Not verified here

- `Engine/`, `Context/`, `TriviaEngine/`, and all of `CSharp/Formatting/`.
- Whether Roslyn ever breaks a line (row 1's negative claim).
