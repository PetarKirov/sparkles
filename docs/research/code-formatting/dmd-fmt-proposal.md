# A Proposal — `sparkles:dmd-fmt`

What this survey recommends building, in what order, and why. Each milestone names the prior art
it borrows from. This is a research conclusion, not a spec: the spec belongs in
`docs/specs/dmd-fmt/` and should be written from M0's findings.

**Last reviewed:** August 16, 2026

---

## The three decisions

Everything below follows from three choices the survey settles.

**1. Format the token stream; use the AST as an oracle.**
[The substrate baseline][baseline] establishes that DMD's own lexer emits comments
(`TOK.comment`) and whitespace (`TOK.whitespace`) as tokens with exact buffer pointers, and that
`dmd:lexer` is already linked. Given that, the token spine is nearly free and buys: no
[comment-attachment module][attachment] (prettier spends 1,255 lines on one language, rustfmt
2,149), formatting of files that do not parse — the common case on an LSP keystroke path — verbatim
literals, and a nearly-free verifier. [dfmt][dfmt] proves the architecture in D; [clang-format][clang-format]
proves it at scale. Two caveats the survey must own rather than round off:

- **The comment cost is reduced, not zero.** The spine converts attachment from a
  tree-mapping problem into a local reordering one — but the moment layout moves tokens (a
  list explodes, a construct collapses), trailing-vs-leading placement still needs
  `lineSuffix` plus policy, diffused through the printer the way it is through dfmt's
  2,402-line `formatter.d`. [gofmt's own in-source TODO][gofmt] shows the problem surfacing
  even in a position-based design.
- **Token spine × `Doc` engine is a combination no surveyed system ships.** dfmt and
  clang-format format their token streams with flat, local decisions; every `group`-IR
  formatter (prettier, [swift-format][swift-format], google-java-format) builds its `Doc`
  from a _tree walk_ — swift-format's `TokenStreamCreator` classifies comments and emits
  nested `open`/`close` pairs while it still holds the tree. Reconstructing correctly
  _nested_ groups from a flat token walk plus start-offset oracle arrays is this design's
  one genuinely novel seam. M0 carries a spike (S2) to de-risk it before M2/M3 are built
  on it.

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

Deliverable: a decision record backed by four spikes. Every load-bearing assumption is
validated **before** any engine code exists; the spikes are ordered by how much of the design
each one can invalidate.

**Spikes:**

- **S1 — Prove the spine.** Instantiate `dmd.lexer.Lexer` with `commentToken: true,
whitespaceToken: true`; reconstruct a corpus of D files byte-for-byte from the token stream.
  Include the spine-level hard cases, not just the printer-level ones: a BOM and a `#!` shebang
  line (both consumed before the first token), `__EOF__` (bytes after it are outside the token
  stream entirely), `\r\n` endings, and nested `/+ +/`.
- **S2 — Prove nested-group reconstruction.** The design's one novel seam (see Decision 1):
  drive a correctly _nested_ `group` tree for one nontrivial construct — a function declaration
  with template constraints and contracts — from the token walk plus sorted-offset oracle
  arrays alone. If start offsets cannot recover the nesting, the fallback is a
  [swift-format][swift-format]-shaped front end — an AST **visitor** emitting the token stream
  with `open`/`close` structure — which changes M3's shape and must be known before M2 fixes
  the printer's input.
- **S3 — Settle the lexing configuration.** Verified against the pinned fork
  (`lexer.d:732–803`): every comment arm **returns the `TOK.comment` token before the
  `doDocComment` branch runs**, so `Token.blockComment`/`lineComment` are never populated on
  the trivia spine. The M1 DDoc check therefore needs either a second lex with
  `doDocComment: true` (dfmt's double-lex precedent, streams kept in offset correspondence) or
  a reimplementation of `getDocComment`'s attachment rules — and the latter is exactly the
  compiler-drift hazard the check exists to catch. **Double-lex is the default answer**; the
  spike confirms the two streams stay in offset correspondence on the corpus.
- **S4 — Inventory `Loc.fileOffset()` and end-recoverability.** Start-offset coverage per node
  kind for the AST-oracle table, **and** end-position recoverability per construct in
  [Q-e's hard list][hard-list]: the do-no-harm valve (M3) emits original bytes for a construct
  it cannot model, which requires knowing where the construct _ends_. Brace-delimited regions
  recover ends by token matching; the spike determines which of the rest cannot.

**Decisions:**

- **State a latency budget** (proposed: p95 < 30 ms for 2 kLOC) and say which path it governs.
  A lexer-only fast path exists, but its output without the oracle must be characterized —
  likely whitespace normalization only, Roslyn-style pairwise adjustments. A tiered
  fast-path/full-path split is a design decision to record, not a benchmark artifact.
- **Fix the output contract** as `TextEdit[]`, **and pick the range-formatting model**:
  format-everything-and-filter-edits (clang-format's — simple, but keystroke latency becomes
  full-file latency) versus format-a-subtree-in-context (requires the M2 engine to start
  mid-document at an inherited indent/column — an engine constraint that must be known at M2,
  not discovered at M6). Fix the escape-hatch spelling too (`// dfmt off`/`on` for migration
  compatibility — see [the hatch table][hatches]).
- **Decide the `signature_layout.d` question**: does the new engine subsume it, and does
  `sparkles:twoslash` migrate? The repo should not carry two layout engines. (`prettyprint.d` is a
  value printer and is out of scope.)

### M1 — The spine and the verifier, before any layout code

_Borrowed from [ocamlformat][ocamlformat] and [ruff][rust-reimpl]; the ordering is deliberate — a
verifier written after a printer is a verifier written to agree with that printer's bugs._

- A lossless token+trivia stream that round-trips the input exactly.
- **Token equality modulo whitespace** as the primary check.
- **A separate DDoc check.** D has OCaml's hazard: ddoc is semantically attached, and a
  formatter that reattaches one silently changes generated documentation. Its own check, its own
  error — [ocamlformat's `moved_docstrings`][ocamlformat]. The attachment oracle is a **second
  lex with `doDocComment: true`** (M0-S3: `Token.blockComment`/`lineComment` are _not_
  populated on the trivia spine), so the compiler's own attachment rules judge the output
  rather than a reimplementation that could drift from them.
- An **idempotence harness** iterating to a fixed point with a bounded count, wired into
  `dub run :ci`.

### M2 — `Doc` IR and greedy engine

_Borrowed from [Lindig via prettier][combinators]; **start from Lindig's strict form**, never
Wadler's lazy one, which is exponential in a strict language._

- `text` / `line` / `softline` / `hardline` / `group` / `fill` / `indent` / `align` /
  `ifBreak` / `lineSuffix`, with **`fits` taking the rest of the worklist** (Lindig's `z`).
- **`conditionalGroup` is in the IR from day one, rationed in the printer.** prettier's three
  genuine additions beyond Lindig are `propagateBreaks`, `fill`, and `conditionalGroup`;
  omitting the N-way primitive is what [dart_style][dart-style]'s whole 3.0 rewrite paid for
  ("bugs that the old solver couldn't express solutions to"). Representing N-way choice in the
  IR keeps [M9](#m9--stretch-cost-search-behind-a-flag) an _interpreter swap_ instead of an IR
  rewrite; **using** it stays a last resort — prettier documents the nested-exponential hazard.
- **The width measurer is an injected parameter**, as `signature_layout.d` already does — and
  the default is **display columns** (`wcwidth`-style, East-Asian wide = 2), which
  `sparkles:base`'s terminal stack already provides. Graphemes ([sdfmt][d-landscape]) undercount
  CJK; bytes (dfmt) are simply wrong.
- `propagateBreaks` as a pre-pass ([prettier][prettier]).
- **The engine must be able to start mid-document** at an inherited (indent, column) — the M0
  range-model decision lands here as a constructor parameter, not as an M6 retrofit.
- Prove on imports, declarations and simple statements — **and run the M8 differential against
  dfmt on this subset immediately**, so a greedy-quality problem (the trigger for promoting M9)
  surfaces at M2, not after the whole-language printer exists.

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
  removed) — but **do not gate CI on it**. ruff can gate because black-compatibility _is_ its
  goal; beating dfmt's citable ceilings _lowers_ the index by design, so a "never decrease"
  gate blocks exactly the changes this project exists to make. The index is a **ratchet**: any
  movement must be named and acknowledged in the change that causes it.
- **Gate CI on the stability triad** instead, on every change: second pass differs / invalid
  output / crashes.
- Delete fixtures as they converge, so the remaining corpus is the remaining disagreement —
  this shrinking-fixture discipline is the ratchet's enforcement mechanism.

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
- **A tree-sitter substrate.** Viable ([topiary][topiary]) but now unnecessary. (The
  "second grammar" cost argument is weaker than it looks — this repo already maintains
  `tree-sitter-d` for `sparkles:syntax` regardless; the decisive arguments are fidelity to the
  compiler's own lexing and the semantic hard list, not grammar maintenance.)
- **Beating dfmt on style opinions.** The measurable goals are the citable ones: dfmt's 32-token
  search window and its silently-unsolved output.

---

## What would make this proposal wrong

Stated plainly, since M0 is a set of spikes and spikes can fail:

- **If the lexer's `whitespaceToken` path is unusable** (DMDLIB-gated at build time in a way the
  pinned fork does not enable, or lossy in practice), the spine costs more and the tree-sitter
  route returns as a serious option. (S1 tests this first.)
- **If S2 fails** — nested groups cannot be reconstructed from the token walk plus start-offset
  arrays — M3's front end becomes an AST visitor emitting a structured token stream
  ([swift-format][swift-format]'s shape). The printer still never re-walks the tree at layout
  time, but "the AST is not consulted after the oracle pass" is lost for the front end, and the
  broken-input story degrades to dfmt's (structure missing exactly when the file is malformed).
- **If the AST oracle cannot disambiguate enough** with start offsets alone, the design needs end
  positions after all — Q-b becomes load-bearing again. Note S4 already treats one instance as
  settled: the M3 do-no-harm valve needs end positions _today_, so Q-b is load-bearing for the
  valve regardless of how disambiguation turns out.
- **If greedy output is materially worse than dfmt's** — measured from M2 onward on the prove-out
  subset, not first at M8 — M9 stops being a stretch goal and becomes a requirement. Both
  existing D formatters (dfmt, sdfmt) independently chose search; the prior that D's constructs
  need it is not low, which is why M2 keeps N-way choice representable in the IR.
- **If the fork treadmill proves too expensive.** The substrate is a personally pinned fork of a
  frontend with **no library-stability promise**, and `whitespaceToken` is an internal DMDLIB
  flag. A formatter must track new language syntax promptly — users format new code the day a
  construct lands — which means rebasing that fork continuously: the exact weakness this survey
  charges [swift-format][swift-format] with, but without SwiftSyntax's versioned-library
  discipline. Mitigation to verify at M0: the formatter's hot dependency is the _lexer_, which
  churns far less than the AST; if lexer churn is also high, the tree-sitter route (whose D
  grammar this repo already maintains) regains ground.

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
[swift-format]: ./swift-format.md
[gofmt]: ./gofmt.md
