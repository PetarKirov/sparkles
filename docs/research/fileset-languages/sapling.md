# Sapling `pathmatcher` (Meta)

Mercurial's fileset language, re-implemented in Rust for a repository with
millions of files. The language is [Mercurial][hg]'s; what is new — and what
this survey wants — is the **matcher trait**, which is the cleanest statement
in the field of the contract a traversal plan has to satisfy, lattice join
rules included.

|                   |                                                                  |
| ----------------- | ---------------------------------------------------------------- |
| Language          | Rust (matchers) · Python (the fileset language)                  |
| License           | MIT (Rust crates) / GPL-2.0 (the Mercurial-derived Python)       |
| Repository        | [facebook/sapling][sl-repo]                                      |
| Surveyed revision | [`87b7db94`][sl-types] (all file/line citations pin this commit) |
| Category          | VCS file selection at scale                                      |
| Composition model | Set algebra over composable matchers                             |
| Grammar           | Mercurial's, inherited                                           |

## Overview

### What it solves

Every Sapling command that takes paths — `status`, `diff`, `add`, `commit` —
against a working copy too large to enumerate. The matcher has to answer not
only "is this file in the set" but "can I skip this entire subtree", or the
command never finishes.

### Design philosophy

Split the question in two and make the cheap half a first-class method:

```rust
/// Limits the set of files to be operated on.
pub trait Matcher {
    /// This method is intended for tree traversals of the file system.
    /// It allows for fast paths where whole subtrees are skipped.
    /// It should be noted that the DirectoryMatch::ShouldTraverse return value is always correct.
    /// Other values enable fast code paths only (performance).
    fn matches_directory(&self, path: &RepoPath) -> Result<DirectoryMatch>;

    /// Returns true when the file path should be kept in the file set and returns false when
    /// it has to be removed.
    fn matches_file(&self, path: &RepoPath) -> Result<bool>;
}
```

— [`eden/scm/lib/pathmatcher/types/src/lib.rs`][sl-types]

## How it works

The directory verdict is a three-element lattice with an explicit top:

```rust
/// Allows for fast code paths when dealing with patterns selecting directories.
/// `Everything` means that all the files in the subtree of the given directory need to be part
/// of the returned file set.
/// `Nothing` means that no files in the subtree of the given directory will be part of the
/// returned file set. Recursive traversal can be stopped at this point.
/// `ShouldTraverse` is a value that is always valid. It does not provide additional information.
/// Subtrees should be traversed and the matches should continue to be asked.
pub enum DirectoryMatch {
    Everything,
    Nothing,
    ShouldTraverse,
}
```

— [`eden/scm/lib/pathmatcher/types/src/lib.rs`][sl-types]

`ShouldTraverse` is the `⊤` of the [literal-path-prefix lattice][concepts]: the
answer that is always sound and never useful. Every combinator is written so
that it may fall back to it, which is what makes the whole scheme safe to
implement incrementally.

## Analysis

### 1. Composition model

Full set algebra over matchers — `UnionMatcher`, `IntersectMatcher`,
`DifferenceMatcher`, `XorMatcher`, plus `AlwaysMatcher`, `NeverMatcher` and a
`GraftMatcher` that remaps paths
([`eden/scm/lib/pathmatcher/types/src/lib.rs`][sl-types]). The joins are the
interesting part, because they are the lattice arithmetic our planner needs,
already written down:

```rust
// IntersectMatcher::matches_directory
if self.matchers.is_empty() {
    return Ok(DirectoryMatch::Nothing);
}
let mut traverse = false;
for matcher in &self.matchers {
    match matcher.matches_directory(path)? {
        DirectoryMatch::Nothing => return Ok(DirectoryMatch::Nothing),
        DirectoryMatch::ShouldTraverse => traverse = true,
        DirectoryMatch::Everything => {}
    };
}
if traverse { Ok(DirectoryMatch::ShouldTraverse) } else { Ok(DirectoryMatch::Everything) }
```

Three things fall out of those five lines:

- **A disjoint intersection prunes at the directory level.** One `Nothing`
  short-circuits the whole subtree — the dynamic counterpart of the static
  "statically empty" diagnostic the [recommendations][rec] propose.
- **`Everything ∩ Everything = Everything`**, so prefix closure survives
  intersection and a fully-included subtree is still never enumerated.
- **The empty intersection is `Nothing`.** Sapling answers the nullary-
  intersection question — the one [nixpkgs][nix] declines to answer and omits
  `intersections` over — by choosing the empty set over the universe. It is
  wrong in set theory and right in a traversal, because `Everything` there would
  mean "walk the entire repository".

`DifferenceMatcher` carries an explicit cost comment:

```rust
// Don't execute the exclude ahead of time, since in some cases we can avoid executing it
// entirely. This is useful when the exclude side is expensive, like in the status case
// where the exclude side may inspect a manifest or the treestate.
```

— [`eden/scm/lib/pathmatcher/types/src/lib.rs`][sl-types]

which is [Mercurial's `filesetlang.optimize`][hg] instinct — cheap operand
first — applied at the plan level rather than the predicate level.

### 2. Operator surface & precedence

Inherited unchanged from [Mercurial][hg] for the textual language
(`eden/scm/sapling/fileset.py`); the Rust side is an API, so composition is
constructor calls.

### 3. Primary vocabulary & the kind namespace

Mercurial's prefix namespace, promoted to a **closed Rust enum** with the
anchoring rule documented per variant:

```rust
pub enum PatternKind {
    /// a regular expression relative to repository root
    RE,
    /// a shell-style glob pattern relative to cwd
    Glob,
    /// a path relative to the repository root, and when the path points to a
    /// directory, it is matched recursively
    Path,
    /// an unrooted glob (e.g.: *.c matches C files in all dirs)
    RelGlob,
    /// a path relative to cwd
    RelPath,
    /// an unrooted regular expression, needn't match the start of a path
    RelRE,
    /// read file patterns per line from a file
    ListFile,
    /// read file patterns with null byte delimiters from a file
    ListFile0,
    /// a fileset expression
    Set,
    /// a path relative to repository root, which is matched non-recursively (will
    /// not match subdirectories)
    RootFilesIn,
}
```

— [`eden/scm/lib/pathmatcher/src/pattern.rs`][sl-pattern]

The leaf matchers behind them are worth naming individually, because they are a
catalogue of the prunable primaries: `ExactMatcher`, `TreeMatcher` (globs
compiled to a tree), `GitignoreMatcher`, `RegexMatcher`, `BasenameMatcher`,
`DepthMatcher`, `HintedMatcher`. `DepthMatcher` is the same primary
[watchman][wm] exposes as `["depth", …]` and is exactly what makes
`RootFilesIn` prunable.

### 4. Anchoring & glob semantics

**Both rules kept, as separate kinds.** `Glob` is "relative to cwd";
`RelGlob` is "an unrooted glob (e.g.: `*.c` matches C files in all dirs)". The
same split appears for regexes (`RE` / `RelRE`) and paths (`Path` / `RelPath`).

This is the survey's second system — with [watchman][wm] — to make anchoring
**explicit in the term** rather than inferring it from whether the pattern
contains a separator, and the two are precisely the two systems that had to
scale. That is worth weighing against the `.gitignore` inference rule the
[recommendations][rec] adopt (see [contradictions] `A5`).

`utils.rs` exposes the normalisations a pattern layer needs and is easy to
forget: `expand_curly_brackets`, `make_glob_recursive`, `normalize_glob`,
`plain_to_glob`.

### 5. Lexis: quoting, escaping, reserved characters

Mercurial's, inherited. `split_pattern` / `build_patterns`
([`pattern.rs`][sl-pattern]) are the kind-prefix splitter, and `plain_to_glob`
is the escape direction — taking a literal path and producing a glob that
matches it, which is the operation a `file:` kind needs and which no other
surveyed system exposes as a named function.

### 6. Evaluation strategy & pruning

The whole point. Every matcher answers the directory question, and the walkers
(`eden/scm/lib/` manifest and status code) act on it. Two details generalise:

- **Soundness is a documented property of one value.** "`ShouldTraverse` is a
  value that is always valid. It does not provide additional information."
  A new matcher can be correct on day one by returning it everywhere, then get
  faster. A lattice whose `⊤` is documented like this is one you can ship
  incrementally.
- **`Everything` is prefix closure as a plan verdict**, not as a matching rule.
  The pattern layer does not need a closure kind to get subtree admission; the
  directory verdict provides it.

## Strengths

- The three-valued directory verdict, with `ShouldTraverse` documented as always
  sound, is the right shape for a traversal plan and is trivially testable.
- The combinator joins are written out, short, and reusable as a specification.
- Anchoring is explicit per kind rather than inferred.
- The empty intersection is decided, not deferred.
- `plain_to_glob` and friends name the normalisations that are otherwise
  scattered through consumers.

## Weaknesses

- Two implementations of one language (Python `fileset.py`, Rust matchers) with
  the usual drift risk.
- The kind enum is closed, so a new selector is a source change rather than a
  registration — the opposite trade from a reserved _shape_.
- `XorMatcher` and `GraftMatcher` are in the general trait's crate but answer
  needs (path remapping) that most consumers do not have.
- The textual language inherits Mercurial's reserved words and its three
  spellings of union.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                     | Trade-off                                                     |
| --------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------- |
| `matches_directory` as a first-class method   | Skipping subtrees is the only thing that makes scale possible | Every matcher must implement it, even trivially               |
| `ShouldTraverse` documented as always valid   | New matchers can be correct before they are fast              | A lazy implementation is silently slow, not wrong             |
| Empty intersection is `Nothing`               | `Everything` would mean walking the whole repository          | Diverges from set theory and from `unions []`'s identity      |
| Difference defers the exclude side            | The exclude operand may inspect a manifest                    | Evaluation order is part of the contract, not an optimisation |
| Anchoring split into `Glob` / `RelGlob` kinds | No inference; the user says which they mean                   | Twice as many kinds; both must be documented                  |
| `PatternKind` is a closed enum                | Exhaustive matching, no unknown-kind path at runtime          | Extensibility requires a source change                        |

## Sources

- [`eden/scm/lib/pathmatcher/types/src/lib.rs`][sl-types] — the `Matcher` trait, `DirectoryMatch`, and the union/intersect/difference/xor joins (all quoted above).
- [`eden/scm/lib/pathmatcher/src/pattern.rs`][sl-pattern] — `PatternKind` with its per-kind anchoring documentation (quoted above).
- [`eden/scm/lib/pathmatcher/src/lib.rs`][sl-lib] — the exported matcher set and the intersection tests.
- [`eden/scm/lib/pathmatcher/src/utils.rs`][sl-utils] — `expand_curly_brackets`, `make_glob_recursive`, `normalize_glob`, `plain_to_glob`.
- [`eden/scm/sapling/fileset.py`][sl-fileset] — the inherited Mercurial fileset language.

<!-- References -->

[sl-repo]: https://github.com/facebook/sapling
[sl-types]: https://github.com/facebook/sapling/blob/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/lib/pathmatcher/types/src/lib.rs
[sl-pattern]: https://github.com/facebook/sapling/blob/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/lib/pathmatcher/src/pattern.rs
[sl-lib]: https://github.com/facebook/sapling/blob/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/lib/pathmatcher/src/lib.rs
[sl-utils]: https://github.com/facebook/sapling/blob/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/lib/pathmatcher/src/utils.rs
[sl-fileset]: https://github.com/facebook/sapling/blob/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2/eden/scm/sapling/fileset.py
[hg]: ./mercurial-filesets.md
[wm]: ./watchman.md
[nix]: ./nixpkgs-fileset.md
[concepts]: ./concepts.md#literal-path-prefix-lattice
[rec]: ./recommendations.md
[contradictions]: ./contradictions.md
