# Comparison & Synthesis

The capstone of the [code-formatting survey][umbrella]: an at-a-glance matrix across the thirteen
surveyed systems, a head-to-head along the survey's [six-dimension spine](#the-six-dimension-spine),
the **consensus** the field has converged on, the **trade-offs that remain genuinely open**, and a
delta table for where D stands.

**Last reviewed:** August 15, 2026

> [!NOTE]
> **Scope.** Thirteen systems read from pinned source trees, plus twenty papers (seventeen held
> locally). Conclusions below are stable for the systems surveyed; three papers
> (Podkopaev & Boulytchev, Mi ×2) are paywalled and are used second-hand where cited.

---

## At-a-glance matrix

| System                       | Input model           | Break paradigm                     | Width           | Broken input      | Comments                | Output             | Config             |
| ---------------------------- | --------------------- | ---------------------------------- | --------------- | ----------------- | ----------------------- | ------------------ | ------------------ |
| [prettier][prettier]         | AST + attached        | [combinator, greedy][combinators]  | hard            | **refuses**       | 1,255-line module       | document           | tiny               |
| [clang-format][clang-format] | **token stream**      | [cost search][cost-search]         | limit + penalty | **formats**       | tokens; **reflows**     | **`Replacements`** | huge + presets     |
| [rustfmt][rustfmt]           | AST + spans           | heuristic budget                   | hard            | refuses           | 2,149-line module       | document           | large              |
| [gofmt][gofmt]               | AST + comment map     | **author's breaks**                | **none**        | refuses           | position-based          | document           | **zero**           |
| [zig fmt][zig-fmt]           | AST + token index     | **source-hint (comma)**            | **none**        | refuses           | forces multi-line       | document           | **zero**           |
| [dfmt][dfmt]                 | **token stream**      | [cost search, capped][cost-search] | soft + hard     | **formats**       | **tokens; none needed** | document           | `.editorconfig`    |
| [Roslyn][roslyn]             | **full-fidelity CST** | **local rule chain**               | (none)          | **formats**       | **owned by tokens**     | **`TextEdit[]`**   | large              |
| [dart_style][dart-style]     | AST → `Piece`s        | **n-way constraint solver**        | hard            | refuses           | pieces                  | document           | **zero**           |
| [topiary][topiary]           | **tree-sitter CST**   | **declarative queries**            | soft            | refuses (`ERROR`) | **tokens; none needed** | document           | **queries**        |
| [ocamlformat][ocamlformat]   | AST + attached        | combinator                         | hard            | refuses           | **verified**            | document           | large + profiles   |
| [swift-format][swift-format] | **full-fidelity CST** | combinator                         | hard            | conservative      | **classified tokens**   | document           | small              |
| [black][long-tail]           | AST                   | greedy + magic comma               | hard            | refuses           | attached                | document           | **tiny by policy** |
| [sdfmt][d-landscape]         | own parser → chunks   | cost search, memoized              | hard            | —                 | chunks                  | document           | minimal            |

---

## The six-dimension spine

### 1. Input model & fidelity

**The field has split into two camps, and the split predicts everything else.**

- **Tree-first** (prettier, rustfmt, gofmt, zig, dart_style, black, ocamlformat): must reconstruct
  what the tree discarded. Every one of them has a large comment module, and every one **refuses
  unparseable input**.
- **Fidelity-first** (clang-format, dfmt, Roslyn, topiary, swift-format): the comment is a token or
  a trivia field, so [the attachment problem][attachment] does not arise. Three of the five
  **format broken input**.

The correlation is not a coincidence: a formatter that can only work from a valid tree cannot work
on a buffer mid-edit, and a formatter whose input already contains every byte does not need to
guess where a comment goes. **Fidelity-first is the better architecture for anything editor-facing**,
and the cost is a token stream you were going to need for verification anyway.

### 2. Layout IR & break decision

Six paradigms, and the surprise is how many systems are _not_ doing line breaking at all:

