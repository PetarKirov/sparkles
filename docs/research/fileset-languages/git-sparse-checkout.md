# git sparse-checkout: cone versus non-cone

The field's one recorded **retreat**. git shipped the full `.gitignore` pattern
language as a working-tree selector, discovered it did not scale, replaced it
with a restricted subset that compiles to a hash lookup, and then wrote down —
in the manual page — eight reasons the general form was a mistake. It is the
strongest available evidence for and against a literal-path-prefix lattice.

|                   |                                                                |
| ----------------- | -------------------------------------------------------------- |
| Language          | C                                                              |
| License           | GPL-2.0                                                        |
| Repository        | [git/git][git-repo]                                            |
| Surveyed revision | [`f78ce2f7`][sparse] (all file/line citations pin this commit) |
| Category          | Working-tree population filter                                 |
| Composition model | Ordered rules (non-cone) · a canonical directory set (cone)    |
| Grammar           | `.gitignore` syntax, with polarity inverted                    |

## Overview

### What it solves

Populating only part of a large repository's working tree, using the
`skip-worktree` index bit:

> "Sparse checkout" allows populating the working directory sparsely. It uses
> the skip-worktree bit … to tell Git whether a file in the working directory is
> worth looking at.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

### Design philosophy

Originally: reuse the pattern language people already know. Currently: **the
default is a mode in which patterns are not user-visible at all.**

> The "cone mode", which is the default, lets you specify only what directories
> to include.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

## How it works

Cone mode takes directories and compiles them into a canonical, restricted
subset of the full pattern set. `git sparse-checkout set A/B/C` produces:

```
/*
!/*/
/A/
!/A/*/
/A/B/
!/A/B/*/
/A/B/C/
```

> We refer to the particular patterns used in those mode as being of one of two
> types:
>
> 1. _Recursive:_ All paths inside a directory are included.
> 2. _Parent:_ All files immediately inside a directory are included.
>
> … If the patterns do match the expected format, then Git will use **faster
> hash-based algorithms** to compute inclusion.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

So a restricted language turns an O(N·M) matching problem into a hash lookup.
Note that the two pattern types are exactly the two kinds every VCS fileset
language exposes — recursive ([jj][jj]'s `prefix-glob:`, [hg][hg]'s `path:`)
and immediate ([hg][hg]'s `rootfilesin:`, [watchman][wm]'s `["depth","eq",0]`).

## Analysis

### 1. Composition model

Non-cone: ordered `.gitignore` rules, with the polarity inverted — patterns
select what to **include**. Cone: a set of directories, order-independent.

The inversion is itself listed as a defect:

> Non-cone mode uses gitignore-style patterns to select what to _include_ (with
> the exception of negated patterns), while `.gitignore` files use
> gitignore-style patterns to select what to _exclude_ (with the exception of
> negated patterns). The documentation on gitignore-style patterns usually does
> not talk in terms of matching or non-matching, but on what the user wants to
> "exclude". This can cause confusion.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

### 2. Operator surface & precedence

Positional, and the generated cone patterns depend on it: "Here, order matters,
so the negative patterns are overridden by the positive patterns that appear
lower in the file."

### 3. Primary vocabulary & the kind namespace

None — and git files that as an inconsistency with its own design:

> Every other git subcommand that wants to provide "special path pattern
> matching" of some sort uses pathspecs, but non-cone mode for sparse-checkout
> uses gitignore patterns, which feels inconsistent.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

That is an independent argument for **one language across every entry point**,
made by a project that has two and regrets it.

### 4. Anchoring & glob semantics

`.gitignore`'s rules, and the manual page records the exact ambiguity the rule
creates — whether a user's argument is a _path_ to be made root-relative or a
_pattern_ to be taken literally:

> First, two users are in a subdirectory, and the first runs
> `git sparse-checkout set '/toplevel-dir/*.c'` while the second runs
> `git sparse-checkout set relative-dir`. Should those arguments be
> transliterated into `current/subdirectory/toplevel-dir/*.c` and
> `current/subdirectory/relative-dir` before inserting into the sparse-checkout
> file? The user who typed the first command is probably aware that arguments to
> set/add are supposed to be patterns … However, many gitignore-style patterns
> are just paths, which might be what the user who typed the second command was
> thinking.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

Cone mode dissolves this by accepting only directories, which are unambiguous.

### 5. Lexis: quoting, escaping, reserved characters

