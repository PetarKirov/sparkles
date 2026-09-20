# Shell tools: `find`, `fd`, ripgrep

Three tools whose selection syntax is what our users' fingers already know.
`find` is the oldest explicit-operator file expression language in existence;
`fd` and ripgrep are the modern replacements that deliberately threw the
expression language away.

|                    |                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------- |
| Subjects           | GNU `find` 4.10.0 · [`fd`][fd-repo] · [ripgrep][rg-repo]                                    |
| Surveyed revisions | findutils 4.10.0 [man page][find-man] · fd [`9e8927e8`][fd-cli] · rg [`3fce3b5b`][rg-flags] |
| Category           | Command-line file traversal and search                                                      |
| Composition model  | `find`: explicit operators with implicit AND · `fd`/`rg`: ordered glob rules                |
| Grammar            | `find`: shell-word tokens, precedence in the tool · `fd`/`rg`: none                         |

## Overview

### What they solve

`find` walks a tree and evaluates a predicate per entry. `fd` and ripgrep do
the same thing with better defaults (gitignore-aware, parallel, coloured) and
drop the predicate language in favour of one pattern plus filter flags.

### Design philosophy

`find`'s expression is a full boolean language whose atoms are tests and whose
terminals are actions — a design that is powerful and, as its own manual page
demonstrates, a reliable source of bugs.

`fd`'s and ripgrep's philosophy is that **the common case should need no
syntax**, and that anything beyond it belongs in flags rather than operators.
The result is that neither can express intersection of two patterns except by
repeating a flag.

## Analysis

### 1. Composition model

`find` has the full set: grouping, negation, conjunction (implicit or `-a`),
disjunction (`-o`), and a sequencing comma. `fd` and ripgrep have ordered glob
rules — ripgrep says so in one sentence:

> Globbing rules match `.gitignore` globs. Precede a glob with a `!` to exclude
> it. If multiple globs match a file or directory, **the glob given later in
> the command line takes precedence.**
>
> — [`crates/core/flags/defs.rs`][rg-flags]

`fd` adds `--and` for additional required patterns, which is conjunction by
flag repetition rather than by operator.

### 2. Operator surface & precedence

`find`'s table, "listed in order of decreasing precedence":

| Form             | Meaning                                            |
| ---------------- | -------------------------------------------------- |
| `( expr )`       | grouping (usually needs shell-escaping: `\( … \)`) |
| `! expr`         | negation; `-not` is the non-POSIX synonym          |
| `expr1 expr2`    | implicit `-a`; short-circuits                      |
| `expr1 -a expr2` | conjunction; `-and` is the non-POSIX synonym       |
| `expr1 -o expr2` | disjunction; `-or` is the non-POSIX synonym        |
| `expr1 , expr2`  | list — both evaluated, value is the second         |

— [`find(1)`][find-man]

and immediately afterwards, the field's most famous precedence footgun, which
the manual page documents because it has bitten everyone:

> Please note that `-a` when specified implicitly (for example by two tests
> appearing without an explicit operator between them) or explicitly has higher
> precedence than `-o`. This means that `find . -name afile -o -name bfile
-print` will never print `afile`.
>
> — [`find(1)`][find-man]

Two lessons. First, `find` gets the precedence _right_ (`-a` over `-o`) and
still confuses people, because the **action** at the end binds into the last
disjunct — a hazard specific to languages that mix predicates with effects, and
a reason to keep a fileset language effect-free. Second, `find` ships both word
(`-and`/`-or`/`-not`) and symbol (`-a`/`-o`/`!`) forms, with the words marked
"not POSIX compliant" — a dual surface whose second half exists only for
readability.

### 3. Primary vocabulary & the kind namespace

`find`'s primaries are flag-shaped: `-name`, `-path`, `-iname`, `-regex`,
`-type f`, `-newer`, `-size`. The leading `-` is the namespace — the same job a
`kind:` prefix does, discharged by the argument convention instead. This works
only because `find` takes its starting points before the expression, so a bare
word is never a pattern.

`fd` and ripgrep have no namespace: the single positional argument is the
pattern and everything else is a flag.

### 4. Anchoring & glob semantics

The three tools give three answers, and the divergence is the practical core of
this page.

**`find`** anchors nothing: `-name` matches the base name, `-path` matches the
whole path, and the user picks.

**`fd`** matches the base name by default. `--full-path`/`-p` switches to the
whole path, and the help text points at the resulting glob form
(`fd --glob -p '**/.git/config'`) — [`src/cli.rs`][fd-cli]. `--exact` exists
because the default pattern is a _substring_ regex, not an anchored one.

**ripgrep** takes `.gitignore`'s rule wholesale, including the part that
surprises people, and documents the surprise in the flag's own help:

> When this flag is set, every file and directory is applied to it to test for
> a match. For example, if you only want to search in a particular directory
> `foo`, then `-g foo` is incorrect because `foo/bar` does not match the glob
> `foo`. Instead, you should use `-g 'foo/**'`.
>
> — [`crates/core/flags/defs.rs`][rg-flags]

That paragraph is the case for **prefix closure**: the tool has to explain, in
its own `--help`, that the obvious input does not do the obvious thing.
[jj][jj] and [Mercurial `path:`][hg] avoid the explanation by making closure
the default.

ripgrep also documents the brace extension and its provenance:

> As an extension, globs support specifying alternatives: `-g 'ab{c,d}*'` is
> equivalent to `-g abc -g abd`. Empty alternatives like `-g 'ab{,c}'` are not
> currently supported. Note that this syntax extension is also currently
> enabled in gitignore files, even though this syntax isn't supported by git
> itself.
>
> — [`crates/core/flags/defs.rs`][rg-flags]

`{a,b}` alternation is therefore expected by every ripgrep user, is already
compiled by [`sparkles.fuzzy.glob`][glob-src], and is the reason a `{…}`
delimiter is a poor choice for a fileset region.

### 5. Lexis: quoting, escaping, reserved characters

All three delegate to the shell, which is why `find`'s manual page is full of
`\(` and why every ripgrep glob example is single-quoted. The relevant fact
they surface is about the **domain**, not the syntax — `find(1)`'s "UNUSUAL
FILENAMES" section states the constraint any file-selection lexer must respect:

> File names are a potential problem since they can contain any character
> except `\0` and `/`.
>
> — [`find(1)`][find-man]

So every reserved character in a file-selection language reserves a legal
filename, and the language owes that filename an escape.

### 6. Evaluation strategy & pruning

`find` prunes explicitly and manually (`-prune`), which is why the
`-name .git -prune -o …` idiom exists. `fd` and ripgrep prune automatically via
the `ignore` crate's directory verdicts — the same prune/accept model
`.gitignore` defines, with the same consequence that an excluded directory's
contents are unreachable.

## Strengths

- `find`: a real algebra, with grouping, that has survived fifty years.
- `fd`/`rg`: the common case needs no syntax at all, and the defaults
  (gitignore-aware, smart-case) are right.
- ripgrep documents its own footguns in `--help`, which is the honest response
  to an anchoring rule that surprises.

## Weaknesses

- `find`'s mixing of predicates with actions makes precedence a correctness
  hazard rather than a readability one.
- `fd` and ripgrep cannot intersect two patterns; `--and` and repeated `-g` are
  flag-level workarounds.
- Three anchoring defaults across three tools people use in the same session.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                 | Trade-off                                                 |
| ------------------------------------------ | ----------------------------------------- | --------------------------------------------------------- |
| `find`: implicit `-a`, explicit `-o`       | Matches boolean convention                | The trailing action binds into the last disjunct          |
| `find`: word and symbol operator spellings | Readability vs POSIX conformance          | Two tables; the words are non-conforming                  |
| `fd`: base name by default                 | The common query is a filename            | `--full-path` needed for anything structural              |
| `rg`: `.gitignore` glob rules verbatim     | One rule for `-g` and for ignore files    | `-g foo` does not match `foo/bar`, and must be documented |
| `rg`/`fd`: no expression language          | Flags are discoverable; nothing to escape | Intersection is unreachable                               |

## Sources

- [`find(1)`, findutils 4.10.0][find-man] — the OPERATORS table, the `-o` footgun and the "UNUSUAL FILENAMES" constraint (all quoted above; reproduce locally with `nix shell nixpkgs#findutils`).
- [POSIX `find`][posix-find] — the standardised operator set, for the "not POSIX compliant" annotations.
- [`fd` `src/cli.rs`][fd-cli] — `--full-path`, `--exact`, `--and` and the glob examples.
- [ripgrep `crates/core/flags/defs.rs`][rg-flags] — the `-g/--glob` documentation (quoted above).

<!-- References -->

[find-man]: https://man7.org/linux/man-pages/man1/find.1.html
[posix-find]: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/find.html
[fd-repo]: https://github.com/sharkdp/fd
[fd-cli]: https://github.com/sharkdp/fd/blob/9e8927e8f3ee7bb699df55cb0b440f848dce6857/src/cli.rs
[rg-repo]: https://github.com/BurntSushi/ripgrep
[rg-flags]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/crates/core/flags/defs.rs
[glob-src]: ../../../libs/fuzzy/src/sparkles/fuzzy/glob.d
[jj]: ./jj-filesets.md
[hg]: ./mercurial-filesets.md
