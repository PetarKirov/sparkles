# `bazel query` and `glob()` (Bazel / Java)

Two languages from one build system, chosen for opposite reasons: `bazel query`
is the field's counter-example on precedence, and `glob()` is the purest
specimen of the ordered-rule model pretending to be a function.

|                   |                                                                   |
| ----------------- | ----------------------------------------------------------------- |
| Language          | Java (engine), Starlark (`glob()` surface)                        |
| License           | Apache-2.0                                                        |
| Repository        | [bazelbuild/bazel][bz-repo]                                       |
| Surveyed revision | [`7c3d22ad`][bz-parser] (all file/line citations pin this commit) |
| Category          | Build-graph query language; build-file file selection             |
| Composition model | Set algebra (query); ordered include/exclude lists (`glob()`)     |
| Grammar           | LL(1) recursive descent                                           |

## Overview

### What it solves

`bazel query` names sets of **targets** — `deps(//foo) except //third_party/...`
— for tooling, CI sharding and dependency audits. `glob()` names sets of
**source files** inside one package, and is the only file-selection construct a
`BUILD` file has.

### Design philosophy

Query's algebra is deliberately ASCII-and-words: every operator has a symbolic
and a word spelling, because the language is typed both into shells (where
symbols are awkward) and into scripts (where words read better).

`glob()`'s philosophy is the opposite of composition — it is a leaf that
produces a list, and lists are combined by Starlark's `+`, not by a set algebra.

## How it works

The grammar is stated in the parser's own header comment:

```
expr ::= WORD
       | LET WORD = expr IN expr
       | '(' expr ')'
       | WORD '(' expr ( ',' expr ) * ')'
       | expr INTERSECT expr
       | expr '^' expr
       | expr UNION expr
       | expr '+' expr
       | expr EXCEPT expr
       | expr '-' expr
       | SET '(' WORD * ')'
```

— [`QueryParser.java`][bz-parser]

and the precedence is one line of code and one comment:

```java
private QueryExpression parseExpression() throws QuerySyntaxException {
  // All operators are left-associative and of equal precedence.
  return parseBinaryOperatorTail(parsePrimary());
}
```

— [`QueryParser.java`][bz-parser]

## Analysis

### 1. Composition model

**Query**: full set algebra minus complement — `intersect`/`^`,
`union`/`+`, `except`/`-`, with `let … in …` for sharing and `set(…)` for
literals. There is no unary complement, because the universe of targets is
unbounded until a `deps()`/`rdeps()` root is named; that is structurally the
same reason a filesystem language cannot afford one.

**`glob()`**: ordered rules.

> Glob returns a new, mutable, sorted list of every file in the current package
> that:
>
> - Matches at least one pattern in `include`.
> - Does not match any of the patterns in `exclude` (default `[]`).
>
> — [`StarlarkNativeModuleApi.java`][bz-glob]

Two lists, one subtracted from the other. Intersection is inexpressible; the
idiom is to nest calls or intersect the resulting Starlark lists by hand.

### 2. Operator surface & precedence

Dual spellings, one precedence level:

| Symbol | Word        | Meaning      |
| ------ | ----------- | ------------ |
| `^`    | `intersect` | intersection |
| `+`    | `union`     | union        |
| `-`    | `except`    | difference   |

Everything left-associative and equal, which means `a + b ^ c` is `(a + b) ^ c`
— the reverse of what a reader schooled on [jj][jj] or [Mercurial][hg] (or on
boolean algebra) expects. The flat table is trivially implementable and,
because every operator is a set operation of the same arity, never produces a
type error — it produces a silently different set. It is the clearest argument
in the survey for spending the extra Pratt level.

### 3. Primary vocabulary & the kind namespace

There is no `kind:` namespace at all: a bare `WORD` is a target pattern
(`//foo:bar`, `//foo/...`), and every non-pattern primary is a **function** —
`deps()`, `rdeps()`, `kind()`, `attr()`, `filter()`, `somepath()`,
`tests()`, `labels()`, `visible()`. Unknown function names produce a
candidate list:

```java
buf.append("unknown function '").append(token).append("' at '")…
   .append("'; expected one of ['")
   .append(functions.keySet().stream().sorted().collect(joining("', '")));
```

— [`QueryParser.java`][bz-parser]

Bazel can get away with bare words because a target pattern is _already_
lexically distinctive (`//`, `:`, `...`), which is exactly the property a bare
filesystem path lacks.

