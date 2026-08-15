# A Proposal — `sparkles:dmd-fmt`

What this survey recommends building, in what order, and why. Each milestone names the prior art
it borrows from. This is a research conclusion, not a spec: the spec belongs in
`docs/specs/dmd-fmt/` and should be written from M0's findings.

**Last reviewed:** August 15, 2026

---

## The three decisions

Everything below follows from three choices the survey settles.

**1. Format the token stream; use the AST as an oracle.**
[The substrate baseline][baseline] establishes that DMD's own lexer emits comments
(`TOK.comment`) and whitespace (`TOK.whitespace`) as tokens with exact buffer pointers, and that
`dmd:lexer` is already linked. Given that, the token spine costs nothing and buys: no
[comment-attachment module][attachment] (prettier spends 1,255 lines on one language, rustfmt
2,149), formatting of files that do not parse — the common case on an LSP keystroke path — verbatim
literals, and a nearly-free verifier. [dfmt][dfmt] proves the architecture in D; [clang-format][clang-format]
proves it at scale.

**2. Greedy `Doc` engine first; search only behind a flag, later, with measurements.**
Every search-based formatter surveyed — clang-format, scalafmt, dfmt, dart_style, sdfmt — is
exponential in the worst case and caps itself with a hard-coded constant, silently
([the incompleteness budget][budget]). Greedy `group`/flat is [what prettier ships][prettier], is
[what `signature_layout.d` already implements in this repo][sig-layout], and has a latency bound.
Search is [M9](#m9--stretch-cost-search-behind-a-flag).

**3. Emit `TextEdit[]`, from day one.**
[clang-format][clang-format] and [Roslyn][roslyn] arrive at this from opposite architectures, and
it is the axis that determines whether range formatting, format-on-type and cursor preservation are
possible at all. Retrofitting it is what produced clang-format's `AffectedRangeManager` and shaped
Roslyn's whole design. It is cheap when decided first.

---

## Milestones

### M0 — Spikes and decisions

Deliverable: a decision record, not code.

- **Prove the spine.** Instantiate `dmd.lexer.Lexer` with `commentToken: true,
whitespaceToken: true`; reconstruct a corpus of D files byte-for-byte from the token stream.
  This is the whole architecture in one experiment.
- **Inventory `Loc.fileOffset()`** coverage per node kind, for the AST-oracle table.
- **State a latency budget** (proposed: p95 < 30 ms for 2 kLOC, lexer-only path) and measure the
  lexer against it.
- **Fix the output contract** as `TextEdit[]`, and the escape-hatch spelling (`// dfmt off`/`on`
  for migration compatibility — see [the hatch table][hatches]).
- **Decide the `signature_layout.d` question**: does the new engine subsume it, and does
  `sparkles:twoslash` migrate? The repo should not carry two layout engines. (`prettyprint.d` is a
  value printer and is out of scope.)

### M1 — The spine and the verifier, before any layout code

_Borrowed from [ocamlformat][ocamlformat] and [ruff][rust-reimpl]; the ordering is deliberate — a
verifier written after a printer is a verifier written to agree with that printer's bugs._

- A lossless token+trivia stream that round-trips the input exactly.
- **Token equality modulo whitespace** as the primary check.
- **A separate DDoc check.** D has OCaml's hazard: ddoc is semantically attached,
  `Token.blockComment`/`lineComment` carry it, and a formatter that reattaches one silently changes
  generated documentation. Its own check, its own error — [ocamlformat's `moved_docstrings`][ocamlformat].
- An **idempotence harness** iterating to a fixed point with a bounded count, wired into
  `dub run :ci`.

### M2 — `Doc` IR and greedy engine

_Borrowed from [Lindig via prettier][combinators]; **start from Lindig's strict form**, never
Wadler's lazy one, which is exponential in a strict language._

- `text` / `line` / `softline` / `hardline` / `group` / `fill` / `indent` / `align` /
  `ifBreak` / `lineSuffix`, with **`fits` taking the rest of the worklist** (Lindig's `z`).
- **The width measurer is an injected parameter**, as `signature_layout.d` already does — and the
  default should count **graphemes**, as [sdfmt][d-landscape] does and dfmt does not.
- `propagateBreaks` as a pre-pass ([prettier][prettier]).
- Prove on imports, declarations and simple statements.

### M3 — The AST oracle and the whole-language printer

_Borrowed from [dfmt][dfmt]'s `ASTInformation` and [google-java-format][long-tail]'s
AST → flat `Op` stream → `Doc` tree pipeline._

- A visitor over the DMD AST populating **sorted offset arrays** of structural facts, queried by
  binary search at format time. The AST is not consulted after this pass.
- The printer walks tokens, consults the oracle, and emits `Doc`.
- **Every construct in [Q-e's hard list][hard-list] gets a fixture before it gets a rule**;
  verbatim regions (`asm`, `q{}`, delimited strings, nested `/+ +/`) are identity by default.
- **The `Option`/do-no-harm valve** ([rustfmt][rustfmt]): a construct the printer cannot model
  yields the original bytes, and `--error-on-unformatted` makes that visible.

### M4 — Comments, blank lines, and the author's signals

_Borrowed from [Buse & Weimer][readability] (blank lines are the one layout feature with real
empirical support), [black][long-tail] and [zig fmt][zig-fmt]._

- Blank-line policy: preserve author intent, collapse runs (gofmt's `maxNewlines = 2`).
- **The magic trailing comma** — a user-written trailing comma pins a list to one-per-line. Four
  systems arrived at this independently; it is cheap on a token spine.
- **DDoc preserved verbatim in v1.** No reflow. Its internal layout is a second formatting
  language ([embedded languages][concepts-embedded]) and belongs in a later milestone if ever.

### M5 — Edits, not strings

- A minimal-diff pass producing `TextEdit[]`.
- `textDocument/formatting`; `--check` with a CI exit code.

### M6 — Range, on-type, and cursor

_Borrowed from [clang-format][clang-format]'s `AffectedRangeManager` and [Roslyn][roslyn]'s
`SuppressOperation`._

- One suppression mechanism serving range requests, `// dfmt off`, verbatim regions and inactive
  `version` blocks — Roslyn's insight that these are the same concept.
- Cursor preservation (`--cursor`).

### M7 — Configuration

- **`.editorconfig` discovery honouring dfmt's `dfmt_*` keys**, so existing projects migrate
  without re-configuring. This is the adoption question, and it is 10% of dfmt's code.
- A small option set, documented [in `Configurations.md`'s before/after style][rustfmt], with a
  **stable/unstable split** (rustfmt) and a **calendar-year style freeze** with a preview channel
  ([black][long-tail]).

### M8 — Corpus and differential testing

_Borrowed wholesale from [ruff][rust-reimpl]._

- Format Phobos, druntime and `sparkles` with both dfmt and `dmd-fmt`.
- Publish the **similarity index** using ruff's published definition — neutral lines ÷ (neutral +
  removed) — and **gate CI on not decreasing it**.
- Run the **stability triad** on every change: second pass differs / invalid output / crashes.
- Delete fixtures as they converge, so the remaining corpus is the remaining disagreement.

### M9 — (Stretch) cost search behind a flag

_Borrowed from [dart_style][dart-style] and [sdfmt][d-landscape], both of which independently
memoize._

- Swap greedy `fits` for a cost-minimizing search behind a flag.
- **Take dart_style's memoized subtree hoisting** — solve layout-independent subtrees once and
  reuse across candidate solutions — and **pinning**, for rules like "nested `static if` always
  breaks" that no penalty expresses robustly.
- **If a cap is needed, report it.** Every surveyed system caps silently; this one should not.
- Measure output quality _and_ p95 latency before committing.

---

## Explicit non-goals

- **Comment reflow.** Neither dfmt nor sdfmt does it; the risk/benefit is poor and DDoc makes it
  worse.
- **Token-changing passes** (import sorting, attribute reordering). clang-format and rustfmt both
  do [job three][three-jobs]; this proposal defers it, and if it lands it should be off by default
  and named as refactoring, not formatting.
- **A tree-sitter substrate.** Viable ([topiary][topiary]) but now unnecessary, and it would mean
  maintaining a second D grammar beside the compiler's own lexer.
- **Beating dfmt on style opinions.** The measurable goals are the citable ones: dfmt's 32-token
  search window and its silently-unsolved output.

---

## What would make this proposal wrong

Stated plainly, since M0 is a spike and spikes can fail:

- **If the lexer's `whitespaceToken` path is unusable** (DMDLIB-gated at build time in a way the
  pinned fork does not enable, or lossy in practice), the spine costs more and the tree-sitter
  route returns as a serious option.
- **If the AST oracle cannot disambiguate enough** with start offsets alone, the design needs end
  positions after all — Q-b becomes load-bearing again.
- **If greedy output is materially worse than dfmt's** on the M8 corpus, M9 stops being a stretch
  goal and becomes a requirement.

---

## Sources

Every milestone's borrowing is cited in its deep-dive. The substrate findings are in
[the baseline][baseline]; the D prior art is in [the D landscape][d-landscape]; the verification
stack is in [verification][verification].

**Related deep-dives in this tree:**
[The substrate baseline][baseline] · [The D landscape][d-landscape] · [Verification][verification] ·
[Comparison][comparison] · [Combinators][combinators] · [Cost & search][cost-search] ·
[dfmt][dfmt] · [prettier][prettier] · [clang-format][clang-format] · [dart_style][dart-style]

<!-- References -->

[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d
[combinators]: ./theory/combinators.md
[cost-search]: ./theory/cost-and-search.md
[budget]: ./theory/cost-and-search.md#the-incompleteness-budget
[concepts]: ./concepts.md
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[hatches]: ./concepts.md#9-verbatim-regions-and-escape-hatches
[three-jobs]: ./concepts.md#1-what-a-formatter-is-and-its-three-jobs
[concepts-embedded]: ./concepts.md#10-embedded-and-foreign-languages
[baseline]: ./dmd-lsp-baseline.md
[hard-list]: ./dmd-lsp-baseline.md#q-e-the-d-specific-hard-list
[d-landscape]: ./d-landscape.md
[verification]: ./verification.md
[readability]: ./readability-evidence.md
[comparison]: ./comparison.md
[dfmt]: ./dfmt.md
[prettier]: ./prettier.md
[clang-format]: ./clang-format.md
[roslyn]: ./roslyn.md
[rustfmt]: ./rustfmt.md
[dart-style]: ./dart-style.md
[ocamlformat]: ./ocamlformat.md
[rust-reimpl]: ./rust-reimplementations.md
[long-tail]: ./long-tail.md
[zig-fmt]: ./zig-fmt.md
[topiary]: ./topiary.md
