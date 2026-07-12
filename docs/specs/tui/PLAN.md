# `sparkles:tui` — delivery plan

_Audience: contributors. Execution-only — deliverables, milestones, dependencies,
verification. For the feature inventory, per-item status, and design rationale
read the [spec](./index.md); item numbers (R1…G1) refer to its §2._

The library's runtime/widget modules are **blocked on the rendering-core decision**
(spec §3.1). This plan therefore front-loads the two things that unblock and scope
that work: the [feature spec](#deliverable-1) (the [`index.md`](./index.md) this
sits beside) and the [render-cost benchmark](#deliverable-2) that picks the core.
Building `libs/tui/src/` is a **follow-up plan**, not part of this one.

## Milestone overview

| #      | Deliverable                                                                                         | Depends on | Status |
| ------ | --------------------------------------------------------------------------------------------------- | ---------- | ------ |
| **D1** | Feature-requirements / delta spec ([`index.md`](./index.md) + this plan)                            | —          | landed |
| **M0** | Bench scaffolding + VT-oracle correctness harness (`libs/tui/bench/render/`)                        | D1         | open   |
| **M1** | Two D PoCs (`line_diff`, `cell_grid`) benched across profiles — **answers the core question**       | M0         | open   |
| **M2** | Sensitivity: `immediate_flat`, scroll-region `cell_grid` variant, (`incremental_dag` if wanted)     | M1         | open   |
| **M3** | Systems-language calibration shims: Ratatui (Rust) → Notcurses (C) → libvaxis (Zig, if cheap)       | M1         | open   |
| **M4** | Runtime-language calibration (subprocess): Bubble Tea (Go); Textual/Ink optional                    | M1         | open   |
| **M5** | Decision record `render-bench-baseline.md`; record the chosen core back in [`index.md`](./index.md) | M1 (+M3)   | open   |

**Realistic MVP that already answers the architecture question:** M0 + M1 +
(M3: Ratatui + Notcurses).

## Deliverable 1

The [feature-requirements / delta spec](./index.md) — the inventory of what the
interactive TUI layer needs on top of the existing sparkles substrate, grounded
only in `sparkles` and the [TUI-libraries survey](../../research/tui-libraries/index.md).
Landed alongside this plan. Its open architectural questions (§3) are what
Deliverable 2 exists to resolve.

## Deliverable 2

A cross-language render-cost benchmark that decides the rendering core (spec §3.1)
by measurement. It mirrors the established `libs/wired/bench/runtime/` pattern:
`@benchmark` unittests driven by `sparkles:test-runner`'s `benchCase`, run via
`dub test -b bench -- --bench --perf --group-by=…`; JSON snapshots under
`results/<date>-<host>-<isa>.json`; per-case verification against a reference so a
wrong-but-fast implementation fails the run; ISA presets for `-mcpu=native`
fairness; foreign toolchains built as Nix packages (not devshell compilers).

**What it measures:** library-side render cost — the CPU + allocation cost to turn
a scripted sequence of frame states into the minimal ANSI byte stream, into an
in-memory reused buffer (isolating the renderer from terminal draw speed). Metrics
per frame: ns, instructions (`--perf`), output bytes, allocations, and diagnostic
cursor-move / SGR-write counts.

**The scene + scenario:** a full-screen operations dashboard (header+clock,
scrollable log, selectable table, expand/collapse tree, spinners+progress, status
line), driven by a fully-materialized declarative scenario script (no runtime RNG)
pinned as `$TUI_BENCH_DATA`. A **profile suite** — `sparse` / `churn` / `scroll` /
`resize` / `mixed` / `unicode` — is reported side-by-side to prevent a rigged
result; the findings weight the profiles by expected workload explicitly.

**Correctness gate (VT oracle):** because line-diff and cell-diff legitimately emit
different bytes, correctness is checked on the _visual result_ — each renderer's
bytes are replayed through the vendored `libghostty-vt` (`libs/ghostty`) into a
grid, whose per-frame fingerprint (grapheme + fg/bg/style + cursor) must match a
full-repaint reference. A mismatch is an isolated error row that fails the run.

### M0 — scaffolding + correctness harness

- `libs/tui/` package skeleton (`dub.sdl`; **library `src/` intentionally empty**
  pending the core decision) + `subPackage "libs/tui"` in the root `dub.sdl`.
- `libs/tui/bench/render/` standalone bench package (own `dub.sdl` with
  `buildType "bench"` copied from wired; `README.md` with the scene/scenario/metric
  spec).
- `scenario.d`/`model.d`/`scene.d` (event model, shared replayer state, rendering
  spec), a deterministic scenario generator, and the `tui-bench-data.nix` pin →
  `$TUI_BENCH_DATA`.
- `sink.d` (reused-buffer counting sink), `fingerprint.d` + `vt_oracle.d` (grid
  fingerprint via `libghostty-vt`), `pocs/reference_fullpaint.d` (ground truth).
- **Exit:** the reference renderer replays the `mixed` profile and its VT-grid
  fingerprint sequence is stable and reproducible.

### M1 — the primary signal (two D PoCs)

- `pocs/line_diff.d` (byte-line buffer + line diff) and `pocs/cell_grid.d`
  (flat `Cell[]` + cell diff, double-buffered), both passing the fingerprint gate.
- `runner.d`: `@benchmark` matrix (PoCs × profiles × terminal-sizes) via `benchCase`,
  reusing wired's `isolated`/`markFilteredOut`/env-subset (`TUI_BENCH_POCS`,
  `TUI_BENCH_PROFILES`) and `traits.d` capability pattern.
