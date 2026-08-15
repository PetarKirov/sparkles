# Layout Preservation — Formatting From a Tree You Did Not Design

The family that takes seriously what [Hughes declared out of scope][hughes-remark]: comments,
existing whitespace, and the fact that a formatter's input is **program text a human wrote**,
not a data structure a program built. Two threads, thirty years apart in the same research
group at Amsterdam and Delft: van den Brand & Visser's **Box** — generate a formatter from a
grammar, translate the AST into a language-independent layout algebra, and restore comments by
their _original position_ — and de Jonge & Visser's **text patching**, which stops unparsing
altogether and instead patches the original source at offsets recovered by origin tracking.

This is the least-cited family in the tree and the most directly applicable to
[the D problem][baseline], because it is the only one whose subject matter _is_ the constraint
D actually has: an AST that has thrown away everything the formatter needs.

## At a glance

| Dimension               | Where the layout-preserving family lands                                                                                                  |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Input**               | A grammar + an AST + **the original text**, with a mapping between them                                                                   |
| **Central problem**     | The "orthogonality of the linguistic and documentary structure" ([de Jonge & Visser][dejonge], §1) — comments do not live in the tree     |
| **Objective**           | Not prettiness: **preservation**. `CONSTRTEXT(PARSE(s)) = s`, and the transformed analogue ([de Jonge & Visser][dejonge], §2)             |
| **Decision rule**       | Box: the `HV`/`HOV` operators fit-test like [Oppen][oppen]. Patching: don't decide — reuse the author's text for unaffected subtrees      |
| **Comment handling**    | **First-class.** Box: comment position in the original text determines position in the output. Patching: heuristic migration rules        |
| **Language-parametric** | Yes, by construction — Box formatters are _generated from the context-free grammar_                                                       |
| **Ships in**            | ASF+SDF / Spoofax / Stratego; conceptually in [topiary][topiary] (tree-sitter queries), Roslyn (trivia), and every IDE refactoring engine |

> [!NOTE]
> This is the [theory tree][theory-index] entry for **formatting text that already exists**.
> Everything else in the tree — [Oppen][oppen], [combinators][combinators],
> [optimality][optimality], [cost & search][cost-search] — answers "given a tree and a width,
> what layout?". This page answers "given a tree, a width, **and the text the tree came
> from**, what layout?" — which is the question a code formatter is actually asked.

---

## Overview / motivation

### The problem, named precisely

De Jonge & Visser give the sharpest available statement of why AST-based formatting loses
comments, and it is not an implementation defect:

> "Whitespace and comments form the **documentary structure** of the program that is not
> formally part of the linguistic structure, but determines the visual appearance of the code,
> which is essential for readability. A fundamental problem for refactoring tools is the
> **informal connection** between linguistic and documentary structure."
> — [de Jonge & Visser 2011][dejonge], §1

and the diagnosis of why the obvious fix (store layout in the AST) does not work:

> "The cause of these limitations lies in the **orthogonality of the linguistic and documentary
> structure**; projecting documentary structure onto linguistic structure loses crucial
> information (Van De Vanter)." — [de Jonge & Visser 2011][dejonge], §1

That is the theoretical content of this page. Comments are not badly-placed tree nodes; they
are a _second structure over the same text_, which is only loosely correlated with the syntax
tree. Any scheme that forces them into the tree must choose an attachment, and — as the next
section shows — there is provably no right choice.

### The canonical counterexample (1996)

Van den Brand & Visser's Box paper contains the earliest clean statement of the
comment-attachment problem in this survey, one year after [Hughes][hughes-remark] set it aside:

> "One approach to solve the problem of restoring comments is to attach them to nodes in the
> abstract syntax tree. During formatting, the comments are regenerated when processing the
> node in question. … Unfortunately, **there is no unique and completely satisfactory method to
> determine to which node the comment should be attached.** For instance, in
>
> ```text
> while x >= 0    (* as long as x positive *)
> do
>   …
> od
> ```
>
> should the comment be attached to the syntax tree for the `0`, the condition, or the
> `while`-construct? A wrong choice may lead to an unexpected placement of the comment in the
> formatted text." — [van den Brand & Visser 1996][box], §5

