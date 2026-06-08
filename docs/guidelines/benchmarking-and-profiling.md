# Benchmarking & Profiling the Terminal Renderer

How to measure, profile, and improve the performance of the raylib terminal
(`apps/terminal`) — both to **reproduce** the published numbers and to get up to
speed with the **measure → profile → hypothesize → fix → re-measure** loop that
produced them.

The running example throughout is the render-CPU work that took a full-screen
repaint from **~32% of a core to ~12%** and idle from **~32% to ~5%**. Every
number here is reproducible with the tooling the repo ships.

> [!NOTE]
> This flow is **Linux-only** (it reads `/proc` and uses `perf`) and needs a real
> display (raylib opens a GL window). It is a local/interactive workflow, not a
> headless CI gate. Absolute percentages are hardware- and driver-specific — the
> figures below were measured on an AMD Ryzen 9 7940HX with the Mesa `radeonsi`
> driver and raylib 5.5. Compare _deltas on one machine_, not absolutes across
> machines.

---

## The short version

```bash
nix develop                                    # harness + perf + cmatrix + tools on PATH

# Build two binaries to compare (e.g. before/after a change)
dub build :terminal -b release
cp apps/terminal/build/sparkles_terminal /tmp/after
git stash && dub build :terminal -b release
cp apps/terminal/build/sparkles_terminal /tmp/before && git stash pop

# Measure render CPU (lower is better)
terminal-benchmark /tmp/before /tmp/after
```

Everything below explains _what those numbers mean_ and _how to dig into them_.

---

## What to measure (and what not to)

The single most important idea: **pick a metric that actually moves with the code
you changed.** For this terminal that metric is **CPU at a fixed rendering load**,
and getting there means avoiding two traps.

### The terminal redraws the whole grid every frame

`runCoreLoop` (`apps/terminal/src/app.d`) drains the pty, snapshots the terminal
into a render state, and redraws **every visible cell every frame** at the 60 FPS
target. There is no partial-region redraw. Two consequences:

- **Idle cost is real.** A static screen still costs a full redraw per frame
  unless [dirty-frame skipping](#the-three-fixes) short-circuits it. This is why a
  paused pager or an idle prompt could burn CPU.
- **Render cost scales with cells drawn, not bytes received.** The work is the
  per-cell draw path (backgrounds, glyphs, decorations), not the byte volume.

### Trap 1: throughput benchmarks are parse-bound

The obvious move — pipe a big escape-sequence stream and time it — measures the
wrong thing. The loop drains the **entire** pty each frame, hands it to
`libghostty-vt` to parse, and renders **once**. Feeding 42 MB renders only ~50
frames while the VT engine parses all 42 MB, so the run is dominated by
**parsing**, which no renderer change touches.

> [!IMPORTANT]
> A continuous-stream workload (`vtebench`, `termbench`, or
> `while :; do cat dense.vt; done`) is **parse-bound**. It is a fine whole-stack
> throughput check, but it will _not_ move when you optimize the renderer. Do not
> use it to validate render work.

### Trap 2: a static screen is skipped, so it measures nothing

Because of dirty-frame skipping, holding a static screen idles at near-zero — the
renderer isn't running. To measure the **render path in isolation** you need a
dense screen that is **redrawn every frame without new parse work**. The terminal
exposes a benchmark hook for exactly this:

```bash
SPARKLES_BENCH_FORCE_REDRAW=1   # redraw every frame regardless of dirty state
```

The harness's `render` scenario sets it automatically. That combination — _a full,
static, dense screen, force-redrawn at the frame cap_ — is the clean render-CPU
benchmark.

### The three regimes

| Regime     | Workload                                     | Bound by                         | Use it to measure               |
| ---------- | -------------------------------------------- | -------------------------------- | ------------------------------- |
| **idle**   | paint a dense screen once, then hold         | the per-frame loop overhead      | dirty-frame skipping            |
| **render** | dense screen + `SPARKLES_BENCH_FORCE_REDRAW` | the **per-cell draw path**       | the renderer (glyphs, batching) |
| **churn**  | repaint continuously (a stream)              | **VT parsing** (`libghostty-vt`) | whole-stack throughput          |

---

## The benchmark harness

`apps/terminal-benchmark` is a D harness that launches one or more terminal
binaries against deterministic, self-generated workloads and samples each
**process's own CPU** from `/proc/<pid>/stat` over a fixed window (reusing
`core-cli`'s `parseCpuTicksFromStat`). It prints a comparison table.

```bash
# Compare two binaries across all scenarios (3 reps each)
terminal-benchmark /tmp/before /tmp/after

# One binary, just the render scenario, longer window
terminal-benchmark --scenario render --reps 5 --window 10 ./apps/terminal/build/sparkles_terminal

# Or without entering the dev shell
nix run .#terminal-benchmark -- /tmp/before /tmp/after
```

Options: `--scenario idle|render|churn|all`, `--reps N`, `--warmup S`,
`--window S`, `--cols N`, `--rows N`, `--keep-streams DIR`. Each workload cell
carries a bold + italic + underline glyph with a distinct 256-color fg/bg — the
heaviest per-cell draw the renderer supports.

Example output (values are average % of one core over the window, lower is
better):

```
scenario \ binary          terminal_before   terminal_batched
idle (static screen)               31.8%              4.8%
render (forced redraw)             31.8%             11.8%
churn (full repaint)               96.1%             96.0%
```

Read it as: dirty-skip cut **idle** 6.6×; batching cut **render** 2.7×;
**churn** is unchanged because it's parse-bound (the renderer was never the
bottleneck there).

