---
status: draft
owner: sparkles:event-horizon
reviewed: 2026-10-05
---

# Capability VFS — Backends

A backend turns the capability VFS's operations into effects on some file
system: a tree in memory, blocking system calls, or operations submitted to
the event loop. This page states what a backend must do so that callers get
the contract of [SPEC.md](./SPEC.md) unchanged on every backend and platform:
the shape every backend shares, how native results become portable errors,
how a native backend resolves paths with the kernel's help, how it opens,
lists and deletes, and what the in-memory backend models.

A caller never needs this page. Requirements here refine guarantees stated in
SPEC.md, and each one links the guarantee it serves. Each requirement's check
is listed in [testing.md](./testing.md#backends-vfb); delivery order is in
[PLAN.md](./PLAN.md) and the reasoning in [decisions.md](./decisions.md).

## 1. The backend concept (`VFB`)

<a id="vfb1-the-concept"></a>
**VFB1: The concept.** `isVfs!V` **must** be true exactly when `V` provides a
`Handle` type and, over `(V.Handle, name)`, the single-name primitives of
[`VFO3`](./SPEC.md#vfo3-the-operation-set), plus `reopen` (a new handle to a
directory, by opening `.`), `close`, `read`, `write`, `sync` and the listing
primitives, each returning `IoResult`. The algorithms
(`walk`, `walkAll`, `removeTree`, `writeFileAtomic`) are written once, over
the concept, in `sparkles:base`.

<a id="vfb2-direct-style"></a>
**VFB2: Direct-style calls.** A backend operation **must** return its result
when the operation completes. The asynchronous backend suspends the calling
fiber until then; the others return at once. The same algorithm code runs on
every backend.

_Rationale:_ Event-horizon generates its `Effect!T` forms from these
direct-style operations, so a second, effect-shaped backend interface is never
needed ([DV2](./decisions.md#dv2-direct-style-concept-not-effect-descriptions)).

<a id="vfb3-the-whole-path-resolver"></a>
**VFB3: The whole-path resolver.** A backend **may** declare
`bool wholePathFor(ResolvePolicy)` and a matching `resolveWhole`. `openRoot`
**must** call `wholePathFor` once and record the answer as the root's
`resolution`, and the backend **must** state the root's `mountCheck` at the
same time ([`VFR2`](./SPEC.md#vfr2-the-root-reports-its-resolver)). On a root
whose resolution is `kernelWholePath`, a walk calls only `resolveWhole`; on
one whose resolution is `componentWalk`, only the single-name primitives.

<a id="vfb4-the-blocking-backend"></a>
**VFB4: The blocking backend.** `BlockingVfs` **must** perform each operation
with one blocking system call relative to the parent handle: the `*at` family
on POSIX, and `NtCreateFile` or `NtOpenFile` with `RootDirectory`, plus
`NtSetInformationFile`, on Windows. On Windows it opens directory handles with
`FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`, so a directory can be
deleted through its own handle.

_Rationale:_ Because this interface never re-resolves a path, an ancestor's
rename does no harm, so delete sharing can stay on
([DV14](./decisions.md#dv14-windows-directory-handles-allow-delete-sharing)).

<a id="vfb5-the-asynchronous-backend"></a>
**VFB5: The asynchronous backend.** `RingVfs` **must** produce results
identical to `BlockingVfs` for every operation. On Linux it submits a ring
operation wherever the kernel has one (`openat2`, `statx`, `mkdirat`,
`unlinkat`, `renameat`, `symlinkat`) and runs listing and `readlinkat` through
`BlockingVfs` on the blocking pool. On macOS and Windows it runs every
operation through `BlockingVfs` on the blocking pool. Event-horizon makes it
the `fs` member of its capability row on every loop backend
([event-horizon §10.5](../../event-horizon/SPEC.md#_10-5-the-file-system)).

<a id="vfb6-the-blocking-package-has-no-loop"></a>
**VFB6: The blocking package has no loop.** `sparkles:event-horizon-sys`
**must not** depend on `sparkles:event-horizon`, `during`, or any event-loop
module.

_Rationale:_ Test fixtures in every package's test build depend on the
blocking backend, and must not pull the loop's platform arms into each of them
([DV1](./decisions.md#dv1-the-vocabulary-lives-in-base-syscalls-live-in-event-horizon)).

## 2. Native results

A native backend classifies every failure once, where the system call
returned it.

<a id="vfn1-kind-is-computed-once"></a>
**VFN1: Kind is computed once, at the backend.** A backend **must** set
`kind` from the native result before returning, and its kernel resolver and
the component walk **must** classify the same condition alike
([`VFE3`](./SPEC.md#vfe3-the-same-kind-from-either-resolver)).

<a id="vfn2-ambiguous-native-results"></a>
**VFN2: Ambiguous native results.** These native results **must** map as
stated, because each is ambiguous on its own:

| Native result                                                   | Context                                             | Kind             |
| --------------------------------------------------------------- | --------------------------------------------------- | ---------------- |
| `ENOTDIR` or `ELOOP` from `openat(… O_NOFOLLOW \| O_DIRECTORY)` | the named entry is a symlink (checked by `fstatat`) | `symlinkRefused` |
| same                                                            | the named entry is a non-directory                  | `notADirectory`  |
| `EMLINK` (FreeBSD), `EFTYPE` (NetBSD)                           | `O_NOFOLLOW` open of a symlink                      | `symlinkRefused` |
| `EXDEV` from `openat2`                                          | `RESOLVE_NO_XDEV` set, no escape                    | `crossesMount`   |
| `EXDEV` from `openat2`                                          | otherwise                                           | `escapesRoot`    |
| `ELOOP` from `openat2` with `RESOLVE_NO_SYMLINKS`               | —                                                   | `symlinkRefused` |
| `EBUSY`, `STATUS_SHARING_VIOLATION`                             | any                                                 | `busy`           |
| `STATUS_REPARSE_POINT_ENCOUNTERED`                              | `OBJ_DONT_REPARSE` set                              | `symlinkRefused` |
| `STATUS_DELETE_PENDING`                                         | any                                                 | `notFound`       |

To tell the two `EXDEV` rows apart, the backend re-issues the lookup with
`O_PATH` and without `RESOLVE_NO_XDEV`, then closes the result unused; it never
returns that handle.

_Rationale:_ Linux returns `ENOTDIR` for a symlinked intermediate opened with
`O_NOFOLLOW | O_DIRECTORY`
([`component-walk.d`](../../../research/safe-path-traversal/examples/component-walk.d)),
so the errno alone cannot tell a symlink from a file in the way.

## 3. Resolution in a native backend

These requirements provide the guarantees of
[SPEC.md § 8](./SPEC.md#_8-resolution-vfr) on real kernels.

<a id="vfn3-availability-is-cached-one-way"></a>
**VFN3: Availability is cached one way.** A backend **must** probe each
kernel resolver at most once per process, and cache only its absence, never
its presence. When a whole-path call fails and an immediate re-probe of the
same system call reports it unavailable (`ENOSYS` or `EPERM` on Linux,
`STATUS_INVALID_PARAMETER` for `OBJ_DONT_REPARSE`), the backend **must** mark
the resolver absent for the process and report `componentWalk` from then on
([`VFR5`](./SPEC.md#vfr5-at-most-one-change)).

<a id="vfn4-race-retries"></a>
**VFN4: Race retries.** On `EAGAIN` from `openat2` with `RESOLVE_BENEATH`, the
backend **must** issue the same call again, up to the
[race retry limit](./SPEC.md#_11-limits), and then fail with
`raceRetryExhausted` ([`VFR6`](./SPEC.md#vfr6-race-exhaustion-is-an-error)).

<a id="vfn5-platform-accelerators"></a>
**VFN5: Platform accelerators.** The blocking and asynchronous backends
**must** declare whole-path resolution exactly as follows, and use the
component walk otherwise:

| Platform    | Mechanism                                                                                                                                       | `wholePathFor(p)` is true when                             |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Linux ≥ 5.6 | `openat2` with `RESOLVE_BENEATH` and `RESOLVE_NO_MAGICLINKS` always; `RESOLVE_NO_SYMLINKS` under `none`; `RESOLVE_NO_XDEV` unless `crossMounts` | always                                                     |
| macOS       | `openat` with `O_NOFOLLOW_ANY`                                                                                                                  | `symlinks = none`, `dotDot = reject`, `crossMounts = true` |
| Windows     | `NtCreateFile` with `RootDirectory` and `OBJ_DONT_REPARSE`                                                                                      | `symlinks = none`, `dotDot = reject`                       |
| other POSIX | none                                                                                                                                            | never                                                      |

On Windows, `OBJ_DONT_REPARSE` also refuses NTFS volume mount points, which
are reparse points, so it satisfies `crossMounts = false`.

<a id="vfn6-the-mount-check"></a>
**VFN6: The mount check.** Under `crossMounts = false`, a Linux backend
**must** enforce [`VFP8`](./SPEC.md#vfp8-mount-boundaries) with
`RESOLVE_NO_XDEV` and report `mountCheck = kernel`. Elsewhere it **must**
compare the device of each opened directory with the device of its parent and
report `mountCheck = racy`, because a concurrent mount can land between the
open and the comparison. Under `crossMounts = true` it reports `none`.

<a id="vfn7-the-windows-component-walk"></a>
**VFN7: The Windows component walk.** Without `OBJ_DONT_REPARSE`, each step
**must** open one name with `RootDirectory` set to the parent handle and
`FILE_OPEN_REPARSE_POINT`, then read the attribute tag. A name-surrogate tag
(bit `0x20000000`, set for symbolic links and junctions) is a link for
[`VFP4`](./SPEC.md#vfp4-no-symlinks) and [`VFP5`](./SPEC.md#vfp5-beneath);
under `beneath` the backend reads the reparse buffer to obtain the target. Any
other tag is treated as the object it is attached to.

<a id="vfn8-windows-dot-dot"></a>
**VFN8: `..` on Windows.** Under `dotDot = inScope`, the Windows walk **must**
collapse `..` lexically against the preceding name before any lookup.

_Rationale:_ The NT object manager resolves `..` only when a symbolic link is
present ([Windows NT § dimension 3](../../../research/safe-path-traversal/windows-nt.md)).

## 4. Opening, listing and access

<a id="vfn9-no-follow"></a>
**VFN9: No-follow opens.** A backend **must** realise
[`VFO2`](./SPEC.md#vfo2-the-named-entry-is-never-followed) with `O_NOFOLLOW`
and `AT_SYMLINK_NOFOLLOW` on POSIX and `FILE_OPEN_REPARSE_POINT` on Windows.

<a id="vfn10-listing-through-a-fresh-handle"></a>
**VFN10: Listing through a fresh handle.** To list a directory, a backend
**must** open `.` relative to its handle and read entries from that new
handle. It **must not** duplicate the directory's own descriptor
([`VFO7`](./SPEC.md#vfo7-listing)).

_Rationale:_ `fdopendir` takes ownership of a file description, and a
duplicate would share its offset with the directory handle
([rustix § `Dir`](../../../research/safe-path-traversal/rustix.md#dir-iterating-from-an-fd)).

<a id="vfn11-rights-reach-the-os"></a>
**VFN11: Rights reach the OS.** A backend **must not** open a handle with
more operating-system access than its rights need. On Windows the rights map
to the handle's access mask: `lookup` to `FILE_TRAVERSE`, `list` to
`FILE_LIST_DIRECTORY`, `stat` to `FILE_READ_ATTRIBUTES`, `read` and `write`
to the data rights, and `remove` to `DELETE` on the child. On POSIX,
directories are opened read-only, and a file opens with `O_WRONLY` or `O_RDWR`
only when `write` is present.

<a id="vfn12-sharing-on-each-platform"></a>
**VFN12: Sharing on each platform.** A POSIX backend **must** pass the mode of
[`VFO5`](./SPEC.md#vfo5-sharing-of-created-entries) to the creating system
call and leave the umask alone. A Windows backend **must** create a `Shared()`
entry with no security descriptor, so it inherits its parent's access control,
and an `OwnerOnly()` entry with a security descriptor whose protected access
control list grants access to the creating user's token owner only. The
Windows backend has no `PosixMode` form.

<a id="vfn14-intermediate-directories-are-opened-for-search"></a>
**VFN14: Intermediate directories are opened for search.** A native backend
**should** provide `openSearchAt(dir, name)`, which opens a directory without
following it and with only the access needed to look up entries in it:
`O_PATH` on Linux, `O_SEARCH` on macOS and FreeBSD, and `FILE_TRAVERSE` on
Windows. When it does, the component walk **must** open every directory it
passes through with it and open the directory it returns with `reopen`, so a
walk needs search permission on intermediate directories, as the kernel
resolver does ([`VFR1`](./SPEC.md#vfr1-two-resolvers-one-result)). A backend
without it uses `openDirAt` throughout.

_Rationale:_ Otherwise a directory the program may search but not read stops
the component walk and not the kernel resolver
([DV28](./decisions.md#dv28-intermediate-directories-are-opened-for-search-was-o5)).

## 5. Deletion on Windows

<a id="vfn13-windows-deletion"></a>
**VFN13: Windows deletion.** A Windows backend **must** delete through the
entry's own handle with `FILE_DISPOSITION_INFORMATION_EX` and
`POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE`. On
`STATUS_INVALID_PARAMETER`, `STATUS_NOT_SUPPORTED` or
`STATUS_INVALID_INFO_CLASS` it **must** fall back to clearing the read-only
attribute and setting the classic disposition. A sharing violation or a
not-empty directory is retried up to the
[Windows delete retry limit](./SPEC.md#_11-limits), then reported as `busy`
or `notEmpty`.

_Rationale:_ This is the remover that fixed Rust's CVE-2022-21658
([Rust std § Windows](../../../research/safe-path-traversal/rust-std.md#windows-ntopenfile-relative-to-a-parent-handle)).

## 6. The in-memory backend (`VFM`)

`MemVfs`, in `sparkles.base.vfs.mem`, is a supported backend and not a test
double. It also makes races reproducible: the scenarios of
[testing.md § oracle 2](./testing.md#oracle-2-scripted-races) run on it.

<a id="vfm1-what-it-models"></a>
**VFM1: What it models.** `MemVfs` **must** model directories, regular files
with contents and an executable bit, symbolic links with opaque targets, a
settable modification time, and a device id per subtree for mount boundaries.
It **must not** model permissions beyond [`VFM5`](#vfm5-sharing-is-recorded),
hard links, reparse tags or case-insensitive names; a scenario that needs one
of those runs on a native backend.

<a id="vfm2-call-counter"></a>
**VFM2: Call counter.** `MemVfs` **must** count every backend call by
`OpKind`. The count is how a test shows that a refusal happened before any
backend call ([`VFP3`](./SPEC.md#vfp3-path-syntax),
[`VFP6`](./SPEC.md#vfp6-reject-dot-dot), [`VFO1`](./SPEC.md#vfo1-names)).

<a id="vfm3-interleaving-hook"></a>
**VFM3: Interleaving hook.** `MemVfs` **must** accept a scripted callback that
runs between two backend calls, receives the index of the call about to run,
and may change the tree: rename, replace an entry with a symbolic link,
remove, or mount. The hook makes a race a repeatable scenario on every
platform. It does not show that real concurrent interleavings are safe; the
native backends remain the evidence for that.

<a id="vfm4-arena"></a>
**VFM4: Arena.** `MemVfs` **must** allocate its nodes from a caller-supplied
arena and never from the GC. A full arena fails the operation with `other`
and the context `"arena exhausted"`, and leaves the tree unchanged.

<a id="vfm5-sharing-is-recorded"></a>
**VFM5: Sharing is recorded.** `MemVfs` **must** record the sharing each entry
was created with ([`VFO5`](./SPEC.md#vfo5-sharing-of-created-entries)) and
report it through its test inspection interface. Under `version (Posix)` its
`Stat` reports the mode bits that sharing implies, with no umask applied.
