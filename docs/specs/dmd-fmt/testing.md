# `sparkles:dmd-fmt` — Testing & Decision Documentation

_**Status:** specified, not implemented · **Date:** 2026-08-25 · **Scope:** how the formatter's
behaviour is pinned by tests and published to users · **Requirement IDs:** `TST*`_

The [decision inventory][decisions] catalogues **160** formatting decisions, of which 132 are
scored Adopt/Adapt/Opt-in for D, several are configurable, and [D9][spec] adds a second tier of
opt-in rewrites on top. That is far past the size where ad-hoc unit tests hold: without a plan,
the suite becomes a pile of string literals nobody can audit for coverage, and the user-facing
documentation drifts from the implementation within one release.

This spec fixes one artifact that serves three jobs — **test fixture, rule specification, and the
source of the published documentation** — plus the gates that keep the three from separating. The
survey behind it is [How formatters test themselves][testing-research]; the two techniques it
takes wholesale are dart_style's multi-case fixture files and rustfmt's
`Configurations.md`-must-cover-every-option gate.

---

## The artifact: `.cases` files

### TST1 — Fixture file format

One file per construct family, many cases per file, plain UTF-8, extension `.cases`, living under
`libs/dmd-fmt/test/cases/<area>/<family>.cases`. The format is dart_style's, with three additions
(decision tags, doc flags, variant sections):

```
### Assignment layout — E. Expression layout.
60 columns                                                  |
(indent_size 4)

>>> [P90] @doc Break the right-hand side before breaking after `=`.
auto configuration = loadConfiguration(path, defaults, overrides);
<<<
auto configuration = loadConfiguration(
    path, defaults, overrides);

>>> [P91] Break after `=` when the right-hand side is a binary chain.
auto accepted = first && second && third && fourth && fifth;
<<<
auto accepted =
    first && second && third && fourth && fifth;

>>> [P33] @doc (variants brace_style) Brace style follows the option.
void f() { return; }
<<< brace_style=allman
void f()
{
    return;
}
<<< brace_style=otbs
void f() {
    return;
}
```

- **`###`** — comment line, ignored.
- **A first line ending in `|`** sets the print width for the whole file, and makes it _visible_:
  the bar sits at the wrap column, so a reader sees where the ruler is without counting. Text
  before the bar is free-form. (dart_style and prettier both do this; it is the cheapest
  readability win available.)
- **Parenthesized lines in the header** set file-wide config keys, spelled exactly as the
  `.editorconfig`/dfmt keys the formatter honours — so a case doubles as documentation of the
  option.
- **`>>>`** opens a case: an optional `[P90]` / `[P90 P91]` decision tag list, an optional `@doc`
  flag, optional `(key value)` per-case options, then a free-text description ending the line.
  Everything until the first `<<<` is the input.
- **`<<<`** opens an expected-output section. A bare `<<<` is the only expectation. A suffixed
  `<<< brace_style=allman` labels a **variant**: the case runs once per variant, with those keys
  merged over the file's.

**The description is the rule statement.** It is what the generated documentation prints, so it is
written as a sentence about behaviour ("Break the right-hand side before breaking after `=`."),
never as a test name.

### TST2 — Decision tags and the coverage gate

Every case carries zero or more decision IDs from the [inventory][decisions]. Two gates run in CI:

1. **Every decision scored Adopt, Adapt or Opt-in has at least one case.** A decision with no case
   fails the build, naming the ID — rustfmt's `does not have a configuration guide` panic, applied
   to behaviour rather than to options.
2. **Every configuration key has at least one case with `(variants <key>)`**, covering every value
   the key accepts.

Decisions scored `Have`, `N/A`, `Reject` or `Oracle` are exempt, and the exemption list is data:
the gate reads the inventory's verdict column, so re-scoring a decision automatically demands a
fixture. Decisions blocked on the precedence oracle are tracked, not silently skipped.

### TST3 — The `@doc` flag

Fixtures torture the implementation; documentation should not. A case marked `@doc` is promised to
be _presentable_: plausible code a user might write, a description that reads as a rule, and no
deliberate ugliness. Only `@doc` cases are rendered into the published pages (TST12).

Every decision needs **≥1 case**; every user-visible decision needs **≥1 `@doc` case**. The
untagged remainder is free to be as hostile as the engine deserves.

