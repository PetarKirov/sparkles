# The `ignore` crate (ripgrep's walker)

ripgrep's directory walker, extracted as a library. Surveyed separately from
[the ripgrep CLI][shell] because it is the closest implementation neighbour to
this repository's own `dir_walk.d` / `gitignore.d` / `glob_walk.d`, and because
its two public types state the ordered-rule model more precisely than any
specification in the survey: a **three-valued verdict** and a **seven-step
precedence fold**.

|                   |                                                                |
| ----------------- | -------------------------------------------------------------- |
| Language          | Rust                                                           |
| License           | MIT / Unlicense                                                |
| Repository        | [BurntSushi/ripgrep][rg-repo] (`crates/ignore`)                |
| Surveyed revision | [`3fce3b5b`][ig-lib] (all file/line citations pin this commit) |
| Category          | Recursive directory walker + matcher library                   |
| Composition model | Ordered rules, folded in a fixed seven-step order              |
| Grammar           | None — `.gitignore` files and API calls                        |

## Overview

### What it solves

> The ignore crate provides a fast recursive directory iterator that respects
> various filters such as globs, file types and `.gitignore` files. The precise
> matching rules and precedence is explained in the documentation for
> `WalkBuilder`.
>
> Secondarily, this crate exposes gitignore and file type matchers for use cases
> that demand more fine-grained control.
>
> — [`crates/ignore/src/lib.rs`][ig-lib]

### Design philosophy

The walker is the product; the matcher is a by-product exposed for people who
need it. Precedence is not derived from a model — it is enumerated, step by
step, in the order the implementation applies it.

## How it works

The verdict type is three-valued, and the third value is the load-bearing one:

```rust
pub enum Match<T> {
    /// The path didn't match any glob.
    None,
    /// The highest precedent glob matched indicates the path should be
    /// ignored.
    Ignore(T),
    /// The highest precedent glob matched indicates the path should be
    /// whitelisted.
    Whitelist(T),
}
```

— [`crates/ignore/src/lib.rs`][ig-lib]

`None` is not "excluded"; it is "no rule had an opinion", which is what lets the
next matcher in the chain decide. A two-valued predicate cannot express that,
and this is precisely why an ordered-rule list is a fold over partial verdicts
rather than a boolean function.

## Analysis

### 1. Composition model

Ordered rules, with the fold written out in the `WalkBuilder` documentation:

> - First, glob overrides are checked. If a path matches a glob override, then
>   matching stops. The path is then only skipped if the glob that matched the
>   path is an ignore glob. (An override glob is a whitelist glob unless it
>   starts with a `!`, in which case it is an ignore glob.)
> - Second, ignore files are checked. … The precedence order is: `.ignore`,
>   `.gitignore`, `.git/info/exclude`, global gitignore and finally explicitly
>   added ignore files. Note that precedence between different types of ignore
>   files is not impacted by the directory hierarchy; any `.ignore` file
>   overrides all `.gitignore` files. Within each precedence level, more nested
>   ignore files have a higher precedence than less nested ignore files.
> - Third, if the previous step yields an ignore match, then all matching is
>   stopped and the path is skipped. If it yields a whitelist match, then
>   matching continues. A whitelist match can be overridden by a later matcher.
> - Fourth, unless the path is a directory, the file type matcher is run …
> - Fifth, if the path hasn't been whitelisted and it is hidden, then the path is
>   skipped.
> - Sixth, unless the path is a directory, the size of the file is compared
>   against the max filesize limit.
> - Seventh, if the path has made it this far then it is yielded in the
>   iterator.
>
> — [`crates/ignore/src/walk.rs`][ig-walk]

Seven numbered steps, two orthogonal precedence axes inside step two (source
kind beats directory depth), and an explicit note that whitelist is
non-terminal while ignore is terminal. That is what an ordered-rule model costs
to _specify_ once it serves more than one source of rules — and it still cannot
express intersection.

### 2. Operator surface & precedence

`!` inside a glob, plus the seven-step order above. The override matcher
inverts the usual polarity — an override glob is a whitelist unless prefixed —
which is the same polarity inversion [git sparse-checkout][sparse] lists among
its defects.

### 3. Primary vocabulary & the kind namespace

