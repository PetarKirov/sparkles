# Comparison & synthesis

What the eleven surveyed systems agree on, where they split, and which of their
answers survive contact with a language that must compile to **both** a
directory-traversal plan and an in-memory predicate.

**Last reviewed:** September 20, 2026

---

## At a glance

| System                       | Composition             | Operators                          | Precedence               | Complement | Kind namespace               | Anchoring                         | Prefix closure      | Plans a walk      |
| ---------------------------- | ----------------------- | ---------------------------------- | ------------------------ | ---------- | ---------------------------- | --------------------------------- | ------------------- | ----------------- |
| [jj filesets][jj]            | set algebra             | `\| & ~` + prefix `~`              | `&`,`~` > `\|`           | **yes**    | hyphenated word + `:`        | root-anchored                     | **default**         | no                |
| [jj revsets][revsets]        | set algebra + graph     | `\| & ~` + 4 graph levels          | 7 levels                 | yes        | hyphenated word + `:`        | n/a                               | n/a                 | no                |
| [Mercurial filesets][hg]     | set algebra             | `\| & - + or and not !`            | `and`,`-` (5) > `or` (4) | yes        | lowercase word + `:` (16)    | root/cwd-anchored                 | `path:` yes         | no (cost model)   |
| [`bazel query`][bazel]       | set algebra             | `^ + -` / `intersect union except` | **flat, left-assoc**     | no         | none (functions)             | n/a                               | n/a                 | no                |
| [Bazel `glob()`][bazel]      | ordered rules           | none                               | n/a                      | no         | none                         | package-anchored                  | no                  | prefetch          |
| [git pathspec][pathspec]     | ordered rules           | `:!` / `:^` only                   | n/a                      | no         | symbol signature / word set  | dir-prefix, `*` crosses `/`       | dir matches subtree | **yes** (per arg) |
| [`.gitignore`][ordered]      | ordered rules           | `!`                                | positional               | per-rule   | none                         | float unless `/`                  | dir → prune         | **yes**           |
| [rsync filters][ordered]     | ordered rules           | `+`/`-` per line                   | positional               | per-rule   | rule-letter prefixes         | suffix, `/` anchors               | `dir/***`           | yes               |
| [nixpkgs `lib.fileset`][nix] | set algebra             | functions                          | host language            | **no**     | n/a (no patterns)            | absolute paths                    | dir = subtree       | lazy cutoff       |
| [fzf][implicit]              | implicit conjunction    | sigils + `\|`                      | **`\|` > implicit AND**  | per-term   | none                         | n/a (strings)                     | n/a                 | no                |
| [fff][implicit]              | implicit conjunction    | `!` prefix only                    | n/a                      | per-term   | word + `:`, incl. `g:` `st:` | gitignore (downstream of a guess) | no                  | no                |
| [`find`][shell]              | explicit + implicit AND | `! -a -o ,` + `( )`                | `!` > `-a` > `-o` > `,`  | yes        | `-flag` primaries            | caller's choice                   | n/a                 | manual `-prune`   |
| [`fd`][shell]                | ordered rules           | `!` in globs, `--and` flag         | n/a                      | per-glob   | none                         | **base name**                     | no                  | yes               |
| [ripgrep][shell]             | ordered rules           | `!` in globs                       | positional (later wins)  | per-glob   | none                         | gitignore                         | no                  | yes               |

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

### 2. Operator surface — symbols, and the precedence is not optional

- **Symbols only, `&`/`~` tighter than `|`** — jj (both languages).
- **Symbols plus words, same precedence shape** — Mercurial, Bazel query,
  `find`.
- **Flat precedence** — Bazel query alone, and its own parser comment
  (`// All operators are left-associative and of equal precedence.`) is the
  clearest statement of the cost: `a + b ^ c` parses as `(a + b) ^ c` and reads
  as the opposite.
- **Inverted precedence** — fzf, forced by implicit conjunction.

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
it.

### 4. Anchoring — the field splits by context, not by taste

| Context                     | Rule                 | Systems                                    |
| --------------------------- | -------------------- | ------------------------------------------ |
| A **query** someone types   | anchored             | jj, Mercurial `glob:`, git pathspec, Bazel |
| An **ignore file**          | float unless slashed | `.gitignore`, `.hgignore`, `.npmignore`    |
| A **search tool's filter**  | float unless slashed | ripgrep `-g`                               |
| A **search tool's pattern** | base name            | `fd`                                       |

