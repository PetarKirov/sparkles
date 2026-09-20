# Fileset & File-Selection Query Languages

A primary-source survey of the languages people use to **name a set of files** —
the infix set algebras of Jujutsu and Mercurial, the ordered rule lists of
`.gitignore` and rsync, the prefix namespace of git pathspec, the combinator API
of nixpkgs' `lib.fileset`, and the implicit-conjunction prompts of fzf and fff.
The evidence base for the textual query DSL that
[`sparkles:build-primitives`](../../../libs/build-primitives/src/sparkles/build_primitives/glob_walk.d) is being
redesigned around, and for hue's [picker][picker] query language (`PKQ*`).

This survey answers seven questions:

1. **Which composition model does a fileset language need?** Set algebra —
   because an ordered rule list provably cannot express intersection, and all
   four ordered-rule subjects have accreted a workaround for the one place they
   needed it. See [concepts] and the [comparison].
2. **What precedence?** `&` and difference above `|`, left-associative — the
   independent conclusion of [jj][jj] and [Mercurial][hg], with
   [`bazel query`][bazel]'s flat table as the counter-example and
   [fzf][implicit]'s inverted one as the consequence of implicit conjunction.
3. **How is a non-path selector reached?** Through a `kind:` prefix, unanimously
   — with [git pathspec][pathspec]'s `:(word,word)` long form as the only shape
   whose modifiers compose additively.
4. **Anchored or floating?** Both, and the field splits by _context_:
   [Mercurial][hg] ships an anchored query language and a floating ignore file
   in the same binary and documents why. Answered for our case in the
   [recommendations][rec].
5. **Can the language afford a unary complement?** Only if its universe is
   already enumerated. Everything in this survey that walks a tree either omits
   complement or accepts that an excluded directory is never opened.
6. **What does it cost to skip the language and classify tokens by heuristic?**
   [fff][implicit]'s parser, which is the most honest available answer.
7. **What does an unprunable language cost?** More than speed:
   [git sparse-checkout][sparse] found that its general pattern mode made
   `--sparse-index` "likely impossible", deprecated it, and replaced it with a
   canonical directory set. The typed counterpart of the prefix lattice —
   `Everything` / `Nothing` / `ShouldTraverse` — is [Sapling][sapling]'s, and
   the split between what enumerates and what filters is [watchman][watchman]'s.

**Last reviewed:** September 20, 2026

> [!NOTE]
> **Scope.** Twenty-two systems, surveyed across fourteen deep-dives. Deferred,
> noted not omitted: Buck2 and Pants `glob()` (both follow Bazel's
> include/exclude shape), Perforce client-view mappings, MSBuild's
> `Include`/`Exclude`/`Remove` triple, and `.dockerignore` (a `.gitignore`-shaped
> dialect with divergences of its own). Out of
> scope: **content** search languages — regexes, trigram query planners and
> ranked retrieval are surveyed in
> [Full-Text Search](../full-text-search/index.md); the matching and ranking of
> a fuzzy query is surveyed in
> [Fuzzy Matching](../fuzzy-matching/index.md). This tree is only about the
> **set-naming** layer.
>
> Every GitHub citation pins a 40-character commit SHA. Mercurial's sources are
> cited to a tag on a host that does not answer automated checkers; each quote
> is reproducible offline with `nix shell nixpkgs#mercurial -c hg help filesets`.

---

## Master catalog

