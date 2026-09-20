# Ant `<fileset>` and Gradle `PatternFilterable`

Where the word "fileset" comes from in build systems, and the one lineage in
the survey that carries **both** models at once: ordered include/exclude
patterns for paths, and a real boolean algebra for everything else. Ant also
invented `**`.

|                    |                                                                   |
| ------------------ | ----------------------------------------------------------------- |
| Languages          | Java                                                              |
| Licenses           | Apache-2.0 (both)                                                 |
| Repositories       | [apache/ant][ant-repo] · [gradle/gradle][gr-repo]                 |
| Surveyed revisions | Ant [`a3a5ba18`][ant-fileset] · Gradle [`cb109726`][gr-pf]        |
| Category           | Build-system file selection                                       |
| Composition model  | Ordered rules (patterns) **and** set algebra (selectors / `Spec`) |
| Grammar            | XML elements (Ant) · a fluent Java/Groovy API (Gradle)            |

## Overview

### What it solves

Naming the inputs of a build task — the sources to compile, the resources to
copy, the files to zip — from inside a build file, against a directory tree.

### Design philosophy

Ant's answer is that a fileset is **a base directory plus a pattern set plus a
tree of selectors**, and that the two layers have different composition rules
because they answer different questions. The manual says so directly:

> Apache Ant gives you two ways to create a subset of files in a fileset, both
> of which can be used at the same time:
>
> - Only include files and directories that match any include patterns and do
>   not match any exclude patterns in a given PatternSet.
> - Select files based on selection criteria defined by a collection of selector
>   nested elements.
>
> — [`manual/dirtasks.html`][ant-dirtasks]

Gradle inherits the model wholesale, keeps the Ant pattern syntax, and replaces
the selector tree with `Spec<FileTreeElement>` predicates.

## How it works

Ant's pattern language, stated in the manual that introduced it:

> Matching is done per-directory. This means that first the first directory in
> the pattern is matched against the first directory in the path to match. …
>
> To make things a bit more flexible, we add one extra feature, which makes it
> possible to match multiple directory levels. … To do this, `**` must be used
> as the name of a directory. When `**` is used as the name of a directory in
> the pattern, **it matches zero or more directories**.
>
> There is one "shorthand": if a pattern ends with `/` or `\`, then `**` is
> appended. For example, `mypackage/test/` is interpreted as if it were
> `mypackage/test/**`.
>
> — [`manual/dirtasks.html`][ant-dirtasks]

Gradle restates the same three rules in `PatternFilterable`'s own javadoc, plus
the fold:

> If no include patterns or specs are specified, then all files in this
> container will be included. If any include patterns or specs are specified,
> then a file is included if it matches **any** of the patterns or specs.
>
> If no exclude patterns or spec are specified, then no files will be excluded.
> If any exclude patterns or specs are specified, then a file is included only
> if it matches **none** of the patterns or specs.
>
> — [`PatternFilterable.java`][gr-pf]

## Analysis

### 1. Composition model

**Both, side by side.** The pattern layer is an ordered include/exclude fold.
The selector layer is a genuine algebra — Ant ships `<and>`, `<or>`, `<not>`,
`<none>`, `<majority>` and `<selector>` as _selector containers_:

> To create more complex selections, a variety of selectors that contain other
> selectors are available for your use. … All selector containers can contain
> any other selector, including other containers, as an element. Using
> containers, the selector tags can be arbitrarily deep.
>
> — [`manual/Types/selectors.html`][ant-sel]

and the two layers meet with a documented conjunction:

> If any of the selectors within the FileSet do not select the file, the file is
> not considered part of the FileSet. **This makes a FileSet equivalent to an
> `<and>` selector container.**
>
> — [`manual/Types/fileset.html`][ant-fileset]

Gradle lifts the ordered-rule bag into a composable object. `PatternSet` has an
`intersect()` that returns an `IntersectionPatternSet`, whose `getAsSpec()` is
literally `Specs.intersect(super.getAsSpec(), other.getAsSpec())` — and whose
`addToAntBuilder` emits an Ant `<and>` node
([`IntersectionPatternSet.java`][gr-ips]). `Specs` supplies `intersect`,
`union` and `negate` over `Spec<T>` ([`Specs.java`][gr-specs]).

So the lineage's answer to "ordered rules cannot intersect" is: keep the
ordered rules for paths, and put a set algebra one level up, over predicates.
That is a third option this survey had not recorded, and it is the one closest
to a fileset IR with two consumers.

### 2. Operator surface & precedence

No infix syntax at all — XML nesting in Ant, method chaining in Gradle. `<and>`
short-circuits ("It returns as soon as it finds a selector that does not select
the file, so it is not guaranteed to check every selector"), which is
[Mercurial][hg]'s cost-ordering instinct without a cost model to drive it.

`<majority>` deserves a note as the survey's only non-boolean combinator: it
selects a file if a majority of its children do. Nothing else in the field has
anything like it, and nothing appears to need it.

### 3. Primary vocabulary & the kind namespace

Ant's non-path primaries are **elements**, not prefixes: `<contains>`,
`<containsregexp>`, `<date>`, `<depend>`, `<depth>`, `<different>`,
`<filename>`, `<present>`, `<size>`, `<type>`, `<modified>`, `<readable>`,
`<writable>`, `<executable>`, `<symlink>`, `<ownedBy>`, `<posixGroup>`,
`<signedselector>`, `<scriptselector>`, `<custom>`. It is the widest primary
vocabulary in the survey, wider even than [Mercurial][hg]'s predicates, and it
is reachable only because XML gives every primary its own namespace for free.

Note `<filename>` — "Select files whose name matches a particular pattern.
Equivalent to the include and exclude elements of a patternset". The pattern
layer is _also_ available as a selector, so the two models are not merely
adjacent, they interoperate.

Gradle's equivalent is any `Spec<FileTreeElement>` closure, which is maximally
open and correspondingly opaque: a closure cannot be analysed, cached by value,
or compiled to a traversal plan.

### 4. Anchoring & glob semantics

**Strictly anchored to the base directory, never floating.**

> In general, patterns are considered relative paths, relative to a task
> dependent base directory (the `dir` attribute in the case of `<fileset>`).
> Only files found below that base directory are considered.
>
> — [`manual/dirtasks.html`][ant-dirtasks]

So `*.java` matches only top-level files and `**/*.java` is the idiomatic form —
which is why Gradle build files are full of `**/`. Prefix closure exists as the
trailing-slash shorthand (`src/main/webapp/` ⇒ `src/main/webapp/**`), the same
affordance [rsync][ordered] spells `dir/***`.

Ant's `**` matching **zero or more** directories is the origin of the rule
`.gitignore` later restated as "`**/foo` matches file or directory `foo`
anywhere, the same as pattern `foo`" — and the rule
[`sparkles.fuzzy.glob` does not yet implement][contradictions].

Case sensitivity is a fileset attribute (`casesensitive`, default true), i.e.
policy on the container rather than on the pattern.

### 5. Lexis: quoting, escaping, reserved characters

Ant: XML attribute quoting, with the notable wrinkle that `includes`/`excludes`
attributes take a **comma- or space-separated list**, so a pattern containing a
space or comma must use the nested `<include>` element instead. That is the
cheapest possible "quoting" story — change element — and it costs a filename
class.

Gradle: Java/Groovy string literals, plus `'/'` or `'\'` accepted
interchangeably as the separator.

Neither has an escape for a literal `*` in a filename. In this lineage, such a
file is unreachable by pattern and must be caught by a `<filename>` selector or
a `Spec`.

### 6. Evaluation strategy & pruning

Ant's `DirectoryScanner` walks the base directory and applies the fold per
entry; selectors run afterwards, per file. Gradle's `FileTree.matching` is
**lazy and live**:

> Restricts the contents of this tree to those files matching the given filter.
> The filtered tree is live, so that any changes to this tree are reflected in
> the filtered tree.
>
> — [`FileTree.java`][gr-ft]

which is [nixpkgs][nix]' laziness argument reached from the incremental-build
side. Neither derives start roots from the patterns; both walk the base
directory. Gradle's up-to-date checking hashes the _resulting_ file set rather
than analysing the patterns, which is why an over-broad include costs build time
rather than correctness.

## Strengths

- Two composition models, each applied where it fits: ordered rules for paths,
  boolean algebra for predicates.
- The widest primary vocabulary in the survey.
- `**` matching zero or more directories, and the trailing-slash closure
  shorthand — both twenty-five years old and both still the right defaults.
- Gradle's `intersect()` shows an ordered-rule bag can be lifted into a
  composable value without changing the pattern language.

## Weaknesses

- The pattern layer still cannot intersect; you must climb to the selector layer
  to do it, and only Gradle gives that a name.