| Paradigm                     | Systems                                                                             | Notes                       |
| ---------------------------- | ----------------------------------------------------------------------------------- | --------------------------- |
| Author's-breaks-preserved    | gofmt, Roslyn (default)                                                             | no width model at all       |
| Source-hint                  | zig fmt (trailing comma), black (magic comma), prettier (blank lines, `objectWrap`) | one bit per construct       |
| Oppen one-pass               | `rustc_ast_pretty`, OCaml `Format`                                                  | the ancestor; bounded space |
| **Combinator group/flat**    | **prettier**, google-java-format, swift-format, ocamlformat, ruff/Biome             | the majority                |
| **Cost-minimizing search**   | **clang-format**, dfmt, dart_style, scalafmt, sdfmt                                 | the quality ceiling         |
| Declarative from foreign CST | topiary                                                                             | one engine, N languages     |

**Two of thirteen have no width limit at all** (gofmt, zig fmt) and a third effectively does not
(Roslyn). "A formatter breaks lines" is a choice, not a definition.

### 3. Alignment, indentation & vertical rhythm

**Alignment is a separate engine wherever it is done well** — gofmt's `text/tabwriter`,
clang-format's `WhitespaceManager` — and absent or weak everywhere else (topiary has no `align`
capture at all; dfmt has one switch). This is why the survey makes it its own dimension rather than
folding it into layout.

**Width measurement is quietly wrong in most systems.** dfmt counts bytes; prettier and
clang-format have real display-width models; sdfmt counts **graphemes** — the only D tool that does.

### 4. Comments, trivia & preservation

The dimension that costs the most and is discussed the least. Measured:

| System               | Comment machinery                                           |
| -------------------- | ----------------------------------------------------------- |
| rustfmt              | `comment.rs` — **2,149 lines**                              |
| prettier             | `attach.js` 393 + `handle-comments.js` **1,255** (JS alone) |
| clang-format         | `BreakableToken.cpp` 1,162 (reflow)                         |
| dfmt, topiary        | **none** — token order is the answer                        |
| Roslyn, swift-format | **none** — trivia is owned                                  |

Against prettier's 578-line _printer_. **In a reprinting formatter, comments cost two to four times
what layout costs.** That single ratio is the strongest architectural argument in the survey.

### 5. Configurability, opinionation & config discovery

Four postures: zero (gofmt, zig, dart_style), tiny-by-policy (black, prettier, swift-format),
large + presets (clang-format, rustfmt, ocamlformat), delegated (dfmt and Roslyn →
`.editorconfig`).

**The zero-options position won the argument and lost the practice.** It is the stated ideal
everywhere, and the two most-deployed formatters for existing codebases (clang-format, rustfmt)
have the largest option surfaces — because a formatter nobody adopts formats nothing. dfmt's
`.editorconfig` delegation is the pragmatic middle and is 10% of its code.

### 6. Integration surface & output contract

**The sharpest divide in the survey, and the least discussed.** Two systems emit **edits**
(clang-format's `Replacements`, Roslyn's `TextEdit[]`); eleven emit a document. Those same two are
the only ones with real range formatting, format-on-type and cursor preservation.

That clang-format and Roslyn reached the same conclusion from opposite architectures — a token
stream with no parse, and a full-fidelity CST inside an IDE — is the strongest single signal here.
**The output contract is not an integration detail; it is a foundational choice**, and retrofitting
it is what produced `AffectedRangeManager` and shaped Roslyn's entire design.

---

## The consensus standard

Where the field genuinely agrees, and a new formatter should not re-litigate:

1. **A layout IR with `group`/flat semantics.** Whatever the engine, the document is built from
   text, breaks, indent, and groups. Even search-based systems have an equivalent.
2. **The consistent/inconsistent distinction.** Invented independently at least four times —
   [Oppen 1980][oppen-cons], [Box 1996][box-ops], prettier's `group`/`fill`,
   swift-format's `GroupBreakStyle`.
3. **Blank lines are preserved, runs are collapsed.** Universal, and the one layout feature with
   [empirical support][readability].
4. **An escape hatch is mandatory.** All thirteen have one; the only variation is line-range vs
   node-scoped.