| Subject                    | Ecosystem  | Category                  | Composition                   | Operators                          | Complement | Link       |
| -------------------------- | ---------- | ------------------------- | ----------------------------- | ---------------------------------- | ---------- | ---------- |
| **jj filesets**            | Rust       | VCS query language        | set algebra                   | `\| & ~` + prefix `~`              | yes        | [jj]       |
| **jj revsets**             | Rust       | VCS query language        | set algebra + graph           | `\| & ~` + 4 graph levels          | yes        | [revsets]  |
| **Mercurial filesets**     | Python     | VCS query language        | set algebra                   | `\| & - +` and `or and not !`      | yes        | [hg]       |
| **Sapling `pathmatcher`**  | Rust       | VCS query language        | set algebra                   | API combinators                    | no         | [sapling]  |
| **watchman**               | C++ / JSON | File-watching query       | generate then filter          | `allof`/`anyof`/`not`              | yes        | [watchman] |
| **`bazel query`**          | Java       | Build-graph query         | set algebra                   | `^ + -` / `intersect union except` | no         | [bazel]    |
| **Bazel `glob()`**         | Starlark   | Build-file file selection | ordered rules                 | none                               | no         | [bazel]    |
| **git pathspec**           | C          | CLI path limiter          | ordered rules                 | `:!` / `:^`                        | no         | [pathspec] |
| **git sparse-checkout**    | C          | Working-tree filter       | ordered rules → directory set | `!` (non-cone only)                | per-rule   | [sparse]   |
| **`.gitignore`**           | C          | Ordered rule file         | ordered rules                 | `!`                                | per-rule   | [ordered]  |
| **rsync filter rules**     | C          | Ordered rule file         | ordered rules                 | `+` / `-` per line                 | per-rule   | [ordered]  |
| **`.npmignore` / `files`** | JS         | Ordered rule file         | ordered rules                 | `!`, polarity inverted             | per-rule   | [ordered]  |
| **CODEOWNERS**             | —          | Ordered rule file         | ordered rules                 | **none** (`!` removed)             | no         | [ordered]  |
| **the `ignore` crate**     | Rust       | Walker + matcher library  | ordered rules                 | `!` in globs                       | per-rule   | [ignore]   |
| **Ant `<fileset>`**        | Java       | Build-file selection      | two-layer hybrid              | `<and>/<or>/<not>/<none>`          | yes        | [ant]      |
| **Gradle `PatternSet`**    | Java       | Build-file selection      | two-layer hybrid              | `intersect`/`union`/`negate`       | yes        | [ant]      |
| **nixpkgs `lib.fileset`**  | Nix        | Build-input selection     | set algebra                   | functions                          | **no**     | [nix]      |
| **fzf**                    | Go         | Interactive finder        | implicit conjunction          | sigils + `\|`                      | per-term   | [implicit] |
| **fff**                    | Rust       | Interactive finder        | implicit conjunction          | `!` prefix                         | per-term   | [implicit] |
| **GNU `find`**             | C          | Tree traversal            | explicit + implicit AND       | `! -a -o ,` + `( )`                | yes        | [shell]    |
| **`fd`**                   | Rust       | Tree traversal            | ordered rules                 | `!` in globs, `--and`              | per-glob   | [shell]    |
| **ripgrep**                | Rust       | Content search filter     | ordered rules                 | `!` in globs                       | per-glob   | [shell]    |

---

## Taxonomy

### By composition model

| Model                | Subjects                                                                                                                                                                            | Can intersect?     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| Set algebra          | [jj][jj], [jj revsets][revsets], [Mercurial][hg], [Bazel query][bazel], [nixpkgs][nix], [Sapling][sapling]                                                                          | yes                |
| Ordered rules        | [`.gitignore`, rsync, npm, CODEOWNERS][ordered], [Bazel `glob()`][bazel], [git pathspec][pathspec], [sparse-checkout][sparse], [the `ignore` crate][ignore], [`fd`, ripgrep][shell] | **no**             |
| Generate then filter | [watchman][watchman]                                                                                                                                                                | within a generator |
| Two-layer hybrid     | [Ant, Gradle][ant]                                                                                                                                                                  | in the upper layer |
| Implicit conjunction | [fzf, fff][implicit], [`find`][shell]                                                                                                                                               | one axis only      |

### By evaluation universe

| Universe                       | Subjects                                                                                                                                                                                           | Complement affordable?     |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| Materialised manifest or index | [jj][jj], [revsets][revsets], [Mercurial][hg], [Bazel query][bazel], [fff][implicit]                                                                                                               | yes                        |
| A self-maintained index        | [watchman][watchman]                                                                                                                                                                               | within a generator's bound |
| A tree that must be walked     | [`.gitignore`][ordered], [pathspec][pathspec], [sparse-checkout][sparse], [nixpkgs][nix], [`fd`/rg][shell], [the `ignore` crate][ignore], [`glob()`][bazel], [Ant/Gradle][ant], [Sapling][sapling] | **no**                     |

### By anchoring rule