> [!NOTE]
> The harness `SIGTERM`s the terminal after the window; closing its pty master in
> turn `SIGHUP`s the workload shell, so nothing is left running. See
> `apps/terminal-benchmark/README.md` for the full reference.

### Building before/after binaries

The harness compares whatever binaries you hand it. Build a release binary of
each revision (the algorithmic deltas show in debug too, but release gives
representative absolutes):

```bash
dub build :terminal -b release && cp apps/terminal/build/sparkles_terminal /tmp/after
git checkout <base-ref> -- apps/terminal/src   # or: git stash
dub build :terminal -b release && cp apps/terminal/build/sparkles_terminal /tmp/before
git checkout HEAD -- apps/terminal/src         # or: git stash pop
```

---

## Profiling with `perf`

The harness tells you _whether_ something got faster; `perf` tells you _where_ the
time goes so you can form the next hypothesis. Attach to the running terminal
under the `render` load:

```bash
terminal-benchmark --keep-streams /tmp/streams --scenario render --reps 1 --window 1 BIN  # writes /tmp/streams/fill.vt
SPARKLES_BENCH_FORCE_REDRAW=1 BIN --exit-behavior hold -- 'cat /tmp/streams/fill.vt; sleep 60' &
perf record -g --call-graph=dwarf -F 999 -p $! -- sleep 8
perf report --stdio -g none | head -40
```

Reading the self-time column is usually enough to find the hotspot. Two profiles
of the same `render` load, _before_ and _after_ the batching fix, tell the whole
story:

| Symbol (self %)                          | Before batching | After batching | What it is                                      |
| ---------------------------------------- | --------------: | -------------: | ----------------------------------------------- |
| `si_set_sampler_state_desc` (libgallium) |            ~18% |           gone | GPU-driver texture/sampler state, per draw call |
| `si_pipe_set_sampler_views`              |            ~16% |           gone | ditto — bind a texture for a draw               |
| `rlVertex3f` (libraylib)                 |            ~11% |           ~28% | immediate-mode geometry submission              |
| `__vdso_clock_gettime`                   |            ~10% |           ~28% | the `SetTargetFPS(60)` frame limiter            |
| `GetGlyphIndex` (libraylib)              |             ~6% |           gone | raylib's O(glyphCount) glyph lookup             |

The lesson is in the **shape**, not the magnitude: before, the dominant cost was a
separate GPU-driver thread (`terminal:gdrv0`) setting sampler state thousands of
times per frame — a sign of **lost batching**. After, that's gone; what remains
(`rlVertex3f` geometry upload, the frame limiter) is the residue that only a
deeper rewrite would remove. **A profile that's dominated by driver state-setup
means too many draw calls; one dominated by vertex submission means too much
geometry.** Those point at different fixes.

> [!TIP]
> raylib and Mesa symbols resolve without extra work; the D binary keeps symbols
> in a release build. `perf_event_paranoid` must allow user profiling (the repo's
> dev machines run `-1`). The GPU driver does work on its own thread — read the
> `Command` column, since `/proc/<pid>/stat` CPU (what the harness samples) sums
> all threads but `perf` attributes per-thread.

---

## Companion tools: `vtebench` & `termbench`

