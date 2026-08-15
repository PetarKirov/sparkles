# Combinators — The `Doc` Algebra and Greedy `group`/`flat`

The **dominant interface** in the field: instead of an imperative printer driven by a token
stream, a small algebra of document values — `text`, `line`, `nest`, concatenation, and a
`group` that means "put this on one line if it fits" — with a `best`/`format` function that
interprets it. Four papers over fifteen years turn Hughes' 1995 combinator library into
Wadler's single-concatenation algebra, Lindig's strict-language transcription, and Chitil's
and Swierstra's re-derivations of [Oppen's linear bound][oppen] in a purely functional
setting. **Prettier ships Lindig's version of Wadler's algebra**, which makes this page the
direct ancestry of the most widely deployed formatter in existence.

## At a glance

| Dimension             | Where the combinator family lands                                                                                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Input**             | A **tree** — a `Doc` value built by the caller, not a token stream                                                                                                              |
| **Core operators**    | `text`, `line`, `nest`, `<>` (concat), `group` — six constructors in [Wadler][wadler] §1–2; [Lindig][lindig]'s Figure 1 is the same six                                         |
| **Objective**         | **Optimal and bounded** _in Wadler's sense_: "chooses line breaks so as to avoid overflow whenever possible" with lookahead ≤ `w` ([Wadler][wadler], §5)                        |
| **Decision rule**     | **Greedy per group** — flatten the group; if it fits in the remaining width, print flat; otherwise break _this_ group's lines and recurse into subgroups                        |
| **Time**              | O(n) with lazy `best` (Haskell) or an explicit mode-tagged worklist (strict); **exponential** if Wadler's Haskell is transliterated naively ([Lindig][lindig], Abstract)        |
| **Space**             | O(w) for the [Chitil][chitil05] / [Swierstra & Chitil][sc09] variants; unbounded for the naive `Doc`-tree approach                                                              |
| **Streaming**         | Only in the Chitil/Swierstra line; Wadler's and Lindig's build the whole `Doc` first                                                                                            |
| **Break granularity** | `group` = Oppen's **consistent** break; `fill` = Oppen's **inconsistent** break                                                                                                 |
| **Comments / trivia** | **Explicitly out of scope** — see [the Hughes remark](#the-remark-that-defines-this-surveys-gap)                                                                                |
| **Ships in**          | [prettier][prettier] (`MODE_FLAT`/`MODE_BREAK`), Haskell's `pretty` & `wl-pprint`, OCaml's `Fmt`/`PPrint`, `google-java-format`, this repo's [`signature_layout.d`][sig-layout] |

> [!NOTE]
> This is the [theory tree][theory-index] entry for the **algebraic interface** family. It
> covers Hughes 1995, Wadler 1998, Lindig 2000, Chitil 2005, Chitil 2006, and Swierstra &
> Chitil 2009 — six papers, one lineage. Read [Oppen][oppen] first: three of the six are
> explicitly framed as recovering Oppen's bound, and the `group`/`fill` distinction _is_
> Oppen's consistent/inconsistent under new names. The question of whether greedy `group` is
> good enough — and what "optimal" should have meant — is [optimality][optimality].

---

## Overview / motivation

### What it solves

Oppen gave a procedure. Hughes asked for a **library**, and the difference is the whole
point. His framing is not about layout at all; pretty-printing is the worked example in an
argument about combinator libraries as the unit of software reuse:

> "On what does the power of functional programming depend? Why are functional programs so
> often a fraction of the size of equivalent programs in other languages? … I claim: because
> functional languages support software reuse extremely well." — [Hughes 1995][hughes], §1

The design that follows is a `Doc` type with operations that compose:

> "What kind of objects should pretty-printing combinators manipulate? I chose to work with
> 'pretty documents', of type `Doc`, which we can think of as documents which 'know how to'
> lay themselves out prettily. A pretty-printer for a particular datatype is a function
> mapping any value to a suitable `Doc`." — [Hughes 1995][hughes], §2.2

Hughes' operator set is four: `text :: String → Doc`, `(<>)` (horizontal composition),
`($$)` (vertical composition), and `sep :: [Doc] → Doc`, "which combines a list of `Doc`s
horizontally or vertically, depending on the context", plus `nest :: Int → Doc → Doc`
(§2.2). The payoff is stated as an absence: "The composition operators `(<>)` and `($$)`
relieve the user of the need to think about the correct indentation."

That is the move Oppen's interface could not make. Oppen's front end emits `begin`/`end`
markers into a stream and gets no value back; Hughes' front end builds a **first-class
value** it can pass around, store, and combine. Every subsequent formatter with a "doc IR"
inherits this, prettier explicitly.

### The remark that defines this survey's gap

One paragraph on page 3 of Hughes is the most important sentence in this tree for a **code**
formatter, and it is a disclaimer:

> "**Remark** Note that we are considering the problem of displaying internal data-structures
> in a readable form, not the harder problem of improving the layout of an existing text,
> such as a program. In the latter case we would have to consider questions such as: should
> we try to preserve anything of the original layout? How should we handle comments? Such
> problems are outside the scope of this chapter." — [Hughes 1995][hughes], §2.1 Remark

Read that carefully. The founding paper of the combinator tradition **explicitly excludes
code formatting** — and names, precisely, the two problems that dominate every real
formatter in [the systems half of this survey][umbrella]: _layout preservation_ and
_comments_. Wadler's paper inherits the exclusion silently (it prints trees, not programs);
Lindig, Chitil and Swierstra & Chitil all likewise.

This is not a criticism of the papers; it is the boundary of what they claim. But it means
that **anyone building a code formatter on the `Doc` algebra is using a tool outside its
stated domain**, and must supply the missing half themselves. That is exactly what prettier's
`comments/attach.js`, clang-format's `BreakableToken`, and rustfmt's `comment.rs` are — and
why they are large. For the D design, it is the reason [`dmd-lsp-baseline.md`][baseline]
treats trivia as the first problem and layout as the second. The rest of the field's answers
are [layout-preserving][layout-preserving].

### Design philosophy: one concatenation, not two

Wadler's contribution is a simplification, argued algebraically:

> "This chapter presents a new pretty printer library, which I believe is an improvement on
> the one designed by Hughes. The new library is based on a single way to concatenate
> documents, which is associative and has a left and right unit. This may seem an obvious
> design, but perhaps it is obvious only in retrospect. Hughes's library has two distinct
> ways to concatenate documents, horizontal and vertical, with horizontal composition
> possessing a right unit but no left unit, and vertical composition possessing neither unit.
> The new library is 30% shorter and runs 30% faster than Hughes's." — [Wadler][wadler], §Intro

The concrete algebraic defect Wadler is removing: Hughes' two operators associate with each
other in only one direction —

```text
x $$ (y <> z)  =  (x $$ y) <> z      -- holds
x <> (y $$ z)  =  (x <> y) $$ z      -- does not
```

— because horizontal composition cancels the nesting of its second argument ([Wadler][wadler],
§5 "Algebra"). Wadler replaces the pair with one associative `<>` and recovers vertical
composition as a derived operator, `x </> y = x <> line <> y`.

The cost of the simplification is admitted: "there are some layouts that Hughes's library can
express and the library given here cannot. It is not clear whether these layouts are actually
useful in practice" (§5, "Expressiveness"). Twenty years later [Bernardy][optimality] argues
they _are_, and reintroduces the missing power as an alignment operator.

---

## How it works

### The six constructors

Wadler §1–2 and [Lindig][lindig] Figure 1 give the same algebra in two notations:

| Wadler (Haskell) | Lindig (BNF) | prettier builder   | Meaning                                                                                                                            |
| ---------------- | ------------ | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `nil`            | `∅`          | `""`               | Empty document; unit of `<>`                                                                                                       |
| `text s`         | `"string"`   | a plain string     | Literal text, contains no newline                                                                                                  |
| `line`           | `␣` (line)   | `line`             | A break point; a space when flat, a newline when broken                                                                            |
| `x <> y`         | `doc · doc`  | an array           | Associative concatenation                                                                                                          |
| `nest i x`       | `i⟨doc⟩`     | `indent` / `align` | Add `i` to the indentation of `x`'s newlines                                                                                       |
| `group x`        | `[doc]`      | `group`            | "the set with one new element added, representing the layout in which everything is compressed on one line" ([Wadler][wadler], §2) |

The semantics are given by two hidden operators the user never sees, `<|>` (union of layout
sets) and `flatten`, with `group x = flatten x <|> x` ([Wadler][wadler], §2). `flatten`
"replaces each line break (and its associated indentation) by a single space", and the
invariant on `<|>` is that _both operands flatten to the same layout_. That invariant is what
makes the choice cheap: the two candidates differ only in line breaks, never in content.

Lindig states the resulting policy operationally, which is how implementers actually think
about it:

> "1. Print every optional line break of the current group and all its subgroups as spaces.
> If the current group then fits completely into the remaining space of current line this is
> the layout of the group. 2. If the former fails every optional line break of the current group is printed as a
> newline. Subgroups and their line breaks, however, are considered individually as they are
> reached by the pretty printing process." — [Lindig 2000][lindig], §2

**Point 2's second sentence is the entire algorithm.** A group that does not fit breaks _its
own_ lines, but its subgroups are re-decided independently — so nesting groups gives you a
cascade of progressively harder breaking, which is what makes a small algebra express complex
layouts.

### `best` and `fits` — the greedy core

Wadler's interpreter is four lines, and every implementation in this tree is a variant of it:

```haskell
best w k Nil            =  Nil
best w k (i `Line` x)   =  i `Line` best w i x
best w k (s `Text` x)   =  s `Text` best w (k + length s) x
best w k (x `Union` y)  =  better w k (best w k x) (best w k y)

better w k x y          =  if fits (w-k) x then x else y

fits w x | w < 0        =  False
fits w Nil              =  True
fits w (s `Text` x)     =  fits (w - length s) x
fits w (i `Line` x)     =  True
```

— [Wadler][wadler], §2

`w` is the page width, `k` the columns already used. Three details carry the weight:

1. **`fits` stops at the first `line`.** `fits w (i \`Line\` x) = True`— a document that
reaches a newline has fit, because everything after it starts on a fresh line. This is why
the check is O(w) and not O(document): it can consume at most`w`characters of text before`w < 0` fails it.
2. **Laziness is load-bearing, not incidental.** "It is essential for efficiency that the
   inner computation of `best` is performed lazily" ([Wadler][wadler], §2). `better` forces
   only enough of `best w k x` for `fits` to decide. In a strict language this line evaluates
   both entire branches — which is Lindig's whole paper.
3. **The invariant makes `better` a two-way choice, not a search.** "By the invariant for
   unions, no first line of the left operand may be shorter than any first line of the right
   operand. Hence … the first operand is preferred if it fits, and the second operand
   otherwise." There is never a third candidate. **This is the greedy commitment**, and it is
   the precise point at which the family diverges from [optimality][optimality].

### Lindig: the strict transcription everyone actually ships

Wadler's code is Haskell and depends on lazy evaluation twice — once in `best`, once in
`group`'s implicit expansion. Lindig's contribution is the observation and the fix:

> "It relies heavily on the lazy evaluation of Haskell and can not be easily ported to a
> strict language without loss of efficiency." — [Lindig 2000][lindig], §1

> "The original design causes exponential complexity when literally used in a strict
> language." — [Lindig 2000][lindig], Abstract

The fix is to **make the flat/broken decision an explicit tag** rather than a lazily-chosen
branch. Lindig's worklist holds triples `(i, m, doc)` — indentation, **mode**, document —
where `mode` is:

```ocaml
type mode =
    | Flat
    | Break
```

and both `fits` and `format` become tail-recursive functions over a list of such triples:

```ocaml
let rec fits w = function
    | (i,m,DocNil)          :: z -> fits w z
    | (i,m,DocCons(x,y))    :: z -> fits w ((i,m,x)::(i,m,y)::z)
    | (i,m,DocNest(j,x))    :: z -> fits w ((i+j,m,x)::z)
    | (i,m,DocText(s))      :: z -> fits (w - strlen s) z
    | (i,Flat, DocBreak(s)) :: z -> fits (w - strlen s) z
    | (i,Break,DocBreak(_)) :: z -> true
    | (i,m,DocGroup(x))     :: z -> fits w ((i,Flat,x)::z)
```

```ocaml
| (i,m,DocGroup(x)) :: z -> if fits (w-k) ((i,Flat,x)::z)
                            then format w k ((i,Flat ,x)::z)
                            else format w k ((i,Break,x)::z)
```

— [Lindig 2000][lindig], §3

Two things to notice, because they are what prettier inherited verbatim. First, `fits` is
passed **`z`, the rest of the worklist**, not just the group — so the fit test accounts for
what follows on the same line, which Wadler's `fits` does by the structure of the lazy `Doc`.
Second, entering a `DocGroup` while measuring forces mode `Flat` unconditionally; the mode is
only reconsidered when `format` reaches that group for real. That is Lindig's operational
statement of "subgroups are considered individually".

### Cross-check: prettier is Lindig's algorithm

prettier states its lineage:

> "This printer is a fork of [recast](https://github.com/benjamn/recast)'s printer with its
> algorithm replaced by the one described by Wadler in 'A prettier printer'."
> — [`docs/technical-details.md`][prettier-td]

but what the code implements is Lindig's strict form, because JavaScript is strict. The
printer's mode constants are Lindig's two-valued `mode`:

```js
const MODE_BREAK = Symbol('MODE_BREAK');
const MODE_FLAT = Symbol('MODE_FLAT');
```

— [`src/document/printer/printer.js`][prettier-printer]

the main loop's worklist holds Lindig's triples under other names —
`const commands = [{ indent: ROOT_INDENT, mode: MODE_BREAK, doc }]` — and `fits` takes the
rest of the worklist exactly as Lindig's does:

```js
function fits(next, restCommands, remainingWidth, hasLineSuffix, groupModeMap, mustBeFlat)
```

The correspondence is not approximate. `DocGroup` → `DOC_TYPE_GROUP`; `(i,Flat,x)` →
`{ indent, mode: MODE_FLAT, doc: doc.contents }`; the `fits (w-k) ((i,Flat,x)::z)` test →
`fits(flatCommand, commands, remainingWidth, …)`, where `commands` is Lindig's `z` verbatim.
prettier's genuine additions beyond Lindig
are enumerated in [its deep-dive][prettier]: `propagateBreaks` (a pre-pass hoisting hard
breaks to enclosing groups), `expandedStates` (`conditionalGroup` — an ordered list of
candidate layouts rather than two), and `fill` (Oppen's inconsistent breaking).

### Chitil and Swierstra: recovering Oppen's bound, purely

Wadler is honest that his printer is not Oppen's equal on space. His conclusion notes Oppen's
algorithm "is optimal and bounded", is "based on a buffer, and can be tricky to implement" —
and adds a parenthesis that names the next paper in the lineage:

> "(Chitil has since published an implementation of Oppen's algorithm that shows just how
> tricky it is to get it right in a purely functional style (Chitil 2001).)"
> — [Wadler][wadler], §5

The three papers in this sub-line all attack the same gap — Wadler's `Doc` must be built
before printing, so space is O(document), whereas Oppen's is O(width):

| Paper                                      | Mechanism                                                                                                            | Result claimed                                                                                         |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| [Chitil 2005][chitil05], TOPLAS 27(1)      | "At its heart lie **two lazy double ended queues**"                                                                  | "the same efficiency is also obtainable without destructive updates … with the same complexity bounds" |
| [Chitil 2006][chitil06], Kent TR 4-06      | "A **double-ended queue of delimited continuations** is the key to addressing all aspects of the problem explicitly" | "all the nice properties of Oppen's and is surprisingly simple"                                        |
| [Swierstra & Chitil 2009][sc09], JFP 19(1) | A functional-pearl derivation, published as _Linear, **bounded**, functional pretty-printing_                        | linear time, bounded space, online output                                                              |

Chitil's 2005 abstract also lands a diagnosis of the whole family that is easy to miss:

> "There are several purely functional libraries for converting tree structured data into
> indented text, but they all make use of some **backtracking**. Over twenty years ago Oppen
> published a more efficient imperative implementation of a pretty printer. This paper shows
> that the same efficiency is also obtainable without destructive updates by developing a
> similar but purely functional Haskell implementation with the same complexity bounds."
> — [Chitil 2005][chitil05], Abstract

"They all make use of some backtracking" is the honest characterization of `fits`: measuring a
group means walking a prefix of the document that will then be walked again to print it.
Oppen never re-walks anything. That is the gap, and closing it purely is the contribution.

> [!NOTE]
> **Title check.** The paper often cited as "Linear, **online**, functional pretty printing"
> is the 2004 Utrecht technical report; the JFP 19(1) publication is titled "Linear,
> **bounded**, functional pretty-printing". Both names refer to the same work. This survey
> uses the published title and notes the alias here once.

Practically, this sub-line is the least deployed of the three: prettier, `google-java-format`
and the D candidates all build the whole `Doc`, because a formatter already holds the whole
file in memory and O(document) space is not a constraint. Its value here is **theoretical
closure** — it proves the algebraic interface costs nothing asymptotically, so choosing
combinators over Oppen's procedure is a pure ergonomics win, not a trade.

---

## Power & limits

**Wadler's "optimal" is not optimality.** This is the single most-confused point in the
literature and it must be stated precisely. Wadler defines:

> "Say that a pretty printing algorithm is **optimal** if it chooses line breaks so as to
> avoid overflow whenever possible; say that it is **bounded** if it can make this choice
> after looking at no more than the next `w` characters, where `w` is the line width."
> — [Wadler][wadler], §5 "Optimality"

Under _that_ definition Wadler's printer and Oppen's are both optimal and bounded, and Hughes'
provably cannot be both ("Hughes notes that there is no algorithm to choose line breaks for
his combinators that is optimal and bounded", §5). But "avoid overflow whenever possible" is
a **feasibility** criterion, not a **quality** criterion: among the many layouts that avoid
overflow, it says nothing about which is best. Bernardy's sense of optimal — _shortest output_
— is strictly stronger and is not achieved here. Keeping these two senses apart is the
precondition for reading [optimality][optimality] correctly.

**What greedy `group` cannot do**, concretely:

1. **Trade a worse local choice for a better global one.** The group at the current position
   fits or it does not; that a _different_ choice would let three later groups fit is
   unrepresentable. Same limitation as [Oppen][oppen] §8, inherited wholesale.
2. **Express alignment.** `nest` adds a relative indent. Aligning subsequent lines under a
   column determined at runtime (`f(a,` / `  b)`) requires knowing the current column, which
   the algebra does not expose. Wadler acknowledges losing layouts Hughes could express;
   this is the main one. prettier adds `align`; Bernardy makes it a first-class operator.
3. **Choose among more than two candidates.** The `<|>` invariant permits exactly two, and
   requires they flatten alike. prettier needed `conditionalGroup`/`expandedStates` — an
   ordered candidate list — to escape it, which technically violates the invariant and is why
   prettier's printer needs `shouldRemeasure`.
4. **Handle a comment.** Out of scope by construction; see [the remark](#the-remark-that-defines-this-surveys-gap).

**The strictness trap is a real, recurring bug.** Lindig's exponential blowup is not a
theoretical curiosity — it reappears every time someone ports Wadler's four lines to a strict
language without introducing the mode tag, because `better w k (best w k x) (best w k y)`
evaluates both complete branches at every union, and unions nest. Any D implementation must
start from Lindig's form, not Wadler's.

---

## Performance & complexity

| Variant                                    | Time                    | Space       | Note                                                                  |
| ------------------------------------------ | ----------------------- | ----------- | --------------------------------------------------------------------- |
| Wadler in Haskell (lazy `best`)            | O(n)                    | O(document) | Laziness is required, not an optimization                             |
| Wadler transliterated to a strict language | **exponential**         | O(document) | [Lindig][lindig], Abstract                                            |
| Lindig (mode-tagged worklist)              | O(n·w) worst, O(n) typ. | O(document) | Each `fits` costs O(w); groups nest, so the bound is not tight        |
| prettier                                   | as Lindig               | O(document) | Plus `propagateBreaks` pre-pass and `conditionalGroup` re-measurement |
| [Chitil 2005][chitil05] / [S&C 2009][sc09] | O(n)                    | **O(w)**    | Oppen's bound, functional interface                                   |
| [Oppen][oppen] (for reference)             | O(n)                    | O(w)        | Imperative, non-composable                                            |

The practically relevant row is Lindig's. `fits` is bounded by the line width, so a single
call is cheap; the cost is that a deeply nested group tower re-measures overlapping suffixes.
prettier mitigates this with `propagateBreaks`, which marks groups containing a hard break as
`break: true` before printing, so `fits` is never called on them.

---

## Where it shows up in practice

| System                                    | Evidence                                                                                                                                                                          |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **prettier**                              | `MODE_FLAT`/`MODE_BREAK` + worklist `fits` — Lindig's algorithm; lineage stated in [`technical-details.md`][prettier-td]                                                          |
| **Haskell `pretty`**                      | The GHC package descended from Hughes' library; "a variant of it was implemented for use in the Glasgow Haskell Compiler by Simon Peyton Jones (1997)" ([Wadler][wadler], §Intro) |
| **Haskell `wl-pprint` / `prettyprinter`** | Direct Wadler-Leijen implementations                                                                                                                                              |
| **OCaml `PPrint`, `Fmt`**                 | Lindig's transcription is written _for_ OCaml; OCaml's stdlib `Format` is Oppen instead ([oppen][oppen])                                                                          |
| **`google-java-format`**                  | A `Doc`/`Level`/`Break` model with `fits`-style measurement — see [the long tail][long-tail]                                                                                      |
| **SDC's `sdfmt`** (D)                     | `chunk.d` / `span.d` / `writer.d` — a `Doc`-like chunk model; see [the D landscape][d-landscape]                                                                                  |
| **this repo**                             | [`signature_layout.d`][sig-layout] is a hand-rolled staged `group`: try flat, then break progressively harder                                                                     |

---

## Strengths

- **Composable.** A `Doc` is a value. Sub-printers compose without coordinating on
  indentation state — Hughes' original selling point, and still the reason this interface won.
- **Tiny core.** Six constructors and ~20 lines of interpreter. Wadler's complete library
  fits on two pages; Lindig's OCaml is comparable.
- **Correct by construction on the fit question.** The `<|>` invariant (both branches flatten
  alike) means a layout choice can never change the _content_, only its line breaks — an
  extremely strong safety property that search-based formatters must establish some other way.
- **Language-independent and well-understood.** Four decades of implementations across
  Haskell, OCaml, ML, JavaScript, Java, Rust and D, with the algebra unchanged.
- **Predictable.** Greedy, local decisions; a change in one part of a file cannot re-lay-out a
  distant part.

## Weaknesses

- **Greedy.** Optimal only in Wadler's feasibility sense; makes no attempt at the best layout
  among the feasible ones.
- **Binary choice.** Two candidates per `group`, both flattening alike. Real formatters
  outgrow this and bolt on candidate lists (`conditionalGroup`, `expandedStates`).
- **No alignment.** `nest` is relative indentation only; column alignment is outside the
  algebra and is added ad hoc by every implementation.
- **Strictness trap.** The canonical Haskell code is exponential in any strict language.
- **Silent on comments and layout preservation** — by explicit disclaimer, and this is the
  half of a code formatter the algebra does not touch.

---

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                                       | Trade-off                                                                                                      |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| A `Doc` **value** rather than a token stream                        | Composability: sub-printers combine without sharing indentation state ([Hughes][hughes], §2.2)                  | The whole document must be built before printing — O(document) space unless you adopt the Chitil/S&C machinery |
| **One** associative concatenation (Wadler) rather than two (Hughes) | Two operators associate in only one direction and lack units; one gives a clean monoid and a simpler derivation | Loses some layouts Hughes could express — Wadler admits it, Bernardy reclaims them                             |
| `group` defined as `flatten x <\|> x`                               | Makes the choice binary and content-preserving; `fits` becomes an O(w) test                                     | Exactly two candidates, forever; `conditionalGroup` is a patch over this                                       |
| `fits` **stops at the first `line`**                                | Bounds the check by the line width, giving Wadler's "bounded" property                                          | The decision cannot consider anything past the current line — the structural cause of greedy suboptimality     |
| Wadler: **laziness** as the evaluation strategy                     | Lets `better` explore only as far as `fits` needs                                                               | Exponential when transliterated strictly — the entire content of [Lindig 2000][lindig]                         |
| Lindig: an explicit **`Flat`/`Break` mode tag**                     | Removes the laziness dependency; makes the printer a tail-recursive worklist loop                               | The mode must be threaded manually through every constructor; more code, but portable to any language          |
| Chitil / S&C: **bounded-space** functional printing                 | Recovers Oppen's O(w) with the algebraic interface                                                              | Substantially more intricate; unnecessary when the file already fits in memory, hence rarely deployed          |
| **Comments and layout preservation declared out of scope**          | Keeps the algebra small and provable                                                                            | Leaves the hardest half of a _code_ formatter entirely to the caller                                           |

---

## Sources

**Primary:**

- John Hughes, _The Design of a Pretty-printing Library_, in _Advanced Functional Programming_
  (LNCS 925), 1995, 44 pp. [`hughes-1995-design-pretty-printing-library-afp.pdf`][hughes]
- Philip Wadler, _A prettier printer_, in _The Fun of Programming_, 2003 (circulated 1998).
  [`wadler-1998-prettier-printer.pdf`][wadler]
- Christian Lindig, _Strictly Pretty_, March 6, 2000. [`lindig-2000-strictly-pretty.pdf`][lindig]
- Olaf Chitil, _Pretty Printing with Lazy Dequeues_, TOPLAS 27(1), January 2005, pp. 163–184.
  [`chitil-2005-pretty-printing-lazy-dequeues-toplas.pdf`][chitil05]
- Olaf Chitil, _Pretty Printing with Delimited Continuations_, University of Kent Technical
  Report 4-06, June 2006. [`chitil-2006-…-techreport.pdf`][chitil06]
- S. Doaitse Swierstra & Olaf Chitil, _Linear, bounded, functional pretty-printing_, JFP
  19(1), January 2009. [`swierstra-chitil-2009-…-jfp.pdf`][sc09]

**Implementations read:**

- `src/document/printer/printer.js` + `docs/technical-details.md` — [prettier][prettier-printer] @ `414e453a`
- `compiler/rustc_ast_pretty/src/pp.rs` — [rust-lang/rust][rustc-pp] (the Oppen contrast)

**Related deep-dives in this tree:**
[Oppen][oppen] · [Optimality][optimality] · [Cost & search][cost-search] ·
[Layout preservation][layout-preserving] · [Concepts][concepts] · [prettier][prettier] ·
[The D landscape][d-landscape]

<!-- References -->

<!-- Papers & external -->

[hughes]: https://web.archive.org/web/2019id_/http://belle.sourceforge.net/doc/hughes95design.pdf
[wadler]: https://homepages.inf.ed.ac.uk/wadler/papers/prettier/prettier.pdf
[lindig]: https://lindig.github.io/papers/strictly-pretty-2000.pdf
[chitil05]: https://www.cs.kent.ac.uk/pubs/2005/2062/content.pdf
[chitil06]: https://www.cs.kent.ac.uk/pubs/2006/2381/content.pdf
[sc09]: https://www.cs.kent.ac.uk/pubs/2009/2847/content.pdf
[prettier-printer]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/document/printer/printer.js
[prettier-td]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/technical-details.md
[rustc-pp]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/compiler/rustc_ast_pretty/src/pp.rs

<!-- Sibling theory docs -->

[theory-index]: ./index.md
[oppen]: ./oppen.md
[optimality]: ./optimality.md
[cost-search]: ./cost-and-search.md
[layout-preserving]: ./layout-preserving.md

<!-- Tree-level docs -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[d-landscape]: ../d-landscape.md
[baseline]: ../dmd-lsp-baseline.md

<!-- System deep-dives -->

[prettier]: ../prettier.md
[long-tail]: ../long-tail.md

<!-- In-repo -->

[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d