| Rule                 | Subjects                                                                                                                               |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Root/cwd anchored    | [jj][jj], [Mercurial `glob:`][hg], [git pathspec][pathspec], [Bazel `glob()`][bazel], [Ant, Gradle][ant]                               |
| Explicit per term    | [watchman][watchman] (`basename`/`wholename`), [Sapling][sapling] (`glob:`/`relglob:`)                                                 |
| Float unless slashed | [`.gitignore`, `.hgignore`, `.npmignore`][ordered], [ripgrep][shell], [the `ignore` crate][ignore], [sparse-checkout non-cone][sparse] |
| Suffix anchored      | [rsync][ordered]                                                                                                                       |
| Base name by default | [`fd`][shell], [watchman `match`][watchman]                                                                                            |
| No patterns at all   | [nixpkgs][nix]                                                                                                                         |

### By kind-namespace shape

| Shape                       | Subjects                                   | Modifier story                 |
| --------------------------- | ------------------------------------------ | ------------------------------ |
| word + `:`                  | [Mercurial][hg] (16 kinds)                 | a new kind per combination     |
| hyphenated word + `:`       | [jj][jj]                                   | `-i` suffix, still multiplying |
| symbol signature / word set | [git pathspec][pathspec]                   | **additive word set**          |
| closed enum                 | [Sapling][sapling]                         | exhaustive; a source change    |
| term name + flag dictionary | [watchman][watchman]                       | **additive flags**             |
| one element per primary     | [Ant][ant]                                 | XML gives each its own         |
| none — functions instead    | [Bazel][bazel], [Mercurial predicates][hg] | n/a                            |
| short aliases (`g:`, `st:`) | [fff][implicit], hue today                 | ambiguous with paths           |

---

## Milestones

> [!NOTE]
> Dates are the year the capability appeared in a release, taken from source
> copyright headers where one exists and from release history otherwise. Rows
> marked _approx._ could not be pinned to a primary source and should be treated
> as ordering, not as dates.

| Year           | What landed                                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------------------- |
| 1990 _approx._ | POSIX `find` standardises `! -a -o` with `-a` binding above `-o` — [shell]                                            |
| 1996 _approx._ | rsync ships `--include`/`--exclude`; the unified `--filter` rule language follows later — [ordered]                   |
| 2005           | `.gitignore` and git pathspec ship with git — [ordered], [pathspec]                                                   |
| 2010           | Mercurial introduces **filesets**; `filesetlang.py` carries a 2010 copyright — [hg]                                   |
| 2014           | `bazel query`'s `QueryParser.java` — copyright 2014, open-sourced with Bazel — [bazel]                                |
| 2015 _approx._ | fzf's extended-search mode: implicit conjunction plus a tighter-binding `\|` — [implicit]                             |
| 2016           | ripgrep adopts `.gitignore` glob rules for `-g`, plus the `{a,b}` extension — [shell]                                 |
| 2000 _approx._ | Ant's `<fileset>` introduces `**` ("matches zero or more directories") and the trailing-`/` closure shorthand — [ant] |
| 2009           | Gradle's `PatternFilterable` inherits Ant's pattern language and adds `intersect()` — [ant]                           |
| 2013 _approx._ | watchman's generator/expression split — [watchman]                                                                    |
| 2016           | ripgrep's `ignore` crate: a three-valued `Match` and a seven-step precedence fold — [ignore]                          |
| 2019 _approx._ | git sparse-checkout ships; cone mode follows, and non-cone is later deprecated — [sparse]                             |
| 2021 _approx._ | Sapling's `pathmatcher`: `DirectoryMatch` as a typed prune verdict — [sapling]                                        |
| 2023           | nixpkgs `lib.fileset` — set algebra with its design decisions written down — [nix]                                    |
| 2024           | jj filesets — Mercurial's idea with symbolic-only operators (`fileset.pest`, 2021–2024) — [jj]                        |
| 2025 _approx._ | fff's per-token constraint classification for a file picker — [implicit]                                              |

---

## Quick navigation

| If you want…                                        | Read                                                     |
| --------------------------------------------------- | -------------------------------------------------------- |
| The vocabulary these pages share                    | [concepts]                                               |
| The closest prior art to what we are building       | [jj][jj], then [Mercurial][hg]                           |
| Why ordered rules cannot be the model               | [ordered], then the [comparison]'s composition section   |
| How a prefix namespace should be shaped             | [pathspec] § kind namespace                              |
| Why complement and pruning are incompatible         | [concepts] § lattice, [ordered] § pruning                |
| What a generator is, and why it licenses complement | [concepts] § generators, then [watchman]                 |
| What an unprunable language costs later             | [sparse] § evaluation                                    |
| The typed shape of a prune verdict                  | [sapling] § evaluation, [ignore] § composition           |
| Where the word "fileset" comes from                 | [ant]                                                    |
| The cost of classifying tokens without a delimiter  | [implicit]                                               |
| **I am designing the sparkles fileset DSL**         | [recommendations][rec] → [contradictions] → [comparison] |

