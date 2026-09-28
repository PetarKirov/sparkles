# Capability VFS — Decisions and open questions

_Companion to [SPEC.md](./SPEC.md). Each decision states its question, the
alternatives, the evidence, the choice and its trade-off, and when to revisit
it. All decisions below were **accepted** by the repository owner in a
four-round design review held from September 23 to 28, 2026, which followed
the [safe path traversal](../../../research/safe-path-traversal/index.md)
research catalog. It supersedes the earlier plan for a `sparkles.base.dir_handle`
module, which the owner rejected so that the research could be done first._

## Accepted

### DV1: The vocabulary lives in base; syscalls live in event-horizon

**Question.** Where does the directory-handle API live, given that
`sparkles:event-horizon` is meant to own every interaction with the OS?

**Alternatives.** (a) Everything in `sparkles:base`, blocking syscalls
included. (b) Everything in `sparkles:event-horizon`, with `TmpFS` depending
on it. (c) The vocabulary and algorithms in base, the syscalls in
event-horizon, split so that `TmpFS` can reach a blocking implementation
without the event loop.

**Evidence.** `sparkles:test-utils` sits inside the test runner's dependency
closure, so option (b) would compile the uring, kqueue and IOCP arms into
every package's `dub test`. Event-horizon's filesystem module had no arm on
kqueue, IOCP or select at all.

