# Capability VFS — Testing and evidence

_Companion to [SPEC.md](./SPEC.md) and [backends.md](./backends.md). Owns the
oracles, the check for every requirement, and the evidence ledger. Delivery
order is in [PLAN.md](./PLAN.md)._

The trace every requirement needs is
`requirement -> falsifying scenario -> oracle -> scoped evidence`. This page
defines six oracles and an allocation check, says what each one is independent
of and what it cannot observe, and then lists the check for every requirement.

## Oracles at a glance

| Oracle                        | Runs on                                | Independent of                                    | Cannot observe                                       |
| ----------------------------- | -------------------------------------- | ------------------------------------------------- | ---------------------------------------------------- |
| 1. The attack table           | every backend, every leg               | the implementation: expectations are hand-derived | whether a refused object was read, on native legs    |
| 2. Scripted races             | `MemVfs`                               | real scheduling                                   | real kernel interleavings                            |
| 3. Kernel versus walk         | `BlockingVfs` on Linux, macOS, Windows | the component walk's code, and vice versa         | a bug the kernel and the walk share by design        |
| 4. Three-backend differential | all three backends                     | each backend's effect code                        | a bug in the shared algorithm code                   |
| 5. Compile-fail rights        | the compiler                           | runtime behaviour                                 | rights the OS enforces differently from the type     |
| 6. Native legs                | Linux, macOS, Windows CI               | the model                                         | platforms without a CI leg (FreeBSD and other POSIX) |
| Allocation instrumentation    | every backend                          | `@nogc` inference                                 | allocations outside the measured calls               |

Oracles 3 and 4 answer different questions. Oracle 3 proves the kernel
accelerator agrees with the portable floor. Oracle 4 proves the three
implementations of the floor agree with each other. A shared defect in the
algorithm code passes oracle 4 and is caught only by oracle 1's hand-derived
expectations.

A few checks need no oracle: a **unit** check is a plain unit test of one
type or value, and a **repository audit** is a search or `dub describe` over
the source tree.

## Oracle 1: the attack table

