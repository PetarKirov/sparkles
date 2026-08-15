# gofmt (Go)

The formatter that proves line breaking is optional. `gofmt` has **no column limit**, does not
wrap long lines, and never decides where a construct should break — it reuses **the author's own
newlines**, clamped to at most two, and spends its effort on the one thing it does decide:
column alignment, delegated to `text/tabwriter`. It is also the cultural origin of the
zero-options formatter, and the reason "gofmt'd" became a verb.

|                     |                                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------------------- |
| **Language**        | Go                                                                                                      |
| **License**         | BSD-3-Clause                                                                                            |
| **Repository**      | [`golang/go`][repo] @ `01534385` (2026-06-01)                                                           |
| **Layout engine**   | `src/go/printer/` — `nodes.go` (2,016) · `printer.go` (1,435) · `comment.go` (155) · `gobuild.go` (170) |
| **Driver**          | `src/cmd/gofmt/` — `gofmt.go` (577) · `simplify.go` (169) · `rewrite.go` (309)                          |
| **Category**        | AST + comment map · **author's-breaks-preserved** · elastic tabstops                                    |
| **Layout paradigm** | line-**preserving**, not line-breaking                                                                  |

---

## Overview

### What it solves

Not "what is the prettiest layout" but "how do we stop arguing". gofmt normalizes everything
mechanical — spacing, indentation, alignment, blank-line runs — and leaves every genuine layout
judgement to the author. The result is a formatter with **no configuration at all** and
consequently no configuration debate, which is the property the rest of the industry copied.

The `gofmt` command's entire flag surface is I/O and rewriting; there is not one formatting
option:

```go
list        = flag.Bool("l", false, "list files whose formatting differs from gofmt's")
write       = flag.Bool("w", false, "write result to (source) file instead of stdout")
rewriteRule = flag.String("r", "", "rewrite rule (e.g., 'a[b:len(a)] -> a[b:]')")
simplifyAST = flag.Bool("s", false, "simplify code")
doDiff      = flag.Bool("d", false, "display diffs instead of rewriting files")
allErrors   = flag.Bool("e", false, "report all errors …")
```

— [`src/cmd/gofmt/gofmt.go`][gofmt-go]

### Design philosophy

gofmt has no design document. The philosophy is legible in one function signature:

```go
func (p *printer) linebreak(line, min int, ws whiteSpace, newSection bool) (nbreaks int) {
	n := max(nlimit(line-p.pos.Line), min)
	…
}
```

— [`src/go/printer/nodes.go`][nodes-go]

`line` is **the line number in the source**. The number of newlines emitted is
`line - p.pos.Line` — the gap the author left — clamped by `nlimit` to `maxNewlines = 2`. The
input's own vertical structure _is_ the layout decision. No `fits`, no width, no cost.

