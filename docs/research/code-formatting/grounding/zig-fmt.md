# Grounding ledger — zig-fmt.md

Verification against `$REPOS/zig/zig` @ `1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa` (tag `0.16.0`).

## Verified verbatim (✓)

| Claim                                                                                                                                                                                                       | Source                                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `isOneLineFnProto` in full — trailing comma / comment / doc-comment force multi-line, **no width test**                                                                                                     | `lib/std/zig/Ast/Render.zig:1722-1741`        |
| `const indent_delta = 4; const asm_indent_delta = 2;`                                                                                                                                                       | `Render.zig:18-19`                            |
| The `Render` struct fields (`gpa`, `ais`, `tree`, `fixups`)                                                                                                                                                 | `Render.zig:13-16`                            |
| `pub fn renderTree(gpa, w, tree, fixups)`; the `Fixups` field names (`omit_nodes`, `gut_functions`, `unused_var_decls`, `replace_nodes_with_string`, `replace_nodes_with_node`, `append_string_after_node`) | `Render.zig:86-94, 149-222, 317-321, 934-938` |
| The array-literal column-alignment excerpt ("Determine the width of each column")                                                                                                                           | `Render.zig:2239-2250`                        |
| `hasComment(tree, from, to)` is a token-range predicate                                                                                                                                                     | `Render.zig:449, 817, 825`                    |
| File sizes (`Render.zig` 3,507; `Ast.zig` 4,013; `src/fmt.zig` 377)                                                                                                                                         | `wc -l`                                       |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                             | Status | Note                                                                                                                                                                                                  |
| --- | --------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "**no page-width constant in the formatter**"                                     | ✓⚠     | `grep -c 'column\|max_line\|line_length\|width'` = 19 hits in `Render.zig`, **all inspected** and all in the array-literal alignment code. As strong as a negative claim gets, but it is still a grep |
| 2   | The `const x = Foo{ … }` before/after example                                     | ◯      | **Constructed by the survey** to illustrate the rule, not taken from zig's tests or docs                                                                                                              |
| 3   | "There is no configuration type, no options struct, no config file"               | ⚠      | Negative claim from `Render.zig` + `src/fmt.zig`; the CLI was not fully read                                                                                                                          |
| 4   | "`zig fmt` with `--check`"                                                        | ⚠      | Not verified in `src/fmt.zig`                                                                                                                                                                         |
| 5   | "Behaviour on unparseable input: refuses"                                         | ⚠      | Inferred; not traced                                                                                                                                                                                  |
| 6   | "the rendering back end for compiler-driven source edits"                         | ◯      | Inferred from `Fixups`' field names; no source says this                                                                                                                                              |
| 7   | "Comments force multi-line rendering **wherever they appear inside a construct**" | ⚠      | Verified for `isOneLineFnProto` and observed at three other `hasComment` sites. Generalizing to _all_ constructs is the survey's                                                                      |
| 8   | "Deleting a trailing comma is a layout change with no semantic signal"            | ◯      | Editorial, though it follows from row 1 of the trade-off table                                                                                                                                        |
| 9   | The "What a D formatter should take / not take" section                           | ◯      | Editorial                                                                                                                                                                                             |

## Not verified here

- `Render.zig` beyond `isOneLineFnProto`, the `Fixups` declarations, the alignment block and the
  `hasComment` call sites — roughly 3,300 of 3,507 lines unread.
- `Ast.zig`, `src/fmt.zig`.