The table is adapted from Go's `rootTestCases`
([Go `os.Root`](../../../research/safe-path-traversal/go-os-root.md#how-it-works)),
extended with the policy columns and the mount and Windows rows Go does not
have. Every row builds its tree from a declared literal, calls `walk` (or the
named operation) on the root, and asserts the outcome in the column for the
active policy. Expectations are derived by hand from [SPEC.md](./SPEC.md), not
computed by any production code.

Each tree also contains a **sentinel**: a directory `outside/` beside the
root, holding `secret`. On `MemVfs` every refusal row additionally asserts
that no backend call touched a sentinel node. On native legs it asserts that
no handle was returned and that `outside/secret`'s content is unchanged; that
a refused row did not _read_ the sentinel is not observable natively, and is
proven only on `MemVfs`.

Policy columns: **N** = `symlinks none, dotDot reject` (the default);
**B** = `beneath, reject`; **BI** = `beneath, inScope`; **NI** =
`none, inScope`. `crossMounts` is `false` except where a row says otherwise.

| #   | Tree                                     | Operation                                | N                   | NI                  | B                   | BI                  |
| --- | ---------------------------------------- | ---------------------------------------- | ------------------- | ------------------- | ------------------- | ------------------- |
| 1   | `a/b/f`                                  | `walk("a/b")`                            | ok                  | ok                  | ok                  | ok                  |
| 2   | `a/b/f`                                  | `walk("./a//b/.")`                       | ok                  | ok                  | ok                  | ok                  |
| 3   | —                                        | `walk("/etc")`                           | escapesRoot         | escapesRoot         | escapesRoot         | escapesRoot         |
| 4   | —                                        | `walk("..")`                             | dotDotRefused       | escapesRoot         | dotDotRefused       | escapesRoot         |
| 5   | `a/`, `c/`                               | `walk("a/../c")`                         | dotDotRefused       | ok (`c`)            | dotDotRefused       | ok (`c`)            |
| 6   | `a/`                                     | `walk("a/../../x")`                      | dotDotRefused       | escapesRoot         | dotDotRefused       | escapesRoot         |
| 7   | `a/b/`, `s -> a`                         | `walk("s/b")`                            | symlinkRefused      | symlinkRefused      | ok (`a/b`)          | ok (`a/b`)          |
| 8   | `s -> /`                                 | `walk("s")`                              | symlinkRefused      | symlinkRefused      | escapesRoot         | escapesRoot         |
| 9   | `s -> ../outside`                        | `walk("s")`                              | symlinkRefused      | symlinkRefused      | escapesRoot         | escapesRoot         |
| 10  | chain `s1 -> a/s2`, `a/s2 -> ../b`, `b/` | `walk("s1")`                             | symlinkRefused      | symlinkRefused      | ok (`b`)            | ok (`b`)            |
| 11  | chain as 10 with `a/s2 -> ../../outside` | `walk("s1")`                             | symlinkRefused      | symlinkRefused      | escapesRoot         | escapesRoot         |
| 12  | cycle `s1 -> s2`, `s2 -> s1`             | `walk("s1")`                             | symlinkRefused      | symlinkRefused      | symlinkLoop         | symlinkLoop         |
| 13  | `a/b/`, `a/f/`, `s -> a/b`               | `walk("s/../f")`                         | dotDotRefused       | symlinkRefused      | dotDotRefused       | ok (`a/f`)          |
| 14  | `d/`, `d/d -> ..`                        | `walk("d/d")`                            | symlinkRefused      | symlinkRefused      | ok (root)           | ok (root)           |
| 15  | `f` (a file)                             | `walk("f/x")`                            | notADirectory       | notADirectory       | notADirectory       | notADirectory       |
| 16  | `a/`                                     | `walk("a/missing")`                      | notFound            | notFound            | notFound            | notFound            |
| 17  | `m/` on another device                   | `walk("m")`                              | crossesMount        | crossesMount        | crossesMount        | crossesMount        |
| 18  | as 17, `crossMounts = true`              | `walk("m")`                              | ok                  | ok                  | ok                  | ok                  |
| 19  | 41-link chain inside the root            | `walk("s1")`                             | symlinkRefused      | symlinkRefused      | symlinkLoop         | symlinkLoop         |
| 20  | 65 nested directories                    | `walkAll` of them                        | depthExceeded       | depthExceeded       | depthExceeded       | depthExceeded       |
| 21  | —                                        | `openDir("a\0b")`                        | invalidName         | invalidName         | invalidName         | invalidName         |
| 22  | —                                        | `openDir` of 256 bytes                   | nameTooLong         | nameTooLong         | nameTooLong         | nameTooLong         |
| 23  | `s -> outside/secret` (a file)           | `openFile("s", read)`                    | symlinkRefused      | symlinkRefused      | symlinkRefused      | symlinkRefused      |
| 24  | `s -> outside/`                          | `removeTree("s")`                        | ok, link removed    | ok, link removed    | ok, link removed    | ok, link removed    |
| 25  | —                                        | `symlinkAt("s", "/etc")`                 | escapesRoot         | escapesRoot         | escapesRoot         | escapesRoot         |
| 26  | `a/`                                     | `symlinkAt("s", "../../outside")` on `a` | ok, stored verbatim | ok, stored verbatim | ok, stored verbatim | ok, stored verbatim |

Rows 25 and 26 check that only absolute link targets are refused
([`VFO10`](./SPEC.md#vfo10-symbolic-link-targets)); on Windows, row 25 also
runs with `C:\x`, `\\server\share` and `\??\C:`.

Rows 23 and 24 check that the named entry is never followed
([`VFO2`](./SPEC.md#vfo2-the-named-entry-is-never-followed),
[`VFD2`](./SPEC.md#vfd2-never-descend-a-link)); in row 24 `outside/secret`
must survive. Row 13 is Go's `dotdot after symlink`: under **BI** the `..`
applies after the link is resolved, so the result is `a/f`, as on Unix.
Rows 3, 4, 6, 20, 21 and 22 must also leave `MemVfs`'s call counter at zero
where the refusal is lexical ([`VFM2`](./backends.md#vfm2-call-counter)).

The four remaining policies set `crossMounts = true`; rows 17 and 18 then
swap, and every other row's outcome is unchanged.

**Windows rows.** On the Windows leg rows 7–14 run a second time with
directory junctions in place of symlinks, because a junction needs no
privilege to create. Directory symlinks need developer mode or a privilege; a
leg without it records those rows as **not run**, not as passed. Three further
Windows-only rows use `openDir` with `CON`, `a:b` and `x.` and expect
`invalidName` ([`VFO1`](./SPEC.md#vfo1-names)).

## Oracle 2: scripted races

Each scenario runs on `MemVfs` with the interleaving hook
([`VFM3`](./backends.md#vfm3-interleaving-hook)) firing at a named call
index. Each names the attacker's action, the enforcement boundary, and the
forbidden effect it must not produce.

| #   | Setup and operation                                                 | Hook action (before call k)                             | Required outcome                                                                                                           |
| --- | ------------------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| R1  | `a/b/c/`, `secret` beside the root; **BI**, `walk("a/b/c/../../x")` | after `a/b/c` is opened, move `a/b` to `outside/b`      | the `..` steps return to held handles; the result is `a/x` or `notFound`, never `outside/x` (Go's `TestRootRaceRenameDir`) |
| R2  | `a/b/`; **N**, `walk("a/b")`                                        | after `a` is opened, replace `a/b` with `s -> /`        | `symlinkRefused`; no call touches a node outside the root                                                                  |
| R3  | as R2, **B**                                                        | as R2                                                   | `escapesRoot`                                                                                                              |
| R4  | `t/d/f`; `removeTree("t")`                                          | after `t` is listed, replace `t/d` with `s -> outside/` | the link is removed; `outside/secret` survives                                                                             |
| R5  | `t/a`, `t/b`; `removeTree("t")`                                     | after `t` is listed, remove `t/b`                       | success ([`VFD4`](./SPEC.md#vfd4-vanished-entries))                                                                        |
| R6  | `t/d/`; `removeTree("t")`                                           | after `t` is listed, replace `t/d` with a file          | the file is removed as an entry; success                                                                                   |
| R7  | root `r/a/`; `walk("a")` on a `Dir` for `r`                         | before the call, move `r` to `elsewhere/r`              | ok: the held root handle still names the moved directory                                                                   |
| R8  | `a/b/`; **N**, `walk("a/b")`                                        | after `a` is opened, mount a device on `a/b`            | `crossesMount`                                                                                                             |
| R9  | `f`; `writeFileAtomic("f", new)`                                    | at every call index in turn, read `f`                   | each read sees the complete old or the complete new content                                                                |

The suite runs each scenario once for every call the unraced operation
makes, firing the hook before that call, which covers every single-point
interleaving rather than one chosen index.

The hook proves the resolver's _logic_ under each interleaving. It does not
prove that a real kernel's interleavings are covered; that evidence comes
from oracle 6, which runs R1 and R4 natively with a concurrent renaming
thread for a fixed iteration count and a recorded seed.

## Oracle 3: kernel versus walk

On each leg with an accelerator, `BlockingVfs` exposes a test-only switch
that forces the component walk. Oracle 1's rows, and the native R1 and R4,
run twice: once with the accelerator and once forced onto the walk. The two
runs must return the same object, compared by `(device, inode)` or the
Windows file id **at test time**, or failures of the same kind
([`VFR1`](./SPEC.md#vfr1-two-resolvers-one-result),
[`VFE3`](./SPEC.md#vfe3-the-same-kind-from-either-resolver)). Comparing
identities is legitimate here: the test compares two results it holds, and
remembers nothing across time.

| Leg     | Accelerator        | Policies it covers         |
| ------- | ------------------ | -------------------------- |
| Linux   | `openat2`          | all eight                  |
| macOS   | `O_NOFOLLOW_ANY`   | **N** with `crossMounts`   |
| Windows | `OBJ_DONT_REPARSE` | **N**, both mount settings |

The same switch drives the one-way downgrade test for
[`VFR5`](./SPEC.md#vfr5-at-most-one-change) and
[`VFN3`](./backends.md#vfn3-availability-is-cached-one-way): force the probe
to report absence mid-run, then assert that a `requireKernel` root fails with
`unsupported` and an ordinary root reports `componentWalk`.

The no-downgrade and retry checks need a backend double, not a real kernel: a
`resolveWhole` that refuses or returns `EAGAIN`, and component primitives that
record calls. They live with oracle 3 because they test the same seam.

## Oracle 4: three-backend differential

One scenario list, written as data (tree literal, operation, expected
result), runs on `MemVfs`, `BlockingVfs` and `RingVfs`. After each scenario
the resulting tree is read back and compared with `MemVfs`'s. Native trees are
built by a small fixture writer in the test code, not by any library that is
itself built on `BlockingVfs`.

Excluded from the list, because `MemVfs` does not model them
([`VFM1`](./backends.md#vfm1-what-it-models)): names differing only in case,
hard links, reparse tags, and permissions other than the recorded sharing.
Each exclusion is covered by a native-only row in oracle 1 or 6. For sharing,
the scenario compares `MemVfs`'s recorded sharing
([`VFM5`](./backends.md#vfm5-sharing-is-recorded)) with the mode bits or
access control the native backend produced.

## Oracle 5: compile-fail rights

A table of `static assert(!__traits(compiles, …))` cases, one per operation
and missing right from the [operation set](./SPEC.md#vfo3-the-operation-set),
plus: widening through `attenuate`; a borrow escaping its owner under
`-preview=dip1000`; a handle of one backend passed to another; copying an
owning handle; `Shared()` or `PosixMode` on a handle without `createShared`;
`PosixMode` combined with `executable`; and `PosixMode` on Windows. A
matching positive `static assert` for each proves the case fails for the
intended reason and not a typo.

## Oracle 6: native legs

| Leg                     | Additionally covers                                                                                                                                                                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Linux (x86_64, aarch64) | a search-only directory (mode `0111`) walked through by both resolvers (`VFN14`); `openat2` flags, `RESOLVE_NO_XDEV` against a bind mount where the runner permits one, R1/R4 with a real renaming thread, created mode bits under a fixed umask |
| macOS                   | a search-only directory walked through by both resolvers; the `O_NOFOLLOW_ANY` probe and its reported `resolution`; `crossesMount` by device comparison, labelled racy; created mode bits under a fixed umask                                    |
| Windows                 | junctions, the forced `OBJ_DONT_REPARSE` downgrade, removal of a git repository's read-only objects ([`VFN13`](./backends.md#vfn13-windows-deletion)), non-inheritable handles, the access control list of owner-only and shared entries         |

A leg that cannot create a bind mount records the row as not run.

## Allocation

Every operation and algorithm runs under the libc allocation wrapper and the
GC counter that `sparkles:fuzzy` uses, on each backend. The expected count is
zero for every operation, including `MemVfs` with a pre-sized arena.

```bash
dub test :base -- -i "vfs.check.allocation"                    # GC counter
dub test :base -c allocation-audit -- -i "vfs.allocation"     # Linux: libc wrapped too
```

The audit configuration first calls `malloc` once and requires the wrapper to
count it, so a build without the `--wrap` flags fails instead of passing.

## Requirement checks

One row per requirement: the observation that would falsify it, and where
that observation is made.

### Handles and rights (`VFH`)

| Requirement                                                 | Check                                                                                                             | Oracle           |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ---------------- |
| [`VFH1`](./SPEC.md#vfh1-owning-handles)                     | the backend counts open handles; every test ends with none; an empty `.init` handle fails every operation         | 4                |
| [`VFH2`](./SPEC.md#vfh2-borrowed-handles)                   | a `@safe` function that returns a `DirRef` to a local `Dir` does not compile                                      | 5                |
| [`VFH3`](./SPEC.md#vfh3-the-backend-is-part-of-the-type)    | passing a `DirRef!(MemVfs, R)` as `renameAt`'s destination on a `Dir!(BlockingVfs, R)` does not compile           | 5                |
| [`VFH4`](./SPEC.md#vfh4-rights)                             | the presets' members are pinned by a `static assert`                                                              | unit             |
| [`VFH5`](./SPEC.md#vfh5-attenuation-only)                   | `attenuate!(Rights.all)` on a `readOnly` handle does not compile                                                  | 5                |
| [`VFH6`](./SPEC.md#vfh6-rights-are-checked-at-compile-time) | one compile-fail case per operation and missing right                                                             | 5                |
| [`VFH7`](./SPEC.md#vfh7-the-ambient-constructor)            | no call to a backend's native open outside backend modules; every `openRoot` call site names `ambientAuthority()` | repository audit |
| [`VFH8`](./SPEC.md#vfh8-handles-are-not-inherited)          | a child process spawned while a `Dir` is held has no descriptor referring to it                                   | 6                |

### Operations (`VFO`)

| Requirement                                                | Check                                                                                                                                                                | Oracle  |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| [`VFO1`](./SPEC.md#vfo1-names)                             | table-driven cases per platform, with the operation counter unchanged                                                                                                | 1       |
| [`VFO2`](./SPEC.md#vfo2-the-named-entry-is-never-followed) | each operation applied to a symlink whose target is a sentinel outside the root leaves the sentinel unopened and unchanged                                           | 1       |
| [`VFO3`](./SPEC.md#vfo3-the-operation-set)                 | each operation has a success and a failure case on every backend                                                                                                     | 4       |
| [`VFO4`](./SPEC.md#vfo4-open-modes)                        | one case per mode combination                                                                                                                                        | 4       |
| [`VFO5`](./SPEC.md#vfo5-sharing-of-created-entries)        | the compile-fail rows for sharing; created bits or access control per sharing; a create without the argument on an attenuated handle records `OwnerOnly` on `MemVfs` | 4, 5, 6 |
| [`VFO6`](./SPEC.md#vfo6-stat)                              | a stat without the time mask records no time lookup on `MemVfs`; on POSIX the permission bits of a created file read back as created                                 | 4       |
| [`VFO7`](./SPEC.md#vfo7-listing)                           | listing a directory twice through the same `Dir`, concurrently, yields the full set both times                                                                       | 4, 6    |
| [`VFO8`](./SPEC.md#vfo8-rename-stays-in-one-root)          | two roots over one directory; a rename between them fails and neither tree changes                                                                                   | 4       |
| [`VFO9`](./SPEC.md#vfo9-atomic-write)                      | R9; a reader loop concurrent with 1000 writes never sees a mixed or empty file on the Linux and Windows legs; the replacement has the requested sharing              | 2, 6    |
| [`VFO10`](./SPEC.md#vfo10-symbolic-link-targets)           | rows 25 and 26, with the operation counter unchanged after row 25                                                                                                    | 1       |

### Paths and resolution policy (`VFP`)

| Requirement                                          | Check                                                                                                     | Oracle  |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------- |
| [`VFP1`](./SPEC.md#vfp1-the-policy-value)            | a default-constructed policy has the stated values                                                        | unit    |
| [`VFP2`](./SPEC.md#vfp2-policy-is-fixed-at-the-root) | a handle obtained by `walk` reports the root's policy; no function other than `openRoot` accepts a policy | unit, 5 |
| [`VFP3`](./SPEC.md#vfp3-path-syntax)                 | rows 2 and 3, plus table-driven cases on `MemVfs` with the operation counter unchanged                    | 1       |
| [`VFP4`](./SPEC.md#vfp4-no-symlinks)                 | rows 7–14 and 19 under **N**/**NI**, with a sentinel beyond the link that is never opened                 | 1       |
| [`VFP5`](./SPEC.md#vfp5-beneath)                     | rows 7–14 and 19 under **B**/**BI**, on every backend                                                     | 1       |
| [`VFP6`](./SPEC.md#vfp6-reject-dot-dot)              | rows 4–6; `MemVfs`'s operation counter is unchanged after the call                                        | 1       |
| [`VFP7`](./SPEC.md#vfp7-in-scope-dot-dot)            | R1: a directory moved out of the root after being entered, then `..`, never reaches an object outside it  | 2       |
| [`VFP8`](./SPEC.md#vfp8-mount-boundaries)            | rows 17–18 and R8; `removeTree` over a mounted subtree on `MemVfs` leaves it untouched                    | 1, 2    |

### Resolution (`VFR`)

| Requirement                                                     | Check                                                                                                  | Oracle |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------ |
| [`VFR1`](./SPEC.md#vfr1-two-resolvers-one-result)               | every row runs on both resolvers and returns the same object or the same kind                          | 3      |
| [`VFR2`](./SPEC.md#vfr2-the-root-reports-its-resolver)          | each native leg's reported `resolution` and `mountCheck`, for each of the eight policies, match `VFN5` | 3, 6   |
| [`VFR3`](./SPEC.md#vfr3-a-root-may-require-the-kernel-resolver) | the macOS leg with the default policy fails with `unsupported`                                         | 6      |
| [`VFR4`](./SPEC.md#vfr4-never-downgrade-a-lookup)               | a backend double whose `resolveWhole` refuses: afterwards, no component primitive was called           | 3      |
| [`VFR5`](./SPEC.md#vfr5-at-most-one-change)                     | the forced-absence switch on each native leg                                                           | 3      |
| [`VFR6`](./SPEC.md#vfr6-race-exhaustion-is-an-error)            | a backend double that returns `EAGAIN` forever yields `raceRetryExhausted` after exactly 129 calls     | 3      |

### Deletion (`VFD`)

| Requirement                                                    | Check                                                                                                     | Oracle |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------ |
| [`VFD1`](./SPEC.md#vfd1-bounded-explicit-stack)                | a tree one level deeper than the removal limit fails with `depthExceeded`; a sentinel beside it survives  | 4      |
| [`VFD2`](./SPEC.md#vfd2-never-descend-a-link)                  | row 24 and R4: a link to a sentinel directory outside the tree; the sentinel's contents survive           | 1, 2   |
| [`VFD3`](./SPEC.md#vfd3-listing-until-empty)                   | a directory of 5000 entries is emptied in one call; R4 plants entries after a directory was emptied       | 4, 6   |
| [`VFD4`](./SPEC.md#vfd4-vanished-entries)                      | R5: entries removed from under the removal; the call succeeds                                             | 2      |
| [`VFD5`](./SPEC.md#vfd5-partial-progress-is-the-failure-state) | a directory made unremovable mid-tree; the error reports `unlinkAt` or `rmdirAt`, and a sentinel survives | 6      |

### Errors (`VFE`)

| Requirement                                                 | Check                                                                                                  | Oracle           |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------- |
| [`VFE1`](./SPEC.md#vfe1-one-error-type)                     | `sparkles.event_horizon.errors` declares no struct, and event-horizon's suite builds on the base types | repository audit |
| [`VFE2`](./SPEC.md#vfe2-error-kinds)                        | the enum's filesystem members are pinned by a `static assert`                                          | unit             |
| [`VFE3`](./SPEC.md#vfe3-the-same-kind-from-either-resolver) | oracle 3 compares kinds and requires equality                                                          | 3                |
| [`VFE4`](./SPEC.md#vfe4-operation-kinds)                    | a failure from each operation reports its own `OpKind`                                                 | 4                |

### Backends (`VFB`)

| Requirement                                                   | Check                                                                                                     | Oracle           |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ---------------- |
| [`VFB1`](./backends.md#vfb1-the-concept)                      | all three backends satisfy `isVfs`, and a type missing one primitive does not                             | 5                |
| [`VFB2`](./backends.md#vfb2-direct-style)                     | one algorithm instantiation per backend                                                                   | 4                |
| [`VFB3`](./backends.md#vfb3-the-whole-path-resolver)          | a backend double counts one `wholePathFor` per `openRoot`; a kernel root's walk calls only `resolveWhole` | 3                |
| [`VFB4`](./backends.md#vfb4-the-blocking-backend)             | oracles 1, 3, 4 and 6 on `BlockingVfs`                                                                    | 1, 3, 4, 6       |
| [`VFB5`](./backends.md#vfb5-the-asynchronous-backend)         | oracle 4 on each leg; a live environment on the select and IOCP backends contains `fs`                    | 4, 6             |
| [`VFB6`](./backends.md#vfb6-the-blocking-package-has-no-loop) | `dub describe :event-horizon-sys` lists only `sparkles:base`, `expected` and `sparkles:reflection`        | repository audit |

### Native backends (`VFN`)

| Requirement                                                                   | Check                                                                                              | Oracle |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------ |
| [`VFN1`](./backends.md#vfn1-kind-is-computed-once)                            | oracle 3 compares kinds across resolvers                                                           | 3      |
| [`VFN2`](./backends.md#vfn2-ambiguous-native-results)                         | one fixture per table row asserts the kind                                                         | 6      |
| [`VFN3`](./backends.md#vfn3-availability-is-cached-one-way)                   | the forced-absence switch, as for `VFR5`                                                           | 3      |
| [`VFN4`](./backends.md#vfn4-race-retries)                                     | the `EAGAIN` double, as for `VFR6`                                                                 | 3      |
| [`VFN5`](./backends.md#vfn5-platform-accelerators)                            | each leg's reported `resolution` per policy matches the table; oracle 3 passes on Linux            | 3, 6   |
| [`VFN6`](./backends.md#vfn6-the-mount-check)                                  | the bind-mount row on Linux where permitted; macOS reports `racy`                                  | 6      |
| [`VFN7`](./backends.md#vfn7-the-windows-component-walk)                       | the Windows leg with real junctions and directory symlinks, the downgrade forced                   | 6      |
| [`VFN8`](./backends.md#vfn8-windows-dot-dot)                                  | the **NI** and **BI** rows with `..` on the Windows leg, junctions in place of links               | 1, 6   |
| [`VFN9`](./backends.md#vfn9-no-follow)                                        | the `VFO2` check on every native leg                                                               | 1, 6   |
| [`VFN10`](./backends.md#vfn10-listing-through-a-fresh-handle)                 | the `VFO7` check on every native leg                                                               | 6      |
| [`VFN11`](./backends.md#vfn11-rights-reach-the-os)                            | on Windows, a read-only `File`'s queried access mask excludes `FILE_WRITE_DATA`                    | 6      |
| [`VFN12`](./backends.md#vfn12-sharing-on-each-platform)                       | mode bits under a fixed umask on POSIX; the queried access control list on Windows                 | 6      |
| [`VFN13`](./backends.md#vfn13-windows-deletion)                               | the Windows leg removes a tree containing a git repository's read-only object files                | 6      |
| [`VFN14`](./backends.md#vfn14-intermediate-directories-are-opened-for-search) | a walk through a directory with mode `0111` succeeds on both resolvers on the Linux and macOS legs | 3, 6   |

### The in-memory backend (`VFM`)

| Requirement                                      | Check                                                                                                 | Oracle     |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | ---------- |
| [`VFM1`](./backends.md#vfm1-what-it-models)      | oracle 1 runs on `MemVfs` with the native legs' expected outcomes, except the rows marked native-only | 1          |
| [`VFM2`](./backends.md#vfm2-call-counter)        | a successful single-name open increments exactly one counter by one                                   | unit       |
| [`VFM3`](./backends.md#vfm3-interleaving-hook)   | each oracle 2 scenario fires the hook at a chosen call index and asserts the outcome                  | 2          |
| [`VFM4`](./backends.md#vfm4-arena)               | an arena sized for N nodes accepts N and refuses the next; no GC allocation is recorded               | allocation |
| [`VFM5`](./backends.md#vfm5-sharing-is-recorded) | oracle 4 compares the recorded sharing with the native result                                         | 4          |

## Worked traces

Three traces for adversarial review. Each is the sequence of backend calls a
conforming implementation makes.

**Success, Linux, default policy.** `root.walk("a/b")`: lexical checks pass;
the root's resolution is `kernelWholePath`; one call,
`openat2(root, "a/b", O_DIRECTORY | O_CLOEXEC, RESOLVE_BENEATH |
RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV)`; the result is
a `Dir` with the root's rights and policy.

**Failure, a symlink swapped in, macOS, default policy.** The resolution is
`componentWalk`, because the default `crossMounts = false` is not covered by
`O_NOFOLLOW_ANY` ([`VFN5`](./backends.md#vfn5-platform-accelerators)).
`openat(root, "a", O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` succeeds; the
attacker replaces `a/b` with a symlink; `openat(a, "b", …)` fails with
`ELOOP` or `ENOTDIR`; `fstatat(a, "b", AT_SYMLINK_NOFOLLOW)` reports a link;
the kind is `symlinkRefused` ([`VFN2`](./backends.md#vfn2-ambiguous-native-results));
the handle for `a` is closed; nothing beyond the link was opened.

**Boundary, `..` at the root, in-scope policy.** `root.walk("a/../..")`: the
walk enters `a` and pushes the root's handle; the first `..` pops back to the
root; the second `..` finds the stack empty and fails with `escapesRoot`
without a backend call ([`VFP7`](./SPEC.md#vfp7-in-scope-dot-dot)).

## Evidence ledger

| Requirements                                                                                                                      | State                | Evidence                                                                                                                                                                                                                                               | Gap                                                                                                                                        |
| --------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `VFE1`, `VFE2`, `VFE4`; `VFP1`–`VFP8`; `VFR2`, `VFR4`; `VFO1`–`VFO10`; `VFH1`–`VFH6`; `VFD1`–`VFD5`; `VFB1`–`VFB3`; `VFM1`–`VFM5` | verified on `MemVfs` | oracles 1, 2, 5, the requirement checks and the allocation audit: `dub test :base`, 50 tests, on Linux x86_64 (LDC 1.42.0, DMD 2.112.1) and macOS 27 arm64 (LDC 1.42.0); the same tests cross-built for `x86_64-pc-windows-msvc` and run under Wine 11 | Windows itself runs only in CI; Wine is not Windows; on `MemVfs`, `VFP8` exercises only the device comparison, and `VFR4` a backend double |
| every other requirement, `VFR1` included                                                                                          | unverified           | —                                                                                                                                                                                                                                                      | needs a native backend; `VFR1` needs a kernel resolver to compare with (oracle 3)                                                          |

The independent-review item of the specification's acceptance gate is
**unmet**: the specification was written by the same agent that ran the
design review, and no second reviewer has inspected it.
