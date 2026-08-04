# `sparkles:test-runner` — Open specification issues

_Companion to [SPEC.md](./SPEC.md) and [PLAN.md](./PLAN.md). A running list
of behavioral questions that are **not yet resolved** in the normative spec.
Each entry records where it bites, the options, and any current leaning.
Resolve by folding a decision into SPEC.md, then delete the entry here (and
reference the commit). Survey-level hardware questions that do not touch the
spec's behavior stay in the research catalog's
[open questions](../../research/cpu-pmu/comparison.md#open-questions-gaps)._

_O9–O12 were surfaced on `feat/wired-json-engine` while re-engineering the
`wired` runtime bench onto the runner and validating its hardware counters
against the retired hand-rolled harness. O10 (suite provenance) and O11
(counting-pass iterations) were resolved on
`feat/test-runner-capability-seam` — `benchProvenance` +
`meta.provenance`, and `--perf-iters` + per-row `countIterations` (SPEC
§7/§8.3) — and are deleted per the lifecycle; O9 and O12 remain below with
their done-parts annotated. The
[validation cross-references](#validation-cross-references) map the
remaining findings onto work that already covers them._

## O1 — The paranoid degradation matrix is unprobed

**Where:** SPEC §9.

All hardware evidence to date was gathered at `perf_event_paranoid = −1`;
the per-level behavior at 0/1/2 (which sources survive, with which reasons)
is literature-derived. The spec currently gates "perf counting at
paranoid ≤ 2" on the literature value.

**Options:** (A) probe on a hardened host and pin the per-level degradation
normatively; (B) keep the matrix descriptive (best-effort reasons from
`errno`) and never promise per-level behavior.

**Leaning:** (A) — probe once, then normatize; the capability report (B1)
is the natural carrier.

## O2 — Switching the counting pass to the rdpmc bracket

**Where:** SPEC §6.2 (`selfMonitoring`); PLAN B2.

The measurement gate is **closed**: `rdpmc.bracketCost` (a `@benchmark` in
`rdpmc.d`, each read asserted real — not the index-0 early exit) measured,
on the Zen 4 dev box, 2.2 µs per ioctl ENABLE/DISABLE pair vs 30 ns per
rdpmc seqlock read vs 551 ns per `read(2)` — a full 7-event rdpmc bracket
(~420 ns) would be ~5× cheaper than the ioctl pair, corroborating the
literature's order-of-magnitude claim. What remains open
is **switching the counting pass**: an rdpmc bracket needs the group enabled
continuously (deltas exclude `between()` work arithmetically instead of via
DISABLE), which changes the multiplex-scaling window semantics.

**Options:** (A) switch automatically for very short bodies when
`cap_user_rdpmc` holds and the group is exact (unscaled); (B) an opt-in
flag; (C) keep the primitive unused until a consumer demonstrates bracket
cost dominating a real measurement.

**Leaning:** (A), scoped to the exact (non-`--perf-scaled`) mode where the
continuous-enable semantics are provably equivalent.

**Update:** option (C)'s condition is met — `sparkles:event-horizon`'s tier-C
benchmarks (~1.2 ns bodies) are a real measurement where the ioctl bracket
does not merely dominate but _is_ the entire reported figure (~3 270 of
3 286 instructions). See [O14](#o14--the-counting-pass-is-unbatched-so-sub-µs-bodies-read-only-the-bracket),
which also argues rdpmc alone is insufficient at that body size (30 ns still
swamps 1.2 ns ~25×) — the two fixes compose rather than compete.

## O3 — The thread-coverage contract

**Where:** SPEC §4 (protocol), §6 (backend contract).

Counter coverage is inherit-shaped: `pid:0, cpu:-1` + `inherit` covers
threads spawned after a source opens; pre-existing threads and short-lived
children are blind spots the harness does not report.

**Options:** (A) document-only (status quo, stated in SPEC §4); (B) per-TID
attach for pre-existing pools; (C) report a coverage stamp per row so
partially-covered runs are visibly marked.

**Leaning:** (C) as the near boundary — a stamp fits the provenance-badge
pattern (cache regime, M6) — with (B) as a later refinement if a real
consumer needs it.

## O5 — The cross-OS event-name vocabulary

**Where:** SPEC §5, §9; PLAN B3/B4.

No naming layer spans operating systems, so the harness owns its vocabulary.
B2 shipped the per-source-prefix shape on Linux (`raw:r<hex>`, `pfm:<name>`
— the leaning's (B), following the `sc:`/`syscalls:` precedent). Open: how
the future macOS/Windows sources join — their own prefixes (`kpep:`,
`pmcsource:`) or an abstract shared core.

**Options:** (A) abstract names (`instructions`, `cache-miss`) mapped
per-OS, failing where unmappable; (B) per-source prefixes (`raw:`, `pfm:`,
`kpep:`, `pmcsource:`) with only the generic seven shared.

**Leaning:** (B) — mirrors the shipped `sc:`/`syscalls:` precedent, keeps
resolution failures local and honest; a shared abstract core can grow later
without breaking prefixed names.

## O6 — `sparkles.quantities` convergence

**Where:** SPEC §5.3.

The units seam awaits the sibling units-of-measure work, whose unit-identity
model (open vs closed dimension basis) is deliberately unsettled. Until it
lands, `Unit.symbol` stays a label and `Mode` stays the rate stand-in.

**Options:** track the sibling spec; migration is localized to the
`scaled`/`fixed` seam by design.

**Leaning:** wait — no benchmark-side action until the quantities spec
exists.

## O8 — Apple counter-model unknowns

**Where:** SPEC §9; PLAN B3.

kpep advertises `fixed_counters: 3` on every generation while kpc's FIXED
class and Linux's driver model 2 — the identity of the third fixed counter
is unresolved (grounding ledger R18). Separately, Linux has no Apple M4 PMU
table and its 8-bit event field cannot express kpep's wider selectors.

**Options:** record and proceed — B3's floor (`proc_pid_rusage`) does not
touch kpc counters; resolve if/when a kpc backend is attempted.

**Leaning:** record only; blocks nothing in B3.

## O9 — Cross-module inlining needs `-linkonce-templates` under `-unittest`

**Where:** SPEC §2 (benchmarks are `@benchmark unittest`s); the `bench` build
type. Surfaced compiling `sparkles:wired` under the runner.

Because benchmarks are unittests, the bench binary is a `-unittest` +
`-checkaction=context` build. A benchmarked library that relies on
`-enable-cross-module-inlining` (CMI) for its hot loops cannot get it from
the `bench` build type — a build type propagates to every dependency, and
CMI culls a template-nested function in mir-ion. Scoping CMI to the one
package (a `library-inline` config) is the fix, but bare CMI then **fails to
link**: it inlines `-checkaction=context` assert bodies whose
`_d_assert_fail!(T)` instances go unemitted (`undefined reference`). The old
executable harness never hit this — it was `-release` with no context
asserts. Adding `-linkonce-templates` alongside CMI emits the templates and
links, recovering the pre-runner codegen exactly (retired-instructions/byte
parity to ±0.06%). Verified on LDC 1.41; a `-linkonce-templates` ICE was
reported on other toolchains, so this is version-sensitive.

**Status:** (A) is **done** — the recipe is documented in wired's `dub.sdl`
(`library-inline`) and in the runner's
[benchmark how-to](../../libs/test-runner/how-to/benchmark.md). (B) — a
runner-side warning — is not implementable: the runner binary cannot see a
dependency's dflags. The entry stays open tracking (C), an upstream
LDC/druntime fix so context-assert templates survive CMI without the extra
flag.

## O12 — Retired-instruction determinism not distinguished from advisory counters

**Where:** SPEC §6.3; `MetricClass { quantitative, diagnostic }` — all perf
cells are `diagnostic`.

The whole-perf-tier `diagnostic` tag flattens a distinction the bench
validation depends on: retired-instruction count (and page-faults) is the
exact, host-stable anchor, while `cycles`/IPC/cache are exact-when-fitting
but host-variable (frequency, µarch) or advisory. A consumer cannot
programmatically tell which column is the trustworthy correctness anchor.
(Wording rule from the research: say "exact/stable", not
"machine-independent" — the latter is a well-founded inference, not a quoted
theorem.)

**Status:** (B) is **done** — the anchor-vs-advisory note is in the
[benchmark how-to](../../libs/test-runner/how-to/benchmark.md)'s `--perf`
section. The entry stays open only for (A), a finer
`deterministic`/`advisory` tag on `MetricDescriptor`, if downstream tooling
ever needs to key off it programmatically.

## O13 — workload table column selection

**Where:** SPEC §5.2, §8.2; `reporting.d` `buildWorkloadTable` (M4).

The workloads table renders a **fixed summary column set** per open source
(perf: instr/cycles/ipc/pg-flt; tier-0: maj-flt/rd-bytes/wr-bytes; syscalls

- named; raw selectors), not catalog-driven columns: `WorkloadWindow` is not
  `BenchStats`, so the `--metrics` catalog machinery (whose semantics are
  per-iteration) doesn't apply directly. Consequences: a `--metrics=syscr`
  run opens tier-0 for windows but shows different tier-0 columns than asked
  for, without a warning — SPEC §5.2's "selectors are never silently dropped"
  holds only for the bench tables. Every collected total does land in
  `--bench-json`, and the docs say so.

**Options:** (A) a window-side column model over the same catalog names
(marking per-iteration-only metrics inapplicable); (B) keep the fixed
summary set but warn when a `--metrics` selector names a column outside it;
(C) status quo, documented.

**Leaning:** (B) soon (cheap, honest), (A) when a real consumer needs
window column control. (M5 and M6 confirmed the prediction that the
window column set grows — `io-stall`, then `regime`.)

## O14 — The counting pass is unbatched, so sub-µs bodies read only the bracket

**Where:** SPEC §7 (counting pass), §8.3 (`--perf-iters`);
[benchmark how-to](../../libs/test-runner/how-to/benchmark.md) `--perf`.

The **timing** pass is batched (`n = 32×4194304`: samples × iterations, one
clock read per sample). The **counting** pass is not — it brackets _each_
iteration with an ENABLE/DISABLE ioctl pair, whose cost O2 measured at
2.2 µs. For a body far below that, every perf cell is the bracket, not the
body.

Measured on `sparkles:event-horizon`'s tier-C benchmarks (`-b bench`,
Zen 4, `--perf-iters=20000`, medians of 3):

| row                         | median/iter | reported `instr/iter` |
| --------------------------- | ----------- | --------------------- |
| `loop.effect.direct`        | 1.238 ns    | 3286.4                |
| `loop.effect.veneer`        | 1.508 ns    | 3297.5                |
| `loop.effect.directLiteral` | 1.222 ns    | 3276.8                |

A ~1.2 ns body cannot retire 3 286 instructions: the floor is ≈ 3 270
(the ioctl pair — consistent with O2's 2.2 µs at this IPC), so the **signal
is ~0.3 % of the reported cell**. Two implementations differing 4× in real
instructions both render "3.3k". The failure is silent: nothing marks the
cell as floor-dominated, and
[benchmark how-to](../../libs/test-runner/how-to/benchmark.md) currently
offers retired instructions as "exact, host-stable anchors — the columns a
correctness comparison between two builds can rest on", which does not hold
in this regime.

`--perf-iters` does **not** help: it pins how many bracketed iterations run,
not the bracketing granularity. Sweeping it 1 → 10⁷ left `instr/iter` flat at
3.20k–3.28k. (Differencing two rows does cancel the common floor — that is
how the veneer question above was settled — but that is a workaround a
consumer has to know to apply, and it only works for rows measured in the
same run.)

O2's rdpmc bracket (~30 ns) shrinks the floor ~70× but does not remove the
regime: 30 ns still swamps a 1.2 ns body ~25×. The orthogonal fix is to give
the counting pass the **same batched shape the timing pass already has**.

**Options:** (A) batch the counting pass — bracket K iterations, divide
counters by K, with K auto-derived from the timing pass's per-sample
iteration count (the floor then amortizes as 1/K, independent of the bracket
primitive, and composes with O2's rdpmc rather than competing with it);
(B) calibrate the empty-bracket cost once per run and subtract it from each
cell (cheaper, but subtraction near equality is numerically poor and cannot
recover IPC); (C) keep per-iteration bracketing but **detect** the regime —
when a cell is within, say, 5× of the calibrated floor, render `—` (or an
`≈`-style label, reusing the multiplex-estimate convention) instead of a
misleading number, and say so in `--bench-json`; (D) document the limitation
and leave it to consumers.

**Leaning:** (A) as the fix, with (C) as the guard that should land
regardless — a floor-dominated cell rendering a confident number is the part
that actually misleads, and (C) is cheap next to (A). (A) needs a decision on
what a batched pass means for `between()`/per-call `benchCase` rows, which is
presumably why the pass is per-iteration today; batching is naturally
available for the `benchIter`/whole-body (batched) rows, which is exactly the
regime where the floor bites.

**Raised by:** `sparkles:event-horizon`'s bench port (this is the consumer
O2's option (C) was waiting for).

## Validation cross-references

Findings from the wired-bench validation that are covered by shipped work or
a planned milestone — recorded as acceptance evidence, not new issues:

- **LLC cache pair dropped silently** → **satisfied**: the bench header now
  discloses degraded-but-available perf modes (`--perf: kernel+user; LLC
events dropped …`), which fires on every run of the Zen 4 dev box (the NMI
  watchdog holds a PMC). The wholly-unavailable case was already named by
  B1's `CapabilityReport` notes.
- **user-only counting fallback not disclosed** → **satisfied** by the same
  disclosure line (`status()` carries the `user-space only` scope
  qualifier); the per-level paranoid matrix itself remains **O1**.
- **no raw/µarch events; exact-or-drop unlabeled** → **shipped in B2**:
  `raw:r<hex>`/`pfm:<name>` selectors, `--perf-scaled`, ≈-labeled estimates
  with the `estimatedMetrics` JSON marking (former O4, resolved).
