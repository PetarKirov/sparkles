# sparkles baseline — Linux outputs from an `aarch64-darwin` laptop

Observed 2026-09-04 on `petar-kirov-macbook-pro`, Darwin 25.6.0
(`ARM64_T6041`), Determinate Nix 3.22.3, Apple `container` 1.1.0
(`5973b9cc626a3e7a499bb316a958237ebe14e2ed`).

## What the flake already declares

`flake.nix` sets `systems = import inputs.systems` with
`github:nix-systems/triplet` →
`aarch64-darwin`, `aarch64-linux`, `x86_64-linux`. So
`packages.aarch64-linux.ci` and `packages.x86_64-linux.ci` exist as
attrpaths. GitHub Actions runs `ci --test` on `ubuntu-latest` and
`ubuntu-24.04-arm`; `nix-build` / `.#all-desktop` runs on
`ubuntu-latest` and `macos-latest` only — **not** on
`ubuntu-24.04-arm`. Linux aarch64 _packages_ still land in
`sparkles.cachix.org` because the aarch64-linux _test_ job's
`devshell: ci` realizes `packages.ci`.

## What this machine has

| Knob                     | Value                                             |
| ------------------------ | ------------------------------------------------- |
| `nix show-config system` | `aarch64-darwin`                                  |
| `extra-platforms`        | `x86_64-darwin` (Rosetta for Darwin, not Linux)   |
| `experimental-features`  | `external-builders pipe-operators`                |
| `external-builders`      | `determinate-nixd builder` for both Linux systems |
| FlakeHub                 | logged in (`PetarKirov`)                          |
| `/etc/nix/machines`      | missing                                           |
| `container`              | on PATH, apiserver starts                         |

[`examples/probe-backends.d`](./examples/probe-backends.d) prints this
table's raw sources (`determinate-nixd version`, `container system status`,
`nix config show …`) and is the standalone example `ci --example-files`
runs; on a Linux host it prints a `SKIP:` line and exits 0.
`ci --linux-host-probe` is the classified version.

## What actually worked

| Command                                                                          | Result                                                                                                                                    |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `nix build nixpkgs#legacyPackages.{aarch64,x86_64}-linux.hello`                  | substitute from `cache.nixos.org`                                                                                                         |
| `nix build` of an uncached `runCommand` with `external-builders` on              | **HTTP 400** gated native builder                                                                                                         |
| `nix build --option external-builders '[]' .#packages.{aarch64,x86_64}-linux.ci` | substitute from `sparkles.cachix.org`                                                                                                     |
| `nix print-dev-env .#devShells.aarch64-linux.ci`                                 | copies many paths, then **platform mismatch** on `nix-shell-env.drv`                                                                      |
| `nix build --dry-run git+file://…?rev=<origin/main>#devShells.x86_64-linux.ci`   | **fetches** 622 paths, builds nothing — the `nix-build` job pushes `.#all` (which includes `devshell-ci`) for x86_64                      |
| the same for `aarch64-linux`                                                     | "this derivation will be built": the shell output is **not** cached — `.#all-desktop` does not run on the arm runner — but every input is |
| `nix derivation show git+file://…?rev=<sha>#devShells.aarch64-linux.ci`          | JSON in ~250 ms once the eval cache is warm; no build                                                                                     |
| `container run --arch arm64 alpine uname`                                        | `aarch64 Linux` 6.18.15                                                                                                                   |
| `container run --arch amd64 --rosetta alpine uname`                              | `x86_64 Linux` 6.18.15                                                                                                                    |
| Nix `hello` via `--volume /nix/store:/nix/store`                                 | `Hello, world!` both arches                                                                                                               |
| `dub test :versions -- -t 1` in that environment                                 | **167 passed**, 4.6 ms, `ldc2` aarch64                                                                                                    |

## What failed, and why

Three failures, each of which moved the design.