Mercurial ships **both** rules in one tool and documents the split explicitly:
`glob:` is rooted at the current directory, while ".hgignore are not rooted".
That is the evidence that anchoring is a property of the _context_, not of the
language, and it is why a language serving both a picker and a build system has
a real decision to make rather than an obvious one.

**Prefix closure** is where the field is most useful and most divided.
jj makes it the default pattern kind; Mercurial's `path:` has it; rsync spells
it `dir/***`; ripgrep refuses it and documents the refusal in `--help`. The
tools that refuse it are the ones that have to explain themselves.

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

| Universe                             | Systems                                                | Consequence                                  |
| ------------------------------------ | ------------------------------------------------------ | -------------------------------------------- |
| A materialised manifest or index     | jj, Mercurial, fff, Bazel query                        | complement is cheap; no plan is needed       |
| A directory tree that must be walked | `.gitignore`, rsync, `fd`, `rg`, git pathspec, nixpkgs | prune/accept verdicts; complement is ruinous |

Everything in this survey that permits a unary complement evaluates against an
already-enumerated universe. Everything that walks a tree either omits
complement (nixpkgs, `glob()`, ripgrep globs) or accepts that negation is
per-rule and that an excluded directory is simply never opened
(`.gitignore`: "Git doesn't list excluded directories for performance
reasons").

Mercurial is the only subject that optimises the expression tree with a **cost
model** — `WEIGHT_CHECK_FILENAME = 0.5` against `WEIGHT_READ_CONTENTS = 30` —
commuting intersections so the cheap predicate runs first, folding `x and not y`
into `minus`, and coalescing a union of patterns into one compiled matcher.
That is the single most directly transferable piece of engineering in the
survey.

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
7. **Complement only if the universe is already enumerated.**
8. **Emptiness treated as a defect** (Bazel's `allow_empty = False`), and
   missing literal paths treated as errors (nixpkgs' strict existence check).

---

## Delta table — where `sparkles` stands today

| Capability                       | Field standard                    | `sparkles` today                                                                     | Gap                                        |
| -------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------ |
| Set algebra over file selections | jj, hg, nixpkgs                   | none — `include`/`exclude` string lists (`glob_walk.d`)                              | the whole language                         |
| Grouping / nesting               | universal                         | none                                                                                 | the whole language                         |
| Explicit operators               | `\| & ~`                          | implicit: `include` wins over `exclude`, positionally                                | the whole language                         |
| `kind:` namespace                | word + `:`                        | `ext:` `path:` `seg:` `glob:` `status:`/`git:`/`st:`/`g:` (`fuzzy/query.d`)          | retire the 1–2 char aliases; fix the shape |
| Bare-token classification        | positive charset + kinds          | per-token heuristics (`dispatchPositive`) with `!=` / `!!foo` carve-outs (`PKQ3`)    | replace with a delimited region            |
| Anchoring                        | `.gitignore` float-unless-slashed | `globAny`: base name **or** whole path, via Phobos `globMatch` where `*` crosses `/` | one rule instead of a double match         |
| Prefix closure                   | jj default, hg `path:`            | ad-hoc: a string-prefix test in `explorer.d` re-admits directories for `build/*.log` | make it a pattern-level rule               |
| Literal-path-prefix analysis     | git pathspec (per arg)            | the same `explorer.d` string test, which fails for `**/x/*.log`                      | a real lattice over the expression         |
| Statically empty detection       | Bazel, dynamically                | none                                                                                 | new, and cheaper than Bazel's              |
| Cost-model reordering            | Mercurial only                    | none                                                                                 | wanted for `git:` and content predicates   |
| Errors as values, borrowed spans | none (all allocate)               | `FuzzyError { code, offset, context }`, `@safe pure nothrow @nogc`                   | **ahead of the field**; keep it            |
| `{a,b}` alternation              | rg extension, hg, our glob engine | supported by `sparkles.fuzzy.glob`                                                   | rules out `{…}` as a region delimiter      |

The two rows at the bottom are worth stating plainly: our error model is
already better than every surveyed subject's (all of which allocate strings and
several of which throw), and our glob engine already implements brace
alternation, which constrains the delimiter choice before the language exists.

---

## Architectural trade-offs

- **Complement versus pruning.** They cannot both be had. Choosing the walk
  means choosing no `~x`, and the compensation is that every expression has a
  computable start set.
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
[implicit-conjunction pickers][implicit], [shell tools][shell].

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
