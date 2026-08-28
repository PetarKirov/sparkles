# `sparkles:dmd-fmt` — Testing & Decision Documentation

_**Status:** specified, not implemented · **Date:** 2026-08-25 · **Scope:** how the formatter's
behaviour is pinned by tests and published to users · **Requirement IDs:** `TST*`_

The [decision inventory][decisions] catalogues **160** formatting decisions, of which 132 are
scored Adopt/Adapt/Opt-in for D, several are configurable, and [D9][spec] adds a second tier of
opt-in rewrites on top. That is far past the size where ad-hoc unit tests hold: without a plan,
the suite becomes a pile of string literals nobody can audit for coverage, and the user-facing
documentation drifts from the implementation within one release.

This spec fixes one artifact that serves three jobs — **test fixture, rule specification, and the
published documentation page** — plus the gates that keep the three from separating. The survey
behind it is [How formatters test themselves][testing-research]; the two techniques it takes
wholesale are dart_style's multi-case fixture files and rustfmt's
`Configurations.md`-must-cover-every-option gate.

The artifact is a **markdown page with VitePress code groups**. There is no bespoke fixture syntax
and no generation step: the page a user reads _is_ the file the test runner executes. The repo
already has the infrastructure this needs — `::: code-group` blocks with `[Title]`-labelled fences
are used across the docs, `<!-- … -->` directives already carry machine-readable metadata for the
markdown example verifier, and the sidebar/staleness gates already run over `docs/`.

---

## The artifact: a page that is also a fixture

### TST1 — Fixture format: a documentation page

A fixture file is a markdown page. Each decision is a section; each section carries one or more
**cases**, and a case is a `::: code-group` whose first fence is the input and whose remaining
fences are the expectations:

````md
### Blank-line runs collapse {#p19}

<!-- fmt id=P19 -->

A run of blank lines collapses to at most `max_blank_lines` (default 2). Blank lines are never
inserted, and never removed entirely — the author's paragraphing survives, bounded.

::: code-group

```d [Before]
void a() {}




void b() {}
```

```d [After]
void a() {}


void b() {}
```

:::
````

- **`<!-- fmt … -->`** carries the machine-readable metadata and renders as nothing. Keys:
  `id=P19` (one or more decision IDs), `width=60` (print width for this case), `variants=<key>`,
  `verifier=<name>` (TST11), `expect=fail` (TST10). The precedent is the repo's existing
  `<!-- md-example-expected -->` and `<!-- md-example-skip -->` directives.
- **The first fence in the group is the input**, conventionally titled `[Before]`.
- **Every later fence is an expectation.** `[After]` means "with this section's configuration";
  a title of the form `[brace_style=allman]` means "with these keys merged over it", and a case
  with two or more such fences is a **variant case** — the reader sees one tab per option value,
  and the runner checks each.
- **Prose is free.** Everything outside the code groups is ordinary documentation, written for a
  reader rather than for the harness.

Print width deserves a note. dart_style and prettier both draw a visible column ruler in their
fixtures, which is genuinely useful and does not survive contact with a syntax-highlighted code
fence. The replacement is honesty in prose: a case whose behaviour depends on the wrap column
states it (`width=60` in the directive, "at a print width of 60" in the sentence), and the
inputs are written short enough that the reader can see the column without counting to 120.

**Validated, not just proposed.** The format above is what
[`docs/libs/dmd-fmt/reference/decisions/layout.md`](../../libs/dmd-fmt/reference/decisions/layout.md)
already uses, and a ~130-line prototype parser calling `formatText` directly runs its seven
expectations against the real formatter. Nothing in TST1 needs a markdown library, a preprocessor,
or a change to the docs build: the page renders as-is with the `::: code-group` support this tree
already uses everywhere.

**The prose above each group is the rule statement.** It is what a user reads and what a reviewer
checks the behaviour against; there is no separate test name to drift from it.