None in the glob language, but the crate does carry a second vocabulary: the
**file-type matcher** (`crates/ignore/src/types.rs` and `default_types.rs`),
which maps names like `rust`, `md`, `cpp` to glob sets. This is `ext:`/`type:`
as a lookup table rather than a prefix, and it is the datapoint that a `type:`
kind wants a curated, shipped table behind it rather than a bare extension.

### 4. Anchoring & glob semantics

`.gitignore`'s, verbatim, via the `globset` crate — the rule the
[recommendations][rec] adopt. `crates/ignore/src/gitignore.rs` is the reference
implementation of the per-directory stack, and `pathutil.rs` of the
strip-to-relative step that every such matcher needs and that is easy to get
wrong across roots.

### 5. Lexis: quoting, escaping, reserved characters

Delegated to `globset`. The interesting API detail is that the `overrides`
module deliberately mirrors the ignore-file model rather than inventing a second
one:

> The overrides module provides a way to specify a set of override globs. This
> provides functionality similar to `--include` or `--exclude` in command line
> tools.
>
> — [`crates/ignore/src/overrides.rs`][ig-over]

and it carries a state the ignore model needs but the pattern language cannot
express — `GlobInner::UnmatchedIgnore`, "No glob matched, but the file path
should still be ignored", the encoding of "there were whitelist globs and this
path matched none of them". A model that needs an out-of-band value to explain
its own result is a model with a missing operator.

### 6. Evaluation strategy & pruning

A parallel walk with per-directory ignore stacks, where a directory judged
`Ignore` is never descended — the behaviour `.gitignore` documents as "Git
doesn't list excluded directories for performance reasons", implemented. The
crate's `incremental.rs` maintains the stack across the parallel walk, which is
the part of the problem the ordered-rule _specification_ never mentions and the
implementation cannot avoid.

## Strengths

- `Match::{None, Ignore, Whitelist}` is the right verdict type, and naming
  `None` separately is what makes chained matchers composable at all.
- The precedence fold is enumerated rather than implied, so it is checkable.
- The matchers are usable standalone, so the walker is not the only entry point.
- The default file-type table is a genuinely useful piece of curation, separate
  from the matching machinery.

## Weaknesses

- Seven steps with two orthogonal precedence axes is a lot of specification for
  "which files", and none of it composes: there is no way to ask for the
  intersection of two rule sets.
- `UnmatchedIgnore` exists because the model cannot say "the include set is
  closed".
- Polarity is inverted between overrides and ignore files.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                       | Trade-off                                                   |
| --------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------- |
| Three-valued `Match`                          | "No opinion" must be distinct from "excluded" to chain matchers | Every consumer handles three cases                          |
| Enumerated seven-step precedence              | Checkable and documentable                                      | The order is the specification; there is no model to derive |
| Ignore terminates, whitelist does not         | A later matcher can still exclude a whitelisted path            | Asymmetric, and easy to misremember                         |
| Overrides mirror the ignore model             | One matcher implementation for both                             | Needs `UnmatchedIgnore` to express a closed include set     |
| Source kind beats directory depth in step two | `.ignore` is the user's override of the project's `.gitignore`  | Surprising if you expect nesting to dominate                |

## Sources

- [`crates/ignore/src/lib.rs`][ig-lib] — the crate documentation and the `Match` enum (quoted above).
- [`crates/ignore/src/walk.rs`][ig-walk] — `WalkBuilder`'s seven-step "Ignore rules" (quoted above).
- [`crates/ignore/src/overrides.rs`][ig-over] — the override matcher and `UnmatchedIgnore` (quoted above).
- [`crates/ignore/src/gitignore.rs`][ig-gi] — the per-directory gitignore matcher.
- [`crates/ignore/src/types.rs`][ig-types] and [`default_types.rs`][ig-defaults] — the file-type vocabulary.

<!-- References -->

[rg-repo]: https://github.com/BurntSushi/ripgrep
[ig-lib]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/lib.rs
[ig-walk]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/walk.rs
[ig-over]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/overrides.rs
[ig-gi]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/gitignore.rs
[ig-types]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/types.rs
[ig-defaults]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/ignore/src/default_types.rs
[shell]: ./shell-tools.md
[sparse]: ./git-sparse-checkout.md
[rec]: ./recommendations.md
