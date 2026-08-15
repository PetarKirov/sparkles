# rustfmt (Rust)

The formatter that **rejects the algebraic approach on purpose** and says so in writing.
rustfmt's `Design.md` is the only document in this survey that argues explicitly against
[the combinator tradition][combinators] — "Many formatting tools use a very general algorithmic
or even algebraic tool for pretty printing. This results in very elegant code, but I believe does
not give the best results" — and builds instead on a _width budget_ threaded through
hand-written per-construct rules, with a fallback to leaving the source untouched.

|                     |                                                                          |
| ------------------- | ------------------------------------------------------------------------ |
| **Language**        | Rust                                                                     |
| **License**         | Apache-2.0 / MIT                                                         |
| **Repository**      | [`rust-lang/rustfmt`][repo] @ `320de2e6` (2026-08-14)                    |
| **Size**            | `src/` = **26,471 lines**; the algorithm spine is ~5,800                 |
| **Also at**         | `$REPOS/rust/rust/src/tools/rustfmt` (in-tree subtree copy)              |
| **Category**        | AST + comment spans · heuristic budget-and-unwind · large option surface |
| **Layout paradigm** | heuristic (`Shape` budget), with verbatim fallback                       |

---

## Overview

### What it solves

Formatting Rust to the community style guide, with an explicit and unusual constraint: **do no
harm.** `Design.md` states the principle that shapes everything else:

> "First, do no harm … rustfmt should never take OK code and make it look worse. If we can't make
> it better, we should leave it as is." — [`Design.md`][design]

That is a formatter with an escape valve built into its _core loop_ rather than into a comment
directive, and it is the design's distinguishing feature.

### Design philosophy

Two choices, both argued in `Design.md`.

**AST over tokens:**

> "A reformatting tool can be based on either the AST or a token stream … I have chosen to use the
> AST approach. The primary reasons are that it allows us to do more sophisticated manipulations,
> rather than just change whitespace, and it gives us more context when making those changes."
> — [`Design.md`][design]

**Heuristics over algebra:**

> "Many formatting tools use a very general algorithmic or even algebraic tool for pretty
> printing. This results in very elegant code, but I believe does not give the best results. I
> prefer a more ad hoc approach where each expression/item is formatted using custom rules."
> — [`Design.md`][design], "Heuristic rather than algorithmic"

This survey has no dog in that fight, but the empirical consequence is measurable: rustfmt's
`src/` is 26,471 lines against prettier's ~13,000 for a comparable job, and `items.rs` alone
(3,644) plus `expr.rs` (2,550) exceed prettier's entire JS rule set. Custom rules per construct
cost custom code per construct.

---

## How it works

### `Shape` — the budget

The whole scheme is a value threaded down the tree:

```rust
pub(crate) struct Shape {
    pub(crate) width: usize,
    // The current indentation of code.
    pub(crate) indent: Indent,
    // Indentation + any already emitted text on the first line of the current
    // statement.
    pub(crate) offset: usize,
}
```

— [`src/shape.rs`][shape]

with the documented semantics that `width` "is the maximum number of characters on the last line
(excluding `indent`)", and a candid parenthesis: "Note that in reality, we sometimes use width for
lines other than the last (i.e., we are conservative)."

`Design.md` summarizes the traversal:

> "So, in summary, to format a node, we calculate the width budget and then walk down the tree
> from the node. At a leaf, we generate an actual string and then unwind, combining these strings
> as we go back up the tree." — [`Design.md`][design]

### `Rewrite` — and the `Option` that is the escape valve

Every formattable thing implements one trait:

```rust
pub(crate) trait Rewrite {
    /// Rewrite self into shape.
    fn rewrite(&self, context: &RewriteContext<'_>, shape: Shape) -> Option<String>;
    …
}
```

— [`src/rewrite.rs`][rewrite]

**Returning `None` means "I cannot format this within this budget."** The caller then either tries
a different shape or gives up and copies the original source verbatim — which is what
`missed_spans.rs` (383 lines) exists to do. "Do no harm" is not a slogan; it is the `None` branch.

This is a genuinely different failure mode from every other system in wave 1. prettier and
clang-format always produce _some_ layout; rustfmt will decline and leave your code alone.

### The shared machinery

