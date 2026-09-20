# Concepts & vocabulary

The terms the rest of this tree uses, each defined once and grounded in a real
system. A file-selection language is small enough that most of its design space
is covered by five axes; this page names them.

**Last reviewed:** September 20, 2026

---

## Composition model

How two selections combine. The field has five answers, and they are not
interchangeable.

| Model                    | Shape                                                                         | Can express intersection?     | Examples                                                                                                         |
| ------------------------ | ----------------------------------------------------------------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Set algebra**          | An expression tree over `union` / `intersection` / `difference` with grouping | yes                           | [jj filesets][jj-filesets], [Mercurial filesets][hg], [`bazel query`][bazel], [nixpkgs][nix], [Sapling][sapling] |
| **Ordered rules**        | A list of patterns, each include or exclude; last (or first) match decides    | **no**                        | [`.gitignore`, rsync, CODEOWNERS][ordered], [`ripgrep -g`][shell], [the `ignore` crate][ignore]                  |
| **Generate then filter** | A generator bounds the candidate set; an algebra filters what it produced     | yes, within one generator     | [watchman][watchman]                                                                                             |
| **Two-layer hybrid**     | Ordered rules for paths, a boolean algebra one level up over predicates       | yes, in the upper layer       | [Ant `<fileset>`, Gradle `PatternSet`][ant]                                                                      |
| **Implicit conjunction** | Juxtaposed terms are ANDed; a prefix sigil negates one term                   | yes, but only over _one_ axis | [fzf, fff][implicit], [`find`][shell] (with explicit `-o`)                                                       |

The distinction that matters for a build system is that **an ordered-rule list
cannot express intersection**. `a` then `!b` is `a ∖ b`, and the rules compose
by overwriting each other's verdicts, not by meeting. There is no ordering of
include/exclude lines that means "files that are both under `src/` and tracked
by git" unless one of the two predicates is folded into the traversal itself.
`bazel`'s [`glob(include, exclude)`][bazel] is the ordered-rule model wearing a
function's clothes: two lists, one subtracted from the other, and no third
operator.

## Generators versus predicates

The distinction [watchman][watchman] makes its API out of, and the one a
fileset IR with two consumers needs a name for.

A **generator** bounds the candidate set: it can be evaluated without being
handed a candidate, because it enumerates. A **predicate** can only test a
candidate it is given. Watchman's five generators (`since`, `suffix`, `glob`,
`path`, `all`) and its expression terms (`match`, `dirname`, `type`, `size`, …)
are exactly this split, and the documentation teaches users to exploit it by
hand: `{"suffix": "c"}` plus a `dirname` term is faster than
`{"glob": ["**/*.c"]}` for the same set.

Two properties follow, and both are used throughout this tree:

- **Only a generator can prune.** A predicate answers about one path, and by
  the time it is asked the walk is already committed. This is why the
  [literal-path-prefix lattice](#literal-path-prefix-lattice) is an analysis
  over the _generating_ parts of an expression.
- **Complement is safe inside a generator's bound and ruinous outside it.**
  `["not", ["match", "*.c"]]` means "of the candidates this generator produced,
  the non-C ones". The same `~x` with no bounding generator means "every path on
  the disk that is not x".

[Sapling][sapling] expresses the same split differently: one `Matcher` trait
with two methods — `matches_directory`, the generator side, which may prune a
whole subtree, and `matches_file`, the predicate side.

## Anchoring

Whether a pattern is positioned relative to a root, or free to match at any
depth. Four distinct rules are in production use:

| Rule                     | A slash-free pattern (`foo`)            | A pattern with a slash (`a/b`)                  | Systems                                                                                |
| ------------------------ | --------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Root-anchored**        | only the root entry `foo`               | only `a/b` from the root                        | [Mercurial `glob:`/`rootglob:`][hg], [jj][jj-filesets], [git][pathspec]                |
| **Float-unless-slashed** | any segment, at any depth (`**/foo`)    | anchored to the root                            | [`.gitignore`][ordered], [`ripgrep -g`][shell]                                         |
| **Suffix-anchored**      | the final component only                | the trailing components (`a/b` matches `x/a/b`) | [rsync filter rules][ordered]                                                          |
| **Base-name by default** | the final component only                | nothing, unless `--full-path`                   | [`fd`][shell], [watchman `match`][watchman] (default scope)                            |
| **Explicit per term**    | whatever the term's scope argument says | whatever the term's scope argument says         | [watchman][watchman] (`basename`/`wholename`), [Sapling][sapling] (`glob:`/`relglob:`) |

Two further sub-questions ride along:

- **Does `*` cross a separator?** Under `fnmatch(3)` without `FNM_PATHNAME` it
  does; under `FNM_PATHNAME` (and in every `.gitignore`-family matcher) it does
  not, and `**` is introduced to recover the crossing case. `git`'s pathspec
  keeps the crossing behaviour by default and offers `:(glob)` to turn it off —
  the only mainstream system that defaults to crossing.
- **Prefix closure.** Does a pattern that matches a _directory_ admit
  everything under it? [jj][jj-filesets] says yes and makes it the **default**
  pattern kind (`prefix-glob:`); [Mercurial `path:`][hg] says yes;
  [`ripgrep -g`][shell] says no, and documents the resulting footgun in its own
  `--help`.

## The kind namespace

Every language in this survey that admits non-path primaries reaches them
through a **prefix** rather than a bare keyword, for the same reason: bare
keywords would collide with directory names. The prefixes differ only in shape.

| System                   | Shape                                       | Examples                                              | Extensibility mechanism                 |
| ------------------------ | ------------------------------------------- | ----------------------------------------------------- | --------------------------------------- |
| [Mercurial][hg]          | lowercase alphanumeric + `:`                | `path:` `glob:` `re:` `rootglob:` `listfile0:` `set:` | new prefix                              |
| [jj][jj-filesets]        | hyphenated identifier + `:`                 | `cwd-prefix-glob:` `root-file:` `glob-i:`             | new prefix, plus a `-i` modifier suffix |
| [git pathspec][pathspec] | `:` + symbol signature, or `:(word,word)`   | `:!` `:/` `:(glob,icase)`                             | a comma-separated **word list**         |
| [hue today][picker]      | lowercase word + `:`, plus 1–2 char aliases | `ext:` `seg:` `git:` `st:` `g:`                       | new prefix                              |

git's long form is the most extensible shape in the field: modifiers compose as
a set rather than multiplying kind names, which is what jj's
`root-prefix-glob-i:` is heading toward.

## Delimiting a language inside another input

A picker prompt, a `.gitignore` line and a command line all carry text that is
_mostly_ not an expression. Three answers exist:

- **A prefix that switches the whole remainder.** Mercurial's `set:` turns a
  pattern argument into a fileset expression; the rest of the argument is the
  expression.
- **A separator token.** `git`'s `--` ("the rest is paths"), reused by
  `ripgrep`, `fd` and every picker that forwards flags.
- **A parse-failure fallback.** jj tries the argument as an expression and, on
  failure, retries it as a bare path pattern
  ([`program_or_bare_string`][jj-pest]). This removes the delimiter entirely at
  the cost of a query whose meaning changes when a typo makes it stop parsing.
- **Restrict the language instead.** [git sparse-checkout][sparse]'s cone mode
  accepts only directory names, which dissolves the question — a directory name
  cannot be confused with an expression, so it needs no delimiter.
- **A heuristic per token.** [fff][implicit] (and hue today) classify each
  whitespace-separated token as constraint-or-text by inspecting it. This is
  the model the [recommendations] replace, and its cost is visible in fff's
  own source as a stack of carve-outs.

## Literal-path-prefix lattice

The static analysis that turns an expression into a **traversal plan**: for
each sub-expression, the longest root-relative path prefix that every member
must start with, with a top element `⊤` meaning "unknown — could be anywhere".

```
prefix(literal "src/app.d")  = "src/app.d"
prefix(glob "src/**/*.d")    = "src/"
prefix(glob "**/*.d")        = ⊤
prefix(a ∪ b)                = longest common prefix of prefix(a), prefix(b)
prefix(a ∩ b)                = the longer of the two, if one extends the other;
                               otherwise the intersection is statically empty
prefix(a ∖ b)                = prefix(a)          (b can only remove)
prefix(¬a)                   = ⊤                  (always)
```

Its **runtime dual** is [Sapling][sapling]'s `DirectoryMatch`, which answers
the same question per directory during the walk rather than per sub-expression
before it: `Everything` (admit the subtree and stop asking), `Nothing` (prune),
`ShouldTraverse` (the `⊤` — "always valid … does not provide additional
information"). A planner computes the static lattice, a matcher answers the
dynamic one, and the two must agree.

Two consequences drive the [recommendations]:

- **Complement destroys pruning.** `¬a` has no literal prefix, so any
  expression containing one must start its walk at the root. This is why
  [jj][jj-filesets] and [Mercurial][hg], which match against an
  already-materialised manifest, can afford `~x` and `not x`, and why a
  language that compiles to a directory walk cannot.
- **A disjoint intersection is statically empty.** `src/** & libs/**` has two
  prefixes neither of which extends the other, so the result is provably the
  empty set before a single `readdir`. [Bazel][bazel] treats the _dynamic_
  version of this as an error (`allow_empty = False` is the default); the
  static version is strictly cheaper to detect.

## Identity versus matching

Whether two paths are the _same file_ is a question about bytes. Whether a
pattern _matches_ a path is a question about policy — case folding, Unicode
normalisation, separator flavour. Conflating them is how a content-addressed
build system ends up with two store entries for one file. Every system here
keeps its case-insensitivity in the pattern (`glob-i:`, `:(icase)`,
`ripgrep --glob-case-insensitive`) and never in the path.

## Sources

Per-subject citations live in the deep-dives; this page's claims are each
restated with a primary source there.

<!-- References -->

[jj-filesets]: ./jj-filesets.md
[jj-pest]: https://github.com/jj-vcs/jj/blob/88c3cd0540d93f60be2ecd8aba3d64573b968418/lib/src/fileset.pest
[hg]: ./mercurial-filesets.md
[bazel]: ./bazel.md
[nix]: ./nixpkgs-fileset.md
[ordered]: ./ordered-rule-filters.md
[pathspec]: ./git-pathspec.md
[implicit]: ./implicit-and-pickers.md
[shell]: ./shell-tools.md
[recommendations]: ./recommendations.md
[picker]: ../../specs/hue/picker.md
[watchman]: ./watchman.md
[sapling]: ./sapling.md
[ant]: ./ant-gradle.md
[ignore]: ./ignore-crate.md
[sparse]: ./git-sparse-checkout.md