Both are pinned in the flake (`nix/packages/bench-tools.nix`) and on the dev-shell
`PATH`. Both measure **sink throughput** — how fast the terminal _accepts_ output
— which (per [Trap 1](#trap-1-throughput-benchmarks-are-parse-bound)) is parse-bound
here, so treat them as whole-stack checks, not renderer benchmarks.
They also render their results _inside_ the terminal under test, so read them from
the window (or a screenshot), not the parent shell.

```bash
# vtebench (alacritty): generates escape-sequence workloads, times write-blocking.
# Writes timings to a .dat you can read back from the real filesystem.
sparkles_terminal -- "vtebench --benchmarks \
  $(dirname $(command -v vtebench))/../share/vtebench/benchmarks --dat /tmp/vte.dat -s"

# termbench (cmuratori): reports an output-sink GB/s, printed into the terminal.
sparkles_terminal -- "termbench small"
```

`vtebench`'s benchmark definitions ship under `$out/share/vtebench/benchmarks` in
its Nix package. For an animated, human-eyeball load, `cmatrix` is also on the
dev-shell `PATH`.

---

## Worked example: the render-CPU pass

This is the loop in action — three fixes, each found by a profile and validated by
the harness.

### The starting point

A profile of a full-screen redraw showed **no single smoking gun**: ~40% in the
GPU-driver thread (sampler-state churn), ~11% `rlVertex3f`, ~10% in the frame
limiter, ~6% `GetGlyphIndex`. The headline gap versus a GPU-instanced terminal
(Ghostty idles <1% on the same load) is **architectural** — raylib draws thousands
of tiny quads per frame — but three targeted fixes recovered most of the easy win.

### The three fixes

1. **Drop raylib's O(glyphCount) glyph scan.** `DrawTextEx` → `GetGlyphIndex` is a
   linear scan over the whole (~3000-glyph) font, run per codepoint per cell per
   frame. Keeping a sorted codepoint→index map and drawing each glyph with
   `DrawTexturePro` made the lookup O(log n). **render: ~32% → ~30%.** Small —
   the profile said so up front (`GetGlyphIndex` was only ~6%).
2. **Dirty-frame skipping.** Query the render state's dirty flag after
   `ghostty_render_state_update`; when nothing changed (and no overlay/animation
   is active), skip `BeginDrawing`..`EndDrawing` entirely, pacing + polling input
   with `PollInputEvents`/`WaitTime` instead of swapping buffers. **idle: ~32% →
   ~4.8% (6.6×).** Doesn't touch `render`/`churn` (always dirty), as expected.
3. **Batch the cell grid onto one texture.** Backgrounds/decorations drew from
   raylib's _shapes_ texture while glyphs drew from the _font atlas_, alternating
   every cell — plus a per-row scissor. Each switch forces `rlDrawRenderBatch`, so
   the frame issued thousands of draw calls (the ~40% driver churn). Drawing every
   solid rect as a textured quad sampling a **white texel in the glyph atlas** (the
   center of the `U+2588` block glyph) makes the whole grid share one texture and
   batch into a handful of draw calls. **render: ~30% → ~11% (2.6×).**

### What the loop teaches

- **Let the profile size the fix _before_ you write it.** `GetGlyphIndex` at 6%
  could never be a 10× win; the texture-switch churn at 40% could. Measuring first
  stops you from polishing the wrong thing — the glyph fix was correct but minor,
  and the profile said so.
- **Validate every change in isolation.** Each fix moved exactly the scenario the
  profile predicted (`idle` for dirty-skip, `render` for batching) and left the
  others flat. A change that moves an _unexpected_ scenario is a red flag.
- **Know when to stop.** The post-batching profile is frame-limiter +
  geometry-upload — closing that needs true GPU instancing (a custom shader, a
  per-cell instance buffer), a different order of effort. The harness makes that a
  data-driven decision, not a guess.

---

## Gotchas

- **Screenshots on a skipped frame are stale.** With dirty-skipping (or any
  frame the loop didn't draw), raylib's `TakeScreenshot` reads a back buffer that
  is one or more frames old. Verify visuals on a _forced-redraw_ or full-rate path.
- **`grim`/`wlr-screencopy` may be unavailable.** Some compositors don't implement
  the screen-capture protocol; the in-app `--debug-take-screenshot-and-exit` flag
  (which forces full-rate frames) is the portable fallback.
- **Kill cleans up the child for free.** `SIGTERM`/`SIGKILL` on the terminal
  closes its pty master, which `SIGHUP`s the workload shell — no orphaned
  `cat`/`while` loops. The harness relies on this.
- **Determinism.** Generate workloads from a fixed seed/pattern (the harness does)
  so two runs render identical content. Warm up before sampling (the GL pipeline
  and the OS scheduler need a second or two to settle).

---

## Checklist

- [ ] Measuring the renderer? Use the **`render`** scenario (or
      `SPARKLES_BENCH_FORCE_REDRAW=1`), never a stream — streams are parse-bound.
- [ ] Comparing **deltas on one machine**, with a warmup and ≥3 reps.
- [ ] Built **release** binaries for representative absolute numbers.
- [ ] Profiled with `perf` to locate the hotspot _before_ writing the fix; let its
      magnitude size the expected win.
- [ ] Re-measured after the fix; it moved the **predicted** scenario and left the
      others flat.
- [ ] Recorded the measurement environment (CPU, GPU driver, raylib version) next
      to any absolute numbers you publish.

---

## See also

- `apps/terminal-benchmark/README.md` — harness reference, scenarios, and the
  manual `vtebench`/`termbench`/`perf` recipes.
- [AGENTS.md](./AGENTS.md) — environment, build/test (`dub` vs `nix`), and the
  `git add` new-files rule.
- [Code Style](./code-style.md) — `@nogc`/`nothrow` discipline that keeps the core
  loop allocation- and GC-pause-free (a prerequisite for stable measurements).
- Tools: [`vtebench`](https://github.com/alacritty/vtebench) ·
  [`termbench`](https://github.com/cmuratori/termbench) ·
  perf docs: <https://perfwiki.github.io/main/>