Underneath the per-construct rules sit a few reusable engines: `lists.rs` (950) formats any
separated list; `overflow.rs` (823) implements the "last argument may overflow" heuristics that
make `foo(a, b, |x| { … })` look right; `chains.rs` (1,080) handles method chains; `pairs.rs`
(376) binary operators; `vertical.rs` (301) struct-literal field alignment. These are the closest
thing rustfmt has to a `Doc` vocabulary.

---

## 1. Input model & fidelity

**AST (`rustc_ast`) with source spans**, plus the original text for verbatim fallback. Comments
are recovered from spans between nodes and processed by `comment.rs` (2,149 lines).

**Round-trip:** `missed_spans.rs` guarantees that unformattable regions are copied byte-for-byte —
a _partial_ preservation guarantee, and the only one of its kind here. `--error-on-unformatted`
turns silent fallback into a failure.

**Behaviour on unparseable input:** refuses; the file must parse.

## 2. Layout IR & break decision

**Paradigm: heuristic budget.** No IR: `rewrite` returns `Option<String>`, so intermediate results
are _strings_, not documents. Width policy is a hard `max_width` (default 100), with
`use_small_heuristics` deriving several sub-limits from it.

The absence of an IR is the design's biggest cost: because a sub-result is already a string,
rustfmt cannot re-decide a nested layout after learning that the enclosing one broke. The
`Option` fallback exists partly to cover for that.

## 3. Alignment, indentation & vertical rhythm

