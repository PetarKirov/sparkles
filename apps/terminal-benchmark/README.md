# terminal-benchmark

A repeatable CPU benchmark harness for the [`terminal`](../terminal) emulator,
plus the third-party tools it pairs with, all pinned in the flake.

The terminal redraws the **whole grid every frame**, so the number that matters
is **CPU consumed at a fixed rendering load** — not raw byte throughput (feeding
a big escape stream is parse-bound: the loop drains the whole PTY, then renders
once per frame). This harness launches one or more terminal binaries against
deterministic, self-generated workloads and samples each process's own CPU ticks
from `/proc/<pid>/stat` over a fixed window.

> [!NOTE]
> It needs a real display (raylib opens a GL window) and Linux (`/proc`). It is a
> local/interactive tool, not a headless CI check.

## Scenarios

| Scenario | Workload                                       | What it isolates                                                                     |
| -------- | ---------------------------------------------- | ------------------------------------------------------------------------------------ |
| `idle`   | paint one dense full screen, then hold         | idle cost — should be near zero with dirty-frame skipping, frame-cap-high without    |
| `render` | paint a dense screen, force a redraw per frame | the **render path** (glyphs, backgrounds, batching) — the metric renderer work moves |
| `churn`  | repaint the entire grid as fast as accepted    | the whole stack; dominated by VT **parsing**, not rendering                          |

Each cell in the workloads carries a bold+italic+underline glyph with a distinct
256-color fg/bg — the heaviest per-cell draw the renderer supports. `render` sets
`SPARKLES_BENCH_FORCE_REDRAW` so the static screen is redrawn every frame instead
of being skipped (a continuous stream would be parse-bound, not render-bound).

## Usage

In the dev shell (`nix develop`) the harness and tools are on `PATH`:

```bash
# Compare two binaries (e.g. before/after a change)
terminal-benchmark /path/to/terminal_before /path/to/terminal_after

# A single binary, all scenarios
terminal-benchmark ./apps/terminal/build/sparkles_terminal

# Tune the run
terminal-benchmark --scenario churn --reps 5 --window 10 --warmup 3 BIN_A BIN_B
```

Or without entering the shell:

```bash
nix run .#terminal-benchmark -- /path/to/terminal_a /path/to/terminal_b
```

Options: `--scenario idle|render|churn|all`, `--reps N`, `--warmup S`,
`--window S`, `--cols N`, `--rows N`, `--keep-streams DIR`.

### Building before/after binaries to compare

```bash
dub build :terminal -b release                 # current tree
cp apps/terminal/build/sparkles_terminal /tmp/after
git stash                                      # or: git checkout <ref> -- apps/terminal/src
dub build :terminal -b release && cp apps/terminal/build/sparkles_terminal /tmp/before
git stash pop
terminal-benchmark /tmp/before /tmp/after
```

### Example output

```
scenario \ binary          terminal_before   terminal_batched
idle (static screen)               31.5%              4.7%
render (forced redraw)             32.2%             11.4%
churn (full repaint)               96.1%             96.0%
```

## Companion tools (manual)

The harness measures CPU; for throughput and profiling, these are also in the
shell. They render their output _inside_ the terminal under test, so read them
from the terminal window (or screenshot), not the parent shell.

```bash
# vtebench — sink throughput; writes blocking time to a .dat file you can read
sparkles_terminal -- "vtebench --benchmarks ${VTEBENCH_BENCHMARKS:-$(dirname $(command -v vtebench))/../share/vtebench/benchmarks} --dat /tmp/vte.dat -s"

# termbench — output sink GB/s (prints into the terminal)
sparkles_terminal -- "termbench small"

# perf — profile the render path. Generate a stream (terminal-benchmark
# --keep-streams DIR writes fill.vt) and force a redraw every frame, then attach.
SPARKLES_BENCH_FORCE_REDRAW=1 sparkles_terminal --exit-behavior hold -- "cat DIR/fill.vt; sleep 60" &
perf record -g --call-graph=dwarf -F 999 -p $! -- sleep 8
perf report --stdio -g none | head -40
```

`vtebench`'s benchmark definitions are installed under
`$out/share/vtebench/benchmarks` in its Nix package.

## How it cleans up

The harness `SIGTERM`s the terminal after the window; closing the terminal's PTY
master in turn `SIGHUP`s the workload shell, so nothing is left running.