## Suggested reading paths

- **Designing the language** — [concepts] → [jj][jj] → [hg] → [comparison] →
  [recommendations][rec].
- **Implementing the parser** — [recommendations][rec] § grammar, diagnostics
  and worked examples, then [jj][jj] § lexis and [hg] § lexis for the two
  positive charsets it is derived from.
- **Implementing the planner** — [concepts] § lattice, [sapling] (the typed
  verdict and its joins), [sparse] (what happens without one), [pathspec]
  § evaluation, [ordered] § pruning, [ignore] (the walker), [hg] § evaluation
  (the cost model).
- **Migrating hue's picker** — [implicit], then [recommendations][rec] O3 and O5.

---

## Sources

Per-subject primary sources are listed in each deep-dive's `Sources` section.
The surveyed revisions are: jj [`88c3cd05`][jj-rev], Bazel [`7c3d22ad`][bz-rev],
git [`f78ce2f7`][git-rev], nixpkgs [`82339b1b`][nix-rev],
ripgrep [`3fce3b5b`][rg-rev], fd [`9e8927e8`][fd-rev], fzf [`b1be3a8b`][fzf-rev],
fff [`3a0ce85c`][fff-rev], rsync [`8b8de523`][rsync-rev],
watchman [`d99639db`][wm-rev], Sapling [`87b7db94`][sl-rev],
Ant [`a3a5ba18`][ant-rev], Gradle [`cb109726`][gr-rev], Mercurial tag `7.1`,
and GNU findutils 4.10.0.

<!-- References -->

[concepts]: ./concepts.md
[jj]: ./jj-filesets.md
[revsets]: ./jj-revsets.md
[hg]: ./mercurial-filesets.md
[bazel]: ./bazel.md
[pathspec]: ./git-pathspec.md
[ordered]: ./ordered-rule-filters.md
[nix]: ./nixpkgs-fileset.md
[implicit]: ./implicit-and-pickers.md
[shell]: ./shell-tools.md
[comparison]: ./comparison.md
[rec]: ./recommendations.md
[contradictions]: ./contradictions.md
[picker]: ../../specs/hue/picker.md
[watchman]: ./watchman.md
[sapling]: ./sapling.md
[ant]: ./ant-gradle.md
[ignore]: ./ignore-crate.md
[sparse]: ./git-sparse-checkout.md
[jj-rev]: https://github.com/jj-vcs/jj/tree/88c3cd0540d93f60be2ecd8aba3d64573b968418
[bz-rev]: https://github.com/bazelbuild/bazel/tree/7c3d22ada1487e275c7f4669d6e2ee4563506af9
[git-rev]: https://github.com/git/git/tree/f78ce2f7b6df702f93d40b85d6bda92a3f65da79
[nix-rev]: https://github.com/NixOS/nixpkgs/tree/82339b1bf90e105158550241d073e4641a274528
[rg-rev]: https://github.com/BurntSushi/ripgrep/tree/3fce3b5bb0236da2df6d99672afb8a719642eca7
[fd-rev]: https://github.com/sharkdp/fd/tree/9e8927e8f3ee7bb699df55cb0b440f848dce6857
[fzf-rev]: https://github.com/junegunn/fzf/tree/b1be3a8be1b833ce5b92fbbac11637643d60a046
[fff-rev]: https://github.com/dmtrKovalenko/fff/tree/3a0ce85c54875563bc55888b6b9829b44aeca911
[rsync-rev]: https://github.com/RsyncProject/rsync/tree/8b8de5232efbf851689d4c2ecd942521cc795d1f
[wm-rev]: https://github.com/facebook/watchman/tree/d99639db2d674b3612f635b0e7cfaf091baf0a37
[sl-rev]: https://github.com/facebook/sapling/tree/87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2
[ant-rev]: https://github.com/apache/ant/tree/a3a5ba1822847196a83fdc497a034a94e70b4006
[gr-rev]: https://github.com/gradle/gradle/tree/cb109726197a008f61fc29e828c9238bcee72cbb
