# Comparison & synthesis

What the twenty surveyed systems agree on, where they split, and which of their
answers survive contact with a language that must compile to **both** a
directory-traversal plan and an in-memory predicate.

**Last reviewed:** September 20, 2026

---

## At a glance

| System                         | Composition             | Operators                            | Precedence               | Complement | Kind namespace               | Anchoring                         | Prefix closure      | Plans a walk      |
| ------------------------------ | ----------------------- | ------------------------------------ | ------------------------ | ---------- | ---------------------------- | --------------------------------- | ------------------- | ----------------- |
| [jj filesets][jj]              | set algebra             | `\| & ~` + prefix `~`                | `&`,`~` > `\|`           | **yes**    | hyphenated word + `:`        | root-anchored                     | **default**         | no                |
| [jj revsets][revsets]          | set algebra + graph     | `\| & ~` + 4 graph levels            | 7 levels                 | yes        | hyphenated word + `:`        | n/a                               | n/a                 | no                |
| [Mercurial filesets][hg]       | set algebra             | `\| & - + or and not !`              | `and`,`-` (5) > `or` (4) | yes        | lowercase word + `:` (16)    | root/cwd-anchored                 | `path:` yes         | no (cost model)   |
| [Sapling matchers][sapling]    | set algebra             | API combinators                      | n/a                      | no         | **closed enum** of hg's      | **explicit per kind**             | a plan verdict      | **yes**           |
| [watchman][watchman]           | generate then filter    | `allof`/`anyof`/`not` (JSON)         | n/a (nesting)            | **yes**\*  | JSON term names              | **explicit per term**             | parameterised depth | **yes**           |
| [`bazel query`][bazel]         | set algebra             | `^ + -` / `intersect union except`   | **flat, left-assoc**     | no         | none (functions)             | n/a                               | n/a                 | no                |
| [Bazel `glob()`][bazel]        | ordered rules           | none                                 | n/a                      | no         | none                         | package-anchored                  | no                  | prefetch          |
| [Ant `<fileset>`][ant]         | two-layer hybrid        | `<and>/<or>/<not>/<none>/<majority>` | XML nesting              | yes        | XML element per primary      | base-dir anchored                 | trailing `/`        | no                |
| [Gradle `PatternSet`][ant]     | two-layer hybrid        | `intersect`/`union`/`negate`         | method chaining          | yes        | `Spec` closures              | base-dir anchored                 | trailing `/`        | no (lazy tree)    |
| [git pathspec][pathspec]       | ordered rules           | `:!` / `:^` only                     | n/a                      | no         | symbol signature / word set  | dir-prefix, `*` crosses `/`       | dir matches subtree | **yes** (per arg) |
| [sparse-checkout cone][sparse] | canonical dir set       | none (directories only)              | n/a                      | no         | none                         | root-anchored dirs                | **only** closure    | **yes** (hashed)  |
| [`.gitignore`][ordered]        | ordered rules           | `!`                                  | positional               | per-rule   | none                         | float unless `/`                  | dir → prune         | **yes**           |
| [rsync filters][ordered]       | ordered rules           | `+`/`-` per line                     | positional               | per-rule   | rule-letter prefixes         | suffix, `/` anchors               | `dir/***`           | yes               |
| [the `ignore` crate][ignore]   | ordered rules           | `!` in globs                         | **7 numbered steps**     | per-rule   | file-type table              | gitignore                         | dir → prune         | **yes**           |
| [nixpkgs `lib.fileset`][nix]   | set algebra             | functions                            | host language            | **no**     | n/a (no patterns)            | absolute paths                    | dir = subtree       | lazy cutoff       |
| [fzf][implicit]                | implicit conjunction    | sigils + `\|`                        | **`\|` > implicit AND**  | per-term   | none                         | n/a (strings)                     | n/a                 | no                |
| [fff][implicit]                | implicit conjunction    | `!` prefix only                      | n/a                      | per-term   | word + `:`, incl. `g:` `st:` | gitignore (downstream of a guess) | no                  | no                |
| [`find`][shell]                | explicit + implicit AND | `! -a -o ,` + `( )`                  | `!` > `-a` > `-o` > `,`  | yes        | `-flag` primaries            | caller's choice                   | n/a                 | manual `-prune`   |
| [`fd`][shell]                  | ordered rules           | `!` in globs, `--and` flag           | n/a                      | per-glob   | none                         | **base name**                     | no                  | yes               |
| [ripgrep][shell]               | ordered rules           | `!` in globs                         | positional (later wins)  | per-glob   | none                         | gitignore                         | no                  | yes               |