- No escape for a literal metacharacter in a filename, and the comma/space list
  form silently forbids those characters too.
- `Spec` closures are opaque: unanalysable, uncacheable by value, impossible to
  compile to a plan.
- Strict anchoring means `**/` appears in nearly every real pattern, which is
  noise that the `.gitignore` float rule removes.

## Key design decisions and trade-offs

| Decision                              | Rationale                                            | Trade-off                                                      |
| ------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------- |
| Patterns ordered, selectors algebraic | Each model where it fits                             | Two mental models; intersection lives only in the upper one    |
| FileSet ≡ an `<and>` of its selectors | One rule for combining the layers                    | Implicit conjunction, invisible in the XML                     |
| `**` matches zero or more directories | `**/foo` finds `foo` at the root too                 | Requires the matcher to handle the empty case explicitly       |
| Trailing `/` implies `/**`            | The common "this subtree" case needs no extra syntax | A trailing slash means something different from `.gitignore`'s |
| Anchored to the base directory        | Predictable; every pattern has a literal prefix      | `**/` prefix on nearly every real-world pattern                |
| Gradle: arbitrary `Spec` predicates   | Escape hatch for anything patterns cannot say        | Opaque to analysis, caching and planning                       |
| Gradle: `FileTree.matching` is live   | Correct under incremental builds                     | Filters are re-evaluated, so they must stay cheap              |

## Sources

- [`manual/dirtasks.html`][ant-dirtasks] — the pattern language, `**`, and the trailing-slash shorthand (quoted above).
- [`manual/Types/fileset.html`][ant-fileset] — the FileSet type and the `<and>` equivalence (quoted above).
- [`manual/Types/selectors.html`][ant-sel] — the core selectors and the selector containers (quoted above).
- [`src/main/org/apache/tools/ant/types/PatternSet.java`][ant-ps] — the pattern-set implementation.
- [`PatternFilterable.java`][gr-pf] — Gradle's restatement of the pattern rules and the include/exclude fold (quoted above).
- [`PatternSet.java`][gr-ps] and [`IntersectionPatternSet.java`][gr-ips] — `intersect()` and its lowering to an Ant `<and>` node.
- [`Specs.java`][gr-specs] — `intersect` / `union` / `negate` over predicates.
- [`FileTree.java`][gr-ft] — `matching`, and the live-filter contract (quoted above).

<!-- References -->

[ant-repo]: https://github.com/apache/ant
[ant-dirtasks]: https://github.com/apache/ant/blob/a3a5ba1822847196a83fdc497a034a94e70b4006/manual/dirtasks.html
[ant-fileset]: https://github.com/apache/ant/blob/a3a5ba1822847196a83fdc497a034a94e70b4006/manual/Types/fileset.html
[ant-sel]: https://github.com/apache/ant/blob/a3a5ba1822847196a83fdc497a034a94e70b4006/manual/Types/selectors.html
[ant-ps]: https://github.com/apache/ant/blob/a3a5ba1822847196a83fdc497a034a94e70b4006/src/main/org/apache/tools/ant/types/PatternSet.java
[gr-repo]: https://github.com/gradle/gradle
[gr-pf]: https://github.com/gradle/gradle/blob/cb109726197a008f61fc29e828c9238bcee72cbb/subprojects/core-api/src/main/java/org/gradle/api/tasks/util/PatternFilterable.java
[gr-ps]: https://github.com/gradle/gradle/blob/cb109726197a008f61fc29e828c9238bcee72cbb/subprojects/core-api/src/main/java/org/gradle/api/tasks/util/PatternSet.java
[gr-ips]: https://github.com/gradle/gradle/blob/cb109726197a008f61fc29e828c9238bcee72cbb/subprojects/core-api/src/main/java/org/gradle/api/tasks/util/internal/IntersectionPatternSet.java
[gr-ft]: https://github.com/gradle/gradle/blob/cb109726197a008f61fc29e828c9238bcee72cbb/subprojects/core-api/src/main/java/org/gradle/api/file/FileTree.java
[gr-specs]: https://github.com/gradle/gradle/blob/cb109726197a008f61fc29e828c9238bcee72cbb/platforms/core-configuration/base-services-groovy/src/main/java/org/gradle/api/specs/Specs.java
[hg]: ./mercurial-filesets.md
[ordered]: ./ordered-rule-filters.md
[nix]: ./nixpkgs-fileset.md
[contradictions]: ./contradictions.md
