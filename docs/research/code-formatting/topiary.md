# Topiary (language-parametric, tree-sitter)

The modern realization of [Box's 1996 idea][layout-preserving]: **do not write a formatter, write
a grammar annotation**. Topiary formats any language for which a tree-sitter grammar exists by
running a set of tree-sitter **queries** whose capture names are formatting directives —
`@append_hardline`, `@prepend_space`, `@leaf`, `@append_indent_start`. There is no per-language
code at all. For a D formatter this is a genuine third option alongside printing from the DMD AST
and formatting the token stream, and it is the reason this deep-dive exists.

|                      |                                                                                                    |
| -------------------- | -------------------------------------------------------------------------------------------------- |
| **Language (host)**  | Rust                                                                                               |
| **License**          | MIT                                                                                                |
| **Repository**       | [`tweag/topiary`][repo] @ `a307aee6` (2026-08-13)                                                  |
| **Engine**           | `topiary-core/src/` — `lib.rs`, `pretty.rs`, `atom_collection.rs`, `tree_sitter.rs`, `language.rs` |
| **Grammar bindings** | `topiary-queries/queries/<lang>/formatting.scm` — 15 languages shipped                             |
| **Category**         | foreign CST (tree-sitter) · declarative capture-driven · queries as configuration                  |
| **Layout paradigm**  | declarative-from-foreign-CST                                                                       |

---

## Overview

### What it solves

The cost of a formatter per language. Topiary's pitch:

> "Topiary aims to be a uniform formatter for simple languages, as part of the [Tree-sitter]
> ecosystem. … **Authors can create a formatter for a language without having to write their own
> formatting engine or even their own parser.** Users benefit from uniform code style and,
> potentially, the convenience of using a single formatter tool, across multiple languages over
> their codebases, each with comparable styles applied." — [`README.md`][readme]

The phrase "or even their own parser" is the crux. tree-sitter grammars already exist for most
languages — including [D, pinned in this repository's own flake][d-grammar] — so the marginal
cost of a formatter becomes the cost of writing queries.

### Design philosophy: capture names are the instruction set

A formatting specification is a `.scm` query file. From the shipped TOML rules:

```scheme
; Sometimes we want to indicate that certain parts of our source text should
; not be formatted, but taken as is. We use the leaf capture name to inform the
; tool of this.
[
  (string)
  (quoted_key)
] @leaf

; Allow blank line before
[
  (comment)
  (table)
  (table_array_element)
  (pair)
] @allow_blank_line_before

; Append line breaks
[
  (comment)
] @append_hardline
```

— [`topiary-queries/queries/toml/formatting.scm`][toml-query]

Every directive in the system is a capture name. The full vocabulary across the shipped grammars
is about thirty, and it maps directly onto [the layout-IR primitives][concepts-ir]:

| Topiary capture                                           | Concept                                                                              |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `@append_space` / `@prepend_space`                        | a space                                                                              |
| `@append_hardline` / `@prepend_hardline`                  | a mandatory break                                                                    |
| `@append_empty_softline` / `@append_spaced_softline`      | `softline` / `line`                                                                  |
| `@append_input_softline`                                  | **break iff the input had one here** — the [author's-breaks][concepts-break] channel |
| `@append_indent_start` / `@append_indent_end`             | `indent` open/close                                                                  |
| `@append_begin_scope` / `@append_end_scope`               | a `group`, delimited rather than nested                                              |
| `@append_begin_measuring_scope` / `@…end_measuring_scope` | measure _this_ span but break _that_ one                                             |
| `@append_scoped_softline` (empty / spaced)                | a break belonging to a named scope                                                   |
| `@leaf`                                                   | verbatim — do not format inside                                                      |
| `@allow_blank_line_before`                                | blank-line policy, per node kind                                                     |
| `@delete` / `@do_nothing`                                 | remove a node / suppress a rule                                                      |
| `@append_delimiter` / `@append_antispace`                 | insert a token / remove a space                                                      |
| `@multi_line_string`, `@multi_line_indent_all`            | whitespace-sensitive region handling                                                 |

Two of these are genuinely novel and worth naming:

- **`@append_input_softline`** makes [author's-breaks-preserved][concepts-break] a _per-capture_
  choice rather than a whole-formatter paradigm. gofmt applies that policy everywhere; zig fmt
  applies it via trailing commas; topiary lets a grammar author apply it to exactly the
  constructs where it is wanted.
- **Measuring scopes** decouple "what determines whether this fits" from "what breaks if it
  doesn't". In a `group`-based algebra those are necessarily the same span; here they are not.
  This is a real expressiveness gain over [the combinator vocabulary][combinators].

### Scopes instead of nesting

`@..._begin_scope` / `@..._end_scope` mark a group by its endpoints rather than by tree
containment. This matters because in a foreign CST you do not control the node boundaries — the
construct you want to group may not correspond to any single node. Delimited scopes are how a
query-driven formatter recovers the grouping the grammar author did not provide.

---

## 1. Input model & fidelity

**A tree-sitter CST**, which is full-fidelity: comments are nodes, and every byte is covered.
Topiary therefore inherits tree-sitter's other properties — error recovery, incremental parsing —
for free.

**Behaviour on unparseable input:** tree-sitter always produces a tree with `ERROR` nodes;
Topiary refuses to format when the tree contains errors (an idempotence/safety choice rather than
an architectural limit).

**Round-trip:** an **idempotence check is part of the tool's own test discipline**, and `@leaf`
gives byte-exact preservation for marked nodes.

## 2. Layout IR & break decision

**Paradigm: declarative-from-foreign-CST.** The queries produce a stream of _atoms_
(`atom_collection.rs`) which `pretty.rs` renders. Under the hood the break decision is
[combinator][combinators]-style fit testing over scopes; the novelty is entirely in how the
document is _specified_.

**Width policy:** a soft `indent`/line-width configured per language in `languages.ncl`.

## 3. Alignment, indentation & vertical rhythm

Indentation via `@append_indent_start`/`_end`; blank lines via `@allow_blank_line_before`. **No
column alignment** — the capture vocabulary has no `align`, which is the clearest expressiveness
gap versus [clang-format][clang-format] or [gofmt][gofmt].

## 4. Comments, trivia & preservation

Comments are ordinary CST nodes and are captured like anything else (`(comment) @append_hardline`).
Like [dfmt][dfmt], **there is no attachment problem** — position in the tree is position in the
output. `@leaf` handles verbatim regions; `@multi_line_string` handles whitespace-sensitive ones.

## 5. Configurability, opinionation & config discovery

**The queries _are_ the configuration.** A project can fork a `.scm` file and change its style
without touching Rust. `languages.ncl` (Nickel) declares per-language settings and grammar
sources. This is a fundamentally different configuration model from every other system here:
instead of options over a fixed formatter, the formatter itself is data.

## 6. Integration surface & output contract

**Whole document.** `topiary-cli` with `--check`; no range formatting, no cursor, no edits. A
`topiary-web-tree-sitter-sys` crate targets the browser.

---

## Strengths

- **No per-language code.** A formatter is a query file; the marginal cost of a new language is
  hours, not months.
- **Full-fidelity input for free**, with comments as nodes and no attachment problem.
- **Measuring scopes** are more expressive than `group` for foreign trees.
- **`@append_input_softline`** makes author's-breaks a per-construct decision — a genuinely good
  idea nobody else has.
- **Style is data**, forkable per project without a build.
- **Rides the tree-sitter ecosystem**, including grammars this repository already pins.

## Weaknesses

- **No alignment** in the capture vocabulary.
- **Layout quality is bounded by the grammar's shape.** If a grammar does not distinguish the
  construct you want to treat specially, no query can.
- **Query files get large and are hard to debug** — the `graphviz.rs` module exists to visualize
  what the queries did.
- **Whole-document output**, no LSP integration story.
- **Quality ceiling below hand-written formatters** for complex languages; it targets "simple
  languages" by its own README.

---

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                          | Trade-off                                                                          |
| --------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| **Formatting spec as tree-sitter queries**          | No engine, no parser, no code per language                         | Expressiveness is bounded by both the query language and the grammar's node shapes |
| **Capture names as the instruction set**            | Reuses tree-sitter's existing tooling and mental model             | ~30 magic strings with no static checking; typos are silent                        |
| **Delimited scopes** rather than tree-nested groups | In a foreign CST the construct you want to group may not be a node | Begin/end must be paired correctly by hand                                         |
| **Measuring scopes separate from breaking scopes**  | "does this fit" and "what breaks" are genuinely different spans    | An extra concept; more ways to get a query wrong                                   |
| **`@leaf` for verbatim**                            | Whitespace-sensitive constructs need byte preservation             | Anything not marked is fair game — errors of omission are silent                   |
| **Refuse trees containing `ERROR` nodes**           | Never reformat code you may have misparsed                         | Gives up tree-sitter's main advantage for editor use                               |
| **Queries as configuration**                        | Projects can restyle without forking the tool                      | No stable style; two projects' "topiary" output can differ arbitrarily             |

---

## What this means for D

Topiary is a **live third option** for a D formatter, and the survey should say so plainly rather
than defaulting to a hand-written engine:

- A `tree-sitter-d` grammar already exists and is **already pinned in this repository's flake**
  (`nix/packages/tree-sitter-d.nix`), and `libs/tree-sitter` + `libs/syntax` already drive
  whole-buffer CSTs.
- A query-driven formatter would have **no comment attachment problem** and no `Loc`-end problem,
  because it never touches DMD's AST.
- It would also have **no semantic knowledge**, which for D matters more than for TOML: `q{}`
  token strings, `mixin` bodies, and the `is`-expression grammar are places where a purely
  syntactic formatter will be blunt.

The honest assessment for [the proposal][proposal]: topiary-style formatting is the cheapest path
to _a_ D formatter and is unlikely to beat [dfmt][dfmt] on quality, because the ceiling is set by
the grammar rather than by the engine. Its ideas — `@append_input_softline`, measuring scopes,
`@leaf` — are worth taking regardless of the architecture chosen.

---

## Sources

- [`tweag/topiary`][repo] @ `a307aee6787602e51087c54f867976949feae383`:
  `topiary-core/src/{lib,pretty,atom_collection,tree_sitter,language,graphviz}.rs` ·
  `topiary-queries/queries/*/formatting.scm` (15 languages) · `languages.ncl` · [`README.md`][readme]

**Related deep-dives in this tree:**
[Layout preservation][layout-preserving] · [Combinators][combinators] · [Concepts][concepts] ·
[dfmt][dfmt] · [The D landscape][d-landscape] · [The proposal][proposal]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/tweag/topiary/tree/a307aee6787602e51087c54f867976949feae383
[readme]: https://github.com/tweag/topiary/blob/a307aee6787602e51087c54f867976949feae383/README.md
[toml-query]: https://github.com/tweag/topiary/blob/a307aee6787602e51087c54f867976949feae383/topiary-queries/queries/toml/formatting.scm
[d-grammar]: https://github.com/PetarKirov/tree-sitter-d

<!-- Theory docs -->

[layout-preserving]: ./theory/layout-preserving.md
[combinators]: ./theory/combinators.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[concepts-ir]: ./concepts.md#the-layout-ir-cross-naming-table
[concepts-break]: ./concepts.md#5-line-breaking-vocabulary
[d-landscape]: ./d-landscape.md
[proposal]: ./dmd-fmt-proposal.md

<!-- System deep-dives -->

[dfmt]: ./dfmt.md
[clang-format]: ./clang-format.md
[gofmt]: ./gofmt.md
