# Capability VFS — Specification

_**Status:** proposed; no requirement is implemented · **Date:** September 28, 2026
· **Owners:** `sparkles:base` (vocabulary, algorithms, in-memory backend),
`sparkles:event-horizon-sys` (blocking backend), `sparkles:event-horizon`
(async backend)_

_Normative at the contract level. Delivery order and gates live in
[PLAN.md](./PLAN.md), oracles and evidence in [testing.md](./testing.md), and
the reasoning behind each consequential choice in [decisions.md](./decisions.md).
The evidence base is the [safe path traversal](../../../research/safe-path-traversal/index.md)
research catalog; its [comparison](../../../research/safe-path-traversal/comparison.md)
is the argument this contract acts on._

## Purpose and scope

A path string is an indirect pointer. Every component can be re-bound by
anyone who can write the directory holding it, between the moment a program
checks a path and the moment it uses it
([Bishop & Dilger](../../../research/safe-path-traversal/bishop-dilger-1996.md)).
Thirty years of attempts to win that race by being fast have failed
([Cai et al.](../../../research/safe-path-traversal/cai-2009.md)). What
survived is walking once, from a held directory handle, refusing links on the
way ([concepts § the fix](../../../research/safe-path-traversal/concepts.md#the-fix)).

This specification defines a filesystem interface built only from that
primitive. A program reaches a file through a **directory capability**: an
open directory handle, carrying a fixed set of rights and a fixed resolution
policy, from which every further object is opened by a single name. Nothing
below the one ambient constructor accepts a path to resolve from the process
root.

Three problems in the repository motivate it, each verified against the
current tree:

- `sparkles:test-utils`' `TmpFS` guards against `..` with a string check and
  then writes and deletes through `std.file`, by path.
- `sparkles:event-horizon`'s `fs.d` issues every operation with `AT_FDCWD` and
  a path string, exposes a copyable `int` as its file handle, and has no
  filesystem arm at all on kqueue, IOCP or select.
- The fileset specification requires the walker to hold handles, never paths,
  and to report when the kernel's containment guarantee is absent
  ([`FSD5`–`FSD7`](../../build-primitives/filesets/SPEC.md)).
  No module provides that today.

**In scope.** The error vocabulary shared with `sparkles:event-horizon`; the
handle, rights and policy types; the single-name operations; the multi-name
algorithms (walk, create-parents, tree removal, atomic write); three backends
(in-memory, blocking, asynchronous); the kernel accelerators on Linux, macOS
and Windows; the migration of `TmpFS`, event-horizon's filesystem modules, and
the fileset specification onto this interface.

**Non-goals.** These are deliberately not defended and not provided:

- An attacker who can change the **mount table**, overmount `/proc`, or plant
  procfs magic links in a way `RESOLVE_NO_MAGICLINKS` does not stop. That is
  "strict" path safety, a container-runtime concern
  ([procfs magic links](../../../research/safe-path-traversal/linux-procfs-magic-links.md)).
- An attacker who controls a directory **above** the root.
- Changing permissions, ownership or timestamps; hard-link creation; extended
  attributes; filesystem watching; a located-but-not-opened (`O_PATH`) handle
  kind; runtime-erased handles; rename flags beyond replace.
- Migrating the repository's other `std.file` call sites.

**Deferred, with entry conditions.** A handle-based watch surface enters when
`sparkles:event-horizon` specifies its watcher redesign. A runtime-erased
`AnyDir` enters when a consumer needs to cross a plug-in boundary. Following a
symlink named as the **final** component of a file open enters when a consumer
needs it.

## Threat model

**Attacker-controlled inputs.** The contents of the tree beneath a root,
changed concurrently with any operation: entries created, removed, renamed,
replaced by symlinks, directory junctions or other directories, and
directories moved elsewhere. Every relative path and every name passed to an
operation. The target text of every symlink met.

**Trusted.** The root directory handle once `openRoot` returns it, and the
path given to `openRoot`. The mount table and `/proc`. Code holding an
`AmbientAuthority` token.

**Enforcement boundary.** The backend call that opens, creates, lists, reads,
writes or removes. Checks made anywhere else are advisory.

**Forbidden effect.** Through a directory capability derived from root `R`, no
operation may read, write, create, list or remove an object that was not
_beneath `R`_ at the moment of the step that reached it.

**Beneath** is defined operationally. An object is beneath `R` if it was
reached from `R` by a chain of steps, where each step opened one directory
entry relative to the handle the previous step returned, no step followed a
symlink except as the active policy permits
([resolution policy](#resolution-policy-vfp)), and no `..` step climbed above `R`. The
definition refers only to handles held at the time; it never refers to a path
string. A directory that is moved away after it was opened remains beneath
`R` for operations through the handle already held. That is the property the
handle exists to provide
([comparison § axis 5](../../../research/safe-path-traversal/comparison.md#axis-5-identity)).

## Package layout and dependencies

| Package                      | Owns                                                                                                       | Depends on                         |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `sparkles:base`              | `sparkles.base.io.errors`; `sparkles.base.vfs` vocabulary; `.walk`, `.remove`, `.write` algorithms; `.mem` | nothing new                        |
| `sparkles:event-horizon-sys` | syscall bindings; `BlockingVfs` in `sparkles.event_horizon.sys.vfs`                                        | `sparkles:base`                    |
| `sparkles:event-horizon`     | `RingVfs` in `sparkles.event_horizon.fs`; the `fs` capability; re-export of the error vocabulary           | `sparkles:event-horizon-sys`, base |
| `sparkles:test-utils`        | `TmpFS` over `BlockingVfs`                                                                                 | `sparkles:event-horizon-sys`       |
| `sparkles:build-primitives`  | the fileset driver, generic over any backend                                                               | base                               |

The last column lists package dependencies. `sparkles:event-horizon-sys` has no
event loop and no dependency on `sparkles:event-horizon`; that is what lets
`TmpFS`, which sits in every package's test closure, depend on it
([`VFB6`](#vfb6-the-blocking-package-has-no-loop)).

Each obligation below has one owner. The error vocabulary, the handle and
rights types, the policy, the resolver algorithms and the in-memory backend
belong to `sparkles:base`. Mapping native results into that vocabulary belongs
to the backend that performs the syscall. Event-horizon's own specification
owns the mapping of network and process operations into the same vocabulary;
this document owns only the filesystem part.

## Invariants

Every later requirement is read against these.

1. **One ambient entry point.** Below `openRoot`, no function in this
   interface resolves a path from the process root or current directory.
   Every operation names its target by a handle and one name.
2. **Authority only attenuates.** A handle derived from another never carries
   more rights than its source, and never a different policy.
3. **One resolver per call.** A lookup that the kernel resolver refused is
   never retried with the component walk.
4. **Errors are values.** Operations return `IoResult!T`. No caller-supplied
   name, path or filesystem state causes an assertion failure.
5. **Bounded and attribute-clean.** Every operation and algorithm is
   `@safe nothrow @nogc`, and memory is bounded by the configured limits
   ([limits](#limits)). `@nogc` is necessary and not accepted as proof;
   allocation is measured ([testing.md](./testing.md#allocation)).
6. **The held handle is the identity.** No operation remembers a path, or a
   `(device, inode)` pair, to recognise an object later. The one exception is
   the mount check's device comparison, which is documented as racy where it
   is the only mechanism ([`VFP7`](#vfp7-mount-boundaries)).

## Errors (`VFE`)

<a id="vfe1-one-error-type"></a>
**`VFE1` — One error type.** Every operation in this interface and every
operation in `sparkles:event-horizon` returns
`IoResult!T = Expected!(T, IoError, NoGcHook)`, where:

```d
struct IoError
{
    ErrorKind kind;     // portable classification; what callers match on
    int code;           // raw errno or NTSTATUS; diagnostic only
    OpKind op;          // the operation that failed
    IoErrorStage stage; // setup, probe, registration, submit, completion, cancel
    string context;     // borrowed detail, a CTFE literal or null
}
```

`IoError`, `IoResult`, `ErrorKind`, `OpKind` and `IoErrorStage` are defined in
`sparkles.base.io.errors`. `sparkles:event-horizon` re-exports them and
defines no second error type. _Detection:_ `sparkles.event_horizon.errors`
contains no struct declaration, and the event-horizon test suite compiles
against the base types.

<a id="vfe2-error-kinds"></a>
**`VFE2` — Filesystem error kinds.** `ErrorKind` must contain at least the
members below, with these meanings. The enum also contains the network and
process kinds whose mapping event-horizon's specification owns.

| Kind                 | Meaning                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------- |
| `notFound`           | the named entry does not exist                                                                              |
| `exists`             | a create found an entry already there                                                                       |
| `notADirectory`      | a directory was required and the entry is not one                                                           |
| `isADirectory`       | a non-directory was required and the entry is a directory                                                   |
| `notEmpty`           | a directory removal found entries                                                                           |
| `permission`         | the OS denied access                                                                                        |
| `busy`               | the entry is in use in a way that blocks the operation (`EBUSY`, `STATUS_SHARING_VIOLATION`)                |
| `invalidName`        | a name failed [`VFO1`](#vfo1-names) validation                                                              |
| `escapesRoot`        | the operation would leave the root: an absolute path, an absolute symlink target, or a climb above the root |
| `dotDotRefused`      | a `..` component under the `reject` policy                                                                  |
| `symlinkRefused`     | a symlink or name-surrogate reparse point where the policy forbids one                                      |
| `symlinkLoop`        | more than the symlink hop limit under the `beneath` policy                                                  |
| `crossesMount`       | a step entered a different filesystem under `crossMounts = false`                                           |
| `nameTooLong`        | a name exceeds [the name limit](#limits)                                                                    |
| `bufferTooSmall`     | a caller-supplied buffer cannot hold the result                                                             |
| `depthExceeded`      | a walk or removal exceeded the depth limit                                                                  |
| `raceRetryExhausted` | the kernel reported a race on every attempt within the retry budget                                         |
| `unsupported`        | the backend or platform cannot provide what was asked                                                       |
| `other`              | anything unclassified; `code` carries the detail                                                            |

<a id="vfe3-kind-is-computed-once"></a>
**`VFE3` — Kind is computed once, at the backend.** A backend must set `kind`
from the native result before returning, and must produce the **same** kind
for the same condition whether the kernel detected it or the component walk
did. `code` may differ. _Rationale:_ libpathrs makes its emulated resolver
synthesise the kernel's errno so callers need one error model
([libpathrs § dimension 6](../../../research/safe-path-traversal/libpathrs.md)).
_Detection:_ the kernel-versus-walk differential
([testing.md § oracle 3](./testing.md#oracle-3-kernel-versus-walk)) compares
kinds and requires equality.

<a id="vfe4-native-mapping"></a>
**`VFE4` — Mapping of ambiguous native results.** These native results must
map as stated, because each is ambiguous on its own:

| Native result                                                   | Context                                             | Kind             |
| --------------------------------------------------------------- | --------------------------------------------------- | ---------------- |
| `ENOTDIR` or `ELOOP` from `openat(… O_NOFOLLOW \| O_DIRECTORY)` | the named entry is a symlink (checked by `fstatat`) | `symlinkRefused` |
| same                                                            | the named entry is a non-directory                  | `notADirectory`  |
| `EMLINK` (FreeBSD), `EFTYPE` (NetBSD)                           | `O_NOFOLLOW` open of a symlink                      | `symlinkRefused` |
| `EXDEV` from `openat2`                                          | `RESOLVE_NO_XDEV` set, no escape                    | `crossesMount`   |
| `EXDEV` from `openat2`                                          | otherwise                                           | `escapesRoot`    |
| `ELOOP` from `openat2` with `RESOLVE_NO_SYMLINKS`               | —                                                   | `symlinkRefused` |
| `STATUS_REPARSE_POINT_ENCOUNTERED`                              | `OBJ_DONT_REPARSE` set                              | `symlinkRefused` |
| `STATUS_DELETE_PENDING`                                         | any                                                 | `notFound`       |

_Rationale:_ Linux returns `ENOTDIR` for a symlinked intermediate opened with
`O_NOFOLLOW | O_DIRECTORY`
([`component-walk.d`](../../../research/safe-path-traversal/examples/component-walk.d)),
so the errno alone cannot tell a symlink from a file in the way. An `EXDEV`
under `RESOLVE_NO_XDEV` cannot tell a mount crossing from an escape; the
backend classifies it by re-issuing the lookup with `O_PATH` and without
`RESOLVE_NO_XDEV`, then closing the result unused; it never returns that handle.
_Detection:_ a fixture for each row asserts the kind.

<a id="vfe5-op-kinds"></a>
**`VFE5` — Operation kinds.** `OpKind` must name every operation of
[operations](#operations-vfo) distinctly: `openAt`, `mkdirAt`, `statAt`,
`readlinkAt`, `symlinkAt`, `unlinkAt`, `rmdirAt`, `renameAt`, `readDir`,
`read`, `write`, `fsync`, `close`, plus `resolve` for a whole-path lookup. The
existing `statx` member is renamed `statAt`. _Detection:_ a failure from each
operation reports its own `OpKind`.

## Resolution policy (`VFP`)

<a id="vfp1-the-policy-value"></a>
**`VFP1` — The policy value.** A root carries one `ResolvePolicy`:

```d
struct ResolvePolicy
{
    SymlinkPolicy symlinks = SymlinkPolicy.none;  // none | beneath
    DotDotPolicy dotDot = DotDotPolicy.reject;    // reject | inScope
    bool crossMounts = false;
}
```

The defaults are the strictest behaviour identical on every supported
platform ([comparison § axes 2 and 3](../../../research/safe-path-traversal/comparison.md#axis-2-what-means)).
_Detection:_ a default-constructed policy has these values.

<a id="vfp2-policy-is-fixed-at-the-root"></a>
**`VFP2` — Policy is fixed at the root.** The policy is chosen at `openRoot`
and every handle derived from the root carries the same value. No operation
changes it. _Detection:_ a handle obtained by `walk` reports the root's
policy, and no function accepts a policy other than `openRoot`.

<a id="vfp3-no-symlinks"></a>
**`VFP3` — `symlinks = none`.** During `walk`, any component that is a symlink
or a name-surrogate reparse point, intermediate or final, must fail the walk
with `symlinkRefused`, and no object reached through it is opened.
_Detection:_ [oracle 1](./testing.md#oracle-1-the-attack-table) rows with a
link component, and a sentinel beyond the link that is never opened.

<a id="vfp4-beneath"></a>
**`VFP4` — `symlinks = beneath`.** During `walk`, a symlink component must be
followed by splicing its target's components into the remaining path, and
resolved relative to the directory holding the link. An absolute target fails
with `escapesRoot`. A target whose `..` climbs above the root fails with
`escapesRoot`. More than 40 symlink hops in one walk fails with
`symlinkLoop`. `..` inside a **symlink target** is always resolved in scope,
whatever `dotDot` says, because the kernel's `RESOLVE_BENEATH` does so and
about 40% of real symlinks contain `..`
([Go `os.Root`](../../../research/safe-path-traversal/go-os-root.md#design-philosophy)).
_Detection:_ oracle 1's symlink-chain and escaping-chain rows, under
`beneath`, on every backend.

<a id="vfp5-reject-dot-dot"></a>
**`VFP5` — `dotDot = reject`.** A `..` component in the path the caller gives
to `walk` must fail with `dotDotRefused` **before any backend call**, even
when it would stay in scope. _Rationale:_ the kernels disagree about `..`
([comparison § axis 2](../../../research/safe-path-traversal/comparison.md#axis-2-what-means)),
so refusing it is the only behaviour identical on every leg. _Detection:_ the
in-memory backend's operation counter is unchanged after the call.

<a id="vfp6-in-scope-dot-dot"></a>
**`VFP6` — `dotDot = inScope`.** A `..` component must return to the handle
of the directory the walk entered before the current one. The walk must keep
the handles of the directories it has entered and pop one per `..`, and must
never issue `openat(dir, "..")` or its NT equivalent. A `..` with no entered
directory to return to fails with `escapesRoot`. On Windows, `..` is collapsed
lexically against the preceding name before any lookup, because the NT parser
resolves `..` only when a symlink is present
([Windows NT § dimension 3](../../../research/safe-path-traversal/windows-nt.md)).
_Detection:_ oracle 2's rename-during-walk scenario: a directory moved out of
the root after being entered, then `..`, never reaches an object outside the
root.

<a id="vfp7-mount-boundaries"></a>
**`VFP7` — Mount boundaries.** With `crossMounts = false`, a walk step that
opens a directory on a different filesystem from the one holding its parent
must fail with `crossesMount`, and `removeTree` must not descend into such a
directory ([`VFD6`](#vfd6-mount-boundaries-during-removal)). Linux enforces it
with `RESOLVE_NO_XDEV`. Elsewhere the backend compares the device of the
opened directory with the device of its parent. That comparison races with a
concurrent mount, and the backend must report `mountCheck = racy` for the root
([`VFR2`](#vfr2-the-root-reports-its-resolver)). With `crossMounts = true` no
check is made. _Detection:_ a fixture with a mount beneath the root, on the
in-memory backend (device ids) and on the Linux leg.

<a id="vfp8-path-syntax"></a>
**`VFP8` — Path syntax.** A `walk` path is split on `/` on every platform, and
additionally on `\` on Windows. Empty and `.` components are dropped. After
dropping, an empty path names the directory itself and yields a new handle to
it. Before any backend call, the walk must fail with `escapesRoot` for a path
that is absolute, or that begins with a drive letter, a UNC prefix or an NT
prefix, and with `invalidName` for a component failing [`VFO1`](#vfo1-names).
_Detection:_ table-driven cases on the in-memory backend with the operation
counter unchanged.

## Resolution and fallback (`VFR`)

<a id="vfr1-two-resolvers-one-result"></a>
**`VFR1` — Two resolvers, one result.** A `walk` is performed either by the
backend's whole-path resolver (`kernelWholePath`) or by the component walk in
`sparkles.base.vfs.walk` (`componentWalk`). For every policy and every
fixture, both must produce the same outcome: the same object, or failures of
the same kind. _Detection:_ [oracle 3](./testing.md#oracle-3-kernel-versus-walk).

<a id="vfr2-the-root-reports-its-resolver"></a>
**`VFR2` — The root reports its resolver.** A backend may declare
`bool wholePathFor(ResolvePolicy)` and a matching `resolveWhole`. `openRoot`
must call `wholePathFor` once and record the answer as the root's
`resolution`, together with `mountCheck` (`kernel`, `racy` or `none`). Every
derived handle reports the same values. _Detection:_ the Linux leg reports
`kernelWholePath` for every policy on a kernel with `openat2`.

<a id="vfr3-a-root-may-require-the-kernel-resolver"></a>
**`VFR3` — A root may require the kernel resolver.** `openRoot` accepts
`require: Resolution.kernelWholePath`. If the backend cannot provide it for
the policy, `openRoot` must fail with `unsupported` and return no handle.
_Detection:_ the macOS leg with the default policy fails this way; see
[`VFR7`](#vfr7-platform-accelerators).

<a id="vfr4-never-downgrade-a-lookup"></a>
**`VFR4` — Never downgrade a lookup.** When a root's `resolution` is
`kernelWholePath` and `resolveWhole` returns a failure, that failure is the
result. The component walk must not be run for the same call. _Rationale:_ a
bug in the fallback would otherwise be reachable by making the kernel refuse
([filepath-securejoin § the downgrade rule](../../../research/safe-path-traversal/filepath-securejoin.md#the-openat2-path-and-the-downgrade-rule)).
_Detection:_ a backend double whose `resolveWhole` refuses and whose component
primitives record calls; after the refusal, no component primitive was called.

<a id="vfr5-availability-is-cached-one-way"></a>
**`VFR5` — Availability is cached one way.** A backend must probe a kernel
resolver at most once per process, cache only its **absence**, and never
cache success. If a whole-path call fails and a trivial re-probe of the same
syscall then also fails with "not available" (`ENOSYS` or `EPERM` on Linux,
`STATUS_INVALID_PARAMETER` for `OBJ_DONT_REPARSE`), the resolver is marked
absent for the process. From then on a root with `require` fails every walk
with `unsupported`, and any other root uses the component walk and reports
`resolution = componentWalk`. A root's `resolution` may therefore move from
`kernelWholePath` to `componentWalk` once, and never back. _Rationale:_ a
process may install a seccomp filter after start
([libpathrs § dimension 5](../../../research/safe-path-traversal/libpathrs.md)).
_Detection:_ a test-only switch that makes the probe report absence, on each
native leg.

<a id="vfr6-race-retry-budget"></a>
**`VFR6` — Race retry budget.** When the kernel reports that it could not
rule out a race (`EAGAIN` from `openat2` with `RESOLVE_BENEATH`), the backend
must retry the same call, at most `vfsRaceRetries = 128` times, and then fail
with `raceRetryExhausted`. It must not fall back to the walk. _Rationale:_
libpathrs measured roughly a 0.1% failure rate at 128 retries under an
all-cores rename storm, and cap-std's 4 retries followed by a silent fallback
violates [`VFR4`](#vfr4-never-downgrade-a-lookup)
([`linux-openat2` § dimension 2](../../../research/safe-path-traversal/linux-openat2.md)).
_Detection:_ a backend double that returns `EAGAIN` forever yields
`raceRetryExhausted` after exactly 129 calls.

<a id="vfr7-platform-accelerators"></a>
**`VFR7` — Platform accelerators.** The blocking and asynchronous backends
must declare whole-path resolution exactly as follows, and use the component
walk otherwise:

| Platform    | Mechanism                                                                                                                                       | `wholePathFor(p)` is true when                             |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Linux ≥ 5.6 | `openat2` with `RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS` always; `RESOLVE_NO_SYMLINKS` under `none`; `RESOLVE_NO_XDEV` unless `crossMounts` | always                                                     |
| macOS       | `openat` with `O_NOFOLLOW_ANY`                                                                                                                  | `symlinks = none`, `dotDot = reject`, `crossMounts = true` |
| Windows     | `NtCreateFile` with `RootDirectory` and `OBJ_DONT_REPARSE`                                                                                      | `symlinks = none`, `dotDot = reject`                       |
| other POSIX | none                                                                                                                                            | never                                                      |

On Windows, `OBJ_DONT_REPARSE` also refuses NTFS volume mount points, which
are reparse points, so it satisfies `crossMounts = false`. _Detection:_ each
native leg's reported `resolution` for each of the eight policies matches the
table, and oracle 3 passes on Linux.

<a id="vfr8-windows-component-walk"></a>
**`VFR8` — The Windows component walk.** Without `OBJ_DONT_REPARSE`, each step
must open one name with `RootDirectory` set to the parent handle and
`FILE_OPEN_REPARSE_POINT`, then read the attribute tag. A name-surrogate tag
(bit `0x20000000`: symbolic links and junctions) is a link for
[`VFP3`](#vfp3-no-symlinks) and [`VFP4`](#vfp4-beneath); under `beneath` the
backend reads the reparse buffer to obtain the target. Any other tag is
treated as the object it is attached to. _Detection:_ the Windows leg with
real junctions and directory symlinks, with the downgrade forced.

## Operations (`VFO`)

<a id="vfo1-names"></a>
**`VFO1` — Names.** Every operation below that takes a name takes exactly one
directory entry name as `in char[]`. It must fail with `invalidName`, before
any backend call, if the name is empty, is `.` or `..`, contains `/` or NUL,
or on Windows contains `\` or `:`, ends in a dot or a space, or is a reserved
device name (`CON`, `PRN`, `AUX`, `NUL`, `COM0`–`COM9`, `LPT0`–`LPT9`, with or
without an extension). On Windows a name that is not well-formed UTF-8 also
fails with `invalidName`. _Rationale:_ Win32 and NT canonicalize those forms
differently, which is how path validation has been bypassed on Windows
([Forshaw § dimension 4](../../../research/safe-path-traversal/forshaw-windows-symlinks.md)).
_Detection:_ table-driven cases per platform with the operation counter
unchanged.

<a id="vfo2-the-named-entry-is-never-followed"></a>
**`VFO2` — The named entry is never followed.** Every single-name operation
acts on the entry itself. If it is a symlink, `openDir` and `openFile` fail
with `symlinkRefused`; `statAt` reports a symlink; `readlinkAt` reads it;
`unlinkAt` removes the link; `renameAt` moves the link. Backends realise this
with `O_NOFOLLOW` (and `AT_SYMLINK_NOFOLLOW`) on POSIX and
`FILE_OPEN_REPARSE_POINT` on Windows. _Detection:_ each operation applied to a
symlink whose target is a sentinel outside the root leaves the sentinel
unopened and unchanged.

<a id="vfo3-the-operation-set"></a>
**`VFO3` — The operation set.** A `Dir` provides exactly these operations,
each gated by the right shown ([`VFH6`](#vfh6-rights-are-checked-at-compile-time)):

| Operation                      | Right(s)                                            | Result                                                       |
| ------------------------------ | --------------------------------------------------- | ------------------------------------------------------------ |
| `openDir(name)`                | `lookup`                                            | a child `Dir` with the same rights                           |
| `openFile(name, mode)`         | `read` and/or `write`; `create` for a creating mode | a `File`                                                     |
| `mkdirAt(name)`                | `create`                                            | nothing; `exists` if present                                 |
| `statAt(name, mask)`           | `stat`                                              | a `Stat` of the entry itself                                 |
| `readlinkAt(name, buffer)`     | `stat`                                              | the target bytes, as a slice of `buffer`                     |
| `symlinkAt(name, target)`      | `create`                                            | nothing; `target` stored verbatim                            |
| `unlinkAt(name)`               | `remove`                                            | nothing; `isADirectory` for a directory                      |
| `rmdirAt(name)`                | `remove`                                            | nothing; `notEmpty` if it has entries                        |
| `renameAt(name, dst, dstName)` | `rename` on both                                    | nothing; replaces a non-directory target                     |
| `list(buffer)`                 | `list`                                              | a `Listing` over the entries                                 |
| `walk(path)`                   | `lookup`                                            | a `Dir` for the directory `path` names                       |
| `walkAll(path)`                | `lookup`, `create`                                  | as `walk`, creating missing directories                      |
| `removeTree(name)`             | `lookup`, `list`, `remove`                          | nothing; see [deletion](#deletion-vfd)                       |
| `writeFileAtomic(name, bytes)` | `create`, `write`, `rename`                         | nothing; readers see the old or the new content, never a mix |

A `File` provides `read(buffer)`, `write(bytes)`, `stat(mask)`, `sync()` and
`close()`, gated by the rights it was opened with. _Detection:_ each operation
has a success and a failure case on every backend
([oracle 4](./testing.md#oracle-4-three-backend-differential)).

<a id="vfo4-open-modes"></a>
**`VFO4` — Open modes.** `openFile` accepts `read`, `write`, `readWrite` and
`append` access, combined with `existing` (fail with `notFound` if absent),
`createNew` (fail with `exists` if present) or `createOrTruncate`. A created
file's executable bit is set only if the mode asks for it. On POSIX the file is
created with mode `0644` or `0755` before the umask. _Detection:_ one case per
combination on the blocking backend.

<a id="vfo5-stat"></a>
**`VFO5` — `Stat`.** `statAt` and `File.stat` return the entry's kind
(`regular`, `directory`, `symlink` or `other`), its executable bit, its size,
and its device, always. The modification time is filled only when the mask
requests it. On Windows the executable bit is always false. _Rationale:_ the
fileset vocabulary needs exactly the kind and the executable bit
([`FSO1`](../../build-primitives/filesets/SPEC.md)),
and a scheme may request the time
([`FSS2`](../../build-primitives/filesets/SPEC.md)).
_Detection:_ a stat without the time mask on the in-memory backend records no
time lookup.

<a id="vfo6-listing"></a>
**`VFO6` — Listing.** `list` must obtain a new, independent handle to the
directory by opening `.` relative to it, and read entries from that. It must
never duplicate the directory's own descriptor. Entries are yielded in an
unspecified order, never include `.` or `..`, and carry a name plus a kind
hint that may be `unknown`. Each entry's name is a slice of the
caller-supplied buffer and is valid only until the next advance. A buffer too
small for one entry yields `bufferTooSmall`. _Rationale:_ `fdopendir` takes
ownership of a file description, and a duplicate would share its offset with
the directory handle
([rustix § `Dir`](../../../research/safe-path-traversal/rustix.md#dir-iterating-from-an-fd)).
_Detection:_ listing a directory twice through the same `Dir`, concurrently,
yields the full set both times.

<a id="vfo7-rename-stays-in-the-root"></a>
**`VFO7` — Rename stays in one root.** `renameAt` must fail with
`escapesRoot`, before any backend call, if `dst` does not descend from the
same root as the source directory. _Detection:_ two roots over one directory;
a rename between them fails and neither tree changes.

<a id="vfo8-atomic-write"></a>
**`VFO8` — Atomic write.** `writeFileAtomic` must create a new file under a
fresh temporary name in the same directory with `createNew`, write and sync
it, and rename it over `name`. On any failure it must remove the temporary
entry. A concurrent reader of `name` observes either the complete old content
or the complete new content. _Detection:_ a reader loop concurrent with 1000
writes never observes a mixed or empty file, on the Linux and Windows legs.

## Handles and rights (`VFH`)

<a id="vfh1-owning-handles"></a>
**`VFH1` — Owning handles.** `Dir!(V, R)` and `File!(V, R)` hold a
`V.Handle` and a pointer to the backend instance `V`. They are move-only
(`@disable this(this)`), not default-constructible, and close their handle
exactly once: in `close()` if it is called, otherwise in the destructor. A
close failure in the destructor is dropped; `close()` returns it.
_Detection:_ a backend double counts closes; every test ends with one close
per open.

<a id="vfh2-borrowed-handles"></a>
**`VFH2` — Borrowed handles.** `DirRef!(V, R)` and `FileRef!(V, R)` borrow an
owner, provide the same operations, and cannot close. Under
`-preview=dip1000` a borrow must not outlive its owner. _Detection:_ a
`@safe` function that returns a `DirRef` to a local `Dir` does not compile.

<a id="vfh3-the-backend-is-part-of-the-type"></a>
**`VFH3` — The backend is part of the type.** A handle from one backend cannot
be passed to another backend's operations. _Detection:_ passing a
`DirRef!(MemVfs, R)` as `renameAt`'s destination on a `Dir!(BlockingVfs, R)`
does not compile.

<a id="vfh4-rights"></a>
**`VFH4` — Rights.** `Rights` is a set of `lookup`, `list`, `stat`, `read`,
`write`, `create`, `remove` and `rename`, with presets
`readOnly = lookup | list | stat | read` and `all`. _Detection:_ the presets'
members are pinned by a `static assert`.

<a id="vfh5-attenuation-only"></a>
**`VFH5` — Attenuation only.** A handle opened from a `Dir` carries the
parent's rights. `dir.attenuate!(R2)` yields a borrow with rights `R2` and
compiles only if `R2` is a subset of the parent's rights. No function widens
rights. _Detection:_ `attenuate!(Rights.all)` on a `readOnly` handle does not
compile.

<a id="vfh6-rights-are-checked-at-compile-time"></a>
**`VFH6` — Rights are checked at compile time.** Calling an operation whose
right ([`VFO3`](#vfo3-the-operation-set)) is absent from the handle's rights
must not compile. _Detection:_ a `static assert(!__traits(compiles, …))` per
operation and missing right ([oracle 5](./testing.md#oracle-5-compile-fail-rights)).

<a id="vfh7-rights-reach-the-os"></a>
**`VFH7` — Rights reach the OS where they can.** A backend must not open a
handle with more OS access than its rights need. On Windows the rights map to
the handle's access mask (`lookup` to `FILE_TRAVERSE`, `list` to
`FILE_LIST_DIRECTORY`, `stat` to `FILE_READ_ATTRIBUTES`, `read` and `write` to
the data rights, `remove` to `DELETE` on the child). On POSIX, directories are
opened read-only and files open with `O_WRONLY` or `O_RDWR` only when `write`
is present. _Detection:_ on the Windows leg, a read-only `File` handle's
queried access mask excludes `FILE_WRITE_DATA`.

<a id="vfh8-the-ambient-constructor"></a>
**`VFH8` — The ambient constructor.** `openRoot!(R)(V*, path, AmbientAuthority,
ResolvePolicy, require)` is the only operation that resolves a path
from the process root or current directory, and the only one that follows
symlinks in the path it is given. It requires an `AmbientAuthority` value,
obtainable only by calling `ambientAuthority()`, so every escape hatch can be
found by searching for that name. _Rationale:_ cap-std's greppable token
([cap-std § design philosophy](../../../research/safe-path-traversal/cap-std.md#design-philosophy)).
_Detection:_ the migrated repository contains no call to a backend's native
open outside backend modules, and every `openRoot` call site names
`ambientAuthority()`.

<a id="vfh9-handles-are-not-inherited"></a>
**`VFH9` — Handles are not inherited.** Every handle a backend opens is
close-on-exec on POSIX and non-inheritable on Windows. _Detection:_ a child
process spawned while a `Dir` is held has no descriptor referring to it.

## Deletion (`VFD`)

<a id="vfd1-bounded-explicit-stack"></a>
**`VFD1` — Bounded, explicit stack.** `removeTree(name)` removes the named
entry and, if it is a directory, everything beneath it. It must use an
explicit stack, not recursion, of at most the depth limit
([limits](#limits)) directory handles. Meeting a directory deeper than the
limit must fail with `depthExceeded` and leave everything outside the named
entry untouched. _Detection:_ a tree one level deeper than the limit.

<a id="vfd2-never-descend-a-link"></a>
**`VFD2` — Never descend a link.** Each entry is classified by opening it as a
directory without following ([`VFO2`](#vfo2-the-named-entry-is-never-followed)).
A symlink or name-surrogate reparse point is removed as an entry, never
entered, under every policy. _Detection:_ a symlink inside the tree pointing
at a sentinel directory outside it; the sentinel's contents survive
([`fd-remove-tree.d`](../../../research/safe-path-traversal/examples/fd-remove-tree.d)).

<a id="vfd3-listing-until-empty"></a>
**`VFD3` — Listing until empty.** A directory is listed through its own
handle ([`VFO6`](#vfo6-listing)) and re-listed until a listing yields no
entries, because removing entries during a listing can make it skip some.
_Detection:_ a directory of 5000 entries is emptied in one call.

<a id="vfd4-vanished-entries"></a>
**`VFD4` — Vanished entries.** An entry that is gone when it is removed or
opened (`notFound`, including a Windows delete-pending state) is not an error.
_Detection:_ oracle 2 removes entries from under the walk; the call succeeds.

<a id="vfd5-windows-deletion"></a>
**`VFD5` — Windows deletion.** The Windows backends must delete through the
entry's own handle with `FILE_DISPOSITION_INFORMATION_EX` and
`POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE`. On `STATUS_INVALID_PARAMETER`,
`STATUS_NOT_SUPPORTED` or `STATUS_INVALID_INFO_CLASS` they must fall back to
clearing the read-only attribute and the classic disposition. A sharing
violation or a not-empty directory is retried, at most 50 times, then reported
as `busy` or `notEmpty`. _Rationale:_ the Rust CVE-2022-21658 remover
([Rust std § Windows](../../../research/safe-path-traversal/rust-std.md#windows-ntopenfile-relative-to-a-parent-handle)).
_Detection:_ the Windows leg removes a tree containing a git repository's
read-only object files.

<a id="vfd6-mount-boundaries-during-removal"></a>
**`VFD6` — Mount boundaries during removal.** Under `crossMounts = false`,
`removeTree` must not descend into a directory on a different filesystem. It
must fail with `crossesMount` and leave that directory and its contents
untouched. _Detection:_ the in-memory backend with a mounted subtree.

<a id="vfd7-partial-progress-is-the-failure-state"></a>
**`VFD7` — Partial progress is the failure state.** On a failure other than
[`VFD4`](#vfd4-vanished-entries), `removeTree` stops and returns it. Entries
already removed stay removed. No entry outside the named one is affected.
_Detection:_ a directory made unremovable mid-tree; the error reports
`unlinkAt` or `rmdirAt`, and a sentinel beside the named entry survives.

## Limits

| Limit                  | Default                                                     | Exceeding it         |
| ---------------------- | ----------------------------------------------------------- | -------------------- |
| Name length            | 255 UTF-8 bytes on POSIX; 255 UTF-16 code units on Windows  | `nameTooLong`        |
| Walk depth             | 64 entered directories, shared with the `..` ancestor stack | `depthExceeded`      |
| Removal depth          | 64 directories                                              | `depthExceeded`      |
| Symlink hops           | 40 per walk                                                 | `symlinkLoop`        |
| Race retries           | 128 per whole-path call                                     | `raceRetryExhausted` |
| Windows delete retries | 50 per entry                                                | `busy` or `notEmpty` |

Depth 64 and name 255 match the fileset limits
([`FSM7`](../../build-primitives/filesets/SPEC.md)).
Every stack is a fixed-capacity buffer of that size; no operation allocates
from the GC. The in-memory backend's arena is bounded separately
([`VFM4`](#vfm4-arena)).

## Backends (`VFB`)

<a id="vfb1-the-concept"></a>
**`VFB1` — The concept.** `isVfs!V` is true when `V` provides a `Handle` type
and the single-name primitives of [`VFO3`](#vfo3-the-operation-set) over
`(V.Handle, name)`, plus `close`, `read`, `write`, `sync` and the listing
primitives, each returning `IoResult`. `wholePathFor` and `resolveWhole` are
optional. The algorithms (`walk`, `walkAll`, `removeTree`, `writeFileAtomic`)
are written once, over the concept, in `sparkles:base`. _Detection:_ all three
backends satisfy `isVfs`, and a type missing one primitive does not.

<a id="vfb2-direct-style"></a>
**`VFB2` — Direct-style calls.** A backend operation returns its result when
the operation completes. The asynchronous backend suspends the calling fiber
until then; the others return at once. The same algorithm code runs on all
three. _Detection:_ oracle 4 runs one algorithm instantiation per backend.

<a id="vfb3-the-blocking-backend"></a>
**`VFB3` — The blocking backend.** `BlockingVfs` performs each operation with
one blocking syscall relative to the parent handle: the `*at` family on POSIX,
and `NtCreateFile`/`NtOpenFile` with `RootDirectory` plus
`NtSetInformationFile` on Windows. Directory handles on Windows are opened
with `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`, so a directory
can be deleted through its own handle. _Detection:_ oracles 1, 3, 4 and 6.

<a id="vfb4-the-asynchronous-backend"></a>
**`VFB4` — The asynchronous backend.** `RingVfs` must produce results
identical to `BlockingVfs` for every operation. On Linux it submits a ring
operation wherever the kernel has one (`openat2`, `statx`, `mkdirat`,
`unlinkat`, `renameat`, `symlinkat`) and runs listing and `readlinkat` on the
blocking pool through `BlockingVfs`. On macOS and Windows it runs every
operation on the blocking pool through `BlockingVfs`. The `fs` capability
must be present in the capability row on every backend of the loop.
_Detection:_ oracle 4 on each leg; a `liveEnv` on the select and IOCP
backends contains `fs`.

<a id="vfb5-effect-wrappers"></a>
**`VFB5` — Effect wrappers.** `sparkles:event-horizon` must provide `Effect!T`
forms of the `Dir` and `File` operations, generated from the direct-style
ones rather than written separately. _Detection:_ one test per operation runs
its effect form and compares with the direct form.

<a id="vfb6-the-blocking-package-has-no-loop"></a>
**`VFB6` — The blocking package has no loop.** `sparkles:event-horizon-sys`
must not depend on `sparkles:event-horizon`, `during`, or any event-loop
module. _Detection:_ `dub describe :event-horizon-sys` lists only
`sparkles:base`, `expected` and `sparkles:reflection` as dependencies.

## The in-memory backend (`VFM`)

`MemVfs`, in `sparkles.base.vfs.mem`, is a supported backend and not a test
double. It replaces the fileset specification's in-memory driver
([`FSD2`](../../build-primitives/filesets/SPEC.md)) and is the substrate for
the deterministic race scenarios in [testing.md](./testing.md).

<a id="vfm1-what-it-models"></a>
**`VFM1` — What it models.** `MemVfs` must model directories, regular files
with contents and an executable bit, symlinks with opaque targets, a settable
modification time, and a device id per subtree for mount boundaries. It must
not model permissions, hard links, reparse tags or case-insensitive names; a
scenario that needs one of those runs on a native leg. _Detection:_ oracle 1
runs on it with the expected outcomes of the native legs, except the rows
marked native-only.

<a id="vfm2-call-counter"></a>
**`VFM2` — Call counter.** `MemVfs` must count every backend call by
`OpKind`. The count is how a test proves that a refusal happened "before any
backend call" ([`VFP5`](#vfp5-reject-dot-dot), [`VFP8`](#vfp8-path-syntax),
[`VFO1`](#vfo1-names)). _Detection:_ a successful single-name open increments
exactly one counter by one.

<a id="vfm3-interleaving-hook"></a>
**`VFM3` — Interleaving hook.** `MemVfs` must accept a scripted callback that
runs between two backend calls, receives the index of the call about to run,
and may change the tree: rename, replace an entry with a symlink, remove, or
mount. The hook makes a race a deterministic, repeatable scenario on every
platform. It does not show that real concurrent interleavings are safe; the
native legs remain the evidence for that. _Detection:_ oracle 2's scenarios
each fire the hook at a chosen call index and assert the outcome.

<a id="vfm4-arena"></a>
**`VFM4` — Arena.** `MemVfs` allocates its nodes from a caller-supplied arena
and never from the GC. A full arena fails the operation with `other` and the
context `"arena exhausted"`, and leaves the tree unchanged. _Detection:_ an
arena sized for N nodes accepts N and refuses the next, and the allocation
instrumentation records no GC allocation.

## Consumer migration (`VFC`)

<a id="vfc1-tmpfs"></a>
**`VFC1` — `TmpFS`.** `TmpFS` must hold a `Dir!(BlockingVfs, Rights.all)` for
its scratch directory and perform every write, directory creation and removal
through it. Its public surface keeps `create`, `share`, `dir`, `writeFile`,
`writeFileAt`, `ensureSubdir` and `createdFiles`, and `dir()` still returns a
path string. A path that leaves the fixture remains an assertion failure at
`TmpFS`'s own boundary, because its input is trusted test code; the VFS
underneath still returns the error as a value. The string check
`enforceBeneath` is deleted. _Detection:_ the twelve consumer suites keep
their current test counts, and `refusesAPathThatLeavesTheFixture` passes.

<a id="vfc2-event-horizon"></a>
**`VFC2` — `sparkles:event-horizon`.** `RingFs` and its path-string functions
(`openFile`, `statxPath`, `readText` by path) and the copyable `FileHandle`
are removed. `cgroup.d` and `sampling.d` open their `/sys/fs/cgroup` and
`/proc` roots with `openRoot` and perform their relative operations through
the resulting `Dir`. `Watcher.addWatch` takes a path together with an
`AmbientAuthority`. _Detection:_ no `atFdCwd` constant and no raw `openat` or
`mkdirat` declaration remain in `sparkles:event-horizon`.

<a id="vfc3-fileset"></a>
**`VFC3` — The fileset specification.** The fileset specification's drivers
(`FSD1`–`FSD7`) and request vocabulary (`FSM2`) must be rewritten to state
that the three drivers are this specification's three backends and that the
fileset driver is one generic adapter over `isVfs`. Its statement that
`RESOLVE_NO_SYMLINKS` is not set is superseded by
[`VFO2`](#vfo2-the-named-entry-is-never-followed): reading a link's target is
a single-name `readlinkAt`, and never needs a lookup that follows.
_Detection:_ the fileset specification contains no normative text duplicating
this one.

## Requirement index

| Group                                         | Covers                                                                                     |
| --------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [`VFE1`–`VFE5`](#errors-vfe)                  | One error type, kinds, where kinds are computed, ambiguous native results, operation kinds |
| [`VFP1`–`VFP8`](#resolution-policy-vfp)       | The policy value and its fixing, symlinks, `..`, mounts, path syntax                       |
| [`VFR1`–`VFR8`](#resolution-and-fallback-vfr) | Two resolvers, reporting, requiring, no downgrade, one-way cache, retries, accelerators    |
| [`VFO1`–`VFO8`](#operations-vfo)              | Names, no-follow, the operation set, modes, stat, listing, rename, atomic write            |
| [`VFH1`–`VFH9`](#handles-and-rights-vfh)      | Ownership, borrowing, backend typing, rights, attenuation, the ambient constructor         |
| [`VFD1`–`VFD7`](#deletion-vfd)                | Bounded stack, links, listing, vanished entries, Windows, mounts, partial progress         |
| [`VFB1`–`VFB6`](#backends-vfb)                | The concept, direct style, blocking and asynchronous backends, effects, loop-free package  |
| [`VFM1`–`VFM4`](#the-in-memory-backend-vfm)   | What the in-memory backend models, its call counter, interleaving hook and arena           |
| [`VFC1`–`VFC3`](#consumer-migration-vfc)      | `TmpFS`, event-horizon, the fileset specification                                          |

Every requirement is currently **unverified**. The evidence ledger is in
[testing.md](./testing.md#evidence-ledger).