Every formatter in [the systems half of this survey][umbrella] answers this question, and every
one answers it differently: prettier's `handle-comments.js` is 1,255 lines of exactly these
decisions for JavaScript; Roslyn has a `TriviaEngine` and a "belongs right unless same line"
default; rustfmt has `comment.rs`. None of them is _wrong_, because there is no right answer —
which is why the code is large and the tests are enormous.

The paper also draws the distinction that determines whether you have the problem at all:

> "— Comments are considered part of the context-free syntax; thus it is specified in the
> context-free grammar of the language where they may occur. … These comments are included in
> the abstract syntax tree.
> — Comments are considered as a part of the lexical syntax, so they may occur anywhere and are
> not included in the abstract syntax tree. Comments are considered as layout.
> The second form of comments is **notoriously difficult** to handle during formatting."
> — [van den Brand & Visser 1996][box], §5

D is squarely in the second category — with the wrinkle that DDoc comments are _semantically
significant_ (`dmd-lsp` deliberately keeps them alive by overriding `doDocComment`), so D has
both kinds at once.

---

## How it works

### Box: a layout algebra generated from a grammar

The 1996 contribution is a pipeline in which nothing is hand-written per language:

> "A specification of a formatter is generated from the context-free grammar of a (programming)
> language. These generated formatters translate abstract syntax trees of programs into box
> expressions. Box expressions are translated by language-independent interpreters of the box
> language into ASCII or TeX." — [van den Brand & Visser 1996][box], Abstract

The **Box language** has six operators:

| Operator | Meaning                                                  | Equivalent elsewhere                                    |
| -------- | -------------------------------------------------------- | ------------------------------------------------------- |
| `H`      | horizontal composition                                   | `<>` / concatenation                                    |
| `V`      | vertical composition                                     | Hughes' `$$`; Wadler's `x <> line <> y`                 |
| `HV`     | horizontal **and/or** vertical                           | **Oppen's _inconsistent_** / prettier's `fill`          |
| `HOV`    | horizontal **or** vertical                               | **Oppen's _consistent_** / prettier's `group`           |
| `I`      | indentation — "has an effect only in a vertical setting" | `nest`                                                  |
| `WD`     | invisible box of the same width as a visible one         | no common equivalent; a width-only spacer for alignment |