**Choice.** (c), with a new loop-free package, `sparkles:event-horizon-sys`,
holding the syscall bindings and `BlockingVfs`
([`VFB6`](./SPEC.md#vfb6-the-blocking-package-has-no-loop)). The same package
is event-horizon's blocking-pool arm on macOS and Windows.

**Revisit if** the test-runner closure stops including `test-utils`, which
would remove the reason for the split.

### DV2: Direct-style concept, not effect descriptions

**Question.** How does one vocabulary admit a backend that never suspends and
one that parks a fiber?

**Alternatives.** A Design-by-Introspection concept whose operations return
when complete, or operations that return `Effect!T` values run by an
interpreter, as in Effect TS.

**Choice.** The concept ([`VFB1`](./SPEC.md#vfb1-the-concept),
[`VFB2`](./SPEC.md#vfb2-direct-style)), with `Effect!T` forms generated on
top ([`VFB5`](./SPEC.md#vfb5-effect-wrappers)). What Effect TS contributes is
the discipline that a service is a value you must be handed; `Dir` is that
value. Effect descriptions would have moved `Effect!T` into base and put an
interpreter under every in-memory test.

**Revisit if** a consumer needs to inspect or rewrite a filesystem program
before running it.

### DV3: The fileset drivers are the VFS backends

The fileset specification's three drivers and this specification's three
backends are the same things, so they are one set
([`VFC3`](./SPEC.md#vfc3-fileset)). The fileset machine stays sans-I/O, and
its driver becomes a generic adapter over `isVfs`.

### DV4: One error vocabulary for every I/O operation

**Choice.** `IoError` with a portable `kind`, the raw `code`, `op`, `stage`
and `context`, owned by `sparkles.base.io.errors` and re-exported by
event-horizon ([`VFE1`](./SPEC.md#vfe1-one-error-type)). `OpKind` covers
every operation, filesystem, network and process, because a split enum cannot
be matched exhaustively.

**Trade-off.** Base now names network and process operations it does not
perform. Accepted: an enum of names costs nothing and has no dependencies.

### DV5: Threat model tier 2

The adversary can rename, replace and symlink inside the tree and race the
walk. An attacker who controls the mount table or `/proc`, or a directory
above the root, is out of scope ([threat model](./SPEC.md#threat-model)).
This is Go's `os.Root` boundary, not libpathrs's.

**Revisit if** a consumer runs privileged operations inside a tree an
untrusted party can mount into.

### DV6: Single-name operations, one multi-name entry point

Every `Dir` operation takes one name; `walk` and `walkAll` are the only
operations that take a path ([`VFO1`](./SPEC.md#vfo1-names),
[`VFO3`](./SPEC.md#vfo3-the-operation-set)). The guarantee of each
single-name operation is then one syscall with `O_NOFOLLOW`, and the resolver
is one function to verify. Following a symlink named as the final component
of a file open is deferred.

### DV7: No symlinks by default; beneath implemented too

**Alternatives.** Refuse every link (`RESOLVE_NO_SYMLINKS`, `O_NOFOLLOW_ANY`,
`OBJ_DONT_REPARSE`) or follow links that stay inside (`RESOLVE_BENEATH`).

**Choice.** Refusal is the default, because it is one flag on three kernels
and the only behaviour identical on every leg. `beneath` is implemented as an
option ([`VFP4`](./SPEC.md#vfp4-beneath)), because real trees contain
relative links, about 40% of them with `..`.

### DV8: Reject `..` by default; in-scope `..` as an option

The kernels disagree about `..`, so the default refuses it lexically before
any call ([`VFP5`](./SPEC.md#vfp5-reject-dot-dot)). The option keeps a stack of
entered directories and pops one per `..`, as cap-std does, rather than
restarting from the root as Go does; it needs no `/proc` and re-walks nothing
([`VFP6`](./SPEC.md#vfp6-in-scope-dot-dot)). `..` inside a symlink target is
always in scope under `beneath`, so the kernel and the walk agree.

### DV9: Never downgrade a lookup; cache absence only

A refused kernel lookup is the answer ([`VFR4`](./SPEC.md#vfr4-never-downgrade-a-lookup)).
Absence of the kernel resolver is cached one way; success never is
([`VFR5`](./SPEC.md#vfr5-availability-is-cached-one-way)). A root can report
and require its resolver ([`VFR2`](./SPEC.md#vfr2-the-root-reports-its-resolver),
[`VFR3`](./SPEC.md#vfr3-a-root-may-require-the-kernel-resolver)). The race
retry budget is 128, after libpathrs's measurement, and exhaustion is an
error, not a fallback ([`VFR6`](./SPEC.md#vfr6-race-retry-budget)).

### DV10: Platform accelerators

`openat2` on Linux, `O_NOFOLLOW_ANY` on macOS, and `OBJ_DONT_REPARSE` with a
one-way downgrade on Windows ([`VFR7`](./SPEC.md#vfr7-platform-accelerators)).
No surveyed consumer used `O_NOFOLLOW_ANY`; using it here is a deliberate
first, and it only covers the no-symlinks policy with mount crossing allowed.

### DV11: Rights in the type, attenuation only

Rights are a compile-time set on the handle type
([`VFH4`](./SPEC.md#vfh4-rights)–[`VFH6`](./SPEC.md#vfh6-rights-are-checked-at-compile-time)).
A child never has more rights than its parent. On Windows the set is also the
handle's real access mask ([`VFH7`](./SPEC.md#vfh7-rights-reach-the-os)).
The policy is a runtime value fixed at the root rather than a type parameter,
because it is a per-tree decision.

### DV12: The backend is part of the handle type

`Dir!(V, R)` holds the backend handle and a pointer to the backend, so the
handle is the whole capability and cannot be used with another backend
([`VFH1`](./SPEC.md#vfh1-owning-handles), [`VFH3`](./SPEC.md#vfh3-the-backend-is-part-of-the-type)).
A runtime-erased handle is deferred until a plug-in boundary needs one.

### DV13: Rename and atomic write are in v1

Atomic replacement is how files should be written, and io_uring and NT both
support a handle-relative rename. Exchange and no-replace flags are deferred
([`VFO7`](./SPEC.md#vfo7-rename-stays-in-the-root),
[`VFO8`](./SPEC.md#vfo8-atomic-write)).

### DV14: Windows directory handles allow delete sharing

Rust std keeps `FILE_SHARE_DELETE`; cap-std drops it so ancestors cannot be
renamed, at the cost of a racy path-based removal. Because this interface
holds handles and never re-resolves a path, an ancestor's rename does no harm,
so delete sharing is kept and removal goes through the handle
([`VFB3`](./SPEC.md#vfb3-the-blocking-backend)).

### DV15: Deletion uses a bounded explicit stack

([`VFD1`](./SPEC.md#vfd1-bounded-explicit-stack).) Most surveyed removers
recurse without a bound; gnulib's descriptor ring and CPython's explicit stack
are the exceptions. The bound is the fileset depth limit.

### DV16: Mount crossing is refused by default

`crossMounts = false` is the default
([`VFP7`](./SPEC.md#vfp7-mount-boundaries)), matching the fileset
specification's `FSD7`. No surveyed general-purpose resolver does this; it is
stricter than the field, on purpose. Outside Linux the check is a device
comparison that races with a concurrent mount, and the root reports that.

### DV17: Watching stays out of v1

`inotify_add_watch` has no handle-relative form. `Watcher.addWatch` takes a
path and an `AmbientAuthority`, so it is a visible escape hatch
([`VFC2`](./SPEC.md#vfc2-event-horizon)).

### DV18: Names

`sparkles.base.io.errors`, `sparkles.base.vfs` with `MemVfs` in `.mem`,
`sparkles:event-horizon-sys` with `BlockingVfs`, and `RingVfs` replacing
`RingFs`. "vfs" rather than "fs", because the in-memory backend is a real
backend and the interface is not a view of the host filesystem only.

## Open

### O1: Should `symlinkAt` refuse absolute targets?

cap-std refuses to create an absolute symlink so a sandboxed program cannot
plant a trap for other tools. The specification stores targets verbatim.
**Affects:** [`VFO3`](./SPEC.md#vfo3-the-operation-set). **Decide by:** the
base milestone ([PLAN M1](./PLAN.md#m1-base-vocabulary-algorithms-and-memvfs)).

### O2: Case-insensitive names on Windows

The Windows backend opens names case-insensitively, as the platform does;
`MemVfs` is case-sensitive. The differential excludes case-only differences.
Whether `MemVfs` should offer a case-insensitive mode for Windows parity is
open. **Affects:** oracle 4. **Decide by:** the blocking-backend milestone
([PLAN M2](./PLAN.md#m2-the-blocking-backend)).

### O3: Where `O_NOFOLLOW_ANY` is available

The research could not pin the macOS version that introduced
`O_NOFOLLOW_ANY` ([Darwin](../../../research/safe-path-traversal/darwin.md)).
Spike S1 in [PLAN.md](./PLAN.md#feasibility-spikes) answers it on the CI
runner. **Affects:** the macOS row of [`VFR7`](./SPEC.md#vfr7-platform-accelerators).

### O4: Platforms without a CI leg

FreeBSD and other POSIX systems get the component walk and no evidence. Using
FreeBSD's `O_RESOLVE_BENEATH`, which needs a behaviour probe because 13 and 14
differ, is deferred until a FreeBSD leg exists.
