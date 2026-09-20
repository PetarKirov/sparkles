# git pathspec magic (C)

Not an algebra at all — a per-argument prefix namespace bolted onto a
positional path list. Surveyed because that namespace is the most carefully
designed one in the field, and because git is the only mainstream system whose
wildcards cross `/` by default.

|                   |                                                                      |
| ----------------- | -------------------------------------------------------------------- |
| Language          | C                                                                    |
| License           | GPL-2.0                                                              |
| Repository        | [git/git][git-repo]                                                  |
| Surveyed revision | [`f78ce2f7`][git-glossary] (all file/line citations pin this commit) |
| Category          | Command-line path limiter                                            |
| Composition model | Ordered rules — non-exclude patterns, then exclude patterns          |
| Grammar           | None; each argument is lexed independently                           |

## Overview

### What it solves

Limiting any git command to a subset of paths, with one syntax that works for
`add`, `diff`, `grep`, `log`, `checkout` and `ls-files`.

### Design philosophy

A pathspec must be **a single shell word**, because it arrives as `argv[n]`.
Everything that would be syntax in an expression language therefore has to be
squeezed into a prefix on each word — and the prefix charset has to be chosen
so that it can never be confused with the path that follows it.

## How it works

> A pathspec that begins with a colon `:` has special meaning. In the short
> form, the leading colon `:` is followed by zero or more "magic signature"
> letters (which optionally is terminated by another colon `:`), and the
> remainder is the pattern to match against the path. **The "magic signature"
> consists of ASCII symbols that are neither alphanumeric, glob, regex special
> characters nor colon.** The optional colon that terminates the "magic
> signature" can be omitted if the pattern begins with a character that does
> not belong to "magic signature" symbol set and is not a colon.
>
> In the long form, the leading colon `:` is followed by an open parenthesis
> `(`, a comma-separated list of zero or more "magic words", and a close
> parentheses `)`, and the remainder is the pattern to match against the path.
>
> — [`Documentation/glossary-content.adoc`][git-glossary]

## Analysis

### 1. Composition model

Ordered, two-phase, and stated as an algorithm rather than an algebra:

> After a path matches any non-exclude pathspec, it will be run through all
> exclude pathspecs (magic signature: `!` or its synonym `^`). If it matches,
> the path is ignored. When there is no non-exclude pathspec, the exclusion is
> applied to the result set as if invoked without any pathspec.
>
> — [`Documentation/glossary-content.adoc`][git-glossary]

So a pathspec list is `(∪ includes) ∖ (∪ excludes)`, with the empty include
list defaulting to the universe. That is a strictly weaker lattice than
`∪`/`∩`/`∖`: there is no nesting and therefore no intersection.

### 2. Operator surface & precedence

None. The only "operator" is the exclusion prefix, and its scope is one
argument.

### 3. Primary vocabulary & the kind namespace

Two shapes for the same table:

| Magic word | Short signature | Meaning                                                  |
| ---------- | --------------- | -------------------------------------------------------- |
| `top`      | `/`             | match from the working-tree root, not the cwd            |
| `exclude`  | `!` or `^`      | subtract this pattern from the result                    |
| `literal`  | —               | wildcards are literal characters                         |
| `icase`    | —               | case-insensitive                                         |
| `glob`     | —               | `fnmatch(3)` with `FNM_PATHNAME` — wildcards stop at `/` |
| `attr`     | —               | require gitattributes, e.g. `:(attr:binary)`             |

Three properties are worth stealing:

1. **The signature charset is defined by exclusion** — "neither alphanumeric,
   glob, regex special characters nor colon" — so a signature can never be
   mistaken for the beginning of a path, and adding a signature letter can
   never reinterpret an existing pathspec.
2. **The long form is a comma-separated word set**, not a concatenated name. A
   new modifier is one more word, not a combinatorial new kind — contrast
   [jj][jj]'s `root-prefix-glob-i:`.
3. **Conflicting modifiers are an error**, not a precedence: "Glob magic is
   incompatible with literal magic."

One anti-pattern to avoid: `:` alone means "no pathspec", a special case the
documentation itself warns against combining with anything.

### 4. Anchoring & glob semantics

Anchored to a directory prefix, with the split done lexically rather than by
the matcher:

> - the pathspec up to the last slash represents a directory prefix. The scope
>   of that pathspec is limited to that subtree.
> - the rest of the pathspec is a pattern for the remainder of the pathname.
>   Paths relative to the directory prefix will be matched against that pattern
>   using `fnmatch(3)`; in particular, `*` and `?` _can_ match directory
>   separators.
>
> — [`Documentation/glossary-content.adoc`][git-glossary]

So `Documentation/*.jpg` matches `Documentation/chapter_1/figure_1.jpg`,
which surprises everyone who learned globbing from `.gitignore` — **in the same
tool**. `:(glob)` restores the separator-respecting behaviour and brings the
`**` rules with it (leading `**/` floats, trailing `/**` is the subtree, `a/**/b`
spans zero or more directories, other runs of asterisks are invalid).

The `top` magic (`:/`) is the explicit root anchor, needed because the default
is cwd-relative.

### 5. Lexis: quoting, escaping, reserved characters

Delegated entirely to the shell: a pathspec is one `argv` element, so quoting
is the shell's job and there is no in-language escape. The cost is that the
magic prefix must be disjoint from everything else by construction, which is
precisely why the signature charset is specified negatively.

### 6. Evaluation strategy & pruning

The directory-prefix split _is_ the pruning plan: git limits the traversal to
the subtree named by the literal prefix of each pathspec, which is the
hand-rolled form of the [literal-path-prefix lattice][concepts]. The lattice
generalises it to expressions; git only needs it per argument because there are
no expressions.

## Strengths

- A prefix namespace designed so that no future addition can reinterpret an
  existing argument.
- Modifiers as a word **set** (`:(glob,icase)`), the most extensible shape in
  the survey.
- Incompatible modifiers rejected rather than ordered.
- Literal-prefix pruning, twenty years before anyone called it that.

## Weaknesses

- No composition: the exclude phase is fixed, so intersection is unreachable.
- Two globbing dialects in one tool (pathspec default vs `:(glob)` vs
  `.gitignore`), and the default is the surprising one.
- The short form's optional terminating colon makes `:!` and `:!:` and
  `:(exclude)` three spellings of one thing.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                              | Trade-off                                              |
| -------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------ |
| Magic prefix per argument, not an expression | A pathspec must survive as one `argv` element          | No nesting, no intersection                            |
| Signature charset defined by exclusion       | Future signatures can never shadow a path              | The charset is hard to state without the negation      |
| Long form is a comma-separated word set      | Modifiers compose additively                           | Two syntaxes for the same table                        |
| `*` crosses `/` by default                   | Backwards compatibility with the original `fnmatch(3)` | Disagrees with `.gitignore`, ripgrep and every `glob:` |
| Exclusion applied after inclusion            | One fixed phase order, trivially explainable           | `(a ∖ b) ∪ c` is not expressible                       |

## Sources

- [`Documentation/glossary-content.adoc`][git-glossary] — the pathspec definition, magic words and matching rules (all quoted above).
- [`Documentation/gitignore.adoc`][git-ignore] — the `**` rules the `glob` magic inherits; see [ordered-rule filters][ordered].

<!-- References -->

[git-repo]: https://github.com/git/git
[git-glossary]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/glossary-content.adoc
[git-ignore]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitignore.adoc
[jj]: ./jj-filesets.md
[ordered]: ./ordered-rule-filters.md
[concepts]: ./concepts.md#literal-path-prefix-lattice