`Indent` distinguishes block indent from visual (alignment) indent — the same distinction
[rustc's Oppen printer makes with `IndentStyle`][oppen]. `vertical.rs` aligns struct-literal
fields. `blank_lines_upper_bound`/`_lower_bound` control blank-line runs. `string.rs` (734) breaks
long string literals.

## 4. Comments, trivia & preservation

`comment.rs` is **2,149 lines** — recognition, normalization, wrapping (`wrap_comments`),
doc-comment handling, and `normalize_comments` to convert `/* */` to `//`. Comparable in scale to
[prettier's 1,255-line JS comment module][prettier], and for the same structural reason: an
AST-based formatter must reconstruct what the tree discarded.

Escape hatch: **`#[rustfmt::skip]`** — an _attribute_, not a comment, and therefore node-scoped
and syntactically checked. `skip.rs` (127) implements it.

## 5. Configurability, opinionation & config discovery

Large. `Configurations.md` is **3,345 lines** of options with before/after examples:

> "Rustfmt is designed to be very configurable. You can create a TOML file called `rustfmt.toml`
> … Each configuration option is either stable or unstable." — [`Configurations.md`][configurations]

The stable/unstable split is a mechanism nothing else here has: options may be added and iterated
on nightly without committing the project to them forever. Discovery walks up for
`rustfmt.toml`/`.rustfmt.toml`.

**`reorder_imports` is on by default** — so rustfmt, like clang-format, does
[job three][three-jobs] and changes tokens. `reorder.rs` (354) and `sort.rs` (377) implement it.

## 6. Integration surface & output contract

**Whole document**, via an `emitter/` abstraction (files, stdout, diff, JSON). `--check` for CI.
`range.rs` (78 lines) exists but line-range formatting is limited and unstable. No cursor
preservation. `cargo-fmt` and `git-rustfmt` wrappers ship in-tree.

---

## Strengths

- **"Do no harm" is architectural**, not aspirational — `Option<String>` plus `missed_spans.rs`.
- **Best-documented design intent** of any system here; `Design.md` argues its choices.
- **`Configurations.md` is exemplary** documentation — every option with before/after.
- **Stable/unstable option split** lets the project evolve style without breaking users.
- **Node-scoped, syntactically-checked escape hatch** (`#[rustfmt::skip]`).
- **Rich construct-specific quality** — chains, overflow, struct alignment are genuinely well
  handled, which is the payoff the heuristic argument predicts.

## Weaknesses

- **26,471 lines** for one language, and the size is a direct consequence of the philosophy.
- **No IR means no re-decision.** Sub-results are strings; a nested layout cannot be revisited.
- **Silent fallback.** Without `--error-on-unformatted`, "we left it alone" is indistinguishable
  from "we formatted it".
- **Refuses unparseable input.**
- **Weak range formatting, no cursor** — poor LSP ergonomics compared to
  [clang-format][clang-format].
- **Comment handling is 2,149 lines** and still a common source of issues.

---

## Key design decisions and trade-offs

| Decision                                                  | Rationale (from `Design.md` where quoted)                                                | Trade-off                                                                                   |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **AST, not tokens**                                       | "allows us to do more sophisticated manipulations … gives us more context"               | Must reconstruct comments and blank lines — 2,149 lines of `comment.rs`                     |
| **Heuristics, not algebra**                               | "algebraic … results in very elegant code, but I believe does not give the best results" | Custom code per construct: `items.rs` + `expr.rs` = 6,194 lines                             |
| **`Shape` budget threaded down, strings unwound up**      | Simple, no IR to design                                                                  | A nested layout is already a string when the enclosing one breaks — no re-decision possible |
| **`rewrite` returns `Option<String>`**                    | "First, do no harm … If we can't make it better, we should leave it as is"               | Failure is silent by default; users may not know a region was skipped                       |
| **Verbatim copy of unformatted regions** (`missed_spans`) | Preserves what the formatter cannot improve                                              | Output is a mix of formatted and original style, which can look inconsistent                |
| **`#[rustfmt::skip]` as an attribute**                    | Node-scoped and checked by the compiler, unlike comment directives                       | Only applies where attributes are legal — not to arbitrary line ranges                      |
| **Large option surface** with a **stable/unstable split** | Rust's community had existing conventions; options are how you get adoption              | 3,345 lines of option docs; unstable options fragment behaviour across toolchains           |
| **`reorder_imports` on by default**                       | Import order is a real style rule                                                        | The formatter changes tokens, which some users do not expect from "formatting"              |

---

## What a D formatter should take

**Take: the `Option`/do-no-harm valve.** A D formatter operating on constructs it does not fully
model — `asm`, `q{}`, deeply nested `static if`, unusual UDA placement — is better off copying
the original bytes than producing something worse. rustfmt shows how to make that a first-class
return value rather than a special case, and `--error-on-unformatted` shows how to make it
visible.

**Take:** `Configurations.md`'s before/after documentation format, and the stable/unstable option
split — both directly applicable and cheap.

**Take as a caution:** the argument against algebra is honestly made, but the line counts are the
counter-argument. For D, where the [existing in-repo layout engine][sig-layout] is already a
hand-rolled `group`, the combinator route is both cheaper and already partly built.

---

## Sources

- [`rust-lang/rustfmt`][repo] @ `320de2e6d44f3190ea7cc73772e67a2ae86f5e71`: `src/shape.rs` (416) ·
  `rewrite.rs` (184) · `visitor.rs` (1,125) · `lists.rs` (950) · `overflow.rs` (823) ·
  `chains.rs` (1,080) · `pairs.rs` (376) · `vertical.rs` (301) · `missed_spans.rs` (383) ·
  `comment.rs` (2,149) · `skip.rs` (127) · `items.rs` (3,644) · `expr.rs` (2,550) ·
  `reorder.rs` (354) · `sort.rs` (377) · `string.rs` (734) · `range.rs` (78)
- [`Design.md`][design] (184 lines) · [`Configurations.md`][configurations] (3,345 lines) ·
  `Contributing.md` · `Processes.md`

**Related deep-dives in this tree:**
[Combinators][combinators] · [Cost & search][cost-search] · [Concepts][concepts] ·
[prettier][prettier] · [clang-format][clang-format] · [dfmt][dfmt] · [Comparison][comparison]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/rust-lang/rustfmt/tree/320de2e6d44f3190ea7cc73772e67a2ae86f5e71
[design]: https://github.com/rust-lang/rustfmt/blob/320de2e6d44f3190ea7cc73772e67a2ae86f5e71/Design.md
[configurations]: https://github.com/rust-lang/rustfmt/blob/320de2e6d44f3190ea7cc73772e67a2ae86f5e71/Configurations.md
[shape]: https://github.com/rust-lang/rustfmt/blob/320de2e6d44f3190ea7cc73772e67a2ae86f5e71/src/shape.rs
[rewrite]: https://github.com/rust-lang/rustfmt/blob/320de2e6d44f3190ea7cc73772e67a2ae86f5e71/src/rewrite.rs
[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d

<!-- Theory docs -->

[oppen]: ./theory/oppen.md
[combinators]: ./theory/combinators.md
[cost-search]: ./theory/cost-and-search.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[three-jobs]: ./concepts.md#1-what-a-formatter-is-and-its-three-jobs
[comparison]: ./comparison.md

<!-- System deep-dives -->

[prettier]: ./prettier.md
[clang-format]: ./clang-format.md
[dfmt]: ./dfmt.md