### TST2 — Decision tags and the coverage gate

Every case carries zero or more decision IDs in its `<!-- fmt id=… -->` directive, drawn from the
[inventory][decisions]. Two gates run in CI:

1. **Every decision scored Adopt, Adapt or Opt-in has at least one case.** A decision with no case
   fails the build, naming the ID — rustfmt's `does not have a configuration guide` panic, applied
   to behaviour rather than to options.
2. **Every configuration key has at least one `variants=<key>` case**, covering every value the
   key accepts — so the docs cannot document an option without showing what it does.

Decisions scored `Have`, `N/A`, `Reject` or `Oracle` are exempt, and the exemption list is data:
the gate reads the inventory's verdict column, so re-scoring a decision automatically demands a
fixture. Decisions blocked on the precedence oracle are tracked, not silently skipped.

### TST3 — Two locations, one format

Fixtures torture the implementation; documentation should not. Rather than flag cases, the
distinction is **which file a case lives in** — same syntax, same parser, same blessing path:

| Location                                          | Published | Contents                                                                         |
| ------------------------------------------------- | --------- | -------------------------------------------------------------------------------- |
| `docs/libs/dmd-fmt/reference/decisions/<area>.md` | ✅ yes    | The presentable case for each decision: plausible code, a sentence a user wants. |
| `libs/dmd-fmt/test/cases/<area>.md`               | ❌ no     | Everything hostile: pathological nesting, comment placement, degenerate input.   |

The unpublished tree is kept out of the site with a `srcExclude` entry in
`docs/.vitepress/docs-config.json`, exactly as the research grounding ledgers already are — and
because that list is also what `ci --check-docs-sidebar` reads, the exclusion is one edit, not two. Every decision needs **≥1 case anywhere**; every user-visible
decision needs **≥1 case in the published tree**.

---

## Running a case

### TST4 — The per-case pipeline

For each case, for each variant, in order — every step a separate failure naming the page, the
heading, and the line of the offending fence:

1. **Format** the input with the merged configuration; compare byte-for-byte with the expectation.
2. **Verify** the formatting with `verifyFormat` — tier-3 token equality plus the DDoc-attachment
   check for the layout tier; for a rewrite-tier case, the rewrite's own verifier (TST11) instead.
3. **Converge** — `checkConvergence`, bounded iteration to a fixed point with per-step verification.
4. **Idempotence on the golden** — `format(expected) == expected`. This is the check gofmt runs as
   a second pass, and it catches the class of bug where the engine produces a stable-looking output
   it would not itself produce.

### TST5 — Blessing

`SPARKLES_UPDATE_GOLDENS=1 dub test :dmd-fmt` rewrites the **expectation fences in place**, in the
markdown, preserving prose, directives, fence titles and group structure. The repo already uses
this environment variable for the markdown golden suite; reusing it is deliberate.

The update path never touches an input fence, never reorders or deletes a case, and never edits
prose — so a blessed diff reads as "what changed in the output", and a prose statement that the new
output contradicts stays in the diff for a reviewer to notice. That is a feature: **the rule
sentence and the golden are in the same diff hunk.**

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

Cases that are expected to fail — an unimplemented decision whose case is already written, a
convergence failure under a specific option — are marked `expect=fail` in the directive and listed
in the registry, not left as a comment. A published page never carries one: a `expect=fail` case
lives in the unpublished tree, because a documentation page must not show output the formatter
does not produce. The harness
asserts they **still** fail, and reports "…now passes, remove it from the registry" when they do
not. Prettier's `unstableTests` list, and the reason its suite cannot silently loosen.

### TST11 — Rewrite-tier verifiers

[D9][spec] requires each opt-in rewrite to ship with its own verifier. A rewrite-tier case must
therefore declare it: `verifier=literal_forms` in the case's directive selects the check TST4
step 2 runs instead of tier-3 equality. The verifier registry is part of the rewrite's implementation, and
a rewrite with no registered verifier cannot have fixtures — which is the mechanism that keeps the
D9 rule from being aspirational.

