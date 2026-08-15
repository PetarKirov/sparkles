# Oppen's Algorithm — One-Pass Scan/Print

The **root of the field**: a language-independent prettyprinting algorithm that formats a
token stream in **time linear in the input and space proportional only to the line width**,
by running two communicating processes — a `SCAN` that looks ahead just far enough to learn
how wide each logical block would be, and a `PRINT` that consumes those measurements and
decides where to break. Everything later in this tree is either a functional re-derivation
of Oppen's bound ([combinators][combinators]), an attempt to beat its greedy decisions
([optimality][optimality]), or an industrial system that gave up on both and searched
([cost & search][cost-search]).

## At a glance

| Dimension              | Where Oppen's algorithm lands                                                                                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Input**              | A flat **stream of tokens** — strings, blanks, and `begin`/`end` block delimiters; not a tree                                                                           |
| **Objective**          | "break a stream into as few lines as possible while respecting the indentation-consistency requirements of the enclosing block" ([rustc `pp.rs`][rustc-pp], module doc) |
| **Decision rule**      | **Greedy** — at each blank, break iff the enclosing block's measured size exceeds the space left on the line                                                            |
| **Time**               | **O(n)** in the input length ([Oppen 1980][oppen], Abstract)                                                                                                            |
| **Space**              | **O(m)** in the line width — _independent of input size_ ([Oppen 1980][oppen], Abstract)                                                                                |
| **Lookahead**          | Bounded: "constant space (one line width) lookahead" ([Oppen 1980][oppen], §8)                                                                                          |
| **Streaming**          | **Yes** — "begins printing as soon as it has received a full line of input" ([Oppen 1980][oppen], Abstract)                                                             |
| **Break granularity**  | Two block modes — **consistent** (all breaks in the block taken) and **inconsistent** (break only where forced)                                                         |
| **Failure mode**       | Cannot recover when a single string exceeds `margin - indent`; "does only constant space … lookahead, and its logic is not as sophisticated as it might be" (§8)        |
| **Ships in**           | rustc's [`rustc_ast_pretty`][rustc-pp], OCaml's [`Format`][ocaml-format], Ruby's `prettyprint`, Go's `go/printer` (partially), Mesa (the original)                      |
| **Direct descendants** | [Chitil 2005][combinators] (lazy dequeues), [Chitil 2006][combinators] (delimited continuations), [Swierstra & Chitil 2009][combinators]                                |

> [!NOTE]
> This is the [theory tree][theory-index] entry for the **one-pass, bounded-lookahead**
> family. The functional re-derivations of the _same_ linear bound — Chitil's lazy dequeues
> and delimited continuations, Swierstra & Chitil's linear/bounded printer — live in
> [combinators][combinators], because their contribution is an _interface_ (a `Doc` algebra)
> layered on Oppen's _procedure_. Read this page first: every one of them is explicitly
> framed as "Oppen's bound, obtained purely".

---

## Overview / motivation

### What it solves

Before 1980 there was no published, language-independent formatting algorithm — only
per-language folklore. Oppen names this directly:

> "Prettyprinters have traditionally been implemented by rather ad hoc pieces of code
> directed toward specific languages. We instead give a language-independent prettyprinting
> algorithm. The algorithm is easy to implement and quite fast." — [Oppen 1980][oppen], §1

The problem is stated in the opening as a _negative_ example — a demonstration that the
naive answer (fill the line, wrap when full) is wrong. Given a declaration stream at width
30 you want the structure respected; but "under no circumstances", Oppen writes, do you want
the greedy-fill result that breaks between `y:` and `char;` — a break that ignores where the
logical blocks are. Formatting is therefore _not_ line wrapping: it is line wrapping
**constrained by a block structure the wrapper is told about**.

That framing sets the interface for the next forty-five years. The formatter does not parse:

> "the prettyprinter requires a front-end processor, which knows the syntax of the language,
> to handle questions about where best to break lines (that is, questions about the inherent
> block or indenting structure of the language) and questions such as whether blanks are
> redundant." — [Oppen 1980][oppen], §1

