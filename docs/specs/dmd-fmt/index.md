# `sparkles:dmd-fmt` — M0 Decision Record

_**Status:** M0–M8 delivered (v1 formatter; M9 deferred by its own gate) ·
**Date:** 2026-08-17, revised 2026-08-23 (D9) · **Scope:** the D formatter on the DMD substrate
(`libs/dmd-fmt`), per
[the research proposal](../../research/code-formatting/dmd-fmt-proposal.md)._

This is the M0 deliverable the proposal calls for: a decision record backed by
the four spikes, written before any engine code exists. The full traceable
feature spec (`FMT*` requirement IDs in the style of
[`docs/specs/dmd-lsp/`](../dmd-lsp/index.md)) arrives with M1; this page fixes
the decisions M1–M9 build on and records the experimental evidence for each.

Everything below is backed by code on this branch: the spike modules
(`libs/dmd-fmt/src/sparkles/dmd_fmt/{spine,oracle,groups,loc_inventory,bench}.d`)
pin every claimed fact as a test, so a fork rebase that invalidates a fact
fails the suite rather than this page silently rotting.

## Decisions

### D1 — Architecture: token spine, AST as a start-offset oracle

Format the token stream lexed by DMD's own lexer in its DMDLIB trivia
configuration (`commentToken: true, whitespaceToken: true`); consult the AST
only through **sorted arrays of start offsets** built in one parse-only pass
(dfmt's `ASTInformation` shape), queried by binary search. The AST is never
walked at layout time.

The one architecturally novel step — building a **nested** `Doc`-style group
tree from that flat substrate, which no surveyed formatter does — was proven
by S2 (below). The swift-format-shaped fallback (an AST visitor emitting a
structured token stream) named in the proposal's failure modes is **not
needed**.

### D2 — Output contract: `TextEdit[]`; range = format-all, filter edits

The formatter emits edits, never a document (the clang-format/Roslyn
convergence). The v1 range-formatting model is **format the whole file and
keep only the edits intersecting the requested range** — affordable because
the full pipeline runs at ~5 ms per 2 kLOC (D3), an order of magnitude inside
the budget, and simple in exactly the way clang-format's
`AffectedRangeManager` is. The M2 engine must nevertheless accept a
mid-document starting context (indent, column) as a constructor parameter, so
the subtree-in-context model stays reachable without an IR change if
whole-file latency ever stops holding.

### D3 — Latency budget: p95 < 30 ms per 2 kLOC, full pipeline

Adopted as proposed, and it governs the **full** path (lex + parse + oracle +
groups), not a lexer-only fast path. Measured (`bench.d`, LDC, this machine)
on a synthetic 2 kLOC module and on the pinned frontend's own
`expressionsem.d` — at ~20 kLOC one of the largest real-world D files in
existence, now a standing corpus member (read from
`$SPARKLES_FLAKE_INPUT_DMD_SRC`; round-trip and group-well-formedness tests
cover it too). The optimized build is
`unittest-checked` (optimize + inline with asserts alive — the repo's
`checked` philosophy; never `-release`):

| Stage (median)                     | 2 kLOC, debug | 2 kLOC, optimized | 20 kLOC real, optimized |
| ---------------------------------- | ------------- | ----------------- | ----------------------- |
| spine lex (trivia config)          | 1.8 ms        | 1.1 ms            | 10.2 ms                 |
| parse + oracle facts               | 1.7 ms        | 0.87 ms           | 9.6 ms                  |
| full pipeline (lex + parse + tree) | 5.0 ms        | 2.7 ms            | **25.7 ms** (max 31.6)  |

The optimized 2 kLOC pipeline holds the budget with a ~10× margin, and the
20 kLOC outlier — whole file, not per-2 kLOC — still lands at ~26 ms: even
the extreme case of D2's format-everything range model is interactive. Two
readings worth recording: the spine lex is now the largest single stage on
big files (so D4's second doc-lex, which runs on the verify path, roughly
doubles the lexing share there), and per-2 kLOC cost stays flat (~2.6 ms)
from 2 to 20 kLOC — the pipeline scales linearly as designed.

That margin retires the tiered fast-path question for now:
no lexer-only keystroke tier is designed in v1. The decision is
**measurement-contingent** — the benchmarks stay in the suite, and if real
files or the M2 printer push p95 near the budget, the reserved tier
(Roslyn-style pairwise whitespace adjustment on the lexer path) is the named
fallback.

### D4 — Lexing configuration: trivia lex + doc-lex, one lock, owned globals

Verified fork fact: `commentToken` returns before the `doDocComment` branch
runs, so **the trivia spine and DDoc attachment are two lexer configurations,
not one**. The formatter therefore double-lexes: the trivia lex is the
fidelity substrate; a second `doDocComment: true` lex is the DDoc-attachment
oracle (M1's `moved_docstrings`-style check judges output with the compiler's
own attachment rules, not a reimplementation). S3's correspondence check
proves the two streams agree on every non-trivia token's kind and offset.

The library owns DMD's global-state hazards so callers cannot hold them
wrong: `Id.initialize()` (without it `__EOF__` and `#line` lex differently),
`global.params.useUnitTests` (without it unittest bodies are token blobs with
no oracle facts), and a process-wide lock around every lexer/parser touch
(DMD's identifier table is not thread-safe; concurrent lexing segfaults). An
LSP built on this inherits the serialization constraint until DMD grows a
thread-safe story upstream.

### D5 — Escape hatch: `// dfmt off` / `// dfmt on`, verbatim

dfmt's line-range spelling is honored as-is for migration; no new spelling is
introduced in v1. The hatch is one instance of the single suppression
mechanism planned for M6 (ranges, verbatim regions, inactive arms — Roslyn's
`SuppressOperation` insight).

**The markers delimit the region; they are not inside it.** Both are laid out
as the ordinary comments they are, at the structural indent, while everything
between them is emitted byte-for-byte with its own indentation and alignment.
A `// dfmt on` left at the depth the suppressed block happened to use is a
comment about the code around it, and reads as one only where that code is —
so it moves, and only it moves.

### D6 — Engine commitments for M2

Restating the proposal's M2 as fixed decisions: Lindig's strict greedy form;
`conditionalGroup` present in the IR from day one (rationed in the printer)
so M9's cost search is an interpreter swap, not an IR rewrite; the width
measurer injected with a **display-column** default (East-Asian wide = 2);
`propagateBreaks` as a pre-pass; mid-document start (D2); and the dfmt
differential runs from the M2 prove-out subset onward, so a greedy-quality
problem surfaces before the whole-language printer exists.

### D7 — One layout engine: `signature_layout.d` retires after M2 parity

The repo will not carry two layout engines. `signature_layout.d`'s staged
breaking (SIG1–SIG6) must be expressible in the M2 engine; once the twoslash
hover rendering reproduces on it, `sparkles:twoslash` migrates and
`signature_layout.d` is deleted. Until parity is demonstrated, both exist and
neither grows features. (`prettyprint.d` is a value printer and is out of
scope permanently.)

### D8 — Verifier before printer (M1 ordering)

Unchanged from the proposal, and **delivered**: `verify.d` is the M1
verifier, built with no printer in existence. `verifyFormat` runs tier 3
(token equality modulo whitespace over the spine — prefix and `__EOF__`
tail byte-verbatim, comments and directives text-exact per v1 policy) and
the separate DDoc-attachment check (doc-lex both texts, compare the
compiler's own attachment: ordinal, preceding-vs-trailing slot, text —
which catches the whitespace-only trailing-`///` reattachment hazard tier 3
cannot see). `checkConvergence` is the idempotence harness: bounded
iteration to a fixed point with per-step verification, ocamlformat's
`max-iters` discipline. The `dub run :ci` sweep wires in with M5's
`--check`, when a formatter exists to drive it.

### D9 — Scope: two tiers; layout always on, rewrites opt-in

**Superseding the v1 posture that no token is ever added or removed.** That posture was a
verification convenience, not a goal, and stating it as scope understated what this formatter is
for. The scope is two tiers:

**Tier 1 — layout.** Reformats without touching the token stream: author's breaks preserved,
indentation recomputed structurally, horizontal whitespace normalized, blank runs collapsed. Always
on, and the only tier the v1 defaults exercise beyond the one exception below. It is verified by
D8's tier-3 token equality plus the DDoc-attachment check, which is exactly why it can be on
unconditionally.

**Tier 2 — rewrites.** May add, remove, or respell tokens. One member is **on by default**:

- **Trailing commas are inserted** when a list breaks one-element-per-line, and elided when it is
  flat (prettier's `ifBreak(",")`, `trailingComma: all`). This is enabling rather than cosmetic —
  without it a broken signature or call has no comma after its final element, and the magic
  trailing comma M4 already _reads_ could only ever be written by hand.

Every other rewrite is **opt-in**, off unless the project's configuration asks for it. The catalog,
with each rule's hazards, is [the prettier decision inventory][decisions] §F and §J; the families
are: import grouping and sorting, declaration ordering and test adjacency, parenthesis
normalization (both removing redundant pairs and adding clarifying ones), string-literal form
selection (`` ` ` `` / `q"…"` / `q{…}` to avoid escapes), attribute ordering, the syntactic
modernizations (`alias X = Y;`, `=>` bodies, DIP1009 expression contracts), DDoc reflow, and
DStyle's spacing rules.

**Three consequences, and they are the reason this is a decision rather than a wish:**

1. **Tier-3 equality cannot verify tier 2 — by construction.** Token equality modulo whitespace is
   precisely what a rewrite breaks. So **each opt-in rewrite ships with its own verifier or it does
   not ship**, and rules are ordered by how cheap that verifier is: literal-form selection is total
   (decode both spellings, compare code units); the syntactic modernizations are local and
   mechanical; import sorting needs a scope-boundary check; parenthesis and spacing rules need
   precedence; declaration reordering needs to prove nothing in the module reflects over
   declaration order. `checkConvergence` (D8) continues to apply to every tier, unchanged.
2. **The M8 differential measures tier 1 only.** The stability triad and the dfmt similarity
   ratchet run with rewrites off, so the 0.927 mean and the 0.85 tripwire floor stay comparable
   across releases and are never moved by enabling an option.
3. **Two standing prohibitions.** No rewrite reorders **aggregate fields** (it changes `.offsetof`,
   the ABI, and every `align`/union assumption); and no reordering rule runs in a module that
   mentions `__traits(allMembers)`, `__traits(derivedMembers)` or `.tupleof`, because D reflects
   over declaration order and a string mixin can bake it into generated code.

**Where the scope stops.** A rewrite belongs to the formatter only when a _syntactic_ argument
establishes its safety. Transformations whose safety needs resolved types — `format("%s %s", a, b)`
→ `i"$(a) $(b)"` is the canonical one — are **codemods**, a distinct tool with its own roadmap
([codemods][codemods]) built on this formatter plus `sparkles:dmd-lsp`. They run _through_ the
formatter, never instead of it, and are never part of `dmd-fmt --check`.

How every decision here gets a fixture, a coverage gate and a generated documentation page is
[the testing spec][testing].

Two tier-1 decisions change with this, both previously recorded as v1 limitations:
**brace style becomes configurable** — Allman by default per [DStyle][dstyle], K&R available as
dfmt has it, and a braceless `if (x) foo();` preserved as written, never expanded and never
brace-injected — and **DStyle's spacing rules become the target** rather than "no opinion on
`a+b`". The latter is gated on unary-versus-binary disambiguation, which D1 declined to solve at
token level; it is the same prerequisite as operator flattening and parenthesis normalization, so
the three are one investment, not three.

### D10 — Orphaned separators and closers rejoin

An amendment to the v1 layout policy, which is otherwise "a newline between
tokens stays a newline". Three shapes are exempt, because the break in them
carries no information to preserve:

- **A `;` or `,` that starts a line.** Both terminate what precedes them, so a
  break in front of one is never information: D writes the comma at the end of
  the element, not at the start of the next. The separator moves up — and the
  break moves with it, so a list written one-per-line stays one-per-line and
  only the commas change ends. This normalizes leading-comma style rather than
  preserving it, which is the one place D10 overrules a layout somebody could
  have chosen: the comma's position is not a matter of taste in D.
- **A closing `)` or `]` under contents that never broke.** `[1, 2, 3\n]`
  becomes `[1, 2, 3]`. When the contents _do_ break, the closer on its own line
  is the exploded shape and the point of it, so it stays.
- **A closing `}` of an expression brace**, on the same terms — a struct
  initializer is a list like any other. A statement block's `}` is never an
  orphan — a block spread over more than one line gets its closer on a line of
  its own, `{ g(); }` on one line stays there — and the token before the brace
  is what separates the two: `=`, `,`, `(`, `[`, `return` and `=>` introduce a
  value; anything else opens a block.

Nothing here adds or removes a token, so this is tier 1, not D9's rewrite
tier. The v1 policy preserves breaks because it cannot tell which are
meaningful; these are the shapes where that doubt does not apply, and dfmt
already joins all of them.

The exemption list is deliberately closed, and the closer/brace entries are
the conservative ones: they touch only breaks that cannot have been chosen,
because the contents beside them did not break either. The separator entry is
the deliberate exception to that conservatism.

Note what stays untouched. `q{ … }` and every other multi-token literal is one
spine entry, emitted byte-for-byte — interior spacing included. What rejoins is
the `;` after the closing brace, not anything inside it.

### D11 — Horizontal adjacency is the author's

Runs of horizontal whitespace collapse to one space, and **zero stays zero**.
The formatter has no opinion on `a+b` versus `a + b`, and none on `{ x }`
versus `{x}` — a policy that reads as timidity until you notice what it
protects.

D writes idioms in the gaps. `{{ … }}` gives a `static foreach` body its own
scope, and the two braces touch; padding them to `{ { … } }` turns a
recognized shape into something that reads like a typo. The same argument
covers author-aligned table literals, which D9 already preserves, and it is
why the alignment question (`P158`) is an option rather than a default.

The rule is not "preserve whitespace" — runs do collapse, and indentation is
recomputed outright. It is narrower and more useful than that: **the formatter
never inserts a space the author did not write**, and never removes the last
one they did.

### D12 — Header chains, and the one-line idioms D is built on

D's grammar makes `switch (x) with (E) { … }` a `switch` whose body is a
`with` whose body is the block. A formatter that mechanically indents "clause
header ⇒ body one level deeper" therefore produces

```d
switch (x)
    with (E)
    {
        case a:
    }
```

— wrong three times over: the braces read as the `with`'s rather than the
`switch`'s, the labels gain a phantom level, and the idiom's entire point (a
one-line header so `case` labels drop the enum prefix) is gone.

**What real D does.** A survey of ~2,000 files from `dlang/dmd`,
`dlang/phobos`, `ldc`, `arsd`, `mir`, `dlang-community/*`, `vibe.d` and others
— ~460 `with` statements — found the joined header is not a stylistic
flourish but the norm:

| Shape                                              | Sightings |
| -------------------------------------------------- | --------: |
| `switch (e) with (E)` / `final switch …`, one line |        60 |
| `with (E) switch (e)` — the reverse order          |        45 |
| `with (a) with (b)`, one line                      |        39 |
| `foreach (…) with (x)` / `if (…) with (x)`         |        11 |
| the same headers split across lines                |     **3** |

The reverse order is more common than the forward one inside dmd, druntime and
mir, so any rule for one must be written for both. Nesting depth ≥ 3 on one
line was never observed.

**The decisions.** The author's-breaks policy already keeps a one-line header
on one line, which is what those 155 sites need; v1 adds nothing for them and
must not. What needed deciding is the rare split form, and the three observed
instances agree with each other: **sibling headers sit at equal indent with a
single brace below**, never staircased.

So: **sibling `with`s over one block share a level** and the brace sits with
them. Every other chain staircases, one level per header, because there the
inner header really is the outer one's body — `if (c)` over a
`while (…) { … }` is a nesting and must read as one.

The narrow scope is deliberate, and was arrived at by measurement rather than
taste: the first cut flattened every chain ending in a block, and formatting
`libs/source-view/.../markdown.d` went _up_ by 26 lines because real code
nests `if` over `while` and wants the indent. The evidence only ever covered
`with` over `with`, so that is all the rule covers.

## Spike results

| Spike                                | Result         | Where                                      |
| ------------------------------------ | -------------- | ------------------------------------------ |
| S1 — spine round-trip                | ✅ proven      | `spine.d` (+ corpus leg)                   |
| S2 — nested-group reconstruction     | ✅ proven      | `oracle.d` + `groups.d` (+ corpus)         |
| S3 — lexing configuration            | ✅ decided     | `spine.d` S3 tests → D4                    |
| S4 — end-recoverability + loc survey | ✅ inventoried | `loc_inventory.d`, granularity/bench tests |

**S1.** The trivia lex reconstructs input byte-for-byte, with the prefix
(BOM), directive gaps (`#line` — consumed tokenlessly, newline included —
and the constructor-consumed shebang line) and the `__EOF__` tail all
explicit, so nothing is silently lost. Along the way S1 forced two fork fixes
(both upstreamable, tracked in the fork's [PLAN-UPSTREAMING.md][plan]): the
DMDLIB scanner desync on U+2028/U+2029-terminated `//` comments, and
`dmd:lexer` not linking standalone. The lexer-only dependency for the spine —
the fork-treadmill mitigation — is now real.

**S2.** A correctly nested group tree for a function declaration with
template constraints and `in`/`out` contracts builds from three ingredients:
bracket matching, oracle start-offset markers, and bounded
keyword-to-matching-closer lookahead. The degraded path (empty oracle →
bracket-only tree) covers unparseable input. A corpus well-formedness check
over three library trees (>100 declarations) guards the builder.

**S3.** `commentToken` suppresses DDoc attachment by construction → the
double-lex design of D4, with offset correspondence proven on the corpus.

**S4.** The tables below, plus: unittest bodies require
`global.params.useUnitTests` to be parsed at all (now owned by the oracle),
and the latency numbers of D3.

## The S4 inventory

### Hard-list constructs (Q-e) — how each end is recovered

| Construct                           | Spine representation             | Oracle marker                                   | End recovery                                  |
| ----------------------------------- | -------------------------------- | ----------------------------------------------- | --------------------------------------------- |
| `q{ … }` token string               | **one entry** (`string_`)        | none                                            | the entry span — verbatim by construction     |
| `q"EOS…EOS"`, `q"(…)"`              | one entry                        | none                                            | entry span                                    |
| `x"…"` hex string                   | one entry                        | none                                            | entry span                                    |
| `i"…"`, `iq{…}` interpolated        | one entry (`interpolated`)       | none                                            | entry span                                    |
| nested `/+ … +/`                    | one comment entry                | none                                            | entry span                                    |
| DDoc comments                       | comment entries (attachment: D4) | doc-lex                                         | entry span                                    |
| `#line …`                           | explicit **directive** entry     | none                                            | entry span (lexer consumes it tokenlessly)    |
| `#!` shebang                        | directive entry                  | none                                            | entry span                                    |
| `__EOF__` + trailing bytes          | explicit tail span               | none                                            | tail span                                     |
| `asm { … }`                         | ordinary tokens                  | none — `TOK.asm_` is self-identifying           | brace matching from the keyword               |
| `version` / `static if` (both arms) | ordinary tokens                  | keyword-anchored node loc; both arms parse      | paren + brace/statement span from the keyword |
| `is(…)`, `__traits(…)`              | ordinary tokens                  | keyword-anchored expression loc                 | paren matching from the keyword               |
| UDAs / attribute clusters           | ordinary tokens                  | **none available** (`Loc.initial`)              | `@` token + token-class run / paren matching  |
| contracts + constraints             | ordinary tokens                  | keyword- or in-span-anchored (see below)        | S2's bounded lookahead                        |
| `extern (C)` / `extern (C++, ns)`   | ordinary tokens                  | keyword-anchored (`LinkDeclaration` / `Nspace`) | paren + brace matching                        |
| `mixin` (decl / stmt / template)    | ordinary tokens                  | keyword-anchored                                | paren matching / `;`                          |
| `mixin("…")` body text              | inside one string entry          | n/a — never reformatted (identity)              | entry span                                    |

Two classes emerge, and both are cheap: **fidelity-layer constructs** are
single spine entries whose end is their own span, and **token-recoverable
constructs** get their extent by bracket matching from a keyword the oracle
(or the token kind itself) identifies. Nothing surveyed needs stored end
positions, which keeps Q-b retired for the whole hard list — the M3
do-no-harm valve's verbatim slice is always a token-span slice.

### Node-kind loc anchors (parse-time, pinned in `loc_inventory.d`)

| Node kind                                   | Anchor                                                        |
| ------------------------------------------- | ------------------------------------------------------------- |
| `FuncDeclaration`, aggregates, `alias`, var | declared **identifier** (adopt preceding tokens)              |
| eponymous `TemplateDeclaration` wrapper     | **`Loc.initial`** — use the member function's loc             |
| template `constraint`                       | top expression's operator (inside the parens)                 |
| contracts (`frequires`/`fensures`)          | expression forms: the keyword; block forms: inside the braces |
| `fbody`                                     | the body's `{` — distinguishes block contracts                |
| `version`/`static if` (decl + stmt)         | the keyword; condition at the version identifier              |
| `LinkDeclaration`, `Nspace`                 | `extern`                                                      |
| `invariant`, `unittest`, `mixin` forms      | the keyword                                                   |
| `CompoundAsmStatement`                      | `asm` (per-instruction locs unusable — unneeded)              |
| `IsExp`, `TraitsExp`                        | `is` / `__traits`                                             |
| `UserAttributeDeclaration`                  | **invalid** — recognize UDAs from the `@` token               |

## Milestone delivery (M1–M8)

All eight milestones shipped on this branch, each guarded by the M1
verifier. What shipped is D9's **tier 1** in full, and none of tier 2: the
style policy stated in `printer.d`'s module doc is
**author's-breaks-preserved with structural reindentation** (the paradigm
gofmt proves out), chosen because it is verifiable today and needs no
unary-vs-binary token disambiguation. D9 keeps that as the always-on tier and
adds the rewrite tier around it; nothing below is invalidated by the scope
revision.

| Milestone                | Delivered as                                                                                                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M1 verifier              | `verify.d` — tier-3 token equality, the separate DDoc-attachment check (double-lex), bounded idempotence harness                                                              |
| M2 `Doc` IR + engine     | `doc.d` — Lindig's strict worklist with `fits` over the rest of the worklist, `conditionalGroup` in the IR, injected display-column measurer, mid-document start, lazy indent |
| M3 printer + valve       | `printer.d` — spine+group walk emitting `Doc`; verbatim by default (`dfmt off/on`, `asm`, directives, tail, multi-line literals/comments); broken input never invents tokens  |
| M4 author signals        | blank-run collapse, magic trailing comma (read, never written), author-aligned comments and table literals preserved verbatim                                                 |
| M5 edits                 | `edits.d` — minimal line edits via `sparkles:diff`, `--check` in the `dmd-fmt` CLI (dub config `cli`)                                                                         |
| M6 range/cursor/suppress | `formatRange` (format-all/filter per D2), `mapCursor`, the single suppression mechanism; on-type stays an LSP-server concern built from these primitives                      |
| M7 configuration         | `.editorconfig` discovery honoring dfmt's keys; unimplemented `dfmt_*` keys ignored (documented migration posture)                                                            |
| M8 differential          | `differential.d` — the stability triad gates over the corpus (repo trees + `expressionsem.d`); the similarity index is a ratchet (measured mean 0.927; tripwire floor 0.85)   |

**M9 stays deferred by its own gate**: the proposal promotes cost search
only if greedy output proves materially worse than dfmt on the M8 corpus —
a comparison the harness runs whenever a `dfmt` binary is present. The IR
already carries N-way choice, so promotion is an interpreter swap.

Known limitations of what has **shipped**, as distinct from what is in scope
(D9 revises three of these from "deliberate" to "scheduled"): no opinionated
spacing between tokens —
adjacency is preserved, so `a+b` vs `a + b` is still the author's choice
(scheduled, gated on the precedence oracle); no brace-style option (scheduled,
Allman default); no comment reflow (scheduled as opt-in DDoc reflow); no
alignment engine — existing alignment is preserved, never created, which D9
notes is in tension with DStyle's one-space field rule and is resolved by
option, not by default.

**Retired:** "one continuation level where authors nest several". A break after
a clause header (`if (…)`, `foreach (…)`, a bare `else`) now opens a level and
recurses, so nested braceless bodies step once per clause; every other break
keeps the single-level rule, because each of its lines is the same expression
continuing. The distinction is a token-class one — the keyword before a `(`
separates `if (c)` from `foo(c)` — so it needed no oracle.

## Risks: retired and open

**Retired by M0:** the token-spine × `Doc`-IR seam (S2); DDoc-attachment
availability (S3 → double-lex); end positions gating the verbatim valve (S4:
token-recoverable throughout); lexer-only linking (fork packaging fix);
whole-file latency (D3's margin); the LS/PS fidelity bug (fixed in the fork,
regression-pinned here).

**Still open, by design:** greedy output quality versus dfmt — the trigger
for promoting M9 — measured from M2 onward per D6; the fork treadmill —
mitigated, not gone: the pin-bump procedure is exercised and the spine's hot
dependency is lexer-only, but every language-version chase still rebases the
fork (upstreaming the fixes, tracked in [PLAN-UPSTREAMING.md][plan], is the
real reduction and is scheduled after this branch ships).

## Traceability

- Research: [the proposal](../../research/code-formatting/dmd-fmt-proposal.md) ·
  [the substrate baseline](../../research/code-formatting/dmd-lsp-baseline.md)
  (Q-a … Q-i, the hard list) ·
  [the survey](../../research/code-formatting/index.md) ·
  [the prettier decision inventory][decisions] (160 scored rules — D9's
  tier-2 catalog and each rule's verifier)
- Code: `libs/dmd-fmt/src/sparkles/dmd_fmt/` — `spine.d` (S1/S3),
  `oracle.d` + `groups.d` (S2), `loc_inventory.d` (S4), `bench.d` (D3)
- Consumers: hue's [format preview](../hue/format-preview.md) (`FPR2`/`FPR7`)
  drives `formatText`/`configFor` interactively from a draggable column ruler
- Fork: [PLAN-UPSTREAMING.md][plan] on `dmdserver-dub` tracks the
  upstreamable fixes and library-quality findings this work produced

[decisions]: ../../research/code-formatting/prettier-decisions.md
[codemods]: ./codemods.md
[testing]: ./testing.md
[dstyle]: ../../guidelines/dstyle.md
[plan]: https://github.com/PetarKirov/dmd/blob/c562711dbd4685c4e4f7bd5ff46e1a306c932259/PLAN-UPSTREAMING.md