---

## Publishing the decisions

### TST12 — No generator, two gates

Because the published page _is_ the fixture, there is nothing to generate and nothing to keep in
sync. What remains is two gates, both `ci` subcommands in the shape of `--check-docs-sidebar`:

- `dub run :ci -- --check-fmt-decisions` — every decision scored Adopt/Adapt/Opt-in in the
  inventory has a case, and every published case's `id=` names a real decision (TST2). Coverage in
  both directions.
- **The runner itself is the staleness gate.** `dub test :dmd-fmt` executes the published pages;
  a documented example that stops being true fails the build. rustfmt's `Configurations.md`
  guarantee, obtained without rustfmt's markdown-scraping test, because the page is the fixture
  rather than a copy of one.

This is the whole argument for the markdown format over a bespoke one: a generated page can be
stale, and a page that is executed cannot.

### TST13 — Page shape

One page per inventory area (§A…§J), each decision an `###` section with an explicit anchor
(`{#p19}`) so `/libs/dmd-fmt/reference/decisions/expressions#p90` is a durable deep link. A
section carries the rule sentence, the option and default when the decision is configurable, a
link to the [inventory][decisions] row for provenance, and its case.

**Configurable decisions render as tabs, not as prose.** A `variants=` case becomes one tab per
option value, so the effect of `brace_style` is one click apart:

````md
<!-- fmt id=P33 variants=brace_style -->

::: code-group

```d [Before]
void f() { return; }
```

```d [brace_style=allman]
void f()
{
    return;
}
```

```d [brace_style=otbs]
void f() {
    return;
}
```

:::
````

No theme component is needed — `::: code-group` is stock VitePress and already used across this
docs tree. An index page carries the full 160-row table (ID, area, rule, verdict, option, default),
which is the map users navigate before the per-area pages.

### TST14 — What lives outside the harness

Prose, entirely. The harness owns the fences inside `::: code-group` blocks that carry an
`<!-- fmt … -->` directive; every other byte of the page — orientation, rationale, links, the
index table — is hand-written and never rewritten. A code block that is not part of a marked group
is ordinary documentation, ignored by the runner (and, since it carries no dub recipe, already
ignored by the existing markdown example verifier).

---

## Layout

```
libs/dmd-fmt/
├── src/sparkles/dmd_fmt/
│   └── cases.d                      # markdown case parser + runner + blesser (TST1, TST4, TST5)
└── test/
    ├── cases/<area>.md              # unpublished, hostile cases (TST3)
    ├── differential/*.snap          # dfmt divergences only (TST9)
    └── known-failures.txt           # the ratchet registry (TST10)
apps/ci/
└── src/fmt_decisions.d              # --check-fmt-decisions (TST12)
docs/libs/dmd-fmt/
├── index.md
└── reference/decisions/
    ├── index.md                     # the 160-row map
    └── <area>.md                    # published cases — read as docs, executed as tests
```

## Delivery

| Phase  | Contents                                                           | Gate                                             |
| ------ | ------------------------------------------------------------------ | ------------------------------------------------ |
| **P1** | TST1/TST4/TST5 — the markdown case parser, the runner, blessing    | The existing golden tests move into `.md` cases  |
| **P2** | TST2/TST3/TST12 — decision ids, both coverage gates, the two trees | Every shipped decision has a case                |
| **P3** | TST13 — the published area pages and the index                     | The decision pages ship with the docs site       |
| **P4** | TST6/TST7 — perturbation oracle and robustness inputs              | Clean over the whole corpus                      |
| **P5** | TST9/TST10 — differential snapshots, the known-failure registry    | The similarity index gets a reviewable companion |
| **P6** | TST11 — rewrite verifier registry                                  | Lands with the first opt-in rewrite (`P154`)     |

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
