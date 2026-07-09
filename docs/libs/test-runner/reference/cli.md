# Command-line options

Everything after `--` in `dub test :pkg -- <options>` goes to the runner.

## Selection and output

| Option            | Description                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| `-i`, `--include` | Run only tests whose `fullName name` matches the regular expression                                      |
| `-e`, `--exclude` | Skip tests whose `fullName name` matches; combines with `-i` (a test must match `-i` and not match `-e`) |
| `-v`, `--verbose` | Durations, `[file:line]` locations, full stack traces                                                    |
| `-t`, `--threads` | Worker threads; `0` (default) auto-detects, `1` runs single-threaded                                     |
| `--no-colours`    | Disable colored output (also honors `$NO_COLOR` and non-tty stdout)                                      |
| `-l`, `--list`    | List discovered tests with `@ctfe`/`@benchmark`/`@betterC`/`@wasm` markers                               |
| `--self-test`     | Also run the test runner's own unittests                                                                 |
| `-h`, `--help`    | Option summary                                                                                           |

## Modes

| Option              | Description                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _(none)_            | Run regular tests in parallel; evaluate selected `@ctfe` tests via CTFE                                                                                                                                                                                                                                                                                                                                                                                 |
| `--bench`           | Measure `@benchmark` tests (serial). Cases are registered from all bench bodies, then scheduled and measured grouped by their streaming key — the `--group-by` group, else the source test — so each table prints the moment its group finishes. On an interactive terminal a live progress spinner (`⠹ 12/40 name`) animates on stderr; it is auto-suppressed when piped, non-tty, `--no-colours`, or `$NO_COLOR` (results on stdout stay byte-stable) |
| `--perf`            | With `--bench`: add hardware perf counters per benchmark (Linux `perf_event`) — IPC, instructions/iter, cache/branch miss rates                                                                                                                                                                                                                                                                                                                         |
| `--syscalls[=LIST]` | With `--bench`: count syscalls/iteration (perf tracepoints); bare = total column, `=futex,…` adds one each. Needs readable tracefs + `perf_event_paranoid ≤ 1` (usually root)                                                                                                                                                                                                                                                                           |
| `--metrics=LIST`    | With `--bench`: choose metric columns (comma list; glob with `*`; `all` = every available; `?`/`help` = list). Default: standard. Naming a perf metric (or `all`) opens the `--perf` pass automatically, so those columns fill without a separate `--perf`                                                                                                                                                                                              |
| `--list-metrics`    | List the available metric columns (name, class, source) and exit. Works with or without `--bench`                                                                                                                                                                                                                                                                                                                                                       |
| `--sort-by=KEY`     | With `--bench`: sort rows by `name` or a metric column name (ascending). Default: `median/iter`. Applied within `--group-by` groups. An unknown column name warns on stderr and leaves the default order                                                                                                                                                                                                                                                |
| `--group-by=KEYS`   | With `--bench`: split the report into one table per group of the given case **label** keys (comma-separated or repeated; each titled `benchmark: <group>` over an `implementation:` column listing the row `name`). E.g. `=dataset,operation`. `=all` groups by every label key; `=list` prints the available keys and exits                                                                                                                            |
| `--better-c`        | Extract `@betterC` tests, compile with `-betterC`, run without druntime                                                                                                                                                                                                                                                                                                                                                                                 |
| `--wasm`            | Extract `@wasm` tests, cross-compile to `wasm32`, run in a wasm runtime                                                                                                                                                                                                                                                                                                                                                                                 |
| `--ctfe-trace FILE` | Evaluate `@ctfe` tests under LDC `-ftime-trace` and report per-test cost                                                                                                                                                                                                                                                                                                                                                                                |

`@ctfe` tests are evaluated by a probe program compiled with `-o- -unittest`
(semantic analysis only) after `-i`/`-e` filtering, so only the selected
tests execute, and `--help`/`--list` never evaluate any — even ones that
would fail. See
[Write compile-time tests](../how-to/write-ctfe-tests.md).

## `@ctfe` / `--better-c` / `--wasm` toolchain options

| Option                     | Description                                                      |
| -------------------------- | ---------------------------------------------------------------- |
| `--compiler DC`            | D compiler to use (default: `$DC`, then `ldc2`, `dmd` from PATH) |
| `-I`, `--import-path DIR`  | Extra import path (repeatable)                                   |
| `--include-import PATTERN` | Compile matching imported modules in (`-i=PATTERN`; repeatable)  |
| `--keep`                   | Keep the generated program files and print their location        |

## Exit status

`0` when everything passed (or a toolchain-missing mode was skipped);
non-zero otherwise.
