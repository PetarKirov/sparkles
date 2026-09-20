# jj filesets (Jujutsu / Rust)

The closest living relative of the language this survey is designing: an infix
set algebra over file patterns, with the operators we want, a prefix namespace
we can borrow, and the one operator we cannot afford.

|                   |                                                                             |
| ----------------- | --------------------------------------------------------------------------- |
| Language          | Rust                                                                        |
| License           | Apache-2.0                                                                  |
| Repository        | [jj-vcs/jj][jj-repo]                                                        |
| Surveyed revision | [`88c3cd05`][jj-pest] (all file/line citations pin this commit)             |
| Category          | VCS file-selection language                                                 |
| Composition model | Set algebra (union / intersection / difference / complement)                |
| Grammar           | [`lib/src/fileset.pest`][jj-pest], PEG via `pest` + a `PrattParser`         |
| Sibling language  | [jj revsets][revsets] — same operators, same precedence, different universe |

## Overview

### What it solves

Selecting a set of files for `jj diff`, `jj split`, `jj file list` and friends,
without inventing a second syntax per command. The documentation states the
lineage plainly:

> Jujutsu supports a functional language for selecting a set of files.
> Expressions in this language are called "filesets" (the idea comes from
> [Mercurial](https://repo.mercurial-scm.org/hg/help/filesets)).
>
> — [`docs/filesets.md`][jj-docs]

### Design philosophy

One grammar, shared with [revsets], and a deliberate refusal to let the
_shape_ of a query depend on which command consumes it. The operators are
symbolic only — there is no `and`/`or`/`except` — and the pattern namespace is
open-ended, so a new selector is a new prefix rather than new syntax.

The second philosophical choice is that **a bare path means a subtree**. The
default pattern kind is `prefix-glob:`, not `glob:`:

> By default, `"path"` is parsed as a `prefix-glob:` pattern, which matches
> cwd-relative path prefix.
>
> — [`docs/filesets.md`][jj-docs]

so `jj diff src` means "src and everything under it", which is what a person
typing `src` means.

## How it works

The grammar is a PEG with a flat `expression` rule; precedence is imposed
afterwards by a Pratt table, so the `.pest` file itself says nothing about
binding power:

```pest
negate_op = { "~" }
union_op = { "|" }
intersection_op = { "&" }
difference_op = { "~" }
prefix_ops = _{ negate_op }
infix_ops = _{ union_op | intersection_op | difference_op }

expression = {
  (prefix_ops ~ whitespace*)* ~ primary
  ~ (whitespace* ~ infix_ops ~ whitespace* ~ (prefix_ops ~ whitespace*)* ~ primary)*
}
```

— [`lib/src/fileset.pest`][jj-pest]

Note that `~` is **both** the prefix complement and the infix difference; the
parser disambiguates by position. The Pratt table is three lines:

```rust
PrattParser::new()
    .op(Op::infix(Rule::union_op, Assoc::Left))
    .op(Op::infix(Rule::intersection_op, Assoc::Left)
        | Op::infix(Rule::difference_op, Assoc::Left))
    .op(Op::prefix(Rule::negate_op))
```

— [`lib/src/fileset_parser.rs`][jj-parser]

`pest`'s `PrattParser` takes operators weakest-first, so this reads: `|`
weakest, `&` and `~` sharing the next level, prefix `~` tightest.

## Analysis

### 1. Composition model

Full set algebra with a complement. `all()` and `none()` are the unit and zero,
supplied as **functions**, not bare words — which is forced, because a bare
`all` would be indistinguishable from a directory named `all`.

### 2. Operator surface & precedence

Symbols only. The documented precedence is exactly the one
[`recommendations`][rec] adopts:

> Operators are listed in order of binding power from strongest to weakest, e.g.
> `x | y & z` is interpreted as `x | (y & z)` since `&` has stronger binding
> power than `|`. Infix operators of the same binding power are parsed from left
> to right, e.g. `x ~ y & z` is interpreted as `(x ~ y) & z`.
>
> — [`docs/filesets.md`][jj-docs]

There is **no implicit operator**: two juxtaposed patterns are a syntax error,
not a conjunction.

### 3. Primary vocabulary & the kind namespace

`pattern = strict_identifier ~ ":" ~ primary`, where `strict_identifier` is
alphanumeric-and-underscore runs joined by hyphens. The shipped kinds form a
three-axis product — root (`cwd-` / `root-`) × granularity (bare prefix /
`file` / `glob` / `prefix-glob`) × case (`-i`):

| Kind                                                  | Meaning                                         |
| ----------------------------------------------------- | ----------------------------------------------- |
| `cwd:` (the default)                                  | cwd-relative path **prefix** — file, or subtree |
| `file:` / `cwd-file:`                                 | cwd-relative exact path                         |
| `glob:` / `cwd-glob:`                                 | cwd-relative glob, non-recursive                |
| `prefix-glob:`                                        | `glob:"p"` ∪ `glob:"p/**"`                      |
| `root:` `root-file:` `root-glob:` `root-prefix-glob:` | the same four, workspace-relative               |
| any of the globs + `-i`                               | case-insensitive (`glob-i:"*.TXT"`)             |

The critical structural point: **the kind is lexically outside the quotes.**
`pattern = strict_identifier ~ pattern_kind_op ~ primary` requires the kind to
be a bare identifier, so `"foo:bar"` is a path named `foo:bar` and no escape is
needed to write one.

### 4. Anchoring & glob semantics

Root-anchored, never floating. `glob:"*.c"` matches `.c` files in the current
directory only; recursion is spelled `**`. The prefix-closure question is
answered by making closure the _default_ and non-closure the named kind.

### 5. Lexis: quoting, escaping, reserved characters

jj uses a **positive** bare-token charset rather than a list of terminators:

```pest
identifier = @{
  (XID_CONTINUE | "+" | "-" | "." | "@" | "_" | "*" | "?" | "[" | "]" | "/" | "\\")+
}
```

Anything outside it must be quoted, and the documentation says so with the
exact ergonomic carve-out a CLI needs:

> File names passed to these commands must be quoted if they contain whitespace
> or meta characters. However, as a special case, quotes can be omitted if the
> expression has no operators nor function calls.
>
> — [`docs/filesets.md`][jj-docs]

That carve-out is implemented as a **parse-failure fallback**: the entry point
is `program_or_bare_string`, whose grammar tries the expression production
first and falls back to treating the whole input as one bare string
([`lib/src/fileset.pest`][jj-pest], used by
[`lib/src/fileset.rs`][jj-fileset]).

Two escaping notes: `\` is bare-legal because jj accepts it as a Windows path
separator, and string literals support C-style escapes (`\t`, `\n`, `\x41`),
with `'...'` raw strings as the no-escape form.

### 6. Evaluation strategy & pruning

jj matches against a materialised tree, so it never needs a traversal plan and
can afford `~x` freely. There is no literal-path-prefix analysis and none is
needed. This is the single structural difference from the language this survey
informs, and the reason a decision jj gets for free costs us pruning.

### Aliases

Named bindings live in configuration, not in the grammar:

```toml
[fileset-aliases]
LOCK = '**/Cargo.lock | **/package-lock.json | **/uv.lock'
'not:x' = '~x'
```

— [`docs/filesets.md`][jj-docs]

Aliases may be symbols, functions **or** `<name>:<value>` patterns, are
expanded as an AST transform after parsing, and recursion is caught explicitly
(`RecursiveAlias` in [`FilesetParseErrorKind`][jj-parser]). The expansion
carries a diagnostic frame — `InAliasExpansion(name)` — so an error inside an
alias reports both spans.

### Diagnostics

```rust
#[error("Syntax error")]                       SyntaxError,
#[error("Function `{name}` doesn't exist")]    NoSuchFunction { name, candidates },
#[error("Function `{name}`: {message}")]       InvalidArguments { name, message },
#[error("In alias `{0}`")]                     InAliasExpansion(String),
#[error("Alias `{0}` expanded recursively")]   RecursiveAlias(String),
```

— [`lib/src/fileset_parser.rs`][jj-parser]

plus, from the evaluator, `Invalid file pattern kind `{0}:`` —
[`lib/src/fileset.rs`][jj-fileset]. The `candidates`field on`NoSuchFunction`is the did-you-mean list; every error carries a`pest::Span` so the CLI can
render a caret.

## Strengths

- One grammar for two languages ([revsets] is the same operator table), so a
  user learns the algebra once.
- The kind namespace is open and the kind sits outside the quotes, so no path
  ever needs a `\:`.
- `prefix-glob:` as the default is the single best ergonomic decision in the
  survey — it makes the obvious input (`src`) mean the obvious thing.
- Errors carry spans, alias frames and candidate lists.

## Weaknesses

- `~` doing double duty as complement and difference means `a ~b` and `a ~ b`
  differ only by a space to the eye, though not to the parser.
- The bare-string fallback makes a query's _meaning_ depend on whether it
  parses: adding a stray `(` silently reinterprets the whole input as a
  filename.
- The kind product is multiplying (`root-prefix-glob-i:`); there is no
  modifier-set form like git's `:(glob,icase)`.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                   | Trade-off                                                  |
| ------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------- |
| Symbols only, no `and`/`or`                 | Shell quoting is needed anyway; no directory names reserved | Less readable in a config file than Mercurial's word form  |
| `&`/`~` bind tighter than `\|`              | Matches boolean-algebra intuition                           | Differs from [`bazel query`][bazel], which is flat         |
| Prefix `~` complement                       | Cheap over a materialised manifest                          | No literal prefix — fatal for a language that plans a walk |
| Default kind is `prefix-glob:`              | `src` means the subtree, as a person expects                | A user wanting the exact entry must name `file:`           |
| Kind outside the quotes                     | `"foo:bar"` needs no escape                                 | A kind can never be computed or quoted                     |
| Bare-string fallback instead of a delimiter | No syntax for the common single-path case                   | A typo changes the meaning instead of reporting an error   |
| Aliases in config, expanded post-parse      | Grammar stays a pure expression language                    | Alias errors need their own diagnostic frame               |

## Sources

- [`lib/src/fileset.pest`][jj-pest] — the grammar (quoted above).
- [`lib/src/fileset_parser.rs`][jj-parser] — the Pratt precedence table and the error enum.
- [`lib/src/fileset.rs`][jj-fileset] — pattern-kind resolution and `Invalid file pattern kind`.
- [`docs/filesets.md`][jj-docs] — the user-facing language reference (quoted above).

<!-- References -->

[jj-repo]: https://github.com/jj-vcs/jj
[jj-pest]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/lib/src/fileset.pest
[jj-parser]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/lib/src/fileset_parser.rs
[jj-fileset]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/lib/src/fileset.rs
[jj-docs]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/docs/filesets.md
[revsets]: ./jj-revsets.md
[bazel]: ./bazel.md
[rec]: ./recommendations.md
