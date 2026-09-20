# Ordered-rule filters: `.gitignore`, rsync, `.npmignore`, CODEOWNERS

Four systems that solve file selection with a **list of rules evaluated in
order** rather than an expression. They are grouped because their limits are
identical and structural: an ordered rule list is a fold over verdicts, and a
fold over verdicts cannot express intersection.

|                    |                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------ |
| Subjects           | `.gitignore`, rsync filter rules, `.npmignore` + `package.json` `files`, GitHub CODEOWNERS                   |
| Surveyed revisions | git [`f78ce2f7`][git-ignore] · rsync [`8b8de523`][rsync-man] · npm [docs v11][npm-files] · GitHub [docs][co] |
| Category           | Ordered include/exclude rule lists                                                                           |
| Composition model  | Ordered rules                                                                                                |
| Grammar            | One pattern per line; no operators                                                                           |

## Overview

### What they solve

"Everything under here except these" — the overwhelmingly common case, stated
in the cheapest possible notation, in a file a non-programmer can edit.

### Design philosophy

Explicitly _not_ a language. `.gitignore`'s entire specification is a pattern
format plus a precedence rule:

> When deciding whether to ignore a path, Git normally checks `gitignore`
> patterns from multiple sources, with the following order of precedence, from
> highest to lowest (**within one level of precedence, the last matching
> pattern decides the outcome**)
>
> — [`Documentation/gitignore.adoc`][git-ignore]

## Analysis

### 1. Composition model

Last-match-wins over a flat list, with `!` re-including. CODEOWNERS is the same
fold with the negation removed:

> There are some syntax rules for gitignore files that do not work in
> CODEOWNERS files: … Using `!` to negate a pattern doesn't work. Using `[ ]`
> to define a character range doesn't work.
>
> — [About code owners][co]

npm inverts the polarity instead of adding an operator — `files` is an
allowlist "similar syntax to `.gitignore`, but **reversed**" — and then has to
bolt on both a subdirectory override rule and a list of files that are included
"regardless of settings" ([`package.json` reference][npm-files]). The
proliferation of special cases is what happens when a model without
intersection meets a requirement that needs one.

### 2. Operator surface & precedence

One prefix, `!`, and positional precedence. There is no grouping, so the only
way to express "A and B" is to compute it by hand into the rule order.

### 3. Primary vocabulary & the kind namespace

None. Every line is a path pattern — which is the property this survey's
[settled design][rec] adopts for bare tokens, and the reason it needs a
`kind:` namespace to recover everything else.

### 4. Anchoring & glob semantics

`.gitignore`'s rule is the one most users know:

> If there is a separator at the beginning or middle (or both) of the pattern,
> then the pattern is relative to the directory level of the particular
> `gitignore` file itself. Otherwise the pattern may also match at any level
> below the `gitignore` level.
>
> — [`Documentation/gitignore.adoc`][git-ignore]

with the equivalence spelled out:

> A leading `**` followed by a slash means match in all directories. For
> example, `**/foo` matches file or directory `foo` anywhere, **the same as
> pattern `foo`**.
>
> — [`Documentation/gitignore.adoc`][git-ignore]

So "float" is exactly "prepend `**/`", not a second matching mode.

rsync is a **third** rule, and a subtly different one — suffix-anchored rather
than floating:

> If a pattern contains a `/` (not counting a trailing slash) or a "`**`"
> (which can match a slash), then the pattern is matched against the full
> pathname, including any leading directories within the transfer. If the
> pattern doesn't contain a (non-trailing) `/` or a "`**`", then it is matched
> only against the final component of the filename or pathname. For example,
> `foo` means that the final path component must be "foo" while `foo/bar` would
> match the last 2 elements of the path.
>
> — [`rsync.1.md`][rsync-man]

Note the divergences from `.gitignore`: a slash-free pattern matches only the
**final** component (not any segment), a slashed pattern matches a **suffix**
(not the root-relative whole), and `**` alone is enough to promote a pattern to
full-path matching. rsync also adds `dir/***` as "the directory and everything
in it" — the prefix-closure case, spelled as a third asterisk.

### 5. Lexis: quoting, escaping, reserved characters

`.gitignore` is the most permissive and the most forgiving:

> A backslash (`\`) can be used to escape any character. E.g., `\*` matches a
> literal asterisk (**and `\a` matches `a`, even though there is no need for
> escaping there**). As with `fnmatch(3)`, a backslash at the end of a pattern
> is an invalid pattern that never matches.
>
> — [`Documentation/gitignore.adoc`][git-ignore]

Two rules worth naming, because a query language should copy one and refuse the
other:

- **`\x` is the identity for every unreserved `x`.** Forgiving today,
  load-bearing forever: once `\a` means `a`, `a` can never become a
  metacharacter without silently changing existing patterns.
- **A trailing backslash silently never matches.** A malformed pattern that
  produces no diagnostic is the worst of both worlds; [`sparkles.fuzzy.glob`
  already rejects it][glob-src] with `invalidEscape` / "trailing glob escape".

rsync's escaping rule is the field's cautionary tale:

> a backslash can be used to escape a wildcard character, but it is **only
> interpreted as an escape character if at least one wildcard character is
> present in the match pattern**. For instance, the pattern "`foo\bar`" matches
> that single backslash literally, while the pattern "`foo\bar*`" would need to
> be changed to "`foo\\bar*`".
>
> — [`rsync.1.md`][rsync-man]

A lexical rule that depends on a property of the whole token cannot be
implemented in one pass, cannot be explained in one sentence, and changes the
meaning of a prefix when a suffix is edited.

### 6. Evaluation strategy & pruning

`.gitignore`'s pruning behaviour is the single most important paragraph in this
page, because it is the model our Plan consumer implements:

> It is not possible to re-include a file if a parent directory of that file is
> excluded. **Git doesn't list excluded directories for performance reasons**,
> so any patterns on contained files have no effect, no matter where they are
> defined.
>
> — [`Documentation/gitignore.adoc`][git-ignore]

That is a leak of the traversal plan into the language's semantics: the rule
list is not evaluated as a predicate over paths, it is evaluated as a sequence
of prune/accept verdicts over a walk, and the two disagree. An expression
language that compiles to _both_ a plan and a predicate must keep them in
agreement, which means it cannot adopt a construct whose meaning depends on
whether a directory was opened.

## Strengths

- Trivially learnable; the format is one pattern per line.
- `.gitignore`'s float rule matches how people think about file extensions
  (`*.o` means "anywhere").
- Pruning falls out of the model for free — an excluded directory is simply not
  descended.

## Weaknesses

- No intersection, ever. Every one of the four has accreted a workaround
  (npm's `files` + subdirectory override, CODEOWNERS' removal of `!`, rsync's
  per-directory merge files).
- Three mutually incompatible anchoring rules across `.gitignore`, rsync and
  git's own pathspec.
- `.gitignore`'s prune/predicate divergence is silent.
- rsync's context-dependent backslash.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                              | Trade-off                                                           |
| ------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------------- |
| Last matching rule wins                                | One pass, no parser, editable by anyone                | Intersection is unreachable                                         |
| Float unless the pattern contains `/`                  | `*.o` means what a person means                        | A slash-free pattern has no literal prefix, so it cannot prune      |
| `\x` is the identity for unreserved `x`                | Forgiving to typists                                   | Permanently blocks reserving `x` later                              |
| Excluded directories are not descended                 | Performance                                            | Re-inclusion is silently impossible — the language and plan diverge |
| rsync: backslash escapes only if a wildcard is present | Backwards compatibility with literal Windows-ish names | Not lexable in one pass; suffix edits change prefix meaning         |

## Sources

- [`Documentation/gitignore.adoc`][git-ignore] — precedence, anchoring, `**`, escaping, and the non-descent rule (all quoted above).
- [`rsync.1.md`][rsync-man] — the "INCLUDE/EXCLUDE PATTERN RULES" section (quoted above).
- [`package.json` reference][npm-files] — the `files` allowlist and `.npmignore` override rules (quoted above).
- [About code owners][co] — the gitignore syntax CODEOWNERS drops (quoted above).

<!-- References -->

[git-ignore]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitignore.adoc
[rsync-man]: https://github.com/RsyncProject/rsync/blob/8b8de5232efbf851689d4c2ecd942521cc795d1f/rsync.1.md
[npm-files]: https://docs.npmjs.com/cli/v11/configuring-npm/package-json
[co]: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
[glob-src]: ../../../libs/fuzzy/src/sparkles/fuzzy/glob.d
[rec]: ./recommendations.md
