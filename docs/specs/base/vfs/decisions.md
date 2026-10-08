# Capability VFS — Decisions and open questions

_Companion to [SPEC.md](./SPEC.md) and [backends.md](./backends.md). Each
decision states its question, the alternatives, the evidence, the choice and
its trade-off, and when to revisit it. DV1–DV18 were accepted by the
repository owner in a four-round design review held from September 23 to 28,
2026, which followed the
[safe path traversal](../../../research/safe-path-traversal/index.md) research
catalog and superseded an earlier plan for a `sparkles.base.dir_handle`
module. DV19–DV22 were accepted in an editorial review held from October 3 to
5, 2026, which reshaped the specification for its readers. DV23 was decided on
October 6, 2026. DV24–DV26 record what implementing the base milestone
changed, and DV27–DV28, decided on October 8, 2026, close the questions the
blocking backend needed answered, and DV29 records what writing it changed._

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

**Choice.** (c), with a loop-free package, `sparkles:event-horizon-sys`,
holding the syscall bindings and `BlockingVfs`
([`VFB6`](./backends.md#vfb6-the-blocking-package-has-no-loop)). The same
package is event-horizon's blocking-pool arm on macOS and Windows.

**Revisit if** the test-runner closure stops including `test-utils`, which
would remove the reason for the split.

### DV2: Direct-style concept, not effect descriptions

**Question.** How does one vocabulary admit a backend that never suspends and
one that parks a fiber?

**Alternatives.** A Design-by-Introspection concept whose operations return
when complete, or operations that return `Effect!T` values run by an
interpreter, as in Effect TS.

**Choice.** The concept ([`VFB1`](./backends.md#vfb1-the-concept),
[`VFB2`](./backends.md#vfb2-direct-style)), with `Effect!T` forms generated
on top by event-horizon
([event-horizon §10.5](../../event-horizon/SPEC.md#_10-5-the-file-system)).
What Effect TS contributes is the discipline that a service is a value you
must be handed; `Dir` is that value. Effect descriptions would have moved
`Effect!T` into base and put an interpreter under every in-memory test.

**Revisit if** a consumer needs to inspect or rewrite a filesystem program
before running it.

### DV3: The fileset drivers are the VFS backends

The fileset specification's three drivers and this specification's three
backends are the same things, so they are one set. The fileset machine stays
sans-I/O, and its driver becomes a generic adapter over `isVfs`
([PLAN M5](./PLAN.md#m5-the-fileset-specification)).

### DV4: One error vocabulary for every I/O operation

**Choice.** `IoError` with a portable `kind`, the raw `code`, `op`, `stage`
and `context`, owned by `sparkles.base.io.errors` and re-exported by
event-horizon ([`VFE1`](./SPEC.md#vfe1-one-error-type),
[event-horizon §9.1](../../event-horizon/SPEC.md#_9-1-ioerror-and-ioresult)).
`OpKind` covers every operation, filesystem, network and process, because a
split enum cannot be matched exhaustively.

**Trade-off.** Base names network and process operations it does not
perform. Accepted: an enum of names costs nothing and has no dependencies.

### DV5: Threat model tier 2

The adversary can rename, replace and symlink inside the tree and race the
walk. An attacker who controls the mount table or `/proc`, or a directory
above the root, is out of scope ([threat model](./SPEC.md#_3-threat-model)).
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
option ([`VFP5`](./SPEC.md#vfp5-beneath)), because real trees contain
relative links, about 40% of them with `..`.

### DV8: Reject `..` by default; in-scope `..` as an option

The kernels disagree about `..`, so the default refuses it lexically before
any call ([`VFP6`](./SPEC.md#vfp6-reject-dot-dot)). The option keeps a stack
of entered directories and pops one per `..`, as cap-std does, rather than
restarting from the root as Go does; it needs no `/proc` and re-walks nothing
([`VFP7`](./SPEC.md#vfp7-in-scope-dot-dot)). `..` inside a symlink target is
always in scope under `beneath`, so the kernel and the walk agree.

### DV9: Never downgrade a lookup; cache absence only

A refused kernel lookup is the answer ([`VFR4`](./SPEC.md#vfr4-never-downgrade-a-lookup)).
Absence of the kernel resolver is cached one way; success never is
([`VFR5`](./SPEC.md#vfr5-at-most-one-change),
[`VFN3`](./backends.md#vfn3-availability-is-cached-one-way)). A root can
report and require its resolver
([`VFR2`](./SPEC.md#vfr2-the-root-reports-its-resolver),
[`VFR3`](./SPEC.md#vfr3-a-root-may-require-the-kernel-resolver)). The race
retry budget is 128, after libpathrs's measurement, and exhaustion is an
error, not a fallback ([`VFR6`](./SPEC.md#vfr6-race-exhaustion-is-an-error)).

### DV10: Platform accelerators

`openat2` on Linux, `O_NOFOLLOW_ANY` on macOS, and `OBJ_DONT_REPARSE` with a
one-way downgrade on Windows
([`VFN5`](./backends.md#vfn5-platform-accelerators)). No surveyed consumer
used `O_NOFOLLOW_ANY`; using it here is a deliberate first, and it only covers
the no-symlinks policy with mount crossing allowed.

### DV11: Rights in the type, attenuation only

Rights are a compile-time set on the handle type
([`VFH4`](./SPEC.md#vfh4-rights)–[`VFH6`](./SPEC.md#vfh6-rights-are-checked-at-compile-time)).
A child never has more rights than its parent. On Windows the set is also the
handle's real access mask ([`VFN11`](./backends.md#vfn11-rights-reach-the-os)).
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
([`VFO8`](./SPEC.md#vfo8-rename-stays-in-one-root),
[`VFO9`](./SPEC.md#vfo9-atomic-write)).

### DV14: Windows directory handles allow delete sharing

Rust std keeps `FILE_SHARE_DELETE`; cap-std drops it so ancestors cannot be
renamed, at the cost of a racy path-based removal. Because this interface
holds handles and never re-resolves a path, an ancestor's rename does no harm,
so delete sharing is kept and removal goes through the handle
([`VFB4`](./backends.md#vfb4-the-blocking-backend)).

### DV15: Deletion uses a bounded explicit stack

([`VFD1`](./SPEC.md#vfd1-bounded-explicit-stack).) Most surveyed removers
recurse without a bound; gnulib's descriptor ring and CPython's explicit stack
are the exceptions. The bound is 64, the fileset specification's depth limit,
so any tree the fileset machine accepts can be removed.

### DV16: Mount crossing is refused by default

`crossMounts = false` is the default
([`VFP8`](./SPEC.md#vfp8-mount-boundaries)), matching the fileset
specification's `FSD7`. No surveyed general-purpose resolver does this; it is
stricter than the field, on purpose. Outside Linux the check is a device
comparison that races with a concurrent mount, and the root reports that
([`VFN6`](./backends.md#vfn6-the-mount-check)).

### DV17: Watching stays out of v1

`inotify_add_watch` has no handle-relative form. Event-horizon's
`Watcher.addWatch` takes a path and an `AmbientAuthority`, so it is a visible
escape hatch
([event-horizon §10.5](../../event-horizon/SPEC.md#_10-5-the-file-system)).

### DV18: Names

`sparkles.base.io.errors`, `sparkles.base.vfs` with `MemVfs` in `.mem`,
`sparkles:event-horizon-sys` with `BlockingVfs`, and `RingVfs` replacing
`RingFs`. "vfs" rather than "fs", because the in-memory backend is a real
backend and the interface is not a view of the host filesystem only.

### DV19: Why the interface exists

**Question.** What in the repository made a capability interface necessary,
rather than a hardened path helper?

**Evidence.** Three modules, checked against the tree when the specification
was written:

- `sparkles:test-utils`' `TmpFS` guarded against `..` with a string check and
  then wrote and deleted through `std.file`, by path.
- `sparkles:event-horizon`'s `fs.d` issued every operation with `AT_FDCWD` and
  a path string, exposed a copyable `int` as its file handle, and had no
  filesystem arm on kqueue, IOCP or select.
- The fileset specification requires its walker to hold handles, never
  paths, and to report when the kernel's containment guarantee is absent
  (`FSD5`–`FSD7`); no module provided that.

**Choice.** One interface for all three, built on directory handles, with the
migrations tracked as [PLAN.md](./PLAN.md) milestones M3–M5.

### DV20: The specification names providers, not consumers

**Question.** Should the specification name the code that uses it?

**Alternatives.** (a) Requirements that bind named consumers, such as `TmpFS`
or event-horizon's cgroup module. (b) Workloads described by role in the
introduction, with consumer migrations in the plan and in each consumer's own
specification.

**Choice.** (b). A protocol specification names its user agents by role,
never by website; a consumer that moves on, or a new one that arrives, should
not change this contract. The specification still names the packages that
**provide** it, because each obligation needs an owner. Obligations on
event-horizon's own surface, such as re-exporting the error vocabulary and
offering `fs` in its capability row, live in event-horizon's specification and
are linked from here.

### DV21: Event-horizon owns the contract

**Question.** Which package owns a contract whose types live in base?

**Choice.** `sparkles:event-horizon`. It owns every interaction between
Sparkles and the operating system, and this interface is the file-system part
of that. The vocabulary, the algorithms and `MemVfs` live in base, and the
blocking backend in `sparkles:event-horizon-sys`, only so that code which must
not depend on the event loop can use them ([DV1](#dv1-the-vocabulary-lives-in-base-syscalls-live-in-event-horizon)).

### DV22: Sharing of created entries

**Question.** Who may access a file or directory the interface creates, and
who decides?

**Alternatives.** The mode could be fixed (event-horizon's file module used
`0600`), passed per call as raw POSIX bits (Go's `os.Root.OpenFile`,
libpathrs), defaulted per root, or bounded per root by a floor that only
attenuation can tighten. On Windows an owner-only request could be honoured
with an explicit access control list, refused as `unsupported`, or ignored.

**Choice.**

- A portable argument per creating call: `Shared()`, the platform's ordinary
  sharing less the umask; `OwnerOnly()`; or `PosixMode(m)` under
  `version (Posix)` only ([`VFO5`](./SPEC.md#vfo5-sharing-of-created-entries)).
  `Shared()` is the default, so files come out as other tools create them.
- A per-root default given to `openRoot`, and a floor expressed as the
  `createShared` right. Without it, `Shared()` and `PosixMode` do not compile
  and the default narrows to `OwnerOnly()`. Reusing the rights mechanism gives
  the floor compile-time checking and attenuation for free; a separate type
  parameter would duplicate that machinery for one bit.
- Windows honours `OwnerOnly()` with a protected access control list
  ([`VFN12`](./backends.md#vfn12-sharing-on-each-platform)). Refusing would
  make portable callers branch by platform, and ignoring the request would be
  a silent downgrade of the kind [`VFR4`](./SPEC.md#vfr4-never-downgrade-a-lookup)
  forbids for links.
- An atomic write's replacement takes the requested sharing, not the replaced
  file's permissions ([`VFO9`](./SPEC.md#vfo9-atomic-write)); preserving them
  would make the result depend on history and could not cover Windows access
  control. A caller who wants the old bits reads them from `Stat`.
- No operation changes the umask, because it is process-wide and racy across
  threads. `MemVfs` records each entry's sharing so the differential can
  compare it ([`VFM5`](./backends.md#vfm5-sharing-is-recorded)).

**Revisit if** a consumer needs access control richer than owner-only versus
shared on Windows, or a floor finer than one bit.

### DV23: Symbolic link targets

**Question.** Should `symlinkAt` refuse targets that point outside the root?

**Alternatives.** (a) Store every target verbatim. (b) Refuse absolute
targets, as cap-std does. (c) Also refuse relative targets whose `..`
components climb above the root, judged from the depth at which the handle
was reached. (d) Allow an absolute target when the call passes
`ambientAuthority()`.

**Evidence.** No walk through this interface follows an absolute target, so
such a link only misleads tools that follow links. Whether a relative target
escapes depends on the link's position, which a later rename of the link or
of any directory above it changes; a creation-time check of (c) is defeated by
renaming a directory upwards, and could not be kept as a property of the
tree.

**Choice.** (b), for simplicity
([`VFO10`](./SPEC.md#vfo10-symbolic-link-targets)). It is one lexical check,
identical on every platform, and it closes the case cap-std closes. Code that
needs an absolute link creates it outside this interface.

**Revisit if** a consumer extracts archives through this interface and needs
protection against relative escaping links, the symlink variant of
zip-slip; (c) is the candidate then.

### DV24: Empty handles instead of no default constructor

**Question.** VFH1 first required owning handles to be non-default-
constructible. Can they be?

**Evidence.** `expected` 0.4 rejects a payload with `@disable this()` ("field
must be initialized in constructor"), and every operation returns its handle
in an `IoResult`.

**Choice.** Owners stay default-constructible. A default-initialized handle
is empty, and every operation on it fails with `other` and the context
`"empty handle"` rather than reaching the backend
([`VFH1`](./SPEC.md#vfh1-owning-handles)). The same holds for a borrow.

**Revisit if** `expected` accepts payloads without a default constructor.

### DV25: The open mode is a template argument

`openFile` takes its mode as a template argument, `openFile!(OpenMode.read)`,
because the rights a mode needs can only be checked at compile time
([`VFH6`](./SPEC.md#vfh6-rights-are-checked-at-compile-time)) if the mode is
known then ([`VFO4`](./SPEC.md#vfo4-open-modes)). A caller that chooses a mode
at run time branches over the modes it supports.

### DV26: Two limits the implementation needed

Splicing link targets into the rest of a walk needs a bounded buffer, so the
remaining path is limited to 4096 bytes, Linux's `PATH_MAX`; a longer one
fails with `nameTooLong`. Removing a directory that keeps receiving new
entries could loop forever, so `removeTree` lists such a directory again at
most 16 times and then fails with `notEmpty`
([§11](./SPEC.md#_11-limits)). Both were found writing M1; the second by the
race sweep of oracle 2.

### DV27: Case-insensitive names stay a native-leg concern (was O2)

`MemVfs` stays case-sensitive. The three-backend differential leaves out names
that differ only in case, and the Windows leg tests the platform's own case
behaviour. Case folding depends on the volume: NTFS uses its own upper-case
table, and a directory can be marked case-sensitive. A `MemVfs` mode would
model one approximation of that, and no consumer needs one.

**Revisit if** a consumer needs `MemVfs` to stand in for a Windows tree.

### DV28: Intermediate directories are opened for search (was O5)

**Question.** The component walk opened every intermediate directory with
read access, so on POSIX it needed read permission where `openat2` needs only
search permission, and the two resolvers disagreed (`VFR1`).

**Evidence.** On macOS 27, `openat(…, O_RDONLY | O_DIRECTORY)` of a
directory with mode `0111` fails with `EACCES`; `O_SEARCH` opens it, and
`openat` relative to that handle reaches its children.

**Choice.** A backend that can opens the directories a walk passes through
for search only: `O_PATH` on Linux, `O_SEARCH` on macOS and FreeBSD,
`FILE_TRAVERSE` on Windows. The walk opens the directory it returns with full
access, so it can be listed
([`VFN14`](./backends.md#vfn14-intermediate-directories-are-opened-for-search)).
The search-only handles never leave the walk, so the non-goal of handing out
handles that only locate an entry still holds. A POSIX system without such a
flag keeps read access, and has no kernel resolver to disagree with.

### DV29: What the native backends changed

Writing the blocking backend changed three things.

- **A listing owns its names.** A result that borrows a caller's stack buffer
  is `scope`, and `expected`'s destructor is not, so once a listing held a
  native pointer (a `DIR*`) it could not be destroyed in `@safe` code. A
  listing now holds a 1024-byte name buffer of its own, and `list()` takes no
  argument ([`VFO7`](./SPEC.md#vfo7-listing)).
- **The kernel's vaguer refusals are classified.** `OBJ_DONT_REPARSE` reports
  only that a path was not found when an intermediate is a file; the Windows
  backend steps through to name the kind, so both resolvers report
  `notADirectory` ([`VFN2`](./backends.md#vfn2-ambiguous-native-results)).
- **Handles have an escape hatch.** `backendHandle()` gives backend tests and
  descriptor-taking code the raw handle, the same capability in an honest
  name ([`VFH1`](./SPEC.md#vfh1-owning-handles)).

## Open

### O3: Where `O_NOFOLLOW_ANY` is available

The research could not pin the macOS version that introduced
`O_NOFOLLOW_ANY` ([Darwin](../../../research/safe-path-traversal/darwin.md)).
Spike S1 found it working on macOS 27.0.1; the CI runner's version is checked
by the macOS leg, and the backend's probe (`VFN3`) reports absence on an older
system rather than assuming. **Affects:** the macOS row of
[`VFN5`](./backends.md#vfn5-platform-accelerators).

### O4: Platforms without a CI leg

FreeBSD and other POSIX systems get the component walk and no evidence. Using
FreeBSD's `O_RESOLVE_BENEATH`, which needs a behaviour probe because 13 and 14
differ, is deferred until a FreeBSD leg exists.