---

## Running a case

### TST4 — The per-case pipeline

For each case, for each variant, in order — every step a separate failure with the case's file,
line and description in the message:

1. **Format** the input with the merged configuration; compare byte-for-byte with the expectation.
2. **Verify** the formatting with `verifyFormat` — tier-3 token equality plus the DDoc-attachment
   check for the layout tier; for a rewrite-tier case, the rewrite's own verifier (TST11) instead.
3. **Converge** — `checkConvergence`, bounded iteration to a fixed point with per-step verification.
4. **Idempotence on the golden** — `format(expected) == expected`. This is the check gofmt runs as
   a second pass, and it catches the class of bug where the engine produces a stable-looking output
   it would not itself produce.

### TST5 — Blessing

`SPARKLES_UPDATE_GOLDENS=1 dub test :dmd-fmt` rewrites the `<<<` sections in place, preserving
comments, descriptions, tags and header. The repo already uses this environment variable for the
markdown golden suite; reusing it is deliberate. The update path is a **rewrite of the expectation
sections only** — it never invents, reorders or deletes cases, so a blessed diff is always
reviewable as "what changed in the output".

---

## Beyond fixtures

### TST6 — The perturbation oracle

The layout tier is _defined_ to normalize horizontal whitespace, recompute indentation and collapse
blank runs. That definition is an equality oracle needing no expected file: perturb only those
dimensions and the output must be **byte-identical**.

```
perturb(s):  randomize leading indentation width and style,
             append trailing spaces to random lines,
             lengthen blank-line runs,
             swap space/tab in leading whitespace
assert:      format(perturb(s)) == format(s)     for every corpus file
```

This is the layout-preserving formatter's replacement for clang-format's `messUp`, which is
[unavailable to us][testing-research-transfer] because it destroys the author's line breaks — which
are input, not noise. Seeded and deterministic, so a failure reproduces; run over the whole corpus,
so coverage comes free of authoring cost.

### TST7 — Robustness inputs

Inputs that carry **no expected output**, only the requirement that the formatter does not crash,
converges, and passes its verifier: `messUp`-style whole-construct-on-one-line collapse, truncation
at every token boundary of a corpus file, unbalanced brackets, unterminated literals, and files
that do not parse at all (the bracket-only degraded path). Failures are recorded as crash
reproductions, never as expected output.

### TST8 — Corpus tests

Already delivered by M8 and retained: the repo's own library trees, the pinned frontend's
`expressionsem.d` (~20 kLOC), and any corpus reachable through `$SPARKLES_FLAKE_INPUT_*`. The
stability triad runs over all of them. TST6's perturbation and TST7's robustness inputs are driven
from the same corpus.

### TST9 — The dfmt differential, as disappearing snapshots

M8's similarity index (mean 0.927, tripwire floor 0.85) is a number, and a number is hard to review.
Alongside it, adopt ruff's model: for each corpus file, if dmd-fmt's output equals dfmt's, **no
artifact exists**; where they differ, a snapshot holding the input, a unified diff labelled
`dfmt`/`dmd-fmt`, and both outputs is written to `libs/dmd-fmt/test/differential/`. Convergence
then shows up in review as files _disappearing_, and every divergence is a reviewable diff instead
of a decimal place. The index stays as the ratchet; the snapshots are what a human reads.

### TST10 — The known-failure ratchet

Cases that are expected to fail — an unimplemented decision with its fixture already written, a
convergence failure under a specific option — live in a registry, not in comments. The harness
asserts they **still** fail, and reports "…now passes, remove it from the registry" when they do
not. Prettier's `unstableTests` list, and the reason its suite cannot silently loosen.

### TST11 — Rewrite-tier verifiers

[D9][spec] requires each opt-in rewrite to ship with its own verifier. A rewrite-tier case must
therefore declare it: `(verifier literal_forms)` in the case header selects the check TST4 step 2
runs instead of tier-3 equality. The verifier registry is part of the rewrite's implementation, and
a rewrite with no registered verifier cannot have fixtures — which is the mechanism that keeps the
D9 rule from being aspirational.

---

## Publishing the decisions

### TST12 — Generated documentation, with a staleness gate

