# Mercurial filesets & pattern prefixes (Python)

The original. Every fileset language in this survey descends from it — jj says
so in its own documentation — and it is still the only one that ships a
**cost-model optimiser** over the expression tree.

|                   |                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------- |
| Language          | Python                                                                                 |
| License           | GPL-2.0-or-later                                                                       |
| Repository        | [repo.mercurial-scm.org/hg][hg-repo]                                                   |
| Surveyed revision | tag `7.1` — [`mercurial/filesetlang.py`][hg-lang]                                      |
| Reproduce locally | `nix shell nixpkgs#mercurial -c hg help filesets` (all quoted help text is its output) |
| Category          | VCS file-selection language                                                            |
| Composition model | Set algebra (union / intersection / difference / complement)                           |
| Grammar           | Hand-written tokenizer + a table-driven Pratt parser                                   |

> [!NOTE]
> `repo.mercurial-scm.org` does not answer automated checkers (a direct
> `curl --max-time 35` returns nothing), so it carries a documented entry in the
> repository's shared `lychee.exclude`. Every quotation below is reproducible
> offline from the pinned Nixpkgs `mercurial` derivation with the command in the
> table.

## Overview

### What it solves

Selecting files by **properties a path does not carry** — status, size,
encoding, executable bit, content — and combining those with ordinary path
patterns:

> Mercurial supports a functional language for selecting a set of files.
> Like other file patterns, this pattern type is indicated by a prefix, `set:`.
> The language supports a number of predicates which are joined by infix
> operators. Parenthesis can be used for grouping.
>
> — `hg help filesets`

### Design philosophy

The fileset language is not a replacement for file patterns; it is **one more
pattern prefix**. `hg status "set:binary()"` reaches the expression language
through the same `kind:` mechanism that reaches `glob:` and `re:`. That is
Mercurial's answer to the delimiter problem: the expression language is opened
by a prefix and runs to the end of the argument.

## How it works

The whole precedence table is a dictionary of
`token: (binding-strength, primary, prefix, infix, suffix)`:

```python
elements = {
    b"(":      (20, None, (b"group", 1, b")"), (b"func", 1, b")"), None),
    b":":      (15, None, None, (b"kindpat", 15), None),
    b"-":      (5,  None, (b"negate", 19), (b"minus", 5), None),
    b"not":    (10, None, (b"not", 10), None, None),
    b"!":      (10, None, (b"not", 10), None, None),
    b"and":    (5,  None, None, (b"and", 5), None),
    b"&":      (5,  None, None, (b"and", 5), None),
    b"or":     (4,  None, None, (b"or", 4), None),
    b"|":      (4,  None, None, (b"or", 4), None),
    b"+":      (4,  None, None, (b"or", 4), None),
    b",":      (2,  None, None, (b"list", 2), None),
    …
}
globchars = b".*{}[]?/\\_"
```

— [`mercurial/filesetlang.py`][hg-lang]

## Analysis

### 1. Composition model

Set algebra with complement. Note that `-` (difference) shares binding strength
`5` with `and`, and `|`/`+`/`or` sit one level below at `4` — the same shape
[jj][jj] later adopted, derived independently.

### 2. Operator surface & precedence

Mercurial ships **both** word and symbol spellings for every operator:

> There is a single prefix operator: `not x` — Files not in x. Short form is `! x`.
>
> These are the supported infix operators:
> `x and y` … Short form is `x & y`.
> `x or y` … two alternative short forms: `x | y` and `x + y`.
> `x - y` — Files in x but not in y.
>
> — `hg help filesets`

The word forms are what make `set:hgignore() and not ignored()` readable in a
configuration file; the cost is that `and`, `or` and `not` become reserved
words, so a file literally named `or` must be quoted. The help text says so:

> Identifiers such as filenames or patterns must be quoted with single or
> double quotes if they contain characters outside of
> `[.*{}[]?/\_a-zA-Z0-9\x80-\xff]` **or if they match one of the predefined
> predicates**.
>
> — `hg help filesets`

Note also the asymmetry Mercurial tolerates and jj removed: there is a prefix
`not`/`!`, but the difference operator is `-`, not `~`. Prefix `-` exists in
the table at binding strength 19 purely for numeric literals and is a hard
error in a fileset position:

```python
if op == b'negate':
    raise error.ParseError(_(b"can't use negate operator in this context"))
```

— [`mercurial/filesetlang.py`][hg-lang]. The shape is worth keeping: **a token
that is syntactically accepted so it can be rejected with a specific message.**

### 3. Primary vocabulary & the kind namespace

Two disjoint vocabularies meet here, and the split is the most directly
transferable thing in this survey.

**Predicates** are functions — `added()`, `binary()`, `clean()`, `copied()`,
`encoding(name)`, `eol(style)`, `exec()`, `grep(regex)`, `hgignore()`,
`ignored()`, `missing()`, `modified()`, `portable()`, `removed()`,
`resolved()`, `revs(revs, pattern)`, `size(expression)`, `status(base, rev,
pattern)`, `subrepo([pattern])`, `symlink()`, `tracked()`, `unknown()`,
`unresolved()` — never bare words used as sets.

**Pattern kinds** are prefixes, and the list is the widest in the field:

| Prefix                         | Meaning                                                           |
| ------------------------------ | ----------------------------------------------------------------- |
| `path:`                        | verbatim path from the repo root; a directory matches recursively |
| `filepath:`                    | exactly one file, repo-root-relative                              |
| `rootfilesin:`                 | files directly in a directory, **not** its subdirectories         |
| `glob:` / `rootglob:`          | extended glob, cwd-rooted / repo-root-rooted                      |
| `relpath:` `relglob:` `relre:` | the "match anywhere below" variants                               |
| `re:`                          | Python regexp, anchored at the repo root                          |
| `listfile:` `listfile0:`       | read patterns from a file (LF- or NUL-delimited)                  |
| `include:` `subinclude:`       | read a whole rule file and splice it in                           |
| `set:`                         | **the fileset expression language itself**                        |

— `hg help patterns`

Two observations. First, the kind namespace is a plain lowercase word plus a
colon, and one member contains a digit (`listfile0:`), so a `^[a-z]+:` shape
would already be too narrow. Second, `set:` proves a kind prefix can open a
_sub-language_, which is the cheapest possible delimiter.

### 4. Anchoring & glob semantics

Strictly anchored, and Mercurial is explicit that this is a deliberate contrast
with its own ignore files:

> To use an extended glob, start a name with `glob:`. Globs are rooted at the
> current directory; a glob such as `*.c` will only match files in the current
> directory ending with `.c`. `rootglob:` can be used instead of `glob:` for a
> glob that is rooted at the root of the repository.
>
> The supported glob syntax extensions are `**` to match any string across path
> separators and `{a,b}` to mean "a or b".
>
> — `hg help patterns`

versus, on the same page:

> Note: Patterns specified in `.hgignore` are **not rooted**.

So the same tool ships **two anchoring rules, chosen by context**: a query
anchors, an ignore file floats. Prefix closure is on for `path:` ("when the
path points to a directory, it is matched recursively") and off for
`filepath:`/`rootfilesin:` — the same axis [jj][jj] exposes as
`prefix-glob:`/`file:`.

### 5. Lexis: quoting, escaping, reserved characters

A **positive** bare charset — `[.*{}[]?/\_a-zA-Z0-9\x80-\xff]`, i.e. ASCII
alphanumerics, the glob metacharacters and every non-ASCII byte — plus the
reserved-word rule above. Quoted strings take C-style escapes, and `r'...'`
raw strings opt out of escaping entirely, which is how a regexp is written
without doubling every backslash.

### 6. Evaluation strategy & pruning

This is where Mercurial is alone in the field. `filesetlang.optimize` rewrites
the tree against a **static cost model**:

```python
WEIGHT_CHECK_FILENAME    = 0.5
WEIGHT_READ_CONTENTS     = 30
WEIGHT_STATUS            = 10
WEIGHT_STATUS_THOROUGH   = 50
```

with three rewrites:

- **Intersection operands are commuted cheapest-first.**
  `if wa <= wb: … else: return wb, _optimizeandops(op, tb, ta)` — so
  `grep(magic) & *.c` runs the filename check before reading any file.
- **`x and not y` is folded into `minus`** (`_optimizeandops`), turning a
  complement into a difference wherever one appears on the right of a
  conjunction — the same normalisation a language _without_ complement gets for
  free.
- **A union of plain patterns is coalesced into a single `patterns` node** and
  compiled to one regexp (`_optimizeunion`), so `*.c | *.h | *.cpp` costs one
  match, not three.

Union operands are then sorted by weight so the cheap arms short-circuit first.

There is still no traversal plan: Mercurial matches against a manifest, so the
optimisation is about _per-file_ cost, not about which directories to open.

## Strengths

- The widest primary vocabulary in the survey, all of it behind functions or
  prefixes, none of it bare words.
- `set:` as a sub-language prefix — a delimiter that costs one token and cannot
  nest ambiguously.
- A real cost model, with the two rewrites (`and`-commutation, union-coalescing)
  that any compiler for such a language wants.
- Two anchoring rules, each documented against its context, rather than one
  compromise.

## Weaknesses

- Word operators reserve `and`, `or`, `not` as filenames needing quotes.
- Three spellings for union (`or`, `|`, `+`) and a fourth operator, `-`, whose
  prefix form is a parse error — expressive surface without expressive power.
- The kind list has grown to sixteen prefixes with overlapping
  `rel*`/`root*`/bare families; there is no modifier mechanism, so each
  combination is its own name.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                             | Trade-off                                                  |
| --------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------- |
| `set:` opens the expression language    | No delimiter, no new argument syntax, composes with every pattern API | The expression must run to the end of the argument         |
| Word **and** symbol operators           | Readable in config, terse on a command line                           | Three reserved words that are legal filenames              |
| Predicates are functions                | No bare keyword can shadow a directory name                           | `binary()` is noisier than a bare `binary`                 |
| Static cost model over the tree         | The difference between 0.5 and 50 units per file                      | Every predicate must publish a weight                      |
| Anchored queries, floating ignore files | Each context gets the rule that suits it                              | Two rules to learn; the help text has to say so explicitly |

## Sources

- [`mercurial/filesetlang.py`][hg-lang] — the precedence table, the `negate`
  rejection, and the cost model (all quoted above).
- [`hg help filesets`][hg-help-filesets] — the operator and predicate reference.
- [`hg help patterns`][hg-help-patterns] — the pattern-kind namespace and the
  anchoring contrast.

<!-- References -->

[hg-repo]: https://repo.mercurial-scm.org/hg
[hg-lang]: https://repo.mercurial-scm.org/hg/file/7.1/mercurial/filesetlang.py
[hg-help-filesets]: https://repo.mercurial-scm.org/hg/help/filesets
[hg-help-patterns]: https://repo.mercurial-scm.org/hg/help/patterns
[jj]: ./jj-filesets.md
