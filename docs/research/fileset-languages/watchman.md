# Watchman query language (Meta)

The only production system in the survey whose **user-facing model is the
architecture this design is building**: a query is one or more _generators_
that enumerate candidates, feeding an _expression evaluator_ that filters them.
That is the Plan/Predicate split, named and shipped.

|                   |                                                                  |
| ----------------- | ---------------------------------------------------------------- |
| Language          | C++ (server), JSON (query surface)                               |
| License           | MIT                                                              |
| Repository        | [facebook/watchman][wm-repo]                                     |
| Surveyed revision | [`d99639db`][wm-query] (all file/line citations pin this commit) |
| Category          | File-watching query service                                      |
| Composition model | Set algebra over an explicitly generated candidate set           |
| Grammar           | JSON s-expressions — no textual syntax                           |

## Overview

### What it solves

Answering "which files under this root satisfy this predicate" against an
in-memory index that a watcher keeps current, fast enough that build tools
(Buck, Mercurial/Sapling, jest) call it on every invocation.

### Design philosophy

The query is explicitly two-layer, and the documentation leads with it:

> Watchman file queries consist of 1 or more _generators_ that feed files
> through the _expression evaluator_.
>
> Generators are analogous to the list of _paths_ that you specify when using
> the `find(1)` utility, but are implemented in watchman with a bit of a twist
> because watchman doesn't need to crawl the filesystem in realtime and instead
> maintains a couple of indexes over the tree.
>
> — [`website/docs/file-query.md`][wm-query]

Everything that can bound the candidate set is a generator; everything that can
only test a candidate is an expression term. The split is not an implementation
detail — it is the API.

## How it works

Five generators:

| Generator | Bounds the candidate set by                                   |
| --------- | ------------------------------------------------------------- |
| `since`   | a [clockspec] — everything modified since a point in time     |
| `suffix`  | a suffix or list of suffixes, served from an index            |
| `glob`    | a list of glob patterns, walked as a tree (below)             |
| `path`    | a path **plus a depth bound** (`{"path": "bar", "depth": 0}`) |
| `all`     | every known file — the default when no generator is named     |

and an expression language of `allof`, `anyof`, `not`, `true`, `false`,
`match`/`imatch`, `name`/`iname`, `dirname`/`idirname`, `type`, `size`,
`empty`, `exists`, `since`, `suffix`, `pcre` — [`website/docs/expr/`][wm-expr].

The `glob` generator is the one that matters most here:

> It does this by building a tree from the glob expression(s) and **walking both
> the expression and the in-memory filesystem tree concurrently**.
>
> — [`website/docs/file-query.md`][wm-query]

## Analysis

### 1. Composition model

Set algebra (`allof`/`anyof`/`not`) over a candidate set that a generator has
already bounded. Multiple generators union, with an explicit duplicate hazard:

> A query may specify any number of generators; each generator will emit its
> list of files and this may mean that you see the same file output more than
> once if you specified the use of multiple generators that all produce the same
> file. … You may ask Watchman to de-duplicate results for you by enabling the
> `dedup_results` boolean.
>
> — [`website/docs/file-query.md`][wm-query]

`dedup_results` defaults off for backwards compatibility and is implicitly on
for the `glob` generator. **This is the start-root deduplication problem**: a
union of arms whose literal prefixes overlap will enumerate the overlap twice
unless the planner merges them by containment.

### 2. Operator surface & precedence

None — the query is JSON, so nesting is explicit and precedence does not exist.
That is the point of comparison: the entire O1–O6 design surface of a _textual_
language is the price of not writing `["allof", ["match", "*.d"], ["not", …]]`.

### 3. Primary vocabulary & the kind namespace

There is no `kind:` prefix, because every primary is a named JSON term. Two
of those terms carry lessons a prefix namespace has to reproduce:

**`match` takes its scope as an argument, not as an inference:**

> The `match` expression performs a glob-style match against the **basename** of
> the file … You may optionally provide a third argument to change the scope of
> the match from the basename to the wholename of the file.
>
> ```json
> ["match", "*.txt", "basename"]
> ["match", "dir/*.txt", "wholename"]
> ```
>
> — [`website/docs/expr/match.md`][wm-match]

**Modifiers are an additive flag dictionary**, not a suffix on the term name:

> ```json
> ["match", "*.txt", "basename", { "includedotfiles": true }]
> ```
>
> By default, backslashes in the pattern escape the next character, so `\*`
> matches a literal `*` character. To change this behavior so backslashes are
> treated literally, set the `noescape` flag.
>
> — [`website/docs/expr/match.md`][wm-match]

That is [git pathspec][pathspec]'s `:(glob,icase)` idea in a different
notation, and the second independent occurrence of it in the survey.

### 4. Anchoring & glob semantics

`basename` by default, `wholename` on request — a **fifth** anchoring rule, and
the important thing is that it is _explicit per term_ rather than inferred from
whether the pattern contains a `/`. `**` works only in `wholename` scope, and
dotfiles are excluded by default.

Prefix closure is a separate, tunable term. `dirname` takes a relational depth
expression:

> The following two terms will match any file whose dirname is either exactly a
> match for `foo/bar` or is any child directory of `foo/bar`. The first of these
> two is a shortcut for the second:
>
> ```
> ["dirname", "foo/bar"]
> ["dirname", "foo/bar", ["depth", "ge", 0]]
> ```
>
> — [`website/docs/expr/dirname.md`][wm-dirname]

so `["dirname", "foo/bar", ["depth", "eq", 0]]` is [Mercurial][hg]'s
`rootfilesin:` and the default is jj's `prefix-glob:` — one term, parameterised,
instead of two kinds.

Case sensitivity is policy in three layers: `match`/`imatch` variants, a
query-level `case_sensitive` field, and automatic equivalence "on systems where
the watched root is a case insensitive filesystem". Identity is never touched.

### 5. Lexis: quoting, escaping, reserved characters

JSON's, entirely. There is no token to escape, which is precisely why watchman
can afford `not` and a flag dictionary and five generators without a grammar.

### 6. Evaluation strategy & pruning

The generator **is** the plan, and the cost trade-off is documented for users to
make by hand:

> Note that it is more efficient to use the `suffix` generator together with a
> `dirname` expression term for such a broadly scoped query as it results in
> fewer comparisons. This example is included as an illustration of recursive
> globbing.
>
> — [`website/docs/file-query.md`][wm-query]

i.e. `{"glob": ["**/*.c"]}` and `{"suffix": "c", "expression": ["dirname", …]}`
denote the same set, and the second is faster. **Watchman asks the user to
choose; a compiler over an IR should choose for them.** That is the clearest
statement in the survey of what the Plan/Predicate split is _for_.

On emptiness, every generator agrees: "If the `suffix` generator is given an
empty array, it produces no files", and likewise for `glob` and `path` — an
empty generator is an empty result, not an error and not the universe.

And on complement: `not` is safe here **because the generator bounds the
universe first**. `["not", ["match", "*.c"]]` never means "every file on the
disk"; it means "every candidate this generator produced that isn't a `.c`
file". That is the precise condition under which a complement is affordable.

## Strengths

- The generator/expression split is explicit, documented, and load-bearing.
- `path` with a depth bound is a prunable primary that the pattern languages
  reach only through kind proliferation.
- `dirname` + relational depth parameterises prefix closure instead of
  multiplying kinds.
- Modifier flags compose additively.
- JSON means no lexis, no precedence, no escaping — and therefore no O1–O6.

## Weaknesses

- Unwritable by hand: the query surface exists for programs, and the documented
  ergonomics gap is real enough that watchman also ships `watchman-make`,
  `watchman-wait` and a [simple query][wm-simple] shorthand.
- Generator choice is a manual performance decision with no compiler behind it.
- `dedup_results` defaults off, so the common multi-generator query is wrong by
  default for backwards-compatibility reasons.
- Generators do not compose with the expression algebra — you cannot intersect
  two generators, only union them and filter afterwards.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                        | Trade-off                                                     |
| --------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------- |
| Generators separate from expressions          | Only a generator can bound the walk; only an expression can test | Two vocabularies to learn; generators cannot intersect        |
| `not` in the expression layer                 | The generator has already bounded the universe                   | Complement is meaningless without knowing which generator ran |
| Scope (`basename`/`wholename`) as an argument | No inference from pattern shape; no surprise                     | Every `match` term is longer than a bare glob                 |
| Modifiers as a flag dictionary                | Additive; no combinatorial term names                            | A fourth positional argument before the flags                 |
| `dedup_results` off by default                | Backwards compatibility                                          | The natural multi-generator query double-counts               |
| JSON instead of a syntax                      | No lexer, no precedence, no escaping                             | Nobody types it; a shorthand had to be added anyway           |

## Sources

- [`website/docs/file-query.md`][wm-query] — the generator/expression split, the five generators, `dedup_results`, and the suffix-versus-glob cost note (all quoted above).
- [`website/docs/expr/match.md`][wm-match] — `basename`/`wholename` scope, `includedotfiles`, `noescape` (quoted above).
- [`website/docs/expr/dirname.md`][wm-dirname] — parameterised prefix closure (quoted above).
- [`website/docs/expr/`][wm-expr] — the full expression-term set.
- [`website/docs/simple-query.md`][wm-simple] — the hand-writable shorthand.

<!-- References -->

[wm-repo]: https://github.com/facebook/watchman
[wm-query]: https://github.com/facebook/watchman/blob/d99639db2d674b3612f635b0e7cfaf091baf0a37/website/docs/file-query.md
[wm-match]: https://github.com/facebook/watchman/blob/d99639db2d674b3612f635b0e7cfaf091baf0a37/website/docs/expr/match.md
[wm-dirname]: https://github.com/facebook/watchman/blob/d99639db2d674b3612f635b0e7cfaf091baf0a37/website/docs/expr/dirname.md
[wm-expr]: https://github.com/facebook/watchman/tree/d99639db2d674b3612f635b0e7cfaf091baf0a37/website/docs/expr
[wm-simple]: https://github.com/facebook/watchman/blob/d99639db2d674b3612f635b0e7cfaf091baf0a37/website/docs/simple-query.md
[clockspec]: https://github.com/facebook/watchman/blob/d99639db2d674b3612f635b0e7cfaf091baf0a37/website/docs/clockspec.md
[pathspec]: ./git-pathspec.md
[hg]: ./mercurial-filesets.md