The **producer/printer split** — a language-aware front end emitting structure markers into
a language-blind back end — is the architecture prettier, `rustc_ast_pretty`, `google-java-format`
and this repository's own [`signature_layout.d`][sig-layout] all still use. It is Oppen's,
and it is the reason a layout engine can be written once and reused across languages.

### Design philosophy

Three commitments, each of which is a deliberate refusal of something more powerful:

1. **Bounded space, not bounded input.** The algorithm never buffers the document. It
   buffers at most one line's worth of unresolved decisions, so it can print an infinite
   stream. Oppen singles this out as the human-facing property:

   > "It is perhaps worth repeating one desirable feature of the algorithm — it starts
   > printing more or less as soon as it has received a full line of input, and printing
   > never lags more than a full line behind the input routine. This we consider an important
   > point in 'human engineering.'" — [Oppen 1980][oppen], §8

2. **Greedy, not optimal.** A break is decided from the block's measured width and the
   remaining columns, with no consideration of what a different choice would do further
   down. Oppen shows the cost of this himself (§8): a `cases` block indents so that a
   nested `if … then … else` no longer fits, where indenting slightly less would have
   let it fit on one line. The paper's own diagnosis: "we do not allow offsets which are a
   function of the next block in the stream" (§8). That single sentence is the gap
   [optimality][optimality] exists to close.

3. **Simple over sophisticated.** Oppen compares his bounds against four contemporaries in
   §7 — Goldstein's O(n) time / **O(n) space** LISP printers, Waters' O(mn)/O(m), Nelson's
   O(n)/O(m), Morris' O(mn)/O(m) — and closes: the algorithm "strikes the right balance
   between simplicity and speed on one hand, and sophistication on the other, to be useful
   in the applications envisaged." It is engineered for editors and unparsers, and says so.

---

## How it works

### The token vocabulary

The input is a stream of four token kinds. This vocabulary — not the procedure — is what
every descendant inherits.

| Token       | Carries                                                       | Meaning                                                                                                                 |
| ----------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **String**  | text (and, in later variants, a length)                       | Verbatim output. "The prettyprinter may break a line between strings but not within a string" ([Oppen 1980][oppen], §2) |
| **Blank**   | a length, and consistency inherited from the enclosing block  | A _candidate_ break point. Printed as that many spaces if not broken                                                    |
| **`begin`** | an `offset`, and a break type (`consistent` / `inconsistent`) | Opens a logical block; the offset is how far to indent when breaking inside it                                          |
| **`end`**   | —                                                             | Closes the innermost open block                                                                                         |

A blank of length zero is called out as a distinct idiom: "useful when one wants to insert a
possible line break but print nothing otherwise" (§4). That is `softline` in prettier's
builders, `Doc.break 0 0` in Lindig's OCaml, and `zerobreak` in `google-java-format` — the
same primitive, renamed four times.

### Consistent vs inconsistent breaking

The one genuinely non-obvious primitive, and the one most modern formatters expose under
another name. The rule:

> "If a block cannot fit on a line, and the blanks in the block are consistent blanks, then
> each subblock of the block will be placed on a new line. If the blanks in the block are
> inconsistent, then a new line will be forced only if necessary." — [Oppen 1980][oppen], §4

Oppen motivates it with a pair of preferences that pull in opposite directions: for a
`begin … end` statement list you want _every_ statement on its own line (consistent), but
for a declaration list `locals x, y, z, w, a, b, c, d;` you want the names packed and
wrapped (inconsistent). Neither policy is right for both, so the block carries its own.

rustc's reimplementation states the trade-off in one line:

> "in the consistent-break blocks we value vertical alignment more than the ability to cram
> stuff onto a line. But in all cases if it can make a block a one-liner, it'll do so."
> — [rustc `pp.rs`][rustc-pp], module doc

**Cross-naming.** Consistent breaking is prettier's `group` (all-or-nothing); inconsistent
breaking is prettier's `fill`. The mapping is not incidental — it is the same distinction
under different vocabulary, and the full table lives in [concepts][concepts-ir].

### `SCAN` and `PRINT`

The algorithm's structure is two coroutines over a shared ring buffer:

