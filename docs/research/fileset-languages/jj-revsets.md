# jj revsets (Jujutsu / Rust)

The same algebra over commits instead of files — surveyed because it is the
_older_ of jj's two languages, because [filesets][jj-filesets] were built to
match it, and because it is the field's best worked example of extending a set
algebra with domain operators without breaking the algebra.

|                   |                                                                     |
| ----------------- | ------------------------------------------------------------------- |
| Language          | Rust                                                                |
| License           | Apache-2.0                                                          |
| Repository        | [jj-vcs/jj][jj-repo]                                                |
| Surveyed revision | [`88c3cd05`][revset-pest] (all file/line citations pin this commit) |
| Category          | VCS revision-selection language                                     |
| Composition model | Set algebra + graph operators                                       |
| Grammar           | [`lib/src/revset.pest`][revset-pest] + a `PrattParser`              |
| Ancestor          | Mercurial revsets                                                   |

## Overview

### What it solves

Naming a set of commits — `main..@`, `author(alice) & ~empty()` — in one
language shared by `log`, `rebase`, `abandon` and every other command that
takes revisions.

### Design philosophy

The set algebra is the substrate; everything domain-specific is either a
**function** (`author()`, `description()`, `heads()`) or a **graph operator**
whose precedence is tighter than the set operators. The result is that a user
who knows `& | ~` can read any revset, and the graph operators compose into it
rather than replacing it.

## How it works

The Pratt table is the filesets table with four more levels stacked on top:

```rust
PrattParser::new()
    .op(Op::infix(Rule::union_op, Assoc::Left)
        | Op::infix(Rule::compat_add_op, Assoc::Left))
    .op(Op::infix(Rule::intersection_op, Assoc::Left)
        | Op::infix(Rule::difference_op, Assoc::Left)
        | Op::infix(Rule::compat_sub_op, Assoc::Left))
    .op(Op::prefix(Rule::negate_op))
    // Ranges can't be nested without parentheses. Associativity doesn't matter.
    .op(Op::infix(Rule::dag_range_op, …) | Op::infix(Rule::range_op, …))
    .op(Op::prefix(Rule::dag_range_pre_op) | Op::prefix(Rule::range_pre_op))
    .op(Op::postfix(Rule::dag_range_post_op) | Op::postfix(Rule::range_post_op))
    // Neighbors
    .op(Op::postfix(Rule::parents_op) | Op::postfix(Rule::children_op))
```

— [`lib/src/revset_parser.rs`][revset-parser]

## Analysis

### 1. Composition model

Set algebra with complement, exactly as [filesets][jj-filesets], plus
`x::y` (DAG range), `x..y` (range), `x-`/`x+` (parents/children).

### 2. Operator surface & precedence

Seven levels, documented in the same words as the filesets page. The page also
carries the survey's clearest warning about **operators that do not distribute
over union**:

> The `..` operator does not distribute over union (`|`) on its left side. For
> example, `(A | B)..` is **not** equivalent to `A.. | B..`. … In fact,
> `(A | B).. = A.. & B..`.
>
> — [`docs/revsets.md`][revset-docs]

That is the failure mode any domain operator added to a set algebra must be
checked against, and it is why a file-selection language should keep its
non-path primaries as plain sets rather than as operators.

### 3. Primary vocabulary & the kind namespace

The same `p:x` pattern form as filesets, over _strings_ rather than paths:

> By default, `"string"` is parsed as a `glob:` pattern.
>
> - `exact:"string"`, `glob:"pattern"`, `regex:"pattern"`, `substring:"string"`
>
> — [`docs/revsets.md`][revset-docs]

So one prefix namespace serves two languages with disjoint kind tables, and a
kind name is never a bare word in either.

### 4. Anchoring & glob semantics

Not applicable — the universe is commits, not paths.

### 5. Lexis: quoting, escaping, reserved characters

Shared with filesets: the same string literals, raw strings and
`strict_identifier` shape.

Revsets add a **compatibility layer** worth copying. Mercurial spells union and
difference `+` and `-`; jj accepts both tokens in the grammar
(`compat_add_op = { "+" }`, `compat_sub_op = { "-" }` in
[`lib/src/revset.pest`][revset-pest]) purely so it can reject them with a
targeted message rather than a syntax error:

```rust
Rule::compat_add_op => Err(not_infix_op(&op, "|", "union"))?,
Rule::compat_sub_op => Err(not_infix_op(&op, "~", "difference"))?,
```

producing `` `+` is not an infix operator `` with `similar_op: "|"` and
`description: "union"` attached — [`lib/src/revset_parser.rs`][revset-parser].
The general shape,

```rust
#[error("`{op}` is not a prefix operator")]
NotPrefixOperator  { op: String, similar_op: String, description: String },
NotPostfixOperator { … },
NotInfixOperator   { … },
```

is the template for **retiring a spelling without silently changing its
meaning**: keep the token in the grammar, give it a position-specific error
that names the replacement.

### 6. Evaluation strategy & pruning

Revsets are optimised as an expression tree (`lib/src/revset.rs` folds
intersections into the index walk) but, like filesets, never compile to a
_filesystem_ plan. Complement is affordable for the same reason.

## Strengths

- One algebra, many domain operators, with the algebra unchanged.
- Explicit, documented non-distributivity instead of a silently wrong result.
- Deliberate error-only tokens for a foreign dialect's spellings.

## Weaknesses

- Seven precedence levels is a lot to hold in the head; `::` and `..` in prefix,
  infix and postfix positions is genuinely hard to read.
- The `~` overload (prefix complement, infix difference) is inherited by
  filesets.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                | Trade-off                                 |
| ----------------------------------------------- | -------------------------------------------------------- | ----------------------------------------- |
| Graph operators bind tighter than set operators | `::x & y` reads as `(::x) & y`, the common intent        | More levels to document                   |
| Domain selectors are functions, not operators   | They stay plain sets, so distributivity is never at risk | `author(alice)` is wordier than `a:alice` |
| Foreign spellings kept as error-only tokens     | A Mercurial user gets a hint, not "syntax error"         | Two dead tokens permanently reserved      |

## Sources

- [`lib/src/revset.pest`][revset-pest] — the grammar, including `compat_*` tokens.
- [`lib/src/revset_parser.rs`][revset-parser] — the Pratt table and the positional error enum.
- [`docs/revsets.md`][revset-docs] — precedence and the non-distributivity note (quoted above).

<!-- References -->

[jj-repo]: https://github.com/jj-vcs/jj
[revset-pest]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/lib/src/revset.pest
[revset-parser]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/lib/src/revset_parser.rs
[revset-docs]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/docs/revsets.md
[jj-filesets]: ./jj-filesets.md
