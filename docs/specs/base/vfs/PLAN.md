# Capability VFS — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Owns delivery order, gates and milestone
progress. Requirements are defined only in the specification; oracles only in
[testing.md](./testing.md)._

The work lands as a stacked series of pull requests, one per milestone, each
green on its own and each linking its predecessor. A milestone moves the
requirements it names from `unverified` to `verified` in the
[evidence ledger](./testing.md#evidence-ledger), naming the configuration.

## Feasibility spikes

Each spike answers one question before the milestone that depends on it
starts. A negative answer changes the specification first.

| Spike | Question                                                                                   | Experiment                                                                                         | Decision criterion                                                                                                                      | Blocks         |
| ----- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| S1    | Does `O_NOFOLLOW_ANY` work on the `macos-latest` runner?                                   | a single-file probe opening a path with a symlinked intermediate, run on the macOS leg             | refused with `ELOOP`: keep the macOS row of `VFR7`. Accepted or `EINVAL`: macOS reports `componentWalk` always                          | M2 macOS arm   |
| S2    | Can D call `NtCreateFile` with `RootDirectory` and `OBJ_DONT_REPARSE` on `windows-latest`? | declare the NT functions (druntime has none), link `ntdll`, open a child of a junction             | returns `STATUS_REPARSE_POINT_ENCOUNTERED`: proceed. Otherwise record the failure and revisit `VFR7`'s Windows row                      | M2 Windows arm |
| S3    | Does `-preview=dip1000` stop a `DirRef` from outliving its `Dir`?                          | the compile-fail case from oracle 5, against a move-only owner like `sparkles.base.unique`         | the escape does not compile: keep `VFH2` as written. It compiles: `VFH2` becomes a documented rule plus a runtime check in debug builds | M1             |
| S4    | Can rights be a compile-time flag set with readable errors?                                | `Dir!(V, Rights.readOnly).removeTree` and `attenuate!(Rights.all)`, reading the compiler's message | the message names the missing right: proceed. Otherwise add a `static assert` with a message per operation                              | M1             |

The io_uring opcodes `VFB4` needs (`openat2`, `statx`, `mkdirat`, `unlinkat`,
`renameat`, `symlinkat`) are all exposed by the `during` binding the
repository already pins; no spike is needed for them. `during` has no
directory-listing or `readlinkat` opcode, which is why those run on the
blocking pool.

## M0: the specification

**Obligations.** None verified; this milestone makes them reviewable.
**Deliverable.** `docs/specs/base/vfs/` with SPEC, PLAN, testing and
decisions, registered in the docs sidebar.
**Acceptance.** `dub run :ci -- --check-docs-sidebar`, `--check-vcs-urls` and
the docs site build pass; each requirement names an oracle. The independent
review item of the Stage 0 gate stays unmet until a second reviewer reads it.
**Excludes.** Code.

## M1: base vocabulary, algorithms and MemVfs

**Obligations.** `VFE1` (the base types), `VFE2`, `VFE5`; `VFP1`–`VFP8`; `VFR1`, `VFR2`,
`VFR4` (with a backend double); `VFO1`–`VFO8` on `MemVfs`; `VFH1`–`VFH6`;
`VFD1`–`VFD4`, `VFD6`, `VFD7`; `VFB1`, `VFB2`; `VFM1`–`VFM4`.
**Prerequisites.** S3, S4. Decide open question O1.
**Deliverable.** `sparkles.base.io.errors`; `sparkles.base.vfs` and its
`.walk`, `.remove`, `.write` and `.mem` modules, with unit tests in feature
modules, not `package.d`.
**Acceptance.**

```bash
dub test :base -- -i "vfs|io.errors"
```

Oracles 1 (the `MemVfs` columns), 2, 5 and the allocation check pass on the
Linux, macOS and Windows legs; the run reports a non-zero count of discovered
`vfs` tests.
**Excludes.** Native backends. Event-horizon keeps its own `IoError` until M3,
so this milestone adds `sparkles.base.io.errors` beside it.

## M2: the blocking backend

**Obligations.** `VFE3`, `VFE4`; `VFR3`, `VFR5`–`VFR8`; `VFH7`–`VFH9`; `VFD5`;
`VFB3`, `VFB6`; `VFO1`–`VFO8` and `VFD1`–`VFD7` on `BlockingVfs`.
**Prerequisites.** M1; S1; S2. Decide open question O2.
**Deliverable.** The `sparkles:event-horizon-sys` package with `BlockingVfs`
for Linux, macOS, Windows and a generic POSIX arm; the test-only switches for
forcing the component walk and forcing probe absence.
**Acceptance.** Oracles 1, 3, 4 (with two backends) and 6 pass on every leg.
`dub describe :event-horizon-sys` shows no dependency beyond base,
`expected` and `sparkles:reflection` (`VFB6`).
**Excludes.** The event loop; consumers.

## M3: the asynchronous backend and the unified errors

**Obligations.** `VFE1` in full (event-horizon's own error type removed);
`VFB4`, `VFB5`; `VFC2`.
**Prerequisites.** M2.
**Deliverable.** `RingVfs` and the `fs` capability on every loop backend;
event-horizon's `errors.d` reduced to re-exports; `fs.d`, `watch.d`,
`cgroup.d` and `sampling.d` migrated; the `Effect!T` forms.
**Acceptance.** Oracle 4 with all three backends on every leg; the full
event-horizon suite and every consumer of it (`http`, `ui-app`, `wsi`,
`terminal-view`) build and test at their previous counts.
**Excludes.** `TmpFS`; the fileset specification.

## M4: TmpFS

**Obligations.** `VFC1`.
**Prerequisites.** M2 (not M3: `TmpFS` depends on `sparkles:event-horizon-sys`
only).
**Deliverable.** `TmpFS` over `Dir!(BlockingVfs, Rights.all)`; `enforceBeneath`
removed; `test-utils` depends on `sparkles:event-horizon-sys`.
**Acceptance.** The twelve consumer suites keep their test counts:

| Package          | Tests at the checked revision |
| ---------------- | ----------------------------- |
| test-utils       | 11                            |
| build-primitives | 24                            |
| docs             | 64                            |
| wired            | 200                           |
| dmd-fmt          | 107, 1 skipped                |
| dmd-lsp          | 82                            |
| event-horizon    | 243, 7 skipped                |
| core-cli         | 101                           |
| raylib-text      | 18                            |
| ci               | 123                           |
| diagram          | 107                           |
| hue              | 432, 3 skipped                |

The counts must be re-measured at the start of M4, since other work lands in
between; the gate is "unchanged from that measurement".
**Excludes.** Any change to `TmpFS`'s public surface.

## M5: the fileset specification

**Obligations.** `VFC3`.
**Prerequisites.** M0 (the text only needs the contract, not the code).
**Deliverable.** The fileset specification's `FSD1`–`FSD7` and `FSM2`
rewritten to reference this specification; its `FSD6` statement about
`RESOLVE_NO_SYMLINKS` marked superseded; its decision A10 updated.
**Acceptance.** Docs checks pass, and a reading of the fileset specification
finds no normative text duplicating this one.
**Excludes.** Implementing the fileset machine.

## Progress

| Milestone | State       | Pull request |
| --------- | ----------- | ------------ |
| M0        | in review   | —            |
| M1–M5     | not started | —            |