The manual page raises the pathological-filename problem in the context of shell
completion, and concludes it is unsolvable in the general language:

> Also, if it suggests paths, what if the user has a file or directory that
> begins with either a `!` or `#` or has a `*`, `\`, `?`, `[`, or `]` in its
> name? … Completing on files or directories might give nasty surprises in all
> these cases.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

and separately records the un-quoted-glob hazard, with the observation that the
delay between the mistake and its symptom is what makes it dangerous:

> Passing globs on the command line is error-prone as users may forget to quote
> the glob … With sparse-checkout, the mistake gets recorded at the time the
> sparse-checkout command is run and might not be problematic until the user
> later switches branches or rebases or merges.
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

### 6. Evaluation strategy & pruning

This is the section the whole subject exists for. The scaling failure is stated
as a complexity bound, and the mitigation is named:

> Fundamentally, it makes various worktree-updating processes (pull, merge,
> rebase, switch, reset, checkout, etc.) require O(N\*M) pattern matches, where
> N is the number of patterns and M is the number of paths in the index. This
> scales poorly.
>
> **Avoiding the scaling issue has to be done via limiting the number of
> patterns via specifying leading directory name or glob.**
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

"Specifying leading directory name" is the literal-path prefix. git's conclusion
is that relying on users to supply one is not enough — so cone mode makes the
leading directory the _only_ thing you can supply.

And the consequence that generalises furthest beyond git:

> The excessive flexibility made other extensions essentially impractical.
> `--sparse-index` is likely impossible in non-cone mode; even if it is somehow
> feasible, it would have been far more work to implement and may have been too
> slow in practice. Some ideas for adding coupling between partial clones and
> sparse checkouts are only practical with a more restricted set of paths as
> well.
>
> **For all these reasons, non-cone mode is deprecated. Please switch to using
> cone mode.**
>
> — [`Documentation/git-sparse-checkout.adoc`][sparse]

An unrestricted pattern language did not merely run slowly; it **foreclosed a
later optimisation entirely**. That is the cost of a language whose expressions
cannot be reduced to a canonical, prunable form — and it is the strongest
argument in this survey that the prefix lattice must be a _guarantee_ of the
language, not a best-effort analysis over it.

## Strengths

- Cone mode is a worked example of "restrict the language so the plan becomes
  cheap", with the before and after both shipped and both documented.
- The restricted form is still expressed in the general pattern language, so one
  matcher serves both — the restriction is a recognised shape, not a fork.
- The failure analysis is unusually candid and specific, complexity bound
  included.

## Weaknesses

- The general mode was shipped first and is now deprecated, so the project
  carries both indefinitely.
- Inverted polarity against `.gitignore` while sharing its syntax.
- Two pattern languages in one tool (pathspec and gitignore) for the same job,
  which git itself calls inconsistent.
- Cone mode cannot express "this directory except these files", so the
  restriction is real expressive loss, not just a UI simplification.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                               | Trade-off                                                |
| --------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------- |
| Reuse `.gitignore` syntax                           | Familiar to every user                                  | Inverted polarity confuses; inconsistent with pathspec   |
| Cone mode accepts directories only                  | O(N·M) becomes a hash lookup; no path/pattern ambiguity | No intra-directory exclusion at all                      |
| Cone patterns still written in the general language | One matcher; the restriction is a recognised shape      | Users can see generated patterns they must not hand-edit |
| Deprecate rather than remove non-cone               | Existing repositories keep working                      | Both modes maintained forever                            |
| Restriction as a precondition for `--sparse-index`  | The optimisation is impossible without it               | Decided after the fact, at the cost of a deprecation     |

## Sources

- [`Documentation/git-sparse-checkout.adoc`][sparse] — "INTERNALS -- NON-CONE PROBLEMS", "INTERNALS -- CONE MODE HANDLING", "INTERNALS -- FULL PATTERN SET" and "INTERNALS -- CONE PATTERN SET" (all quoted above).
- [`Documentation/gitignore.adoc`][git-ignore] — the pattern syntax both modes share; see [ordered-rule filters][ordered].

<!-- References -->

[git-repo]: https://github.com/git/git
[sparse]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/git-sparse-checkout.adoc
[git-ignore]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitignore.adoc
[ordered]: ./ordered-rule-filters.md
[jj]: ./jj-filesets.md
[hg]: ./mercurial-filesets.md
[wm]: ./watchman.md
