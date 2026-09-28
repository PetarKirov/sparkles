# Capability VFS — Testing and evidence

_Companion to [SPEC.md](./SPEC.md). Owns the oracles, the acceptance
scenarios, and the evidence ledger. Delivery order is in [PLAN.md](./PLAN.md)._

The trace every requirement needs is
`requirement -> falsifying scenario -> oracle -> scoped evidence`. This page
defines six oracles and an allocation check, says what each one is independent
of, and states what it cannot observe.

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

| #   | Tree                                     | Operation              | N                | NI               | B                | BI               |
| --- | ---------------------------------------- | ---------------------- | ---------------- | ---------------- | ---------------- | ---------------- |
| 1   | `a/b/f`                                  | `walk("a/b")`          | ok               | ok               | ok               | ok               |
| 2   | `a/b/f`                                  | `walk("./a//b/.")`     | ok               | ok               | ok               | ok               |
| 3   | —                                        | `walk("/etc")`         | escapesRoot      | escapesRoot      | escapesRoot      | escapesRoot      |
| 4   | —                                        | `walk("..")`           | dotDotRefused    | escapesRoot      | dotDotRefused    | escapesRoot      |
| 5   | `a/`, `c/`                               | `walk("a/../c")`       | dotDotRefused    | ok (`c`)         | dotDotRefused    | ok (`c`)         |
| 6   | `a/`                                     | `walk("a/../../x")`    | dotDotRefused    | escapesRoot      | dotDotRefused    | escapesRoot      |
| 7   | `a/b/`, `s -> a`                         | `walk("s/b")`          | symlinkRefused   | symlinkRefused   | ok (`a/b`)       | ok (`a/b`)       |
| 8   | `s -> /`                                 | `walk("s")`            | symlinkRefused   | symlinkRefused   | escapesRoot      | escapesRoot      |
| 9   | `s -> ../outside`                        | `walk("s")`            | symlinkRefused   | symlinkRefused   | escapesRoot      | escapesRoot      |
| 10  | chain `s1 -> a/s2`, `a/s2 -> ../b`, `b/` | `walk("s1")`           | symlinkRefused   | symlinkRefused   | ok (`b`)         | ok (`b`)         |
| 11  | chain as 10 with `a/s2 -> ../../outside` | `walk("s1")`           | symlinkRefused   | symlinkRefused   | escapesRoot      | escapesRoot      |
| 12  | cycle `s1 -> s2`, `s2 -> s1`             | `walk("s1")`           | symlinkRefused   | symlinkRefused   | symlinkLoop      | symlinkLoop      |
| 13  | `a/b/`, `a/f/`, `s -> a/b`               | `walk("s/../f")`       | dotDotRefused    | symlinkRefused   | dotDotRefused    | ok (`a/f`)       |
| 14  | `d/`, `d/d -> ..`                        | `walk("d/d")`          | symlinkRefused   | symlinkRefused   | ok (root)        | ok (root)        |
| 15  | `f` (a file)                             | `walk("f/x")`          | notADirectory    | notADirectory    | notADirectory    | notADirectory    |
| 16  | `a/`                                     | `walk("a/missing")`    | notFound         | notFound         | notFound         | notFound         |
| 17  | `m/` on another device                   | `walk("m")`            | crossesMount     | crossesMount     | crossesMount     | crossesMount     |
| 18  | as 17, `crossMounts = true`              | `walk("m")`            | ok               | ok               | ok               | ok               |
| 19  | 41-link chain inside the root            | `walk("s1")`           | symlinkRefused   | symlinkRefused   | symlinkLoop      | symlinkLoop      |
| 20  | 65 nested directories                    | `walkAll` of them      | depthExceeded    | depthExceeded    | depthExceeded    | depthExceeded    |
| 21  | —                                        | `openDir("a\0b")`      | invalidName      | invalidName      | invalidName      | invalidName      |
| 22  | —                                        | `openDir` of 256 bytes | nameTooLong      | nameTooLong      | nameTooLong      | nameTooLong      |
| 23  | `s -> outside/secret` (a file)           | `openFile("s", read)`  | symlinkRefused   | symlinkRefused   | symlinkRefused   | symlinkRefused   |
| 24  | `s -> outside/`                          | `removeTree("s")`      | ok, link removed | ok, link removed | ok, link removed | ok, link removed |

