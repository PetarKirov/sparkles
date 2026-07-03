# Command-line options

Everything after `--` in `dub test :pkg -- <options>` goes to the runner.

## Selection and output

| Option            | Description                                                                |
| ----------------- | -------------------------------------------------------------------------- |
| `-i`, `--include` | Run only tests whose `fullName name` matches the regular expression        |
| `-e`, `--exclude` | Skip tests whose `fullName name` matches (ignored when `-i` is given)      |
| `-v`, `--verbose` | Durations, `[file:line]` locations, full stack traces                      |
| `-t`, `--threads` | Worker threads; `0` (default) auto-detects, `1` runs single-threaded       |
| `--no-colours`    | Disable colored output (also honors `$NO_COLOR` and non-tty stdout)        |
| `-l`, `--list`    | List discovered tests with `@ctfe`/`@benchmark`/`@betterC`/`@wasm` markers |
| `--self-test`     | Also run the test runner's own unittests                                   |
| `-h`, `--help`    | Option summary                                                             |

## Modes

| Option              | Description                                                             |
| ------------------- | ----------------------------------------------------------------------- |
| _(none)_            | Run regular tests in parallel; report `@ctfe` as compile-time-verified  |
| `--bench`           | Measure `@benchmark` tests (serial); print the statistics table         |
| `--better-c`        | Extract `@betterC` tests, compile with `-betterC`, run without druntime |
| `--wasm`            | Extract `@wasm` tests, cross-compile to `wasm32`, run in a wasm runtime |
| `--ctfe-trace FILE` | Attribute CTFE cost per `@ctfe` test from an LDC `-ftime-trace` JSON    |

## `--better-c` / `--wasm` toolchain options

| Option                     | Description                                                      |
| -------------------------- | ---------------------------------------------------------------- |
| `--compiler DC`            | D compiler to use (default: `$DC`, then `ldc2`, `dmd` from PATH) |
| `-I`, `--import-path DIR`  | Extra import path (repeatable)                                   |
| `--include-import PATTERN` | Compile matching imported modules in (`-i=PATTERN`; repeatable)  |
| `--keep`                   | Keep the generated program files and print their location        |

## Exit status

`0` when everything passed (or a toolchain-missing mode was skipped);
non-zero otherwise.