### 4. Anchoring & glob semantics

`glob()` is anchored to the package directory and cannot escape it — a pattern
may not contain `..` and may not cross into a subpackage. `*` does not cross
`/`; `**` does. `exclude_directories` defaults to `1`, so directories are not
members: the same "a fileset is a set of files" stance
[nixpkgs][nix] argues at length.

### 5. Lexis: quoting, escaping, reserved characters

Query words are shell-quoted in practice; the lexer treats quoted strings as
single WORDs. `glob()` patterns are Starlark string literals, so escaping is
Starlark's, not the glob's — a clean separation, and the reason `glob()` needs
no escaping rules of its own.

### 6. Evaluation strategy & pruning

Query is evaluated over a loaded target graph with a streaming
`QueryExpression` visitor. `glob()` is the interesting one: it is evaluated
during package loading, prefetched, and **an empty result is an error by
default**:

> Whether we allow glob patterns to match nothing. If `allow_empty` is False,
> each individual include pattern must match something and also the final
> result must be non-empty (after the matches of the `exclude` patterns are
> excluded).
>
> — [`StarlarkNativeModuleApi.java`][bz-glob]

with the failure message

> `'…' didn't match anything, but allow_empty is set to False (the default value)`
>
> — [`GlobberUtils.java`][bz-globber]

This is the strongest precedent in the survey for treating emptiness as a
**defect rather than a result** — and it is the dynamic, post-I/O version of
the check a literal-path-prefix lattice can make statically.

## Strengths

- Dual spellings make one language readable in both a shell and a script.
- Unknown-function errors list the candidates.
- `allow_empty = False` catches the commonest build-file bug (a renamed
  directory) at load time rather than as a mysteriously smaller target.
- `glob()`'s patterns are ordinary string literals, so the escaping question
  never arises.

## Weaknesses

- One precedence level for three set operators: `a + b ^ c` is silently
  `(a + b) ^ c`.
- `glob()` cannot intersect, cannot reference another glob, and cannot leave
  the package — three separate reasons a `BUILD` file ends up with generated
  file lists.
- The two languages share a build system but not a grammar, an operator set or
  a precedence rule.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                             | Trade-off                                                   |
| --------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------- |
| Flat, left-associative precedence             | One-line parser; no operator can be a type error      | `a + b ^ c` means something other than it reads             |
| Symbol **and** word operators                 | Shell ergonomics vs script readability                | Six tokens for three operations                             |
| Bare `WORD` primaries, functions for the rest | Target patterns are lexically distinctive already     | The trick does not transfer to bare filesystem paths        |
| `glob()` is include/exclude lists             | Trivially explainable; matches `.gitignore` intuition | No intersection, no composition, no reference to other sets |
| `allow_empty = False` by default              | A glob that matches nothing is nearly always a typo   | Legitimate empty globs need an explicit opt-in              |

## Sources

- [`QueryParser.java`][bz-parser] — the grammar comment, the precedence line and the unknown-function error (quoted above).
- [`Lexer.java`][bz-lexer] — `BINARY_OPERATORS` and the keyword table.
- [`StarlarkNativeModuleApi.java`][bz-glob] — the `glob()` contract (quoted above).
- [`GlobberUtils.java`][bz-globber] — the empty-glob error text.

<!-- References -->

[bz-repo]: https://github.com/bazelbuild/bazel
[bz-parser]: https://github.com/bazelbuild/bazel/blob/7c3d22ada1487e275c7f4669d6e2ee4563506af9/src/main/java/com/google/devtools/build/lib/query2/engine/QueryParser.java
[bz-lexer]: https://github.com/bazelbuild/bazel/blob/7c3d22ada1487e275c7f4669d6e2ee4563506af9/src/main/java/com/google/devtools/build/lib/query2/engine/Lexer.java
[bz-glob]: https://github.com/bazelbuild/bazel/blob/7c3d22ada1487e275c7f4669d6e2ee4563506af9/src/main/java/com/google/devtools/build/lib/starlarkbuildapi/StarlarkNativeModuleApi.java
[bz-globber]: https://github.com/bazelbuild/bazel/blob/7c3d22ada1487e275c7f4669d6e2ee4563506af9/src/main/java/com/google/devtools/build/lib/packages/GlobberUtils.java
[jj]: ./jj-filesets.md
[hg]: ./mercurial-filesets.md
[nix]: ./nixpkgs-fileset.md
