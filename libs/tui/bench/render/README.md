# `tui-render-bench` — terminal render-cost benchmark

Decide the `sparkles:tui` rendering core by measurement, not taste: a **line-diff**
buffer of styled byte-lines vs a **2-D cell-grid** with per-cell diffing (spec
[`docs/specs/tui/`](../../../../docs/specs/tui/index.md) §3.1). Both are D
proofs-of-concept benched head-to-head under `sparkles:test-runner`; cross-language
reference implementations (Ratatui, Notcurses, …) are added later as external
calibration. Structure mirrors [`libs/wired/bench/runtime`](../../../wired/bench/runtime/README.md).

## What it measures

Library-side render cost: the CPU + allocation cost to turn a scripted sequence of
frame states into the minimal ANSI byte stream, into a **reused in-memory buffer**
(not a fd — no per-flush syscall pollutes the number). This is the _producer_ side;
`termbench`/`vtebench` measure the _consumer_ (terminal) side. One iteration times a
**whole scenario** (a diffing renderer's per-frame cost depends on the previous
frame); metrics are reported per frame.

| Column       | Meaning                                                                |
| ------------ | ---------------------------------------------------------------------- |
| `frame/s`    | throughput (scenario frames ÷ iteration time)                          |
| `B`          | bytes emitted per frame (deterministic; the terminal's input)          |
| `instr/iter` | instructions per scenario (`--perf`) — the architecture-invariant view |
| `IPC`        | instructions per cycle (`--perf`)                                      |

## Running

```sh
# Canonical run (release, -mcpu=native; debug builds are meaningless under --bench):
dub test -b bench --root=libs/tui/bench/render -- --bench --perf --group-by=profile,size

# Subsets (comma lists; empty = all):
TUI_BENCH_POCS=line_diff,cell_grid TUI_BENCH_PROFILES=mixed TUI_BENCH_SIZES=120x40 \
    dub test -b bench --root=libs/tui/bench/render -- --bench

# Snapshot for the record (absolute path — the test binary's cwd differs):
dub test -b bench --root=libs/tui/bench/render -- --bench \
    --bench-json="$PWD/libs/tui/bench/render/results/$(date -I)-$(hostname)-native.json"
```

## The scene + scenario

A full-screen operations dashboard (`scene.d`): header + clock, a scrollable log
pane, a selectable data table with a counter column, an expand/collapse tree, a
spinner + progress footer, a status line. Driven by a deterministic, fully
materialized scripted scenario (`scenario.d`, no runtime RNG) applied to a shared
`model.d`. Renderers are pure replayers; `scene.d` produces the neutral target
`Grid` (`cell.d`) so neither architecture is favoured by the encoding.

**Profiles** (the anti-rigging device — reported side-by-side): `sparse`
(~1–3 % cells change → favours cell), `churn` (most cells change → favours line),
`scroll` (whole-screen shift), `resize` (reflow + realloc), `mixed` (headline),
`unicode` (wide/emoji — D-PoC-only, not yet benched pending wide-cell verification).

## Correctness gate (VT oracle)

line-diff and cell-diff legitimately emit _different_ bytes for the same picture,
so bytes can't be fingerprinted. Instead each renderer's output is replayed through
the vendored `libghostty-vt` (`vt_oracle.d`, `sparkles:ghostty`) and the
reconstructed grid is fingerprinted (grapheme + fg/bg/attrs per cell) and compared
frame-by-frame against the target — a renderer that renders _differently_ fails.
It needs the devshell's `ghostty-vt` pkg-config, so it's a separate configuration:

```sh
nix develop -c dub test --root=libs/tui/bench/render -c oracle
```

Verified: `reference_fullpaint`, `line_diff`, and `cell_grid` reconstruct the
target every frame across `sparse`/`churn`/`scroll`/`resize`/`mixed`.

## Recorded results

Snapshots under `results/<date>-<host>-<isa>.json` (`--bench-json`).

## Current findings (M1–M2, one host, AMD Ryzen 9 7940HX, `-mcpu=native`, 120×40)

Instructions per scenario (300 frames, `--perf`) and bytes/frame:

| renderer         | sparse instr | mixed instr | churn instr | bytes/frame (sparse→churn) |
| ---------------- | ------------ | ----------- | ----------- | -------------------------- |
| `cell_grid`      | 294M         | **316M**    | **349M**    | **277 → 3.9k**             |
| `line_diff_lazy` | **275M**     | 368M        | 460M        | 1.0k → 7.6k                |
| `line_diff`      | 455M         | 457M        | 460M        | 1.0k → 7.6k                |
| `reference`      | 457M         | 457M        | 458M        | 7.8k → 7.8k                |

- **`line_diff` tracks the full-repaint reference on CPU**: it re-serializes _every_
  row each frame just to diff it, so its diffing saves output bytes, not instructions.
- **`line_diff_lazy` (M2)** — cell-compare rows, serialize only changed ones — fixes
  that _when few rows change_ (sparse: 275M, even edging `cell_grid`), but reverts to
  full-repaint cost on `churn` (all rows change → serialize all), and still emits
  whole rows so it loses on bytes everywhere.
- **`cell_grid` is the most consistent on CPU** (best on mixed/churn, ~tie on sparse)
  and **dominates on bytes** on every profile — cell-run emission is fundamentally
  more byte-efficient than whole-row.

Takeaway so far: the evidence favours the 2-D cell-grid core. Next: allocation /
zero-alloc-steady-state comparison, foreign calibration (M3: Ratatui, Notcurses),
then the M5 decision record. Numbers are one scene on one host.