\* watchman's `not` is safe because a generator has already bounded the
universe — see [Generators versus predicates][gen].

---

## Per-dimension synthesis

### 1. Composition model — set algebra wins, and the reason is intersection

Every system whose job is to **answer a question** (jj, Mercurial, Bazel query,
nixpkgs) is a set algebra. Every system whose job is to **configure a default**
(`.gitignore`, rsync, `.npmignore`, CODEOWNERS, `glob()`, `rg -g`) is an
ordered rule list. The split is not historical; it follows from whether
intersection is ever needed.

Ordered rules cannot express intersection at all, and all four of the
ordered-rule subjects have accreted a workaround for the one place they needed
it: npm's `files`-plus-subdirectory-`.npmignore` override, CODEOWNERS' removal
of `!` to keep the fold total, rsync's per-directory merge files, and Bazel's
`glob(include, exclude)` pair.

Two further models appear once the survey includes systems built for scale:

- **Generate then filter** ([watchman][watchman]). A generator bounds the
  candidate set, an algebra filters it. This is the only model in the field that
  makes the Plan/Predicate split part of the user-facing API, and it is the one
  that licenses a complement — see [Generators versus predicates][gen].
- **Two-layer hybrid** ([Ant and Gradle][ant]). Ordered include/exclude patterns
  for paths, a genuine boolean algebra one level up over predicates. Ant's
  manual states the seam exactly — "this makes a FileSet equivalent to an
  `<and>` selector container" — and Gradle names it with
  `PatternSet.intersect()`, whose `addToAntBuilder` emits an Ant `<and>` node.
  The lineage's answer to "ordered rules cannot intersect" is: don't fix the
  rules, put the algebra above them.

And one model is the _absence_ of a language. [git sparse-checkout][sparse]'s
cone mode takes a list of directory names and nothing else, because the general
pattern language did not scale — the field's only recorded retreat.

### 2. Operator surface — symbols, and the precedence is not optional

- **Symbols only, `&`/`~` tighter than `|`** — jj (both languages).
- **Symbols plus words, same precedence shape** — Mercurial, Bazel query,
  `find`.
- **Flat precedence** — Bazel query alone, and its own parser comment
  (`// All operators are left-associative and of equal precedence.`) is the
  clearest statement of the cost: `a + b ^ c` parses as `(a + b) ^ c` and reads
  as the opposite.
- **Inverted precedence** — fzf, forced by implicit conjunction.
- **No precedence at all** — [watchman][watchman] (JSON nesting), [Ant][ant]
  (XML nesting), [Gradle][ant] and [Sapling][sapling] (API calls),
  [nixpkgs][nix] (host language). Every system that gave up on a textual syntax
  also gave up on this entire design question, which is the honest accounting of
  what a syntax costs.

The [`ignore` crate][ignore] is the limiting case in the other direction: with
no operators at all, it still needs **seven numbered precedence steps**, with
two orthogonal axes inside step two, to specify what its walker does.

Word operators are a genuine readability win in a config file and a genuine
cost in a language whose operands are filenames: Mercurial has to say that an
identifier must be quoted "if it matches one of the predefined predicates".

### 3. Kind namespace — a prefix, never a bare keyword

Unanimous among the systems that have non-path primaries. The shapes differ in
extensibility:

| Shape                       | Example             | New selector | New modifier               |
| --------------------------- | ------------------- | ------------ | -------------------------- |
| word + `:`                  | `glob:`             | new prefix   | new prefix (combinatorial) |
| hyphenated word + `:`       | `root-prefix-glob:` | new prefix   | new suffix (combinatorial) |
| symbol signature            | `:!`                | new symbol   | new symbol                 |
| **word set in parentheses** | `:(glob,icase)`     | new word     | **new word (additive)**    |

git's long form is the only shape where modifiers compose instead of
multiplying, and jj's `root-prefix-glob-i:` is the visible cost of not having
it. [watchman][watchman] reached the same shape independently in a different
notation — a trailing flag dictionary,
`["match", "*.txt", "basename", {"includedotfiles": true}]` — which makes it two
occurrences of the additive idea against three of the combinatorial one.

