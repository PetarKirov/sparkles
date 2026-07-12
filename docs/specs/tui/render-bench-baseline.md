# `sparkles:tui` — render-core benchmark baseline

**Status:** living baseline (preliminary — foreign calibration pending) ·
**Date:** 2026-07-12 · **Scope:** the rendering-core decision, spec
[§3.1](./index.md#31-rendering-core-line-diff-vs-2-d-cell-grid).

The evidence for choosing the `sparkles:tui` rendering core by measurement. Numbers
from the harness at `libs/tui/bench/render` (see its `README.md`); the raw snapshot
is under `libs/tui/bench/render/results/`. This is the D-internal comparison
(M1–M2); cross-language calibration (M3) is the remaining step before the decision
is final — see [What's next](#whats-next).

## Environment

|             |                                                                                                                                  |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------- |
| CPU         | AMD Ryzen 9 7940HX (Zen 4)                                                                                                       |
| D toolchain | LDC, front-end 2.111, `-mcpu=native` (`bench` build type)                                                                        |
| Scene       | full-screen ops dashboard, 120×40 (also run 80×24)                                                                               |
| Scenario    | 300 frames, deterministic, per profile                                                                                           |
| Correctness | every renderer reconstructs the target grid every frame via the `libghostty-vt` oracle, on all five profiles, before being timed |

## Method

Each renderer replays an identical scripted scenario into a reused in-memory byte
buffer; one timed iteration is a whole scenario (a diffing renderer's per-frame
cost is inter-frame-dependent). Per-scenario setup is untimed, so the timed body is
allocation-free in steady state. The candidates:

- **`cell_grid`** — retained 2-D cell grid, per-cell diff, changed cells emitted as
  cursor-positioned runs (Ratatui / libvaxis / Notcurses lineage).
- **`line_diff`** — double-buffered styled byte-lines, whole changed lines
  re-emitted (Bubble Tea lineage).
- **`line_diff_lazy`** — `line_diff`'s whole-line emission but `cell_grid`'s
  cell-compare change detection (the M2 sensitivity variant).
- **`reference_fullpaint`** — full repaint every frame (ground truth / "no diffing"
  baseline).

## Headline: instructions and bytes (120×40, `--perf`)

Instructions per scenario (300 frames; the architecture-invariant view — IPC is
3.6–4.1 across the board, so gaps are work, not scheduling) and bytes per frame
(the terminal's input):

| renderer         | sparse instr | mixed instr | churn instr | bytes/frame sparse→churn |
| ---------------- | -----------: | ----------: | ----------: | ------------------------ |
| **`cell_grid`**  |         294M |    **316M** |    **349M** | **277 → 3.9k**           |
| `line_diff_lazy` |     **275M** |        368M |        460M | 1.0k → 7.6k              |
| `line_diff`      |         455M |        457M |        460M | 1.0k → 7.6k              |
| `reference`      |         457M |        457M |        458M | 7.8k → 7.8k              |

Throughput tracks instructions: `cell_grid` runs at ≈18–21k frame/s, the
whole-line renderers at ≈11–12k, across profiles.

## Findings

1. **`line_diff` costs the same CPU as a full repaint.** It re-serializes _every_
   row each frame just to compare it, so line-level diffing saves output _bytes_ but
   not _instructions_ (455–460M ≈ the reference's 457M on every profile).

2. **The CPU deficit is fixable for sparse workloads, not churn.**
   `line_diff_lazy` (cell-compare rows, serialize only changed ones) drops sparse to
   275M — beating even `cell_grid` — but on `churn`, where nearly every row changes,
   it reverts to full-repaint cost (460M). It is a workload-shape-sensitive fix.

3. **`cell_grid` is the most consistent on CPU** — best on mixed/churn, within noise
   of the lazy variant on sparse — because per-cell diffing never does more than the
   changed cells require, at any change density.

4. **`cell_grid` dominates on bytes on every profile** (277 B–3.9k vs the whole-line
   renderers' 1.0k–7.6k). Cell-run emission is fundamentally more byte-efficient than
   re-sending whole rows; those bytes are what a real terminal must then parse.

5. **Allocation does not differentiate the architectures.** All four renderers are
   zero-GC-allocation in steady state (asserted: `GC.stats` delta == 0 over a replay
   after warmup). The plan hypothesized the GC-pause axis might decide it; it does
   not — both designs reach zero-alloc steady state with buffer reuse.

## Preliminary recommendation

**The evidence favours the 2-D cell-grid core.** It is the only candidate that is
simultaneously best-or-tied on CPU and best on bytes at every change density, and
the allocation axis (the plan's suspected tiebreaker) is neutral. Line-diff's
appeal — reusing sparkles' existing string producers directly — comes at a real,
measured cost: either full-repaint CPU (`line_diff`) or, once change-detection is
fixed, a byte overhead that persists and a CPU profile that degrades with change
density (`line_diff_lazy`).

This is **preliminary**: it establishes the _relative_ ordering of D approaches
robustly, but not whether the _absolute_ numbers are competitive with the state of
the art. That is what M3 confirms.

## What's next

- **M3 — foreign calibration.** Ratatui (Rust) and Notcurses (C) reference
  implementations of the same scene, as C-ABI shims, to place the D PoCs' absolute
  numbers against the frontier (a D cell-grid at 2× Notcurses is a very different
  conclusion from 20×).
- **Sensitivity** — a scroll-region (`DECSTBM`) `cell_grid` variant; wider profile
  and terminal-size coverage; the `unicode` (wide-cell) profile once the PoCs'
  wide-cell handling is oracle-verified.
- On M3 completion, flip spec [§3.1 / the R1 decision](./index.md#decision-ledger)
  to the chosen core and unblock the follow-up library-build plan.

## Reproduce

```sh
# Timed matrix with hardware counters:
dub test -b bench --root=libs/tui/bench/render -- --bench --perf --group-by=profile,size

# Correctness gate (needs the nix devshell's ghostty-vt):
nix develop -c dub test --root=libs/tui/bench/render -c oracle
```