The `HV`/`HOV` split is worth pausing on. The paper's own descriptions: for `HV`, "For each
argument box it is considered whether this box fits in the remaining space or not"; for `HOV`,
"For **all** argument boxes it is considered whether they fit in the remaining space". Per-box
versus all-boxes-together — which is [Oppen's inconsistent/consistent distinction][oppen-cons]
independently rediscovered sixteen years later, and a **third** naming of it after Oppen's and
prettier's. The full cross-naming table lives in [concepts][concepts-ir]; that three research
lines invented the same two-valued flag without coordination is the strongest evidence in this
survey that it is a real feature of the problem rather than an artifact of one design.

**Comments, solved by position.** Box's answer is to refuse the attachment question entirely:

> "In our approach, the position of a comment in the original text is used to determine its
> position in the formatted text." — [van den Brand & Visser 1996][box], §5

Boxes carry source positions; a comment is placed relative to the boxes whose original
positions bracket it. There is no attachment decision because there is no attachment — only an
ordering. This is a genuinely different answer from prettier's or Roslyn's, and it is the one a
formatter with a **token stream** (rather than a bare AST) can implement cheaply.

### Text patching: stop unparsing

De Jonge & Visser 2011 make the more radical move. If the goal is preservation, then
_regenerating_ the text is the mistake:

> "In this paper, we address the limitations of existing approaches to layout preservation with
> an approach based on **automated text patching**. A text patch is an incremental modification
> of the original text, which can consist of a deletion, insertion or replacement of a text
> fragment at a given location. The patches are computed automatically by comparing the terms
> in the transformed tree, with their original term in the tree before the transformation."
> — [de Jonge & Visser 2011][dejonge], §1

Unaffected subtrees are not printed at all — their original text is reused verbatim, so their
layout and comments survive by construction rather than by careful reconstruction. Only the
changed regions are pretty-printed, and a "layout adjustment strategy corrects the whitespace at
the beginning and end of the changed parts, and migrates comments so that they remain
associated with the linguistic structures to which they refer."

**The architecture that makes it possible** is stated in §3, and this is the single most
transferable paragraph in the paper for [the D design][baseline]:

> "The program structure is represented by an abstract syntax tree (AST). **Each node in the AST
> keeps a reference to its leftmost and rightmost token in the token stream, which in turn keep
> a reference to their start and end offset in the character stream.** … This architecture makes
> it possible to locate AST-nodes in the source text and retrieve the corresponding text
> fragment. **The layout structure surrounding the text fragment is accessible via the token
> stream, which contains layout and comment tokens.**" — [de Jonge & Visser 2011][dejonge], §3

Three layers — AST node → token span → character offsets — with comments living in the token
stream, not the tree. That is the canonical shape, and it is precisely the shape
`sparkles:dmd-lsp` does **not** currently have: DMD's `Loc` is `(file, line, col)` with a start
only, and there is no token stream in the facade at all. Q-a and Q-b in
[the substrate baseline][baseline] are, in effect, asking whether this architecture is
reachable from the DMD frontend.

The mechanism relating trees before and after is **origin tracking** — "a general technique
which relates subterms in the resulting tree back to their originating term in the original
tree" (§3), with the rewrite engine propagating the links. For a pure formatter (no
transformation) origin tracking is trivial: every node is its own origin. The formatter case is
the _degenerate_ case of the refactoring problem, which is why this literature over-serves it.

### The comment heuristics, in full

§5 is the part a formatter author should actually copy, and it is the most concrete answer to
the attachment problem anywhere in this survey. The diagnosis first:

> "Figure 11 makes clear why attaching comments to AST nodes is problematic. The connection of
> comments with AST-nodes only becomes clear when taking into account **the full documentary
> structure, including newlines, indentation and separator tokens**. Comments can point forward,
> as well as backward and, purely based on analysis of the tree structure, it is impossible to
> decide which one is the case." — [de Jonge & Visser 2011][dejonge], §5

Note what that says: the information needed to attach a comment **is not in the tree at all**.
It is in the whitespace. A formatter that has only an AST cannot recover it in principle — which
is the precise reason [the D substrate question][baseline] is about tokens, not about smarter
tree-walking.

Their answer is to define binding as **layout patterns** rather than tree positions:

> "Instead of a fixed mapping between comments and AST nodes, heuristic rules are defined that
> interpret the documentary structure around the moved AST-part. Comment heuristics are defined
> as layout patterns using newlines, indentation, and separators as building blocks."
> — [de Jonge & Visser 2011][dejonge], §5

Five patterns (Figure 12), each written as a sequence over layout tokens:

| Pattern         | Layout signature                                                                                 | Example                                              |
| --------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| `Preceding(1)`  | `<newline OR lower-indent><newline><comments><newline><nodes><newline><newline OR lower-indent>` | a `/*..*/` on its own line above a declaration group |
| `Preceding(2)`  | `<separator><comments><node>`                                                                    | `int i, /*..*/ int j` — binds forward                |
| `Succeeding(1)` | `<node><comments><newline>`                                                                      | `int i /*..*/` then `int j` — binds back             |
| `Succeeding(2)` | `<node><comments><separator>`                                                                    | `int i /*..*/ , int j`                               |
| `Succeeding(3)` | `<node><separator><comments><newline>`                                                           | `int i, /*..*/` then `int j`                         |

The rule that follows: "if a node / group of nodes is (re)moved, all adjacent comments that bind
to the node(s) are (re)moved as well. Adjacent comments that do not bind, stay at their original
position in the source code."

Three cases they call out as genuinely unresolvable are worth internalizing, because a D
formatter will meet all three:

- **A comment with no structural referent** — a commented-out statement "does not have a
  structural referent. It can best be seen as lying between the surrounding code elements."
  None of the five patterns matches it, and that is the correct outcome.
- **A comment referring to a _sublist_**, not a node — "lacks an explicit referent in terms of a
  single AST node."
- **One logical comment split across two lines**, recognized by a human "although it is
  structurally split in two separate parts. In this case, the vertical alignment hints at the
  fact that both parts belong together" — and their patterns explicitly fail on it: "with the
  exception of vertical alignment (#5), which is not detected."

And the paper's own honest limit, which belongs in any formatter's design document:

> "Heuristic rules will never handle all cases correctly; ultimately, it requires understanding
> of the natural language to decide the meaning of the comment and how it relates to the program
> structure." — [de Jonge & Visser 2011][dejonge], §5

### Preservation as a pair of equations

De Jonge & Visser state the correctness of the whole scheme as two criteria (§2):

```text
Correctness.   PARSE(CONSTRTEXT(TRANSF(PARSE(s)))) = TRANSF(PARSE(s))
Preservation.  CONSTRTEXT(PARSE(s)) = s
```

"The correctness criterion states that text reconstruction followed by parsing is the identity
function on the AST after transformation. The preservation criterion states that parsing
followed by text reconstruction returns the original source text."

And then the observation that ties this to a much larger literature:

> "The layout preservation problem falls in the wider category of **view update problems**.
> Foster et al. define a semantic framework … They introduce **lenses**, which are
> bi-directional tree transformations. … A lens is well-behaved if and only if the GET and
> PUTBACK functions obey the following laws: `GET(PUTBACK(t, s)) = t` and
> `PUTBACK(GET(s), s) = s`. These laws resemble our correctness and preservation criterion.
> Indeed, the bi-directional transformation PARSE, CONSTRUCTTEXT forms a **well-behaved lens**."
> — [de Jonge & Visser 2011][dejonge], §2

For a formatter the two equations specialize usefully. **Correctness** becomes
`PARSE(FORMAT(s)) = PARSE(s)` — _the formatter must not change the program_, which is exactly
the AST-equivalence check [ocamlformat enforces][verification] and black tests for.
**Preservation** in its literal form (`FORMAT(s) = s`) is too strong for a formatter — a
formatter is _supposed_ to change layout — but it is exactly right for the regions a formatter
declines to touch: verbatim blocks, `// dfmt off` ranges, and everything outside a range-format
request. The pair is the cleanest formal statement of a formatter's contract in this survey,
and [`verification.md`][verification] builds on it.

---

## Power & limits

**What this family gets right that no other does:**

- It **starts from the right problem**. The input is text a human wrote; the tree is derived.
  Every other family has the arrow pointing the other way.
- **Comments have a principled answer** — by position (Box) or by not regenerating at all
  (patching) — rather than a pile of language-specific heuristics.
- **Preservation is specified, not hoped for**, and connects to the lens laws.
- **Language-parametric by construction.** A Box formatter is generated from the grammar; a
  patching reconstructor is language-generic given origin tracking. This is what
  [topiary][topiary] is doing with tree-sitter queries, thirty years later.

**What it does not give you:**

1. **Layout quality.** Box's `HV`/`HOV` is [Oppen][oppen] with different names — greedy,
   two-valued, no cost model. Nothing here competes with [optimality][optimality] or
   [cost & search][cost-search] on _how good the output looks_. These are orthogonal concerns
   and the literature keeps them apart.
2. **An opinionated formatter.** Patching is designed to change as little as possible, which is
   the opposite of what prettier or gofmt want. A formatter whose job is to _impose_ a style
   must reprint everything, and then it is back to the attachment problem.
3. **The infrastructure is assumed.** Origin tracking, leftmost/rightmost token references, a
   layout-carrying token stream — Spoofax has them; a compiler frontend usually does not. The
   papers do not tell you how to retrofit them.
4. **Nothing about incremental or range formatting.** Ironically, the machinery is exactly
   right for it (patches _are_ `TextEdit`s), but the papers frame it as batch refactoring.

**Why it is under-cited.** This work is published at SLE/TOSEM in the language-workbench
community; the pretty-printing literature is published at ICFP/JFP in the functional-programming
community, and the two barely touch. A word count over the seven [combinator][combinators] and
[optimality][optimality] papers held locally makes the separation concrete:

| Paper                   | occurrences of "comment" | in what sense                                                      |
| ----------------------- | ------------------------ | ------------------------------------------------------------------ |
| Lindig 2000             | 0                        | —                                                                  |
| Chitil 2005             | 0                        | —                                                                  |
| Chitil 2006             | 0                        | —                                                                  |
| Bernardy 2017           | 0                        | —                                                                  |
| Wadler 1998             | 1                        | acknowledgements ("for comments on earlier versions of this note") |
| Swierstra & Chitil 2009 | 1                        | acknowledgements                                                   |
| Yelland 2016            | 2                        | [a footnote][yelland-fn] declaring them out of scope               |
| APEP 2023               | 3                        | two layout primitives, `reset` and `full`, added because of them   |

APEP's is the only substantive engagement, and it is instructive precisely because it is
_narrow_: `full 𝑑` "marks 𝑑 as full, which means there must be no more text after it in the same
line … especially useful for formatting line comments, as it is illegal to put a piece of code
after a line comment", and `reset` drops the indentation to 0 "for formatting multiline comments
and here-string". Both treat a comment as a **layout constraint**, never as something that must
be _attached_ to a node — which is the problem this page is about. APEP also cites the
Amsterdam/Delft line exactly once, a passing reference to _Merijn_ De Jonge's 2002 reengineering
paper, not to either paper on this page.

The pattern in that table is worth stating: the only two papers in the combinator/optimality
literature that mention comments at all were written by people **shipping a code formatter**
(Yelland's `rfmt` for R, APEP's foundation for Racket's `fmt`). The split is institutional
rather than intellectual — but the consequence is real: **the two halves of the problem a code
formatter must solve have essentially never been solved in the same paper.**

---

## Where it shows up in practice

| System                           | Relationship                                                                                                                                                                                                                                                             |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **ASF+SDF / Spoofax / Stratego** | The papers' own home; Box is the formatter layer, origin tracking is Spoofax infrastructure                                                                                                                                                                              |
| **[topiary][topiary]**           | The modern language-parametric formatter: tree-sitter queries attach formatting captures to grammar nodes — Box's "generate the formatter from the grammar" with a different grammar formalism                                                                           |
| **Roslyn**                       | Full-fidelity trivia + a rule chain: every token owns its leading/trailing trivia, so the tree _is_ the text. The industrial answer to "make linguistic and documentary structure non-orthogonal by construction" — see [its deep-dive][roslyn]                          |
| **rust-analyzer / `rowan`**      | "full-fidelity representation (\*any\* text can be precisely represented as a syntax tree)" ([`crates/syntax/src/lib.rs`][ra-syntax]) — same posture as Roslyn, and explicitly "inspired by the [Swift] one", which is the tree [swift-format][swift-format] is built on |
| **Every IDE "extract method"**   | The refactoring case the papers actually target                                                                                                                                                                                                                          |
| **`dmd-lsp`**                    | **Has none of this.** AST without token access, `Loc` without end offsets, comments discarded — see [the baseline][baseline]                                                                                                                                             |

---

## Strengths

- **The only family that treats comments as a first-class problem**, and it has been doing so
  since 1996.
- **Formal preservation criteria** that specialize into a formatter's real contract.
- **Language-parametric**: a formatter from a grammar, not from hand-written per-node printers.
- **Patching is minimal-diff by construction** — the property [diff-conscious teams want][diff-review]
  and that every reprinting formatter has to work to recover.
- **The three-layer architecture** (AST → token span → offsets) is a concrete, checkable design
  target, not a principle.

## Weaknesses

- **Says nothing about layout quality.** Box is greedy Oppen; patching avoids the question.
- **Assumes infrastructure** most compiler frontends lack, and does not discuss retrofitting.
- **Aimed at refactoring, not formatting.** A formatter is the degenerate case, and the
  literature never optimizes for it.
- **Wrong for opinionated formatters**, which must reprint and therefore must attach.
- **Institutionally isolated** — barely cited by the pretty-printing literature, and barely
  citing it.

---

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                             | Trade-off                                                                                                    |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **Generate the formatter from the grammar** (Box)          | One formatter engine, N languages, no hand-written printer per node                   | Generated rules need tuning to look good; the paper concedes they "can easily be tuned", i.e. must be        |
| Box's **six operators** incl. `HV`/`HOV`                   | Covers the fill/group distinction that real layout needs                              | Still greedy and two-valued — no cost model, same ceiling as [Oppen][oppen]                                  |
| **Comment position from the original text** (Box)          | Dissolves the attachment problem: there is an ordering, not an owner                  | Requires source positions on every box; and a comment between two moved nodes has no defined home            |
| **Patch, don't reprint** (de Jonge & Visser)               | Unaffected layout survives by construction, not by careful reconstruction             | Cannot impose a style; only usable when "unaffected" is most of the file                                     |
| **Origin tracking** as the tree↔text link                  | Survives arbitrary rewriting, so refactorings compose                                 | Must be threaded through the rewrite engine; unavailable unless the whole stack cooperates                   |
| AST node → **leftmost/rightmost token** → **char offsets** | Locates any subtree in the source and exposes surrounding trivia via the token stream | Requires end positions on nodes and a retained token stream — precisely what a compiler AST usually discards |
| **Preservation stated as equations** (and as lens laws)    | Makes "did we lose anything" checkable rather than aspirational                       | The literal preservation law is too strong for an opinionated formatter and must be relativized              |

---

## Sources

**Primary:**

- Mark van den Brand & Eelco Visser, _Generation of Formatters for Context-Free Languages_,
  ACM TOSEM 5(1), January 1996, pp. 1–41. [`vandenbrand-visser-1996-…-toplas.pdf`][box]
- Maartje de Jonge & Eelco Visser, _An Algorithm for Layout Preservation in Refactoring
  Transformations_, SLE 2011, LNCS 6940, pp. 40–59. [`dejonge-visser-2011-…-sle.pdf`][dejonge]

**Cited within, not held:** Van De Vanter on linguistic vs documentary structure; Van Deursen
et al. on origin tracking; Foster et al. on lenses; Rose & Welsh and the CENTAUR system on
comment attachment.

**Related deep-dives in this tree:**
[Oppen][oppen] · [Combinators][combinators] · [Optimality][optimality] ·
[Cost & search][cost-search] · [Concepts][concepts] · [Verification][verification] ·
[topiary][topiary] · [Roslyn][roslyn] · [The substrate baseline][baseline]

<!-- References -->

<!-- Papers & external -->

[box]: https://eelcovisser.org/publications/1996/BrandV96.pdf
[dejonge]: https://eelcovisser.org/publications/2011/JongeV11.pdf

<!-- Sibling theory docs -->

[theory-index]: ./index.md
[oppen]: ./oppen.md
[oppen-cons]: ./oppen.md#consistent-vs-inconsistent-breaking
[combinators]: ./combinators.md
[hughes-remark]: ./combinators.md#the-remark-that-defines-this-surveys-gap
[optimality]: ./optimality.md
[yelland-fn]: ./optimality.md#power--limits
[cost-search]: ./cost-and-search.md

<!-- Tree-level docs -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[concepts-ir]: ../concepts.md#the-layout-ir-cross-naming-table
[verification]: ../verification.md
[baseline]: ../dmd-lsp-baseline.md

<!-- System deep-dives -->

[topiary]: ../topiary.md
[roslyn]: ../roslyn.md
[swift-format]: ../swift-format.md

<!-- Source trees -->

[ra-syntax]: https://github.com/rust-lang/rust-analyzer/blob/3033d4fac8aab3f1725aa9c9d6293436aeceb0a5/crates/syntax/src/lib.rs

<!-- Other research trees -->

[diff-review]: ../../diff-review/index.md
