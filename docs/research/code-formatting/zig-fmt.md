# zig fmt (Zig)

The formatter whose line-breaking decision is made **by the author, one bit at a time, using a
trailing comma**. `zig fmt` has no column limit and no `fits` test; whether a construct renders
on one line or one-item-per-line is determined by whether the source has a trailing comma before
the closing delimiter — and by whether a comment is present. It is the most extreme version of
the [author's-breaks-preserved paradigm][concepts-break], and the cleanest demonstration that a
formatter can be fully deterministic and fully opinionated while making almost no layout
decisions of its own.

|                     |                                                               |
| ------------------- | ------------------------------------------------------------- |
| **Language**        | Zig                                                           |
| **License**         | MIT                                                           |
| **Repository**      | [`ziglang/zig`][repo] @ `1bcd8d9f` (tag `0.16.0`, 2026-06-02) |
| **Layout engine**   | `lib/std/zig/Ast/Render.zig` (3,507 lines) — a single file    |
| **Supporting**      | `lib/std/zig/Ast.zig` (4,013) · driver `src/fmt.zig` (377)    |
| **Category**        | full AST + token index · source-hint breaking · zero options  |
| **Layout paradigm** | source-hint (trailing comma decides)                          |

---

## Overview

### What it solves

Zig's position is that the formatter should be _predictable_ and the author should retain
control over vertical structure, without the formatter needing a width model, a cost model, or a
search. The mechanism is a single, learnable rule: **a trailing comma means "explode this"**.

```zig
const x = Foo{ .a = 1, .b = 2 };     // stays on one line

const y = Foo{
    .a = 1,
    .b = 2,                          // trailing comma → one field per line, forever
};
```

The rule is implemented, not inferred. `isOneLineFnProto` is the decision for a function
signature and it reads exactly as described:

```zig
fn isOneLineFnProto(tree: Ast, fn_proto: Ast.full.FnProto,
                    lparen: Ast.TokenIndex, rparen: Ast.TokenIndex) bool {
    const trailing_comma = tree.tokenTag(rparen - 1) == .comma;
    if (trailing_comma or hasComment(tree, lparen, rparen))
        return false;
    …
    return !hasDocComment(tree, after_last_param, rparen);
}
```

— [`lib/std/zig/Ast/Render.zig`][render]

Three conditions force multi-line, and **none of them is width**: a trailing comma, an ordinary
comment inside the parens, or a doc comment. There is no measurement anywhere in that function
because there is no measurement anywhere in the formatter.

### Design philosophy

Indentation is a compile-time constant:

```zig
const indent_delta = 4;
const asm_indent_delta = 2;
```

— [`Render.zig`][render]

There is no configuration type, no options struct, no config file. The philosophy is the same as
[gofmt][gofmt]'s — end the debate — reached by a different route: gofmt preserves the author's
newlines wholesale, zig fmt asks the author for **one bit per construct** and derives everything
else.

---

## How it works

### `AutoIndentingStream`

Rendering is a direct AST walk (`renderExpression`, `renderFnProto`, …) writing into an
`AutoIndentingStream` that tracks indentation with `pushIndent`/`popIndent` and can
`insertNewline`. There is no intermediate document: the tree is walked once and bytes come out.
That makes zig fmt the simplest architecture in wave 1 — one file, one pass, no IR.

Each render call takes a `Space` parameter (`.none`, `.space`, `.newline`, `.comma`, …) telling
it what to emit after the token, which is how spacing policy is expressed without a
[whitespace alphabet][gofmt] or a `Doc`.

### The one place width appears

`grep` for `column`/`width` in `Render.zig` finds nineteen hits, and **all of them are about
aligning the columns of a multi-line array literal** — computing `col_widths` across a "section"
of rows so a grid-shaped literal lines up:

```zig
// Determine the width of each column
var col_widths = try gpa.alloc(usize, row_size);
```

— [`Render.zig`][render]

That is alignment, not line breaking. There is no page-width constant in the formatter.

### `Fixups` — the formatter as an edit channel

`renderTree` takes a `Fixups` struct that lets a caller inject semantic edits during rendering:
`omit_nodes`, `gut_functions`, `unused_var_decls` (insert `_ = foo;`),
`replace_nodes_with_string`, `replace_nodes_with_node`, `append_string_after_node`.

This is unusual and worth noting: zig fmt is not only a formatter but the **rendering back end
for compiler-driven source edits**, which is how `zig fmt`-adjacent tooling applies fixes. For a
D formatter the analogous question is whether the printer should be reusable by a future
refactoring or `dfix`-style tool — see [layout preservation][layout-preserving], where that is
the _original_ motivation for the whole family.

---

## 1. Input model & fidelity

**A full AST with token indices.** `Ast.zig` keeps a token array alongside the tree, and render
functions address tokens by index (`tree.tokenTag(rparen - 1)`) — so the renderer can ask
questions about the _source token stream_, which is exactly how the trailing-comma rule is
implementable. This is a middle position between [dfmt][dfmt]'s pure token stream and a bare AST,
and it is the minimum a source-hint formatter needs.

**Comments** are reachable via `hasComment(tree, from, to)` — a token-range predicate rather than
an attachment.

**Behaviour on unparseable input:** refuses; the AST must parse.

## 2. Layout IR & break decision

**Paradigm: source-hint.** No IR, no `fits`, no cost, no search. The decision procedure per
construct is a boolean derived from the token stream.

**Width policy: none.** A long single-line call stays long. Combined with the trailing-comma
rule, the author's remedy is to add a comma — which is a genuinely different social contract from
every other formatter here: **the tool does not wrap for you; it makes your decision permanent.**

## 3. Alignment, indentation & vertical rhythm

`indent_delta = 4` (2 inside `asm`), spaces. Array-literal column alignment is the one real
alignment feature, computed per section (above). Blank-line handling is part of the render walk.

## 4. Comments, trivia & preservation

Comments force multi-line rendering wherever they appear inside a construct — a deliberate
simplification that sidesteps most of [the attachment problem][attachment] by refusing to make
any layout decision in a comment's vicinity. No comment reflow. Doc comments (`///`) are likewise
a multi-line trigger.

## 5. Configurability, opinionation & config discovery

**Zero options.** `indent_delta` is a `const`. No config file, no discovery, nothing to migrate.

## 6. Integration surface & output contract

**Whole document.** `zig fmt` with `--check`; no range formatting, no on-type, no cursor. The
`Fixups` mechanism is an _input_ channel, not an edit-output contract.

---

## Strengths

- **Radically simple** — one 3,507-line file, one pass, no IR, no search, no measurement.
- **Perfectly predictable.** A reader can state the rule in one sentence and always be right.
- **Zero options**, with no config machinery to maintain.
- **The author keeps control of vertical structure** with a one-character signal.
- **Minimal diffs**: layout is a function of the author's own commas, so reformatting is a no-op
  for anyone already using the tool.
- **Fast** — no backtracking, no re-measurement.

## Weaknesses

- **Cannot make anything fit.** Same objection as [gofmt][gofmt], and for the same reason.
- **The rule is load-bearing punctuation.** Deleting a trailing comma is a layout change with no
  semantic signal; a careless edit silently collapses a list.
- **Comments force expansion**, which can be surprising — adding a `//` inside a call rewrites the
  call's layout.
- **Refuses invalid input.**
- **No range formatting, cursor, or edit output.**

---

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                                        | Trade-off                                                                              |
| ----------------------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Trailing comma decides** one-line vs exploded | One learnable rule; the author keeps control; the formatter needs no width model | Layout depends on punctuation with no other meaning; deleting a comma is a layout edit |
| **A comment forces multi-line**                 | Avoids every hard case where a comment interacts with a break decision           | Adding a comment reformats the construct around it                                     |
| **No column limit at all**                      | Removes the entire line-breaking problem                                         | Long lines stay long                                                                   |
| **`indent_delta` as a `const`**                 | Zero options, zero config machinery                                              | Nothing adapts to an existing codebase's conventions                                   |
| **Direct AST walk**, no intermediate document   | Simplest possible architecture; one file                                         | No reusable layout engine; every construct's policy is hand-written                    |
| **Token indices alongside the tree**            | Lets the renderer read source hints (commas, comments) the AST does not carry    | The renderer is coupled to token positions, so tree edits must keep them consistent    |
| **`Fixups` as a render-time edit channel**      | One renderer serves formatting _and_ compiler-driven source fixes                | Rendering and rewriting are entangled in one API                                       |

---

## What a D formatter should take

**Take seriously:** the trailing-comma signal. It is the highest-value-per-line idea in wave 1 —
[black's magic trailing comma][concepts-break] is the same mechanism — and it costs almost
nothing to implement on a token spine. A D formatter that otherwise wraps by width can still
honour "the author wrote a trailing comma, so keep this exploded".

**Do not take:** the absence of a width limit, or "a comment forces multi-line". The first is
discussed under [gofmt][gofmt]; the second is affordable in Zig's grammar and would be too blunt
for D, where a trailing `//` comment on a parameter is idiomatic.

---

## Sources

- [`ziglang/zig`][repo] @ `1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa` (tag `0.16.0`):
  `lib/std/zig/Ast/Render.zig` (3,507), `lib/std/zig/Ast.zig` (4,013), `src/fmt.zig` (377)

**Related deep-dives in this tree:**
[Concepts][concepts] · [gofmt][gofmt] · [dfmt][dfmt] · [Layout preservation][layout-preserving] ·
[Comparison][comparison]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/ziglang/zig/tree/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa
[render]: https://github.com/ziglang/zig/blob/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/zig/Ast/Render.zig

<!-- Theory docs -->

[layout-preserving]: ./theory/layout-preserving.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[concepts-break]: ./concepts.md#5-line-breaking-vocabulary
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[comparison]: ./comparison.md

<!-- System deep-dives -->

[gofmt]: ./gofmt.md
[dfmt]: ./dfmt.md