This is the paradigm [this survey calls **author's-breaks-preserved**][concepts-break], and gofmt
is its purest instance. Note that it appears elsewhere in weaker forms — prettier keeps an object
expanded if the source had a newline after `{`, black's magic trailing comma is the same channel
with one bit — but only gofmt makes it the entire policy.

---

## How it works

### Whitespace as a byte alphabet

`printer.go` encodes pending whitespace as single bytes, several of which are instructions to
the downstream `tabwriter` rather than characters:

```go
const (
	ignore   = whiteSpace(0)
	blank    = whiteSpace(' ')
	vtab     = whiteSpace('\v')
	newline  = whiteSpace('\n')
	formfeed = whiteSpace('\f')
	indent   = whiteSpace('>')
	unindent = whiteSpace('<')
)
```

— [`src/go/printer/printer.go`][printer-go]

`vtab` is a **column separator** and `formfeed` **terminates an alignment section**. The printer
emits a stream annotated with these, and `text/tabwriter` makes the second pass that turns them
into aligned spaces. Alignment is therefore a genuinely separate engine — the same structural
separation clang-format makes with `WhitespaceManager`, and evidence for
[treating alignment as its own dimension][spine].

### Elastic tabstops

The alignment model is Nick Gravgaard's _elastic tabstops_: consecutive lines form a "section",
columns within a section are widened to the widest cell, and a `formfeed` breaks the section so a
long outlier does not stretch its neighbours. This is why gofmt aligns struct field types and
consecutive assignments without any `AlignConsecutive*`-style options, and why inserting one long
field re-aligns its block — a **local** churn that is bounded by the section.

### Comments

Comments are held in an `ast.CommentGroup` map and interspersed by position rather than attached
to nodes. gofmt is honest in-source about the seam this leaves — a `TODO` on `linebreak` itself:

> "TODO(gri): linebreak may add too many lines if the next statement at 'line' is preceded by
> comments because the computation of n assumes the current position before the comment and the
> target position after the comment. … At the moment there is no easy way to know about future
> (not yet interspersed) comments in this function."
> — [`src/go/printer/nodes.go`][nodes-go]

That is [the attachment problem][attachment] surfacing even in a formatter that has deliberately
minimized its exposure to it.

---

## 1. Input model & fidelity

**AST (`go/ast`) plus a comment map.** Not a full-fidelity tree: whitespace is not in the tree,
which is exactly why the printer must carry source line numbers into `linebreak`.

**Round-trip:** not a goal. gofmt is idempotent in practice and tested against a `testdata/*.golden`
corpus, but there is no equivalence checker.

**Behaviour on unparseable input: refuses.** `go/parser` must succeed. This is the opposite of
[dfmt][dfmt] and [clang-format][clang-format], and it is the property that makes gofmt a poor
model for an LSP-attached formatter — a buffer mid-edit does not parse.

## 2. Layout IR & break decision

**Paradigm: author's-breaks-preserved.** No IR in the [Doc][combinators] sense; the printer emits
tokens and whitespace directly.

**Width policy: none.** There is no column limit anywhere in `go/printer`. A 300-character line
written by the author stays 300 characters. `infinity = 1 << 30` exists in `printer.go` as a
sentinel for "no constraint", which is a fair summary of the design.

The consequence, stated plainly because it is easy to miss: **gofmt cannot make code fit.** It
guarantees consistency, not legibility at any particular width. Everything in [`theory/`][theory]
is about a problem gofmt declines to have.

## 3. Alignment, indentation & vertical rhythm

The strongest dimension. Tabs for indentation, `tabwriter` elastic tabstops for alignment,
`maxNewlines = 2` for blank-line runs, `formfeed` to bound alignment sections. Width is counted
in **runes** by `tabwriter`.

## 4. Comments, trivia & preservation

Position-based interspersal from a comment map; no reflow of comment interiors; the known
`linebreak`/comment interaction documented as a TODO above.

## 5. Configurability, opinionation & config discovery

**Zero formatting options.** No config file, no discovery, nothing to find. `-r` (a rewrite rule)
and `-s` (simplify) are _refactoring_ switches, off by default — an interesting boundary case for
[the "does my formatter change tokens" question][three-jobs], since gofmt ships the capability but
does not enable it.

## 6. Integration surface & output contract

**Whole document.** `-l` lists non-conforming files, `-d` prints a diff, `-w` writes in place —
the `--check` idiom in three flags. No range formatting, no on-type formatting, no cursor
preservation, no `TextEdit[]`. Editor integrations reformat the entire buffer on save, which is
tolerable precisely _because_ the formatter is line-preserving: the diff is small by construction.

---

## Strengths

- **Zero options ends the debate.** The cultural contribution, and the reason it is imitated.
- **Fast and simple.** No search, no measurement, no backtracking.
- **Minimal diffs by construction.** Preserving the author's breaks means a reformat rarely
  touches lines the author did not touch — the property search-based formatters must work to
  recover.
- **Excellent alignment** via a genuinely separate, well-understood mechanism.
- **Predictable**: output is a local function of the input's own shape.

## Weaknesses

- **Cannot make anything fit.** No width limit means long lines stay long; the reader gets no
  help from the tool.
- **Consistency is only partial.** Two authors writing the same expression with different
  newlines both get "gofmt'd" output that differs.
- **Refuses invalid input**, which rules out formatting-while-typing.
- **No range formatting or cursor preservation.**
- **A known comment/linebreak interaction** left as a TODO in the source.

---

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                       | Trade-off                                                                            |
| --------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| **No column limit**                                       | Line breaking is where formatters become opinionated and slow; skip it entirely | The formatter cannot help with the layout problem readers actually have              |
| **Reuse the author's newlines**, clamped to 2             | The author knows the logical grouping; the tool need not guess                  | Identical code formats differently depending on how it was typed                     |
| **Zero configuration options**                            | Ends style debate; makes "gofmt'd" a checkable property                         | Nothing can be adapted to a project's existing conventions                           |
| Alignment via **`text/tabwriter`** and elastic tabstops   | Reuses a general mechanism; keeps alignment out of the printer                  | Adding one long field re-aligns its whole section — bounded churn, but churn         |
| Whitespace as a **byte alphabet** incl. `vtab`/`formfeed` | Lets the printer stream and the aligner run as a second pass                    | The two passes must agree on section boundaries; `formfeed` placement becomes subtle |
| **Refuse unparseable input**                              | Never emit code you did not understand                                          | Cannot format a buffer being edited — the common LSP case                            |
| Ship `-r`/`-s` but **default them off**                   | Rewriting is available without being imposed                                    | The tool is capable of token-level changes it does not advertise as formatting       |

---

## What a D formatter should take

**Take:** the blank-line policy (`maxNewlines = 2` — cheap, and it is most of what "tidy" means);
alignment as a separate post-pass rather than a printer concern; the `-l`/`-d`/`-w` CLI triple.

**Do not take:** the absence of a width limit. D's `getopt` chains and template constraints are
exactly the constructs a reader needs help with, and dfmt's users already expect wrapping. gofmt's
answer works for Go partly because Go's grammar discourages deep nesting; D's does not.

**Note for the proposal:** gofmt is the counterexample to the assumption that a formatter must
line-break. It is worth being explicit in the [proposal][proposal] that D is choosing to take on
that problem, rather than inheriting the choice unexamined.

---

## Sources

- [`golang/go`][repo] @ `015343854b5d9e2829481df30dbcae2ca6682d25`: `src/go/printer/nodes.go`,
  `printer.go`, `comment.go`; `src/cmd/gofmt/gofmt.go`, `simplify.go`, `rewrite.go`
- Alignment: Go's `text/tabwriter`, implementing elastic tabstops

**Related deep-dives in this tree:**
[Concepts][concepts] · [Oppen][oppen] · [Combinators][combinators] · [dfmt][dfmt] ·
[clang-format][clang-format] · [Comparison][comparison]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/golang/go/tree/015343854b5d9e2829481df30dbcae2ca6682d25
[nodes-go]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/go/printer/nodes.go
[printer-go]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/go/printer/printer.go
[gofmt-go]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/cmd/gofmt/gofmt.go

<!-- Theory docs -->

[theory]: ./theory/index.md
[oppen]: ./theory/oppen.md
[combinators]: ./theory/combinators.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[concepts-break]: ./concepts.md#5-line-breaking-vocabulary
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[three-jobs]: ./concepts.md#1-what-a-formatter-is-and-its-three-jobs
[spine]: ./index.md#taxonomies
[comparison]: ./comparison.md
[proposal]: ./dmd-fmt-proposal.md

<!-- System deep-dives -->

[dfmt]: ./dfmt.md
[clang-format]: ./clang-format.md
