# `sparkles:dmd-fmt`

A D formatter built on DMD's own lexer. It reads the token stream the compiler reads — comments and
whitespace included — and consults the parse tree only as a table of byte offsets, which is why it
formats files that do not parse and never has to guess where a comment belongs.

## What it does to your code

Two tiers, and the distinction is the whole design:

- **The layout tier is always on and changes no tokens.** Your line breaks are yours; indentation,
  horizontal whitespace and blank-line runs are the formatter's. It is verified by token equality —
  lex the input and the output, compare every non-whitespace token — so it cannot silently change
  your program.
- **The rewrite tier may add, remove or respell tokens** — trailing commas, import order, string
  literal forms, brace style. Trailing-comma insertion is on by default; everything else is opt-in,
  and each rule ships with its own check because token equality cannot verify a rewrite.

Transformations that need to know _types_ — turning `format("%s", x)` into an interpolated string,
say — are not the formatter's job at all. Those are [codemods](../../specs/dmd-fmt/codemods.md), a
separate tool built on this one.

## Reference

- **[Layout decisions](./reference/decisions/layout.md)** — every decision the layout tier makes,
  with a before/after for each. The examples are executed by the test suite, so they cannot drift
  from the implementation.

## Configuration

Discovered from `.editorconfig`, honouring dfmt's key names so an existing project's configuration
keeps working:

| Key                         | Default | Meaning                          |
| --------------------------- | ------- | -------------------------------- |
| `indent_style`              | `space` | Spaces or tabs.                  |
| `indent_size`               | `4`     | Columns per indentation level.   |
| `tab_width`                 | `4`     | Columns a tab advances.          |
| `dfmt_soft_max_line_length` | `120`   | The width wrapping targets.      |
| `max_line_length`           | `120`   | Accepted for dfmt compatibility. |
| `insert_final_newline`      | `true`  | Guarantee one trailing newline.  |

Unrecognised keys — including the `dfmt_*` style options not implemented yet — are ignored, which
is the documented migration posture rather than an oversight.

## Escape hatches

`// dfmt off` … `// dfmt on` ranges are emitted byte-for-byte, and so are `asm { … }` bodies,
`#line`/shebang directives, the `__EOF__` tail, and every single-token construct (`q{}`, delimited
and hex strings, interpolated literals, comments — no reflow, DDoc included).

## Design documents

- [M0 decision record](../../specs/dmd-fmt/index.md) — architecture, latency budget, scope (`D9`)
- [Testing & decision documentation](../../specs/dmd-fmt/testing.md) — why the reference pages here
  are also the test fixtures
- [Codemod roadmap](../../specs/dmd-fmt/codemods.md) — where type-aware transformation lives
- [The decision inventory](../../research/code-formatting/prettier-decisions.md) — 160 catalogued
  formatting decisions, each scored for D
- [The code-formatting survey](../../research/code-formatting/index.md) — the research this is built on