5. **A one-bit author signal is worth having.** Trailing commas (zig, black, swift-format),
   blank lines (prettier), input newlines (topiary's `@append_input_softline`). Four independent
   arrivals.
6. **Verbatim regions exist and must be identity.** String literals, raw strings, `asm`.
7. **Search-based formatters cap themselves.** clang-format, dfmt, scalafmt, dart_style and sdfmt
   all do. Six instances, zero of which tell the user.

---

## Architectural trade-offs still genuinely open

**Greedy vs search.** Greedy has a latency bound and local, predictable output; search reaches
layouts greedy cannot and pays an exponential worst case that must be capped. [dart*style rewrote
\_into* search][dart-style] for Flutter's nesting; prettier remains greedy and is the most-deployed
formatter alive. **Unresolved, and genuinely task-dependent.**

**Width limit or not.** gofmt and zig fmt decline the problem entirely and are widely liked.
[Buse & Weimer's line-length result][readability] is weak support for having one. **Unresolved.**

**How much configuration.** See dimension 5. **Unresolved, and probably about adoption strategy
rather than about formatting.**

**Whether a formatter may change tokens.** clang-format ships seven such passes and rustfmt has
`reorder_imports` on by default; prettier and gofmt keep them opt-in. **No consensus on whether
this is "formatting".**

**How to change a formatter's output over time.** Two good answers, neither dominant:
[black's calendar-year freeze with a preview channel][long-tail] and
[dart_style's language-version gating][dart-style]. Most projects still have no answer.

---

## Where D stands — the delta table

| Capability               | Field consensus                      | D today ([dfmt][dfmt])             | Gap                   |
| ------------------------ | ------------------------------------ | ---------------------------------- | --------------------- |
| Token-spine input        | fidelity-first is better for editors | ✅ (via `libdparse`)               | —                     |
| Formats broken input     | valuable                             | ✅                                 | —                     |
| Comment attachment       | avoided by token spine               | ✅ avoided                         | —                     |
| `.editorconfig` config   | good citizenship                     | ✅                                 | —                     |
| Break search quality     | uncapped or well-capped              | ❌ **32-token window**, 1,000 pops | **large**             |
| Silent degradation       | nobody reports it (but should)       | ❌ emits unsolved lines silently   | shared with the field |
| Width measurement        | graphemes/display columns            | ❌ **bytes**                       | real (sdfmt has it)   |
| Alignment engine         | separate, capable                    | ❌ one switch                      | moderate              |
| Verification             | idempotence + equivalence            | ❌ **none at all**                 | **largest**           |
| Output contract          | edits, for editor use                | ❌ whole document                  | **large**             |
| Range / on-type / cursor | required for LSP                     | ❌ none                            | **large**             |
| Comment reflow           | optional                             | ❌ none                            | acceptable            |

Two gaps dominate: **verification** (dfmt's documented mitigation is "make backups") and
**the output contract** (no edits ⇒ no range, on-type or cursor ⇒ no good LSP integration). Both
are addressed early in [the proposal][proposal], and neither requires winning the greedy-vs-search
argument.

The survey's substrate finding changes the third: [DMD's own lexer already emits comments and
whitespace as tokens with exact offsets][baseline], so the architecture the field considers best is
available in D **without a new dependency**.

---

## Sources

This synthesis rests on the thirteen system deep-dives and the [theory subtree][theory]; each
carries its own primary citations, and each has an internal grounding ledger recording what was
verified against a local artifact. The
cross-cutting classifications — the six paradigms, the fidelity-first/tree-first split, the
incompleteness budget, the output-contract divide — are this survey's own, and are argued in the
pages linked above.

<!-- References -->

[umbrella]: ./index.md
[theory]: ./theory/index.md
[oppen-cons]: ./theory/oppen.md#consistent-vs-inconsistent-breaking
[combinators]: ./theory/combinators.md
[cost-search]: ./theory/cost-and-search.md
[box-ops]: ./theory/layout-preserving.md#box-a-layout-algebra-generated-from-a-grammar
[concepts]: ./concepts.md
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[verification]: ./verification.md
[readability]: ./readability-evidence.md
[d-landscape]: ./d-landscape.md
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md
[prettier]: ./prettier.md
[clang-format]: ./clang-format.md
[rustfmt]: ./rustfmt.md
[gofmt]: ./gofmt.md
[zig-fmt]: ./zig-fmt.md
[dfmt]: ./dfmt.md
[roslyn]: ./roslyn.md
[dart-style]: ./dart-style.md
[topiary]: ./topiary.md
[ocamlformat]: ./ocamlformat.md
[swift-format]: ./swift-format.md
[long-tail]: ./long-tail.md
