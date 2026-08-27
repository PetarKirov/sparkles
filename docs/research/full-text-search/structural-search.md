# Structural search — ast-grep, Comby, Semgrep, tree-sitter queries

A **boundary page**: what regex cannot express, and where content search stops.
Not a competing implementation target — the [scope statement][index] says so —
but the border needs to be drawn, because hue has tree-sitter and will be asked
why it does not use it for search.

> **Last reviewed:** August 28, 2026.

---

## What regex cannot express

Three things, and each has a real user request behind it:

1. **Nesting.** "A `try` block containing an `await` with no `catch`" is not a
   regular language. Balanced delimiters are the canonical example, and no amount
   of pattern cleverness fixes it.
2. **Identity across a match.** "A variable assigned and then used" needs
   backreference-like binding across arbitrary distance. Backreferences do exist
   in [PCRE2][pcre2] — at the cost of the [linear-time guarantee][engine], which
   is the trade every guaranteeing engine refuses.
3. **Semantic role.** "`parse` as a _function name_, not in a comment or a
   string" needs a parse, not a pattern. This is the same question `PKL6`'s
   definition classifier asks, one step further.

## The subjects, briefly

**ast-grep** (Rust, `6cf4957f5151ec68c4434127d4d9cc0f35992a87`) is the closest to
grep's ergonomics:

> _"ast-grep is an abstract syntax tree based tool to search code by pattern
> code. Think of it as your old-friend grep, but matching AST nodes instead of
> text. You can write patterns as if you are writing ordinary code."_
> — [`README.md`][ag-readme] `[source-verified]`

The pattern _is_ code with metavariables (`var code = $PATTERN`), so there is no
second query language to learn — and its core is tree-sitter, the same engine
[`sparkles:tree-sitter`][ts] wraps.

**Comby** (`3b6bdff7bc3b50361b621da9db030152772e7e6b`) takes a different position:
lightweight parsing of balanced delimiters rather than a full grammar, so one
matcher works across many languages without a grammar per language. Less precise,
far cheaper to extend.

**Semgrep** goes furthest — real semantic analysis, taint tracking, cross-file
inference — and is a static-analysis tool that happens to have a search interface.

**tree-sitter queries** are the substrate under ast-grep and are already available
in this repository: `sparkles:syntax` runs them for highlighting.

## Why this is a boundary, not a target

**Cost.** Structural search requires a parse per file. A regex scan reads bytes
and discards them; a structural scan builds a tree. For an interactive picker over
a whole repository that is the difference between a frame budget and a coffee
break — and it is precisely the reason `PKL6`'s decided design classifies with a
byte heuristic during the scan and reserves tree-sitter for the handful of visible
rows, from a parse the preview already performed.

**Grammar coverage.** Structural search only works where a grammar exists. hue
bundles a fixed grammar set; content search must work on the files that have none,
which is most of a real tree's configuration, data and prose.

**It answers a different question.** "Where is this string" and "where is this
construct" are different user intents. A tool that silently converts one into the
other is wrong more often than it is clever.

## What hue should take from it

One thing, and it is already decided: **tree-sitter as a refinement on a small
set, never as the scan.** [Zoekt][zoekt] reaches the same conclusion from the
other direction — it runs ctags at _index_ time so that definition-ness is a
stored fact rather than a per-hit computation. Same insight, different affordance:
do the expensive structural work once, where it is affordable, and let something
cheap do the volume.

A future `hue` structural-search _mode_ — explicitly chosen, over the open
document or a bounded file set — is a reasonable feature and is out of scope for
`P4`. Recording it here means it will not be confused with the grep source.

## Sources

`[source-verified]`: [ast-grep `README.md`][ag-readme] at
`6cf4957f5151ec68c4434127d4d9cc0f35992a87`; Comby cloned at
`3b6bdff7bc3b50361b621da9db030152772e7e6b`. `[literature]`: Semgrep's published
architecture. Related: [`PKL6`'s classifier evidence][fff-grep], [Zoekt's symbol
index][zoekt], and this repository's existing tree-sitter integration.

<!-- References -->

[index]: ./index.md
[pcre2]: ./pcre2.md
[engine]: ./engine-comparison.md
[fff-grep]: ./fff-grep.md
[zoekt]: ./trigram-indexes/zoekt.md
[ts]: ../../libs/base/index.md
[ag-readme]: https://github.com/ast-grep/ast-grep/blob/6cf4957f5151ec68c4434127d4d9cc0f35992a87/README.md