[Sapling][sapling] shows the other axis: its kind namespace is Mercurial's,
promoted to a **closed Rust enum** with the anchoring rule documented per
variant. That buys exhaustive matching and no unknown-kind path at runtime, and
costs the ability to add a selector without a source change — the exact opposite
trade from reserving a _shape_.

### 4. Anchoring — the field splits by context, not by taste

| Context                      | Rule                  | Systems                                    |
| ---------------------------- | --------------------- | ------------------------------------------ |
| A **query** someone types    | anchored              | jj, Mercurial `glob:`, git pathspec, Bazel |
| An **ignore file**           | float unless slashed  | `.gitignore`, `.hgignore`, `.npmignore`    |
| A **search tool's filter**   | float unless slashed  | ripgrep `-g`                               |
| A **search tool's pattern**  | base name             | `fd`, watchman `match` (default)           |
| A **build file**             | anchored to base dir  | Ant, Gradle                                |
| A system built for **scale** | **explicit per term** | watchman, Sapling                          |

Mercurial ships **both** rules in one tool and documents the split explicitly:
`glob:` is rooted at the current directory, while ".hgignore are not rooted".
That is the evidence that anchoring is a property of the _context_, not of the
language, and it is why a language serving both a picker and a build system has
a real decision to make rather than an obvious one.

The last row should give a designer pause. The two subjects here that had to
make file selection work at Meta scale both **refuse to infer** the anchoring
scope from a pattern's shape: [watchman][watchman] takes it as an argument
(`["match", "dir/*.txt", "wholename"]`), [Sapling][sapling] as a separate kind
(`glob:` versus `relglob:`, `path:` versus `relpath:`, `re:` versus `relre:`).
Inference is what the tools people type into interactively choose; explicitness
is what the tools that must be right at scale choose. A language serving both
needs the inference _and_ a one-character override in each direction — see
[the recommendations][rec] O1.

**Prefix closure** is where the field is most useful and most divided.
jj makes it the default pattern kind; Mercurial's `path:` has it; rsync spells
it `dir/***`; [Ant][ant] has spelled it as a trailing `/` since 2000; ripgrep
refuses it and documents the refusal in `--help`. The tools that refuse it are
the ones that have to explain themselves.

[Sapling][sapling] supplies a fourth answer, and it is the best one: closure
need not be a property of the _pattern_ at all. `DirectoryMatch::Everything` is
a verdict the matcher returns about a directory during the walk, so a subtree is
admitted wholesale without any kind having to say so.

### 5. Lexis — a positive charset, and one honest escape

Both VCS languages define the bare-token charset **positively** — jj's
`XID_CONTINUE | "+" | "-" | "." | "@" | "_" | "*" | "?" | "[" | "]" | "/" | "\\"`,
Mercurial's `[.*{}[]?/\_a-zA-Z0-9\x80-\xff]`. Neither defines it as "everything
except the operators". The difference matters for evolution: with a positive
charset, reserving a new operator character is a no-op for every query that
parses today; with a negative one, it silently reinterprets existing input.

On escaping, the field offers one convention and two anti-patterns:

- **Convention** — `\` quotes the next character (`.gitignore`, jj, Mercurial).
- **Anti-pattern 1** — `\x` is the _identity_ for unreserved `x` (`.gitignore`:
  "`\a` matches `a`, even though there is no need for escaping there"), which
  permanently freezes the reserved set.
- **Anti-pattern 2** — a context-dependent escape (rsync: `\` escapes "only …
  if at least one wildcard character is present in the match pattern"), which
  cannot be lexed in one pass.

And the domain constraint every one of them lives under, from `find(1)`: file
names "can contain any character except `\0` and `/`".

### 6. Evaluation & pruning — the divide that decides everything else

| Universe                             | Systems                                                                                         | Consequence                                      |
| ------------------------------------ | ----------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| A materialised manifest or index     | jj, Mercurial, fff, Bazel query                                                                 | complement is cheap; no plan is needed           |
| An index the system itself maintains | watchman                                                                                        | complement is cheap _within a generator's bound_ |
| A directory tree that must be walked | `.gitignore`, rsync, `fd`, `rg`, git pathspec, nixpkgs, Ant/Gradle, the `ignore` crate, Sapling | prune/accept verdicts; complement is ruinous     |

Everything in this survey that permits a unary complement evaluates against an
already-enumerated universe. Everything that walks a tree either omits
complement (nixpkgs, `glob()`, ripgrep globs) or accepts that negation is
per-rule and that an excluded directory is simply never opened
(`.gitignore`: "Git doesn't list excluded directories for performance
reasons").

Three subjects turn this into engineering rather than a caveat.

**[Sapling][sapling]** makes the plan a typed method. `matches_directory`
returns `Everything` / `Nothing` / `ShouldTraverse`, with the soundness property
documented on the top element — "`ShouldTraverse` is a value that is always
valid. It does not provide additional information." Its combinators then write
the lattice joins out: one `Nothing` short-circuits an intersection,
`Everything ∩ Everything = Everything` preserves closure, and the empty
intersection is `Nothing`, because `Everything` there would mean walking the
whole repository. `DifferenceMatcher` even defers evaluating its exclude
operand, "since in some cases we can avoid executing it entirely … [it] may
inspect a manifest or the treestate".

**[git sparse-checkout][sparse]** supplies the counterfactual. Non-cone mode is
the unrestricted pattern language, and git measured what that costs —
"O(N\*M) pattern matches, where N is the number of patterns and M is the number
of paths in the index" — named the only mitigation, "limiting the number of
patterns via specifying leading directory name or glob", concluded that users
cannot be relied on to supply one, and replaced the whole thing with a canonical
directory set over which "Git will use faster hash-based algorithms to compute
inclusion". The sentence to pin above any fileset IR is the last one: "The
excessive flexibility made other extensions essentially impractical.
`--sparse-index` is likely impossible in non-cone mode." An unprunable language
does not merely run slowly — it forecloses later work.

**[Mercurial][hg]** is the only subject that optimises the expression tree with
a **cost model** — `WEIGHT_CHECK_FILENAME = 0.5` against
`WEIGHT_READ_CONTENTS = 30` — commuting intersections so the cheap predicate
runs first, folding `x and not y` into `minus`, and coalescing a union of
patterns into one compiled matcher.

Together they are the three layers a fileset compiler wants: a typed prune
verdict (Sapling), a language restricted enough that the verdict is always
computable (sparse-checkout), and a cost model to order what remains
(Mercurial).

---

## Consensus standard

A file-selection language written today, on the evidence of this survey, has:

1. **Explicit infix set algebra** — `|`, `&`, difference, parentheses.
2. **`&` and difference binding tighter than `|`**, left-associative.
3. **Symbolic operators**, with word forms only if the language is primarily
   read rather than typed.
4. **A `kind:` prefix namespace**, so no bare word is ever a keyword, with
   modifiers as an additive set rather than concatenated names.
5. **A positive bare-token charset** and a `\` escape that errors rather than
   silently identifies.
6. **Prefix closure by default** — a pattern naming a directory means its
   subtree.
7. **Complement only if the universe is already enumerated** — or, following
   [watchman][watchman], only inside a generator that has bounded it.
8. **Emptiness treated as a defect** (Bazel's `allow_empty = False`), and
   missing literal paths treated as errors (nixpkgs' strict existence check).
9. **A typed, three-valued directory verdict** whose top element is documented
   as always sound ([Sapling][sapling]'s `ShouldTraverse`, the
   [`ignore` crate][ignore]'s `Match::None`) — two independent arrivals at the
   same shape.
10. **A language restricted enough that the verdict is always computable.**
    [git sparse-checkout][sparse] is the field's proof by counterexample.

---

## Delta table — where `sparkles` stands today

| Capability                       | Field standard                      | `sparkles` today                                                                     | Gap                                        |
| -------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------ |
| Set algebra over file selections | jj, hg, nixpkgs                     | none — `include`/`exclude` string lists (`glob_walk.d`)                              | the whole language                         |
| Grouping / nesting               | universal                           | none                                                                                 | the whole language                         |
| Explicit operators               | `\| & ~`                            | implicit: `include` wins over `exclude`, positionally                                | the whole language                         |
| `kind:` namespace                | word + `:`                          | `ext:` `path:` `seg:` `glob:` `status:`/`git:`/`st:`/`g:` (`fuzzy/query.d`)          | retire the 1–2 char aliases; fix the shape |
| Bare-token classification        | positive charset + kinds            | per-token heuristics (`dispatchPositive`) with `!=` / `!!foo` carve-outs (`PKQ3`)    | replace with a delimited region            |
| Anchoring                        | `.gitignore` float-unless-slashed   | `globAny`: base name **or** whole path, via Phobos `globMatch` where `*` crosses `/` | one rule instead of a double match         |
| Prefix closure                   | jj default, hg `path:`              | ad-hoc: a string-prefix test in `explorer.d` re-admits directories for `build/*.log` | make it a pattern-level rule               |
| Literal-path-prefix analysis     | git pathspec (per arg)              | the same `explorer.d` string test, which fails for `**/x/*.log`                      | a real lattice over the expression         |
| Statically empty detection       | Bazel, dynamically                  | none                                                                                 | new, and cheaper than Bazel's              |
| Cost-model reordering            | Mercurial only                      | none                                                                                 | wanted for `git:` and content predicates   |
| Generator / predicate split      | watchman (API), Sapling (trait)     | planned — the IR's two consumers                                                     | name it; it is the whole design            |
| Three-valued directory verdict   | Sapling, the `ignore` crate         | `dir_walk.d`'s hook returns `bool` from `enterDir`                                   | a boolean cannot say "admit the subtree"   |
| Explicit anchoring override      | watchman (argument), Sapling (kind) | none — `globAny` infers, and in two directions at once                               | keep the inference, add `/p` and `**/p`    |
| Errors as values, borrowed spans | none (all allocate)                 | `FuzzyError { code, offset, context }`, `@safe pure nothrow @nogc`                   | **ahead of the field**; keep it            |
| `{a,b}` alternation              | rg extension, hg, our glob engine   | supported by `sparkles.fuzzy.glob`                                                   | rules out `{…}` as a region delimiter      |

The two rows at the bottom are worth stating plainly: our error model is
already better than every surveyed subject's (all of which allocate strings and
several of which throw), and our glob engine already implements brace
alternation, which constrains the delimiter choice before the language exists.

---

## Architectural trade-offs

- **Complement versus pruning.** They cannot both be had _in an unbounded
  expression_. [watchman][watchman] shows the seam: a complement under a
  generator that has already bounded the universe is cheap, and only a
  free-floating one is ruinous. Choosing the walk therefore means choosing no
  free `~x`, with the compensation that every expression has a computable start
  set.
- **Flexibility versus future optimisations.** The cost of an unprunable
  language is not only slowness — [git sparse-checkout][sparse] found that it
  made `--sparse-index` "likely impossible". Restrictions adopted late cost a
  deprecation.
- **Delimiter versus heuristics.** A region marker costs one token and buys the
  removal of fff's entire carve-out chain. The cost is that a fileset region is
  a mode, and modes need a visible affordance in the prompt.
- **Anchoring versus muscle memory.** Anchoring is more predictable; floating
  is what every user's ripgrep and `.gitignore` have trained them on. The
  `.gitignore` rule is the one compromise the field has actually converged on,
  because it anchors precisely the patterns that _can_ prune.
- **Word operators versus filenames.** Every reserved word is a directory name
  someone has. Symbols cost nothing because the input is quoted anyway.

---

## Sources

Every claim on this page is restated with a primary-source citation in the
deep-dive it comes from: [jj filesets][jj], [jj revsets][revsets],
[Mercurial][hg], [Bazel][bazel], [git pathspec][pathspec],
[ordered-rule filters][ordered], [nixpkgs][nix],
[implicit-conjunction pickers][implicit], [shell tools][shell],
[watchman][watchman], [git sparse-checkout][sparse], [the `ignore` crate][ignore],
[Ant & Gradle][ant] and [Sapling][sapling].

<!-- References -->

[jj]: ./jj-filesets.md
[revsets]: ./jj-revsets.md
[hg]: ./mercurial-filesets.md
[bazel]: ./bazel.md
[pathspec]: ./git-pathspec.md
[ordered]: ./ordered-rule-filters.md
[nix]: ./nixpkgs-fileset.md
[implicit]: ./implicit-and-pickers.md
[shell]: ./shell-tools.md
[watchman]: ./watchman.md
[sapling]: ./sapling.md
[ant]: ./ant-gradle.md
[ignore]: ./ignore-crate.md
[sparse]: ./git-sparse-checkout.md
[rec]: ./recommendations.md
[gen]: ./concepts.md#generators-versus-predicates