> "The algorithm is described in terms of two parallel processes: the first scans the input
> stream to determine the space required to print logical blocks of tokens; the second uses
> this information to decide where to break lines of text; the two processes communicate by
> means of a buffer of size O(m)." — [Oppen 1980][oppen], Abstract

- **`SCAN`** consumes input tokens, pushes them into the buffer, and maintains a `scan_stack`
  of the _unresolved_ `begin` and blank positions. Its job is to compute each token's
  **size**, where the size of a `begin` is the total width of everything up to its matching
  `end`. That total is unknown when the `begin` arrives, so sizes are written as negative
  placeholders and back-patched when the `end` (or a blank at the same level) resolves them.
- **`PRINT`** consumes `(token, size)` pairs off the other end of the buffer and emits
  characters, maintaining a `print_stack` of enclosing blocks and the current indentation.
  It can only act on a token whose size is known.

The bound falls out of one trick: **`SCAN` gives up early**. Once a block is obviously wider
than a line, its exact width no longer matters — any value ≥ the margin produces the same
decision — so `SCAN` writes "infinity" and lets `PRINT` proceed. rustc's exposition:

> "SCAN takes input and buffers tokens and pending calculations, while PRINT gobbles up
> completed calculations and tokens from the buffer. The theory is that the two can never
> get more than 3N tokens apart, because once there's 'obviously' too much data to fit on a
> line, in a size calculation, SCAN will write 'infinity' to the size and let PRINT consume
> it." — [rustc `pp.rs`][rustc-pp], module doc

That is the whole reason the algorithm is O(m) in space rather than O(n): **the printer never
needs to know how much too wide something is, only that it is.** Every later "linear,
bounded" result ([Chitil 2005, Swierstra & Chitil 2009][combinators]) is a re-derivation of
this same early-give-up in a functional setting.

### Cross-check: the size-is-negative-while-pending encoding