- Bench across all profiles × 3 sizes with `--perf` + allocation counters; first
  findings draft comparing the two.
- **Exit:** a defensible line-diff-vs-cell-grid comparison exists from D alone.

### M2 — sensitivity + optional D PoCs

- `pocs/immediate_flat.d` (ImTui-style; cheap, tests the immediate-vs-retained
  axis) and a scroll-region-optimized `cell_grid` variant (tests whether the
  cell-diff `scroll`/`churn` loss is fundamental or a missing DECSTBM feature).
- `pocs/incremental_dag.d` (Nottui-style) **only** if a reactive design is on the
  table after M1.

### M3 — systems-language calibration (FFI shims)

- Nix-built C-ABI staticlib shims + `foreign/*_engines.d` adapters, timed
  in-process by the D runner (one `run_scenario` call/iteration). Reuse
  `nix/packages/wired-bench-{rs,cpp-shim,isa-presets}.nix` and the `benchIsaHook`
  (refactored into a helper both benches share).
- Order: **Ratatui (Rust)** (cell flagship, reuses the Rust machinery) →
  **Notcurses (C)** (the cell-diff frontier) → **libvaxis (Zig)** if cheap.
- Cross-language gate runs on the **ASCII-safe** scene; the `unicode` profile stays
  D-PoC-only (foreign width tables legitimately differ). `results/` snapshots.

### M4 — runtime-language calibration (subprocess, best-effort)

- Standalone executables implementing the identical protocol, ingested by a
  subprocess adapter: **Bubble Tea (Go)** (the line-diff lineage reference);
  Textual/Rich (Python) and Ink (Node) optional (they measure framework overhead,
  not the diff algorithm).

### M5 — decision record

- `docs/specs/tui/render-bench-baseline.md` (mirrors
  [`docs/specs/wired/bench-baseline.md`](../wired/bench-baseline.md)): environment
  table, per-profile tables, hardware-counter analysis, numbered findings, a
  recommendation with evidence, and a reproduce block.
- Record the chosen rendering core in the [spec's decision ledger](./index.md#decision-ledger),
  flipping R1's status and unblocking the follow-up library-build plan.

## Deferred / explicitly out of scope

- Building `libs/tui/src/` proper (runtime, backend, input, color, style, layout,
  widgets, images) — a follow-up plan, gated on M5.
- FTXUI (C++) as a bench engine (redundant with Ratatui + Notcurses for the core
  question — spec §3.1).
- The non-goals in [spec §4](./index.md#4-non-goals) (terminfo, accessibility,
  terminal handshake queries).
