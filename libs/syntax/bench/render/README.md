# `syntax-render-bench` — syntax-highlighting render-cost benchmark

Measures `sparkles:syntax`'s render backends — **ANSI** (`renderAnsi`) and
**HTML** (`renderHtml`) — head-to-head under `sparkles:test-runner`, across
viewport sizes, a theme-switch scenario, and the page-background toggle. A
Nix-pinned **foreign panel** (bat/syntect, chroma, pygments, shiki) runs the
same corpus end-to-end for cross-library comparison. Structure mirrors
[`libs/tui/bench/render`](../../../tui/bench/render/README.md) and
[`libs/wired/bench/runtime`](../../../wired/bench/runtime/README.md).

## What it measures

Library-side render cost: the CPU + allocation cost to fold a **cached**
highlight-event stream into styled bytes, into a reused in-memory buffer (no fd
— a per-flush syscall would pollute the number). Parsing (tree-sitter) is done
once per case in untimed setup, so the timed body is exactly the app's
per-frame work: re-render (and, for `ansi-switch`, re-resolve the theme).

| Column | Meaning                                                            |
| ------ | ------------------------------------------------------------------ |
| `B/s`  | throughput — **source** bytes highlighted ÷ iteration time (MB/s)  |
| `B`    | **output** bytes per render (deterministic; balloons with `bg=on`) |
| `bg`   | `AnsiOptions.emitBackground` — the page-background axis            |

The `name` column is the compared dimension:

| Case          | Body (timed)                                           |
| ------------- | ------------------------------------------------------ |
| `ansi`        | `renderAnsi` over cached events, one resolved theme    |
| `ansi-switch` | per theme in a rotation: `resolveTheme` + `renderAnsi` |
| `html`        | `renderHtml` over cached events                        |

`ansi-switch` is the interactive **live theme previewer** hot path (`apps/hue`):
one iteration walks the whole theme rotation, so its per-frame cost is the row
median ÷ rotation length.

## Running

```sh
# Canonical run (release, -mcpu=native; debug builds are meaningless under --bench):
dub test -b bench --root=libs/syntax/bench/render -- --bench --group-by=size

# Subsets (comma lists; empty = all):
SYNTAX_BENCH_MODES=ansi,ansi-switch SYNTAX_BENCH_SIZES=40l \
    dub test -b bench --root=libs/syntax/bench/render -- --bench

# Snapshot for the record (absolute path — the test binary's cwd differs):
dub test -b bench --root=libs/syntax/bench/render -- --bench \
    --bench-json="$PWD/libs/syntax/bench/render/results/$(date -I)-$(hostname)-native.json"

# Foreign panel (nix-pinned bat/chroma/pygments/shiki over the same corpus):
libs/syntax/bench/render/foreign/run.sh
```

## The corpus

Frozen real source under `corpus/` (ours, BSL — deterministic and
cwd-independent via `stringImportPaths`). `size` labels take the first N lines
to simulate a terminal viewport height (`24l`/`40l`/`51l`), plus `full` for a
steady end-to-end throughput number. The foreign panel highlights the same
files.

## Interpreting `bg=on`

ANSI has no background inheritance (unlike HTML's `<pre>` container), so with
`emitBackground` on, every run that a theme styles fg-only still has to carry
the page background explicitly. That is correct — it is how the theme's backdrop
shows through in a terminal — but it inflates both output bytes and the per-run
SGR transition count, which is why `bg=on` rows are slower. The benchmark keeps
`bg` a first-class column so that cost stays legible.