rustc's implementation makes the invariant explicit — `PRINT` "can't output anything until
the size is >= 0 (sizes are set to negative while they're pending calculation)"
([`pp.rs`][rustc-pp]). The `Breaks` enum is the paper's break type verbatim:

```rust
pub enum Breaks {
    Consistent,
    Inconsistent,
}
```

— [`compiler/rustc_ast_pretty/src/pp.rs`][rustc-pp]

The same file adds a distinction Oppen did not have, and it is the one place a modern
implementation _had_ to extend the model: `IndentStyle::Visual` (align under the column the
block opened at) vs `IndentStyle::Block { offset }` (indent relative to the previous line's
level). Oppen's `begin` offset is only the second kind. Visual alignment — `f(a,` /
`  ⟨aligned⟩b)` — is a genuinely separate mechanism, and its absence from the original
vocabulary is why [alignment is its own spine dimension][spine] in this survey.

---

## Power & limits

**What it decides well.** Any layout whose quality is a function of "does this block fit on
the remaining line" is decided correctly and in one pass. That covers the overwhelming
majority of real formatting decisions, which is why the algorithm survived.

**What it cannot express**, from the paper's own §8:

1. **Offsets that depend on the future.** "we do not allow offsets which are a function of
   the next block in the stream" — so a block cannot indent _less_ in order to let a later
   sibling fit. This is exactly the class of decision that requires either backtracking or a
   global objective, and is the entire content of [optimality][optimality].
2. **Strings wider than the remaining margin.** "Another deficiency of the algorithm is that
   it can do nothing if there is not room on the line for a string." Oppen offers two "crude
   solutions" (wrap, or forcibly reduce indentation) and declines to pick. Real formatters
   still face this: clang-format's `BreakableToken` splits long string literals, rustfmt has
   `string.rs`, and prettier simply lets the line overflow.
3. **Cost trade-offs of any kind.** There is no notion that one legal layout is _better_
   than another beyond "fewer lines". A penalty model — the industrial answer — has no place
   to live in a one-pass scan.

**What it does not address at all**: comments and trivia. The token stream has no room for a
comment that must attach to a particular node, and the paper never mentions them. rustc's
implementation had to smuggle them in — encoding "a thing that should be on its own line" as
a String token with a _deliberately false_ length ("an explicit length that's huge, surrounded
by two zero-length breaks"), so the fitting logic is guaranteed to fail and isolate it. That
hack, documented at length in `pp.rs`, is a good measure of how far outside Oppen's model
comment handling sits.

---

## Performance & complexity

| Algorithm (as surveyed in [Oppen 1980][oppen], §7) | Time     | Space    |
| -------------------------------------------------- | -------- | -------- |
| Goldstein (LISP)                                   | **O(n)** | **O(n)** |
| Waters                                             | O(mn)    | O(m)     |
| Nelson                                             | **O(n)** | **O(m)** |
| Morris (two parallel processors)                   | O(mn)    | O(m)     |
| Hearn & Norman                                     | O(mn)    | O(m)     |
| **Oppen**                                          | **O(n)** | **O(m)** |

Two remarks the table needs. First, Oppen credits the lookahead insight as independently
discovered: "Dick Waters (private communication) independently discovered the observations
given here on how much lookahead is required" (§7) — and Nelson had the same bounds. The
contribution is the _published, language-independent_ formulation, not sole priority.

Second, the constant matters more than the asymptotics in practice. rustc's buffer is
**3N tokens** where N is the line width, justified as: "Yes, linewidth is chars and tokens
are multi-char, but in the worst case every token worth buffering is 1 char long, so it's ok"
([`pp.rs`][rustc-pp]). For an 80-column margin that is a 240-slot ring buffer — a fixed,
cache-resident working set regardless of file size. No later algorithm in this tree improves
on that, and several are dramatically worse.

---

## Where it shows up in practice

| System                       | Evidence                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mesa** (the original)      | "A prettyprinter for MESA has been implemented in this fashion by Philip Karlton and the author" — [Oppen 1980][oppen], §6                                          |
| **rustc** `rustc_ast_pretty` | "a direct reimplementation of Philip Karlton's Mesa pretty-printer, as described in the appendix to Derek C. Oppen, 'Pretty Printing' (1979)" — [`pp.rs`][rustc-pp] |
| **OCaml** `Format`           | `stdlib/format.ml`, Pierre Weis / INRIA, 1996 — a `Size` module whose values are explicitly `unknown` until back-patched, the Oppen encoding                        |
| **Ruby** `prettyprint`       | stdlib, documented as an implementation of Oppen's algorithm                                                                                                        |
| **Go** `go/printer`          | Partially — see [gofmt][gofmt]; it keeps the token/blank vocabulary but replaces the fitting decision with the author's own line breaks                             |

The provenance chain is unusually well documented and worth stating once: Oppen's TOPLAS
paper describes the algorithm; Karlton's Mesa implementation appears in the appendix of the
1979 Stanford tech report (STAN-CS-79-770); rustc reimplements _Karlton's appendix_, not the
paper body. rustc's author, writing in 2011, on why:

> "I am implementing this algorithm because it comes with 20 pages of documentation
> explaining its theory, and because it addresses the set of concerns I've seen other
> pretty-printers fall down on. Weirdly. Even though it's 32 years old." — [rustc `pp.rs`][rustc-pp]

---

## Strengths

- **Genuinely linear and genuinely streaming.** The only family in this tree that can format
  an unbounded stream in bounded memory, and it does so without approximation.
- **Small.** rustc's complete implementation is 615 lines including the ring buffer; OCaml's
  is a fraction of `format.ml`. Nothing else here is that cheap to own.
- **The vocabulary outlived the procedure.** String / blank / begin-end / consistent /
  inconsistent is the interface every descendant kept, even those that discarded the
  two-process implementation entirely.
- **Predictable.** Greedy decisions are local, so output is easy to reason about and a change
  in one part of a file cannot alter layout elsewhere — a property [cost-minimizing
  search][cost-search] gives up and then has to partially recover.

## Weaknesses

- **Greedy.** Cannot trade a worse local choice for a better global one; the `cases` /
  `if-then-else` example in §8 is the paper's own counterexample.
- **No cost model.** "Fewer lines" is the only objective; there is no way to say that
  breaking before `+` is preferable to breaking after it.
- **No comment or trivia model.** Comments must be smuggled through as strings with lied-about
  lengths, or handled entirely outside the algorithm.
- **No visual alignment.** The `begin` offset is a relative indent only; column alignment had
  to be added by every implementation independently.
- **Imperative and stateful.** Two mutually-recursive processes over a shared mutable ring
  buffer with back-patched sizes is hard to get right, hard to test, and hard to reason about
  compositionally — which is precisely the complaint that produced [the combinator
  line][combinators].

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                                                | Trade-off                                                                                                                  |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Format a **token stream**, not a tree                  | Language independence — the front end owns syntax, the printer owns layout ([Oppen 1980][oppen], §1)     | The printer can never make a decision that needs semantic or structural knowledge it wasn't handed                         |
| **Two processes** over a shared bounded buffer         | Enables streaming output and O(m) space                                                                  | Mutable, back-patched state; the hardest part of every reimplementation                                                    |
| **Give up on exact size** past the margin ("infinity") | The decision only needs `size > remaining`, so precision beyond that is waste — this _is_ the O(m) proof | Forecloses any cost model that would need the true overflow amount                                                         |
| **Greedy** break decisions                             | One pass, no backtracking, predictable output                                                            | Provably suboptimal; §8 supplies the counterexample                                                                        |
| **Two** block modes (consistent / inconsistent)        | The `begin…end` vs `locals x, y, …` preferences genuinely differ and no single policy serves both        | Two is empirically not enough — prettier added `fill`, `conditionalGroup`, `indentIfBreak`; clang-format has ~30 penalties |
| Blank length is a **parameter** (including zero)       | One primitive covers separators, optional breaks, and invisible break points                             | Conflates "how much space" with "may break here"; later systems split these apart                                          |
| **Nothing** about comments                             | Keeps the model small and the front end responsible                                                      | Every real implementation reintroduces comments as a hack against the fitting logic                                        |

---

## Sources

**Primary:**

- Derek C. Oppen, _Prettyprinting_, ACM Transactions on Programming Languages and Systems
  2(4), October 1980, pp. 465–483. [`oppen-1980-prettyprinting-toplas.pdf`][oppen]
- Derek C. Oppen, _Pretty Printing_, Stanford Computer Science Department STAN-CS-79-770
  (1979) — the tech report whose appendix carries Karlton's Mesa implementation. [Stanford][oppen-tr]

**Implementations read:**

- `compiler/rustc_ast_pretty/src/pp.rs` (615 lines) — [rust-lang/rust][rustc-pp]; the module
  doc comment is the clearest secondary exposition of the algorithm in existence.
- `stdlib/format.ml` (1629 lines) — [ocaml/ocaml][ocaml-format]; note the `Size` module with
  an explicit `unknown` value, the functional spelling of Oppen's negative-size placeholder.

**Related deep-dives in this tree:**
[Combinators][combinators] · [Optimality][optimality] · [Cost & search][cost-search] ·
[Concepts][concepts] · [gofmt][gofmt] · [The D landscape][d-landscape]

<!-- References -->

<!-- Papers & external -->

[oppen]: https://dl.acm.org/doi/10.1145/357114.357115
[oppen-tr]: https://web.archive.org/web/20210928120136/http://i.stanford.edu/pub/cstr/reports/cs/tr/79/770/CS-TR-79-770.pdf
[rustc-pp]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/compiler/rustc_ast_pretty/src/pp.rs
[ocaml-format]: https://github.com/ocaml/ocaml/blob/ddb608abde9cd4787a24c825e07352dfa73fd717/stdlib/format.ml

<!-- Sibling theory docs -->

[theory-index]: ./index.md
[combinators]: ./combinators.md
[optimality]: ./optimality.md
[cost-search]: ./cost-and-search.md

<!-- Tree-level docs -->

[concepts]: ../concepts.md
[concepts-ir]: ../concepts.md#the-layout-ir-cross-naming-table
[spine]: ../index.md#taxonomies
[d-landscape]: ../d-landscape.md

<!-- System deep-dives -->

[gofmt]: ../gofmt.md

<!-- In-repo -->

[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d