**The `ci` wrapper is not the dev shell.** `ci --test --fail-fast` with
only the `packages.ci` wrapper on `PATH` died on package `ci` itself:
`pkg-config` missing, then `tree_sitter/api.h: No such file`. The
wrapper's `PATH` is `git`, `dub`, `nodejs`, `lld`, `ldc` — not
`pkg-config`. Hand-adding `pkg-config` and tree-sitter's `.pc` got `ci`'s
own tests green and then died one package later, linking `diagram`:
`ld.gold: error: cannot find -lraylib`. The shell has ~25 such packages
on Linux; reconstructing its variables by hand is the wrong job. The fix
is to enter the shell itself — see [concepts § Enter a dev shell without
building it](./concepts.md#enter-a-dev-shell-without-building-it).

**The working tree is not a cached revision.** With `apps/ci/src`
modified, `nix build .#packages.aarch64-linux.ci` is a new drv:
`Cannot build '…-ci-0.1.0.drv'`, platform mismatch. The `ci` package's
source is its app dir plus the transitive `libs/*/src` closure, so most
edits to the repo invalidate it. The dispatcher evaluates a pinned
`git+file://…?rev=` reference instead, never `.#`.

**A `symlinkJoin` of Linux packages is a new drv** and fails the same
way — do not join; the shell's setup hooks compose paths at runtime.

**Bare store paths do not see cachix.** The first x86_64 attempt failed
substituting `sparkles-dmd-import-paths`, a path cachix demonstrably had:
the flake's `nixConfig` substituters apply only to flake-scoped commands.
See [concepts § Substituters are per-flake](./concepts.md#substituters-are-per-flake).

## The working recipe

```bash
REV=$(git rev-parse HEAD)            # or merge-base / origin/main: a rev CI built
REF="git+file://$PWD?rev=$REV"

# 1. gate: is this revision's Linux ci cached? (substitutes; gated helper off)
nix build --no-link --print-out-paths --option external-builders '[]' \
  "$REF#packages.aarch64-linux.ci"

# 2. instantiate the dev shell — evaluation only, no build
nix derivation show "$REF#devShells.aarch64-linux.ci" > shell.json

# 3. realize every store path the shell's env names (minus its own `out`)
nix build --no-link --option external-builders '[]' $(paths-in shell.json)

# 4. write enter.sh from shell.json (see concepts.md), then
container system start --enable-kernel-install   # once
container run --rm --arch arm64 --cpus 13 --memory 18G \
  --volume /nix/store:/nix/store:ro \
  --volume "$PWD:$PWD" --workdir "$PWD" \
  --volume /private/tmp/enter:/private/tmp/enter:ro \
  --env DC=ldc2 \
  alpine /private/tmp/enter/enter.sh --test --fail-fast --no-coverage
```

`ci --test --host-system aarch64-linux` is that recipe, with `--cpus` from
`hwParallelism()` and `--memory` half the host's RAM. `--linux-host-probe`
prints the backend table; `--host-ci-rev <rev>` pins step 1.

## Results: `ci --test` on aarch64-linux

Two dispatched runs plus a per-package sweep of the remainder, all in an
11–13 vCPU / 18 GiB guest entered into `devShells.aarch64-linux.ci` at
`9c888fc5`. Every package passes both legs (`-t 1`, then `-t N`) except:

- **`event-horizon`** — hung in **2 of 3** single-threaded runs: main
  thread at 100 % user CPU for 37 min, three threads parked in
  `io_uring_enter`, two `iou-wrk` kernel workers. That is the shape of
  `pool.workStealing.distributesTasksAcrossWorkers` (seeding thread + 3
  peers) and the "O22 GC/io_uring-enter deadlock" its own comment names —
  the same pre-existing hang seen at `-t 29` on an x86 box, now
  reproducible at `-t 1`. Not a property of the VM: the third run passed
  both legs. Kill the test binary from the host
  (`container exec <id> … kill <pid>`) and the sweep continues; run
  without `--fail-fast`.
- **`test-utils`** failed once on a real, previously invisible bug:
  `delta` always pipes through `less --RAW-CONTROL-CHARS`, GNU less
  behaves like `cat` on a non-tty so CI never noticed, and the guest's
  busybox `less` rejects the flag. Fixed by `--paging=never` in
  `diff_tools.d`'s test configuration; green since.

The `dmd-fmt`, `dmd-lsp`, `syntax`, `wired` and `ghostty` packages —
the ones that read `$SPARKLES_FLAKE_INPUT_*`, `$SPARKLES_DMD_IMPORT_PATH`,
`$SPARKLES_TS_GRAMMAR_PATH`, `$JSON_TEST_SUITE` and link libghostty-vt —
all pass, which is the evidence that the hook's exports reached the guest.

## Results: `ci --test` on x86_64-linux (Rosetta)

Dispatched from the linked worktree into `devShells.x86_64-linux.ci` at
`1cbbee86` (identical shell hash to `9c888fc5`; the whole shell output is
cached for this system, so realization is a 4 s substitute). The `ci`
wrapper's compiler here is **dmd**, as on CI's x86_64/dmd leg. The first
18 packages passed both legs, then `event-horizon` took the guest down:
`forkserver.crashIsOneLostRequestNotTheHost` makes a grandchild `SIGSEGV`
on purpose, druntime's `unittestSegvHandler` (installed by
`runModuleUnitTests` with `SA_RESETHAND`, inherited across `fork`) printed
its backtrace **780,820 times**, and the container's init exited — `ci`
returned 137. Same under `ldc2`.

The kernel is not at fault; Rosetta is. [`examples/sa-resethand.d`](./examples/sa-resethand.d)
installs a one-byte handler with `SA_RESETHAND` and faults:

| Host                               | Result                                        |
| ---------------------------------- | --------------------------------------------- |
| Darwin, native                     | `1 delivery, child died of SIGSEGV`           |
| `container --arch arm64`           | `1 delivery, child died of SIGSEGV`           |
| `container --arch amd64 --rosetta` | `100+ deliveries, child killed by the parent` |

So on x86_64 exclude that one test
(`dub test :event-horizon -- -e forkserver.crashIsOneLostRequestNotTheHost`)
and the sweep proceeds; the remaining packages are reported below.

With that exclusion, **every package passes** under Rosetta, both legs,
with two more Rosetta-shaped caveats:

- `event-horizon` reports **78 skipped**: `io_uring_setup` is not
  available under Rosetta, so every ring-backed test takes its `skipTest`
  path. The 46 that do not need a ring pass. The `-t 1` hang seen on
  aarch64 cannot show here — the pool test that hangs is among the
  skipped.
- `tui` at `-t 10` **timed out once (20 min, no output) and fails
  deterministically at `-t 4` and above**:
  `integration.pty.lifecycleAndCellDiff` drains the pty master until
  120 ms of silence and asserts the alt-screen sequence arrived; under
  Rosetta with several workers the child's setup bytes come later than
  that. `-t 1` and `-t 2` pass in a second. A timing race in an
  emulated-x86 pty, not a toolkit bug.

Realization cost is the same as aarch64 once cached: the dispatcher
substituted the shell in 4 s and the container booted in under a second.
Build throughput under Rosetta is roughly half of native: `hue`'s test
build took 5.4 min against 2.5 min on aarch64.

## Gaps that remain

- Uncached Linux drvs still cannot be _built_ here (Determinate gated;
  nix-darwin builder off; IOHK not installed). That includes a change to
  the dev shell itself, or to `apps/ci` — those are tested on Linux only
  after a push.
- `nix-build` CI does not push `.#all-desktop` for `aarch64-linux`, so
  the aarch64 shell _output_ is never cached. The dispatcher does not
  need it, but `nix develop` on a real aarch64 box would.
- Default Determinate `--cpu-count 1` would be wrong even after the
  gate lifts.
- `x86_64-linux` under Rosetta is not a faithful kernel for signal
  semantics (`SA_RESETHAND` above). A native x86 box, or the IOHK /
  Determinate builders' guests (also Rosetta), share or do not share this
  bug — unknown; the probe answers in one run.
- VirtioFS: `dub` writes `.dub/` and `build/` into the mounted tree, so a
  Linux run leaves Linux objects beside the Darwin ones. dub keys build
  dirs by platform, so they coexist; they are not small.

<!-- References -->

[detsys]: ./determinate-linux-builder.md
[container]: ./apple-container.md
