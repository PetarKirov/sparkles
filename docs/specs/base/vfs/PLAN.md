# Capability VFS — Delivery plan

_Companion to [SPEC.md](./SPEC.md) and [backends.md](./backends.md). Owns
delivery order, gates, milestone progress, and the migration of existing code
onto the interface. Requirements are defined only in the specification;
oracles and checks only in [testing.md](./testing.md)._

The work lands as a stacked series of pull requests, one per milestone, each
green on its own and each linking its predecessor. A milestone moves the
requirements it names from `unverified` to `verified` in the
[evidence ledger](./testing.md#evidence-ledger), naming the configuration.

## Feasibility spikes

Each spike answers one question before the milestone that depends on it
starts. A negative answer changes the specification first.

| Spike | Question                                                                                                                               | Experiment                                                                                                                              | Decision criterion                                                                                                                                                       | Blocks         |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------- |
| S1    | Does `O_NOFOLLOW_ANY` work on the `macos-latest` runner?                                                                               | a single-file probe opening a path with a symlinked intermediate, run on the macOS leg                                                  | refused with `ELOOP`: keep the macOS row of `VFN5`. Accepted or `EINVAL`: macOS reports `componentWalk` always                                                           | M2 macOS arm   |
| S2    | Can D call `NtCreateFile` with `RootDirectory` and `OBJ_DONT_REPARSE` on `windows-latest`, and pass an owner-only security descriptor? | declare the NT functions (druntime has none), link `ntdll`, open a child of a junction, create an owner-only file                       | returns `STATUS_REPARSE_POINT_ENCOUNTERED` and the created file's access control list has one entry: proceed. Otherwise record the failure and revisit `VFN5` or `VFN12` | M2 Windows arm |
| S3    | Does `-preview=dip1000` stop a `DirRef` from outliving its `Dir`?                                                                      | the compile-fail case from oracle 5, against a move-only owner like `sparkles.base.unique`                                              | the escape does not compile: keep `VFH2` as written. It compiles: `VFH2` becomes a documented rule plus a runtime check in debug builds                                  | M1             |
| S4    | Can rights be a compile-time flag set with readable errors, including the sharing tags?                                                | `Dir!(V, Rights.readOnly).removeTree`, `attenuate!(Rights.all)`, and `Shared()` without `createShared`, reading the compiler's messages | the messages name the missing right: proceed. Otherwise add a `static assert` with a message per operation                                                               | M1             |

### Results

Both M1 spikes ran on DMD 2.112.1 and LDC 1.42.0 with `-preview=dip1000
-preview=in`, against probes that model the handle types.

- **S3: positive; `VFH2` stands.** With `borrow()` declared `return` on the
  owner and every `DirRef` member declared `scope`, all four escapes fail to
  compile on both compilers: returning a borrow of a local, assigning one to
  a global, assigning one to a variable in an enclosing scope, and returning
  one from a non-`return` `ref` parameter. Using a borrow locally, passing it
  down as a `scope` parameter, and returning one from a `return ref`
  parameter all compile. Moving the owner while a borrow is alive is not
  caught, but the borrow then sees the moved-from owner's closed handle, so
  an operation through it fails rather than touching freed memory.
- **S1: positive; the macOS row of `VFN5` stands.** On macOS 27.0.1 arm64,
  `openat` with `O_NOFOLLOW_ANY` refuses a symlinked intermediate and a
  symlinked final component with `ELOOP`, and does not confine `..`, which
  is why the row needs `dotDot = reject`. The same machine showed that
  `O_SEARCH` opens a directory with mode `0111` where `O_RDONLY` fails with
  `EACCES`, which settled O5 (DV28).
- **S2: partly answered; real Windows decides the rest.** Under Wine 11, D
  calls `NtCreateFile` relative to a directory handle, deletes through
  `FileDispositionInformationEx`, and attaches a security descriptor to a
  new file. Wine cannot create a junction (`STATUS_NOT_SUPPORTED`), cannot
  resolve the symbolic links it reports creating, and does not keep a
  protected DACL, so `OBJ_DONT_REPARSE` through a link and the owner-only
  entry's single access-control entry wait for the Windows leg, where their
  tests are written and run.
- **S4: positive, with messages from `static assert`.** A template constraint
  per operation rejects every missing right on both compilers, and quotes
  the failed constraint (`R & Rights.remove`) rather than naming the right.
  A combined rights value prints as `cast(Rights)33u`. A `static assert` per
  operation instead reports, for example, "removeTree needs Rights.remove;
  this handle has Rights.readOnly". `__traits(compiles, …)` is false either
  way, so oracle 5 works with both. M1 uses the `static assert` form, with a
  compile-time formatter that lists a combined value's members.

The io_uring opcodes `VFB5` needs (`openat2`, `statx`, `mkdirat`, `unlinkat`,
`renameat`, `symlinkat`) are all exposed by the `during` binding the
repository pins; no spike is needed for them. `during` has no
directory-listing or `readlinkat` opcode, which is why those run on the
blocking pool.

## M0: the specification

**Obligations.** None verified; this milestone makes them reviewable.
**Deliverable.** `docs/specs/base/vfs/` with SPEC, backends, PLAN, testing and
decisions, registered in the docs sidebar, and the glossary entries its
opening relies on.
**Acceptance.** `dub run :ci -- --check-docs-sidebar`, `--check-glossary`,
`--check-vcs-urls` and the docs site build pass; every requirement has a row
in [testing.md § requirement checks](./testing.md#requirement-checks). The
independent-review item stays unmet until a second reviewer reads it.
**Excludes.** Code.

## M1: base vocabulary, algorithms and MemVfs

**Obligations.** `VFE1` (the base types), `VFE2`, `VFE4`; `VFP1`–`VFP8`;
`VFR2`, `VFR4` (with a backend double); `VFO1`–`VFO10` on `MemVfs`;
`VFH1`–`VFH6`; `VFD1`–`VFD5`; `VFB1`–`VFB3`; `VFM1`–`VFM5`.
**Prerequisites.** S3, S4 (both passed).
**Deliverable.** `sparkles.base.io.errors`; `sparkles.base.vfs` and its
`.walk`, `.remove`, `.write` and `.mem` modules, with unit tests in feature
modules, not `package.d`.
**Acceptance.**

```bash
dub test :base -- -i "vfs|io.errors"
```

Oracles 1 (the `MemVfs` columns), 2, 5 and the allocation check pass on the
Linux, macOS and Windows legs; the run reports a non-zero count of discovered
`vfs` tests. On Linux the allocation audit also passes:

```bash
dub test :base -c allocation-audit -- -i "vfs.allocation"
```

**Excludes.** Native backends. Event-horizon keeps its own `IoError` until M3,
so this milestone adds `sparkles.base.io.errors` beside it.

## M2: the blocking backend

**Obligations.** `VFE3`; `VFR1`, `VFR3`, `VFR5`, `VFR6`; `VFH7`, `VFH8`;
`VFN1`–`VFN14`; `VFB4`, `VFB6`; `VFO1`–`VFO10` and `VFD1`–`VFD5` on
`BlockingVfs`.
**Prerequisites.** M1; S1 (passed); S2.
**Deliverable.** The `sparkles:event-horizon-sys` package with `BlockingVfs`
for Linux, macOS, Windows and a generic POSIX arm; the test-only switches for
forcing the component walk and forcing probe absence.
**Acceptance.** Oracles 1, 3, 4 (with two backends) and 6 pass on every leg.
`dub describe :event-horizon-sys` shows no dependency beyond base,
`expected`, `sparkles:reflection` and `sparkles:metadata` (`VFB6`).
**Excludes.** The event loop; consumers.

## M3: the asynchronous backend and event-horizon's migration

**Obligations.** `VFE1` in full; `VFB5`; event-horizon's own
[§9.1](../../event-horizon/SPEC.md#_9-1-ioerror-and-ioresult) and
[§10.5](../../event-horizon/SPEC.md#_10-5-the-file-system).
**Prerequisites.** M2; event-horizon's open question
[O32](../../event-horizon/open-issues.md#o32-network-and-process-error-kinds)
decided.
**Deliverable.**

- `RingVfs`, and the `fs` member of the capability row on every loop backend.
- Event-horizon's `errors.d` reduced to re-exports plus `fromRes`; its
  `OpKind.statx` member renamed `statAt`.
- `RingFs`, its path-string functions (`openFile`, `statxPath`, `readText` by
  path) and the copyable `FileHandle` removed; the `io` verbs take any handle
  that lends a descriptor, as O32 decided.
- `cgroup.d` and `sampling.d` opening their `/sys/fs/cgroup` and `/proc` roots
  with `openRoot` and performing their relative operations through the
  resulting `Dir`.
- `Watcher.addWatch` taking a path together with an `AmbientAuthority`.
- The `Effect!T` forms of the `Dir` and `File` operations.

**Acceptance.** Oracle 4 with all three backends on every leg; no `atFdCwd`
constant and no raw `openat` or `mkdirat` declaration remain in
`sparkles:event-horizon`; the full event-horizon suite and every consumer of
it (`http`, `ui-app`, `wsi`, `terminal-view`) build and test at their previous
counts.
**Excludes.** `TmpFS`; the fileset specification.

## M4: TmpFS

**Obligations.** None of this specification's; this milestone moves
`sparkles:test-utils` onto the blocking backend.
**Prerequisites.** M2 (not M3: `TmpFS` depends on `sparkles:event-horizon-sys`
only).
**Deliverable.** `TmpFS` holds a `Dir!(BlockingVfs, Rights.all)` for its
scratch directory and performs every write, directory creation and removal
through it. Its public surface keeps `create`, `share`, `dir`, `writeFile`,
`writeFileAt`, `ensureSubdir` and `createdFiles`, and `dir()` still returns a
path string. A path that leaves the fixture remains an assertion failure at
`TmpFS`'s own boundary, because its input is trusted test code; the VFS
underneath still returns the error as a value. The string check
`enforceBeneath` is deleted, and `test-utils` depends on
`sparkles:event-horizon-sys`.
**Acceptance.** `refusesAPathThatLeavesTheFixture` passes, and the twelve
consumer suites keep their test counts:

| Package          | Tests before and after M4 |
| ---------------- | ------------------------- |
| test-utils       | 12                        |
| build-primitives | 30                        |
| docs             | 70                        |
| wired            | 243                       |
| dmd-fmt          | 108, 1 skipped            |
| dmd-lsp          | 96                        |
| event-horizon    | 243, 7 skipped            |
| core-cli         | 101                       |
| raylib-text      | 20                        |
| ci               | 150                       |
| diagram          | 110                       |
| hue              | 314, 3 skipped            |

The counts were measured on the branch just before the change and again
after it, on Linux x86_64; the gate is that they match. On macOS 27 arm64,
`test-utils` passes 11, its Linux-only exec test excluded.
**Excludes.** Any change to `TmpFS`'s public surface.

## M5: the fileset specification

**Obligations.** None of this specification's; this milestone rewrites the
fileset specification to rest on it.
**Prerequisites.** M0 (the text only needs the contract, not the code).
**Deliverable.** The fileset specification's drivers (`FSD1`–`FSD7`) and
request vocabulary (`FSM2`) state that its three drivers are this
specification's three backends and that its driver is one generic adapter over
`isVfs`. Its `FSD6` statement that `RESOLVE_NO_SYMLINKS` is not set is marked
superseded by [`VFO2`](./SPEC.md#vfo2-the-named-entry-is-never-followed):
reading a link's target is a single-name `readlinkAt`, and never needs a
lookup that follows. Its decision A10 is updated.
**Acceptance.** Docs checks pass, and a reading of the fileset specification
finds no normative text duplicating this one.
**Excludes.** Implementing the fileset machine.

## Progress

| Milestone | State                                                    | Pull request |
| --------- | -------------------------------------------------------- | ------------ |
| M0        | delivered; reshaped for readers and for creation sharing | #535, #594   |
| M1        | in review                                                | —            |
| M2        | implemented locally; Windows leg pending                 | —            |
| M3        | implemented locally                                      | —            |
| M4        | implemented locally                                      | —            |
| M5        | written locally                                          | —            |