Rows 23 and 24 check that the named entry is never followed
([`VFO2`](./SPEC.md#vfo2-the-named-entry-is-never-followed),
[`VFD2`](./SPEC.md#vfd2-never-descend-a-link)); in row 24 `outside/secret`
must survive. Row 13 is Go's `dotdot after symlink`: under **BI** the `..`
applies after the link is resolved, so the result is `a/f`, as on Unix.
Rows 3, 4, 6, 20, 21 and 22 must also leave `MemVfs`'s call counter at zero
where the refusal is lexical ([`VFM2`](./SPEC.md#vfm2-call-counter)).

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
([`VFM3`](./SPEC.md#vfm3-interleaving-hook)) firing at a named call index.
Each names the attacker's action, the enforcement boundary, and the forbidden
effect it must not produce.

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
[`VFE3`](./SPEC.md#vfe3-kind-is-computed-once)). Comparing
identities is legitimate here: the test compares two results it holds, and
remembers nothing across time.

| Leg     | Accelerator        | Policies it covers         |
| ------- | ------------------ | -------------------------- |
| Linux   | `openat2`          | all eight                  |
| macOS   | `O_NOFOLLOW_ANY`   | **N** with `crossMounts`   |
| Windows | `OBJ_DONT_REPARSE` | **N**, both mount settings |

The same switch drives the one-way downgrade test for
[`VFR5`](./SPEC.md#vfr5-availability-is-cached-one-way): force the probe to
report absence mid-run, then assert that a `require` root fails with
`unsupported` and an ordinary root reports `componentWalk`.

The `VFR4` no-downgrade check needs a backend double, not a real kernel: a
`resolveWhole` that refuses, and component primitives that record calls. It
lives with oracle 3 because it tests the same seam.

## Oracle 4: three-backend differential

One scenario list, written as data (tree literal, operation, expected
result), runs on `MemVfs`, `BlockingVfs` and `RingVfs`. After each scenario
the resulting tree is read back and compared with `MemVfs`'s. Native trees are
built by a small fixture writer in the test code, not by `TmpFS`, which is
itself a consumer of `BlockingVfs`.

Excluded from the list, because `MemVfs` does not model them
([`VFM1`](./SPEC.md#vfm1-what-it-models)): names differing only in case,
permissions, hard links and reparse tags. Each exclusion is covered by a
native-only row in oracle 1 or 6.

## Oracle 5: compile-fail rights

A table of `static assert(!__traits(compiles, …))` cases, one per operation
and missing right from the [operation set](./SPEC.md#vfo3-the-operation-set),
plus: widening through `attenuate`, a borrow escaping its owner under
`-preview=dip1000`, a handle of one backend passed to another, and copying an
owning handle. A matching positive `static assert` for each proves the case
fails for the intended reason and not a typo.

## Oracle 6: native legs

| Leg                     | Additionally covers                                                                                                                                                      |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Linux (x86_64, aarch64) | `openat2` flags, `RESOLVE_NO_XDEV` against a bind mount where the runner permits one, R1/R4 with a real renaming thread                                                  |
| macOS                   | the `O_NOFOLLOW_ANY` probe and its reported `resolution`; `crossesMount` by device comparison, labelled racy                                                             |
| Windows                 | junctions, the forced `OBJ_DONT_REPARSE` downgrade, removal of a git repository's read-only objects ([`VFD5`](./SPEC.md#vfd5-windows-deletion)), non-inheritable handles |

A leg that cannot create a bind mount records the row as not run.

## Allocation

Every operation and algorithm runs under the libc allocation wrapper and the
GC counter that `sparkles:fuzzy` uses, on each backend. The expected count is
zero for every operation, including `MemVfs` with a pre-sized arena.

## Worked traces

Three traces for the Stage 0 adversarial review. Each is the sequence of
backend calls a conforming implementation makes.

**Success, Linux, default policy.** `root.walk("a/b")`: lexical checks pass;
the root's resolution is `kernelWholePath`; one call,
`openat2(root, "a/b", O_DIRECTORY | O_CLOEXEC, RESOLVE_NO_SYMLINKS |
RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV)`; the result is a `Dir` with the
root's rights and policy.

**Failure, a symlink swapped in, macOS, default policy.** The resolution is
`componentWalk`, because the default `crossMounts = false` is not covered by
`O_NOFOLLOW_ANY` ([`VFR7`](./SPEC.md#vfr7-platform-accelerators)).
`openat(root, "a", O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` succeeds; the
attacker replaces `a/b` with a symlink; `openat(a, "b", …)` fails with
`ELOOP` or `ENOTDIR`; `fstatat(a, "b", AT_SYMLINK_NOFOLLOW)` reports a link;
the kind is `symlinkRefused` ([`VFE4`](./SPEC.md#vfe4-native-mapping)); the
handle for `a` is closed; nothing beyond the link was opened.

**Boundary, `..` at the root, in-scope policy.** `root.walk("a/../..")`: the
walk enters `a` and pushes the root's handle; the first `..` pops back to the
root; the second `..` finds the stack empty and fails with `escapesRoot`
without a backend call ([`VFP6`](./SPEC.md#vfp6-in-scope-dot-dot)).

## Evidence ledger

| Requirements      | State      | Evidence | Gap                      |
| ----------------- | ---------- | -------- | ------------------------ |
| every requirement | unverified | —        | no implementation exists |

The Stage 0 gate's independent-review item is **unmet**: this specification
was written by the same agent that ran the design review, and no second
reviewer has inspected it.