`docs/libs/dmd-fmt/reference/decisions/<area>.md` — one page per inventory area (§A…§J), each
decision an anchored subsection, generated from the `@doc` cases. Generation and checking are
subcommands of the `ci` tool, reusing the case parser from the library rather than reimplementing
it:

- `dub run :ci -- --gen-fmt-docs` — regenerate the pages.
- `dub run :ci -- --check-fmt-docs` — fail if the committed pages differ from what the fixtures
  would generate. Runs in CI and as a pre-commit hook, in the same shape as `--check-docs-sidebar`.

Because the pages are generated from cases that are themselves executed (TST4), a documented
example cannot be wrong: it is the formatter's actual output for the input shown. This is
rustfmt's `Configurations.md` guarantee obtained by generation instead of by parsing prose.

### TST13 — Page layout

Each decision renders as:

- **Left column** — the ID, the rule sentence (the case description), the option and its default
  when the decision is configurable, and a link to the [inventory][decisions] row for provenance.
- **Right column** — the example: input above output, or side by side on a wide viewport, with the
  print-width ruler drawn from the case's header so the reader sees _why_ it wrapped.
- **Variants as tabs** — a case with `(variants brace_style)` renders as a VitePress code group,
  one tab per value (`allman`, `otbs`, …), so the effect of an option is one click apart rather
  than one page apart.

The two-column shape is a small theme component registered like the repo's existing ones
(`TextCellViz`, `TablePlayground`), plus a code group per variant. An index page carries the full
160-row table — ID, area, rule, verdict, option, default — sortable and searchable, which is the
map users navigate before the per-area pages.

### TST14 — What the docs do _not_ generate

Prose. The area pages open with hand-written orientation (what this family of decisions is about,
which option governs it) and the generated blocks follow. The generator owns only the blocks
between its markers, so hand-written text survives regeneration — the same contract the repo's
other generated docs use.

---

## Layout

```
libs/dmd-fmt/
├── src/sparkles/dmd_fmt/
│   └── cases.d                  # .cases parser + runner + blesser (TST1, TST4, TST5)
└── test/
    ├── cases/<area>/*.cases     # the fixtures (TST1–TST3)
    ├── differential/*.snap      # dfmt divergences only (TST9)
    └── known-failures.txt       # the ratchet registry (TST10)
apps/ci/
└── src/fmt_docs.d               # --gen-fmt-docs / --check-fmt-docs (TST12)
docs/libs/dmd-fmt/
├── index.md
└── reference/decisions/*.md     # generated (TST12, TST13)
```

## Delivery

| Phase  | Contents                                                          | Gate                                             |
| ------ | ----------------------------------------------------------------- | ------------------------------------------------ |
| **P1** | TST1/TST4/TST5 — the parser, the runner, blessing                 | The existing golden tests migrate to `.cases`    |
| **P2** | TST2/TST3 — decision tags, the coverage gate, `@doc`              | Every shipped decision has a case                |
| **P3** | TST12/TST13 — generation, `--check-fmt-docs`, the theme component | The decision pages publish                       |
| **P4** | TST6/TST7 — perturbation oracle and robustness inputs             | Clean over the whole corpus                      |
| **P5** | TST9/TST10 — differential snapshots, the known-failure registry   | The similarity index gets a reviewable companion |
| **P6** | TST11 — rewrite verifier registry                                 | Lands with the first opt-in rewrite (`P154`)     |

P1–P3 are the sequence that matters: they are what turn 160 catalogued decisions into 160 executed,
published, non-rotting statements about behaviour. P4–P6 are depth.

## Traceability

- Research: [How formatters test themselves][testing-research] ·
  [Verification][verification] · [The decision inventory][decisions]
- Spec: [the decision record][spec] (`D8` verifier, `D9` two-tier scope) ·
  [the codemod roadmap][codemods]
- Code: `libs/dmd-fmt/src/sparkles/dmd_fmt/verify.d` (the checks TST4 composes),
  `differential.d` (TST8/TST9)

[decisions]: ../../research/code-formatting/prettier-decisions.md
[testing-research]: ../../research/code-formatting/testing-methodology.md
[testing-research-transfer]: ../../research/code-formatting/testing-methodology.md#what-does-not-transfer
[verification]: ../../research/code-formatting/verification.md
[spec]: ./index.md
[codemods]: ./codemods.md
