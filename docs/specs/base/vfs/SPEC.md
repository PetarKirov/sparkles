---
status: draft
owner: sparkles:event-horizon
reviewed: 2026-10-05
---

# Capability VFS — Specification

## Abstract

The capability VFS, a virtual file-system interface, is how Sparkles programs
reach the file system. A program
is given open directory handles instead of path strings, and names every file
relative to one of them, so code holding a handle cannot reach anything
outside that directory, even while another process renames entries or plants
symbolic links inside it. Each handle carries a fixed set of rights that can
be narrowed but never widened, and the compiler rejects an operation a handle
has no right to perform. The interface has three implementations: in memory,
over blocking system calls, and over the `sparkles:event-horizon` event loop.
One set of algorithms runs unchanged on all three.

## Introduction

Many programs work inside directory trees that someone else can also write. A
test fixture creates a scratch tree and deletes it afterwards; a build tool
hashes every file of a source checkout; a process supervisor reads entries
under `/proc` and `/sys`. Such programs name files by path, and a path is an
indirect reference. Each of its components is looked up again on every use,
and anyone who can write a directory along the way can re-bind a component
between the moment a program checks the path and the moment it uses it. This
is the [time-of-check to time-of-use](https://cwe.mitre.org/data/definitions/367.html)
race, which [Bishop and Dilger](../../../research/safe-path-traversal/bishop-dilger-1996.md)
characterised for Unix file systems. Deletion shows the cost most plainly: a
remover that follows a symbolic link planted in the tree deletes files
outside it.

Checking the path more carefully does not close the race. [Cai et al.](../../../research/safe-path-traversal/cai-2009.md)
showed that an attacker can make any lookup slow enough to win every race,
which defeated the probabilistic defenses of the time. What survives is
resolving each component once, relative to a directory handle the program
already holds, and refusing symbolic links on the way
([concepts § the fix](../../../research/safe-path-traversal/concepts.md#the-fix)).
Operating systems offer this unevenly. Linux resolves a whole path beneath a
handle in one system call; macOS can refuse every link in a path but cannot
confine `..`; Windows opens relative to a handle and can refuse reparse points
per open; other POSIX systems offer one component at a time. A portable
library therefore needs a resolver of its own as well as the kernel's, and
that is where such libraries are weakest: one that retries with its own
resolver whenever the kernel refuses hands an attacker the weaker of the two.

This interface is built only from the surviving primitive. A program holds
[directory capabilities](../../../glossary.md#directory-capability): open
directory handles, each carrying a fixed set of rights and a fixed policy for
symbolic links and `..`. Every operation names a single entry relative to a
handle. A path of several components is resolved one entry at a time by the
[component walk](../../../glossary.md#component-walk), or in one call by a
kernel resolver that enforces the same policy. Which of the two serves a root
is decided once, when the root is opened, and one lookup never uses both. By
default a walk refuses every symbolic link, every `..` and every crossing into
another mounted file system, the one behaviour identical on every supported
platform; a root may instead follow links and `..` that stay inside it. Rights
live in the handle's type. A handle opened from another has the same rights,
and [attenuation](../../../glossary.md#attenuation) derives one with fewer;
nothing derives one with more. Exactly one function turns a path into a first
handle. It requires a token named for the
[ambient authority](../../../glossary.md#ambient-authority) it exercises, so
every place that creates authority can be found by searching for that name.

In scope are the shared I/O error vocabulary; the handle, rights and policy
types; the single-entry operations; four algorithms built on them, namely
walking a path, creating missing directories, removing a tree and replacing a
file atomically; three backends; and the kernel resolvers of Linux, macOS and
Windows, which the two backends that make system calls both use. The contract
belongs to `sparkles:event-horizon`, which owns every interaction between
Sparkles and the operating system; its types and two of its backends live in
lower packages so that code without an event loop can use them. The interface
does not defend against an attacker who can change the mount table, overmount
`/proc`, or control a directory above the handle a program starts from; that
stricter guarantee is a container runtime's concern. A file hard-linked into
the tree counts as inside it. The interface does not change permissions,
ownership or timestamps after creation, create hard links, read extended
attributes, watch for changes, or offer a handle that locates an entry
without opening it. A handle whose backend is chosen at run time is
deferred until a consumer needs one
([DV12](./decisions.md#dv12-the-backend-is-part-of-the-handle-type)), and so
is following a symbolic link named as the last component of a file open
([DV6](./decisions.md#dv6-single-name-operations-one-multi-name-entry-point)).

Sections 1–4 give the terms, the contract at a glance, the threat model and
the packages. Sections 5–10 state what a caller can rely on: handles and
rights, operations, path policy, resolution, deletion and errors; §11 holds
every limit. What a backend must do to provide this contract, including the
kernel resolvers, the mapping of native results and the in-memory backend, is
specified in [backends.md](./backends.md). [testing.md](./testing.md) names
the check and oracle for every requirement and holds the evidence ledger;
[PLAN.md](./PLAN.md) orders delivery, including moving existing code onto this
interface; [decisions.md](./decisions.md) records why each choice was made.
The evidence base is the
[safe path traversal research catalog](../../../research/safe-path-traversal/index.md).

## 1. Terminology

The terms this specification coins, or uses in a narrower sense than usual,
are defined once in the [glossary](../../../glossary.md) and listed here with
the rest of `sparkles:event-horizon`'s vocabulary:

<GlossaryList owner="sparkles:event-horizon" />

A directory capability is an enforcement boundary. The
[capability row](../../../glossary.md#capability-row) through which
event-horizon code receives its services is not, and the two are unrelated
despite the shared word.

## 2. The contract at a glance

_The example is illustrative: it uses the names this page defines, but it is
not compiled._

```d
IoResult!void publishReport(BlockingVfs* vfs, in char[] outDir, in char[] text)
{
    // The one call that resolves a path from the process root. Passing
    // ambientAuthority() makes every such call findable by name.
    auto root = openRoot!(Rights.all)(vfs, outDir, ambientAuthority());
    if (root.hasError)
        return ioErr!void(root.error);

    // Below the root, every lookup is relative to a held handle. The default
    // policy refuses symbolic links and `..` on every platform.
    auto dir = root.value.walkAll("reports/latest");
    if (dir.hasError)
        return ioErr!void(dir.error);

    // Readers see the old summary or the new one, never a mix, and only the
    // owner may read the new one.
    auto written = dir.value.writeFileAtomic("summary.txt", text, OwnerOnly());
    if (written.hasError)
        return written;

    // A helper gets a narrowed handle: it may look up, list, stat and read.
    // Calling view.removeTree("x") would not compile.
    auto view = dir.value.attenuate!(Rights.readOnly);
    auto file = view.openFile!(OpenMode.read)("summary.txt");
    if (file.hasError && file.error.kind == ErrorKind.symlinkRefused)
        return ioErr!void(file.error); // replaced by a link since the write
    return ioOk();
}
```

The names a caller handles:

| Name                                 | What it is                                                                | Defined in                                                  |
| ------------------------------------ | ------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `openRoot!(R)`                       | the only function that resolves a path from the process root              | [`VFH7`](#vfh7-the-ambient-constructor)                     |
| `Dir!(V, R)`, `File!(V, R)`          | an owning, move-only directory or file over backend `V` with rights `R`   | [`VFH1`](#vfh1-owning-handles)                              |
| `DirRef!(V, R)`, `FileRef!(V, R)`    | a borrow that cannot close or outlive its owner                           | [`VFH2`](#vfh2-borrowed-handles)                            |
| `Rights`                             | the compile-time set of operations a handle permits                       | [`VFH4`](#vfh4-rights)                                      |
| `ResolvePolicy`                      | how a walk treats symbolic links, `..` and mount points                   | [`VFP1`](#vfp1-the-policy-value)                            |
| `Shared`, `OwnerOnly`, `PosixMode`   | who may access an entry a call creates                                    | [`VFO5`](#vfo5-sharing-of-created-entries)                  |
| `IoResult!T`, `IoError`, `ErrorKind` | the result of every operation, and the portable classification of failure | [`VFE1`](#vfe1-one-error-type), [`VFE2`](#vfe2-error-kinds) |
| `AmbientAuthority`                   | the token `openRoot` requires, obtained only from `ambientAuthority()`    | [`VFH7`](#vfh7-the-ambient-constructor)                     |

Every later requirement is read against these invariants:

1. **One ambient entry point.** Only `openRoot` resolves a path from the
   process root or current directory
   ([`VFH7`](#vfh7-the-ambient-constructor)). Every other operation names its
   target by a handle and one entry name.
2. **Authority only narrows.** A derived handle never has more rights than its
   source, and never a different policy
   ([`VFH5`](#vfh5-attenuation-only), [`VFP2`](#vfp2-policy-is-fixed-at-the-root)).
3. **One resolver per lookup.** A lookup the kernel resolver refused is never
   retried with the component walk ([`VFR4`](#vfr4-never-downgrade-a-lookup)).
4. **Errors are values.** Operations return `IoResult!T`. No caller-supplied
   name, path or file-system state causes an assertion failure.
5. **Bounded and attribute-clean.** Every operation and algorithm is
   `@safe nothrow @nogc` and uses memory bounded by the [limits](#_11-limits).
   Allocation is measured, not inferred from `@nogc`.
6. **The held handle is the identity.** No operation remembers a path or a
   `(device, inode)` pair to recognise an object later. The mount check's
   device comparison is the one documented exception
   ([`VFP8`](#vfp8-mount-boundaries)).

## 3. Threat model

**Attacker-controlled inputs.** The contents of the tree beneath a root,
changed concurrently with any operation: entries created, removed, renamed,
replaced by symbolic links, directory junctions or other directories, and
directories moved elsewhere. Every relative path and every name passed to an
operation. The target text of every symbolic link met.

**Trusted.** The root handle once `openRoot` returns it, and the path given to
`openRoot`. The mount table and `/proc`. Code holding an `AmbientAuthority`
token.

**Enforcement boundary.** The backend call that opens, creates, lists, reads,
writes or removes. Checks made anywhere else are advisory.

**Forbidden effect.** Through a directory capability derived from root `R`, no
operation may read, write, create, list or remove an object that was not
[beneath](../../../glossary.md#beneath) `R` at the moment of the step that
reached it.

**Beneath** is defined operationally. An object is beneath `R` if it was
reached from `R` by a chain of steps in which each step opened one directory
entry relative to the handle the previous step returned, no step followed a
symbolic link except as the active policy permits
([§7](#_7-paths-and-resolution-policy-vfp)), and no `..` step climbed above
`R`. The definition refers only to handles held at the time, never to a path
string. A directory moved away after it was opened therefore remains beneath
`R` for operations through the handle already held; that is the property a
handle exists to provide
([comparison § axis 5](../../../research/safe-path-traversal/comparison.md#axis-5-identity)).

## 4. Packages

`sparkles:event-horizon` owns this contract, as it owns every interaction
between Sparkles and the operating system. The parts that need no event loop
live in lower packages, so that code which must not depend on the loop, such
as fixtures in every package's test build, can use them.

| Package                      | Provides                                                                                                                                                      | Depends on                                    |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `sparkles:base`              | the error vocabulary in `sparkles.base.io.errors`; handles, rights, policy and the walk, removal and atomic-write algorithms in `sparkles.base.vfs`; `MemVfs` | nothing new                                   |
| `sparkles:event-horizon-sys` | the system-call bindings and `BlockingVfs`, in `sparkles.event_horizon.sys.vfs`; no event loop                                                                | `sparkles:base`                               |
| `sparkles:event-horizon`     | `RingVfs`, the `fs` member of its capability row, and the error vocabulary re-exported                                                                        | `sparkles:event-horizon-sys`, `sparkles:base` |

Mapping native results into the error vocabulary belongs to the backend that
makes the system call ([backends.md § 2](./backends.md#_2-native-results)).
Network and process failures use the same vocabulary; event-horizon's
specification defines their kinds and mapping
([§9.1](../../event-horizon/SPEC.md#_9-1-ioerror-and-ioresult)).

## 5. Handles and rights (`VFH`)

A handle is the capability: holding one is what permits an operation, and its
type states which operations. Each requirement's check is listed in
[testing.md](./testing.md#handles-and-rights-vfh).

<a id="vfh1-owning-handles"></a>
**VFH1: Owning handles.** `Dir!(V, R)` and `File!(V, R)` **must** hold a
`V.Handle` and a pointer to the backend instance `V`, be move-only
(`@disable this(this)`), and close their handle exactly once: in `close()` if
it is called, otherwise in the destructor. `close()` **must** return a close
failure; the destructor drops it. A default-initialized handle is empty:
every operation on it **must** fail with `other` and the context
`"empty handle"`, and closing it does nothing.

_Rationale:_ The `expected` library cannot hold a payload without a default
constructor, and every operation returns its handle in an `IoResult`
([DV24](./decisions.md#dv24-empty-handles-instead-of-no-default-constructor)).

<a id="vfh2-borrowed-handles"></a>
**VFH2: Borrowed handles.** `DirRef!(V, R)` and `FileRef!(V, R)` borrow an
owner. They **must** provide the owner's operations except `close`, and under
`-preview=dip1000` a borrow **must not** outlive its owner.

<a id="vfh3-the-backend-is-part-of-the-type"></a>
**VFH3: The backend is part of the type.** A handle from one backend **must
not** be accepted by another backend's operations, including as `renameAt`'s
destination.

<a id="vfh4-rights"></a>
**VFH4: Rights.** `Rights` is a set of `lookup`, `list`, `stat`, `read`,
`write`, `create`, `createShared`, `remove` and `rename`. The preset
`readOnly` **must** be `lookup | list | stat | read`, and the preset `all`
**must** contain every member. `create` alone permits creating entries only
their owner may access; `createShared` also permits entries others may access
([`VFO5`](#vfo5-sharing-of-created-entries)).

<a id="vfh5-attenuation-only"></a>
**VFH5: Attenuation only.** A handle opened from a `Dir` **must** carry its
parent's rights. `dir.attenuate!(R2)` yields a borrow with rights `R2` and
**must** compile only if `R2` is a subset of the parent's rights. No function
widens rights.

<a id="vfh6-rights-are-checked-at-compile-time"></a>
**VFH6: Rights are checked at compile time.** Calling an operation whose right
([`VFO3`](#vfo3-the-operation-set)) is absent from the handle's rights **must
not** compile.

<a id="vfh7-the-ambient-constructor"></a>
**VFH7: The ambient constructor.** The signature is:

```d
IoResult!(Dir!(V, R)) openRoot(Rights R, V)(
    V* vfs,
    in char[] path,
    AmbientAuthority authority,
    ResolvePolicy policy = ResolvePolicy.init,
    CreateDefault create = CreateDefault.shared_,  // shared_ | ownerOnly
    bool requireKernel = false,
);
```

`openRoot` is the only operation that resolves a path from the process root
or current directory, and the only one that follows symbolic links in the
path it is given. An `AmbientAuthority` value **must** be obtainable only by
calling `ambientAuthority()`. The returned `Dir` carries rights `R`, the
policy `policy` ([`VFP2`](#vfp2-policy-is-fixed-at-the-root)) and the creation
default `create` ([`VFO5`](#vfo5-sharing-of-created-entries)).

_Rationale:_ A token with a fixed name makes every escape from the capability
discipline findable by searching for `ambientAuthority(`, as in
[cap-std](../../../research/safe-path-traversal/cap-std.md#design-philosophy).

<a id="vfh8-handles-are-not-inherited"></a>
**VFH8: Handles are not inherited.** Every handle a backend opens **must** be
close-on-exec on POSIX and non-inheritable on Windows.

## 6. Operations (`VFO`)

A `Dir` offers a closed set of operations on single entries, plus four
algorithms over them. Each requirement's check is listed in
[testing.md](./testing.md#operations-vfo).

<a id="vfo1-names"></a>
**VFO1: Names.** Every operation that takes a name takes exactly one
directory-entry name as `in char[]`. It **must** fail with `invalidName`,
before any backend call, if the name is empty, is `.` or `..`, or contains
`/` or NUL. On Windows it **must** also fail with `invalidName` if the name
contains `\` or `:`, ends in a dot or a space, is a reserved device name
(`CON`, `PRN`, `AUX`, `NUL`, `COM0`–`COM9`, `LPT0`–`LPT9`, with or without an
extension), or is not well-formed UTF-8.

_Rationale:_ Win32 and NT canonicalize those forms differently, which is how
path validation has been bypassed on Windows
([Forshaw § dimension 4](../../../research/safe-path-traversal/forshaw-windows-symlinks.md)).

<a id="vfo2-the-named-entry-is-never-followed"></a>
**VFO2: The named entry is never followed.** Every single-name operation
**must** act on the named entry itself. If that entry is a symbolic link,
`openDir` and `openFile` fail with `symlinkRefused`, `statAt` reports a link,
`readlinkAt` reads it, `unlinkAt` removes the link, and `renameAt` moves the
link.

<a id="vfo3-the-operation-set"></a>
**VFO3: The operation set.** A `Dir` **must** provide exactly these
operations, each gated by the rights shown
([`VFH6`](#vfh6-rights-are-checked-at-compile-time)). `sharing` is the
optional argument of [`VFO5`](#vfo5-sharing-of-created-entries); passing
`Shared()` or `PosixMode` additionally needs `createShared`.

| Operation                               | Right(s)                                            | Result                                                       |
| --------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------ |
| `openDir(name)`                         | `lookup`                                            | a child `Dir` with the same rights                           |
| `openFile!mode(name, sharing)`          | `read` and/or `write`; `create` for a creating mode | a `File`                                                     |
| `mkdirAt(name, sharing)`                | `create`                                            | nothing; `exists` if present                                 |
| `statAt(name, mask)`                    | `stat`                                              | a `Stat` of the entry itself                                 |
| `readlinkAt(name, buffer)`              | `stat`                                              | the target bytes, as a slice of `buffer`                     |
| `symlinkAt(name, target)`               | `create`                                            | nothing; see [`VFO10`](#vfo10-symbolic-link-targets)         |
| `unlinkAt(name)`                        | `remove`                                            | nothing; `isADirectory` for a directory                      |
| `rmdirAt(name)`                         | `remove`                                            | nothing; `notEmpty` if it has entries                        |
| `renameAt(name, dst, dstName)`          | `rename` on both                                    | nothing; replaces a non-directory target                     |
| `list(buffer)`                          | `list`                                              | a `Listing` over the entries                                 |
| `walk(path)`                            | `lookup`                                            | a `Dir` for the directory `path` names                       |
| `walkAll(path, sharing)`                | `lookup`, `create`                                  | as `walk`, creating missing directories                      |
| `removeTree(name)`                      | `lookup`, `list`, `remove`                          | nothing; see [§9](#_9-deletion-vfd)                          |
| `writeFileAtomic(name, bytes, sharing)` | `create`, `write`, `rename`                         | nothing; readers see the old or the new content, never a mix |

A `File` **must** provide `read(buffer)`, `write(bytes)`, `stat(mask)`,
`sync()` and `close()`, gated by the rights it was opened with.

<a id="vfo4-open-modes"></a>
**VFO4: Open modes.** `openFile` **must** take its mode as a template
argument, so the rights the mode needs are checked at compile time
([`VFH6`](#vfh6-rights-are-checked-at-compile-time)). A mode combines `read`,
`write`, `readWrite` or `append` access combined with `existing` (fail with `notFound` if
absent), `createNew` (fail with `exists` if present) or `createOrTruncate`. A
creating mode **may** add `executable`, which marks the created file
executable for everyone its sharing admits.

<a id="vfo5-sharing-of-created-entries"></a>
**VFO5: Sharing of created entries.** Every operation that creates a file or
directory **must** accept an optional sharing argument of one of these types:

- `Shared()`: the platform's ordinary sharing. On POSIX a file is created
  with mode `0666`, or `0777` with `executable`, and a directory with `0777`,
  in each case less the process umask. On Windows the entry inherits its
  parent's access control.
- `OwnerOnly()`: only the creating user may access the entry. On POSIX a
  file gets `0600`, or `0700` with `executable`, and a directory `0700`, less
  the umask. On Windows the entry gets an access control list that admits
  only its owner.
- `PosixMode(m)`: exactly the mode bits `m`, less the umask. It exists only
  under `version (Posix)`, and combining it with `executable` **must not**
  compile, because `m` already states the bits.

Passing `Shared()` or `PosixMode` **must not** compile on a handle without
the `createShared` right. A call without the argument uses the handle's
creation default: the `create` argument of the `openRoot` that produced it,
narrowed to `OwnerOnly()` on a handle without `createShared`. No operation
changes the process umask.

_Rationale:_ The default matches what other tools create, so ordinary output
stays readable to its usual readers, and the umask remains the user's control.
Removing `createShared` gives a handle's holder a floor it cannot lower,
using the same compile-time rights as every other operation
([DV22](./decisions.md#dv22-sharing-of-created-entries)).

<a id="vfo6-stat"></a>
**VFO6: `Stat`.** `statAt` and `File.stat` **must** return the entry's kind
(`regular`, `directory`, `symlink` or `other`), its executable bit, its size
and its device. They **must** fill the modification time only when the mask
requests it. Under `version (Posix)` a `Stat` also carries the permission
bits. On Windows the executable bit is always false.

_Rationale:_ Hashing a tree by content needs the kind and executable bit of
every entry, and only some uses need a time; the permission bits let a caller
recreate a file with the mode it had ([`VFO9`](#vfo9-atomic-write)).

<a id="vfo7-listing"></a>
**VFO7: Listing.** `list` **must** read entries through a listing independent
of every other listing of the same directory. Entries come in an unspecified
order, never include `.` or `..`, and carry a name and a kind hint that may be
`unknown`. Each name is a slice of the caller's buffer, valid until the next
advance. A buffer too small for one entry yields `bufferTooSmall`.

<a id="vfo8-rename-stays-in-one-root"></a>
**VFO8: Rename stays in one root.** `renameAt` **must** fail with
`escapesRoot`, before any backend call, if `dst` does not descend from the
same root as the source directory.

<a id="vfo9-atomic-write"></a>
**VFO9: Atomic write.** `writeFileAtomic` **must** create a file under a fresh
temporary name in the same directory, with `createNew` and the requested
sharing, write and sync it, and rename it over `name`. On any failure it
**must** remove the temporary entry. A concurrent reader of `name` observes
either the complete old content or the complete new content. The replacement
does not take the replaced file's permissions; a caller who wants them reads
them with `statAt` and passes them as `PosixMode`.

<a id="vfo10-symbolic-link-targets"></a>
**VFO10: Symbolic link targets.** `symlinkAt` **must** fail with `escapesRoot`,
before any backend call, if `target` is absolute by the rules of
[`VFP3`](#vfp3-path-syntax): it begins with `/`, or on Windows with `\`, a
drive letter, a UNC prefix or an NT prefix. It **must** fail with
`invalidName` if `target` is empty or contains NUL. Any other target is stored
verbatim, including one whose `..` components climb above the root.

_Rationale:_ No walk through this interface can follow an absolute target
([`VFP5`](#vfp5-beneath)), so such a link only ever misleads other tools, as
cap-std also judges. A relative target's escape depends on where the link
ends up, which renames can change, so it is not checked
([DV23](./decisions.md#dv23-symbolic-link-targets)).

## 7. Paths and resolution policy (`VFP`)

`walk` and `walkAll` are the only operations that take a path. A root's
policy decides what the path may contain and what a walk does on meeting a
symbolic link, a `..` or a mount point. Each requirement's check is listed in
[testing.md](./testing.md#paths-and-resolution-policy-vfp).

<a id="vfp1-the-policy-value"></a>
**VFP1: The policy value.** A root carries one `ResolvePolicy`:

```d
struct ResolvePolicy
{
    SymlinkPolicy symlinks = SymlinkPolicy.none;  // none | beneath
    DotDotPolicy dotDot = DotDotPolicy.reject;    // reject | inScope
    bool crossMounts = false;
}
```

The defaults are the strictest behaviour that is identical on every supported
platform
([comparison § axes 2 and 3](../../../research/safe-path-traversal/comparison.md#axis-2-what-means)).

<a id="vfp2-policy-is-fixed-at-the-root"></a>
**VFP2: Policy is fixed at the root.** The policy is chosen at `openRoot`.
Every handle derived from the root **must** carry the same value, and no
operation changes it.

<a id="vfp3-path-syntax"></a>
**VFP3: Path syntax.** A walk path is split on `/` on every platform, and also
on `\` on Windows. Empty and `.` components are dropped; a path with nothing
left names the directory itself and yields a new handle to it. Before any
backend call, a walk **must** fail with `escapesRoot` for a path that is
absolute or begins with a drive letter, a UNC prefix or an NT prefix, and with
`invalidName` for a component that fails [`VFO1`](#vfo1-names).

<a id="vfp4-no-symlinks"></a>
**VFP4: `symlinks = none`.** A walk that meets a symbolic link or a
name-surrogate reparse point, as an intermediate or the final component,
**must** fail with `symlinkRefused` and open nothing reached through it.

<a id="vfp5-beneath"></a>
**VFP5: `symlinks = beneath`.** A walk that meets a symbolic link **must**
continue by splicing the link's target into the remaining path, resolved
relative to the directory holding the link. An absolute target, or a target
whose `..` climbs above the root, fails with `escapesRoot`. A walk that
follows more links than the [symlink hop limit](#_11-limits) fails with
`symlinkLoop`. A walk whose remaining path, with a target spliced in, exceeds
the [spliced path limit](#_11-limits) fails with `nameTooLong`. A `..` inside a link target is always resolved in scope,
whatever `dotDot` says.

_Rationale:_ The kernel's `RESOLVE_BENEATH` resolves `..` in targets the same
way, and about 40% of real symbolic links contain `..`
([Go `os.Root`](../../../research/safe-path-traversal/go-os-root.md#design-philosophy)).

<a id="vfp6-reject-dot-dot"></a>
**VFP6: `dotDot = reject`.** A `..` component in the path given to a walk
**must** fail with `dotDotRefused` before any backend call, even when it
would stay in scope.

_Rationale:_ The kernels disagree about `..`
([comparison § axis 2](../../../research/safe-path-traversal/comparison.md#axis-2-what-means)),
so refusing it is the only behaviour identical on every platform.

<a id="vfp7-in-scope-dot-dot"></a>
**VFP7: `dotDot = inScope`.** A `..` component **must** return to the handle
of the directory the walk entered before the current one. The walk keeps the
handles of the directories it has entered and pops one per `..`; it **must
not** open `..` through the backend. A `..` with no entered directory to
return to fails with `escapesRoot`.

<a id="vfp8-mount-boundaries"></a>
**VFP8: Mount boundaries.** With `crossMounts = false`, a walk step that
enters a directory on a different file system from its parent **must** fail
with `crossesMount`. `removeTree` **must not** descend into such a directory;
it fails with `crossesMount` and leaves that directory and its contents
untouched. Where a backend can detect a crossing only by comparing devices
after the open, the check races with a concurrent mount, and the root **must**
report `mountCheck = racy` ([`VFR2`](#vfr2-the-root-reports-its-resolver)).
With `crossMounts = true` no check is made.

## 8. Resolution (`VFR`)

A walk is resolved either by a kernel resolver that takes the whole path or by
the component walk in `sparkles.base.vfs.walk`. These requirements state what
a caller observes; [backends.md § 3](./backends.md#_3-resolution-in-a-native-backend)
states how a backend provides it. Each requirement's check is listed in
[testing.md](./testing.md#resolution-vfr).

<a id="vfr1-two-resolvers-one-result"></a>
**VFR1: Two resolvers, one result.** For every policy and every tree, the
kernel resolver and the component walk **must** produce the same outcome: the
same object, or failures of the same kind.

<a id="vfr2-the-root-reports-its-resolver"></a>
**VFR2: The root reports its resolver.** Every `Dir` **must** report its
root's `resolution`, either `kernelWholePath` or `componentWalk`, and its
`mountCheck`, one of `kernel`, `racy` or `none`. Both are decided when
`openRoot` runs ([`VFB3`](./backends.md#vfb3-the-whole-path-resolver)).

<a id="vfr3-a-root-may-require-the-kernel-resolver"></a>
**VFR3: A root may require the kernel resolver.** `openRoot` with
`requireKernel: true` **must** fail with `unsupported`, and return no handle,
if the backend cannot provide `kernelWholePath` for the policy.

<a id="vfr4-never-downgrade-a-lookup"></a>
**VFR4: Never downgrade a lookup.** When a root's resolution is
`kernelWholePath` and the kernel resolver refuses a lookup, that refusal
**must** be the result. The component walk **must not** run for the same call.

_Rationale:_ Otherwise a bug in the fallback becomes reachable by any input
that makes the kernel refuse
([filepath-securejoin § the downgrade rule](../../../research/safe-path-traversal/filepath-securejoin.md#the-openat2-path-and-the-downgrade-rule)).

<a id="vfr5-at-most-one-change"></a>
**VFR5: At most one change of resolver.** A root's `resolution` **may** change
from `kernelWholePath` to `componentWalk` at most once in a process, when the
backend finds the kernel resolver withdrawn, and **must not** change back.
After that change, every walk on a root opened with `requireKernel` fails with
`unsupported`.

_Rationale:_ A process may install a seccomp filter after it starts
([libpathrs § dimension 5](../../../research/safe-path-traversal/libpathrs.md)).

<a id="vfr6-race-exhaustion-is-an-error"></a>
**VFR6: Race exhaustion is an error.** When the kernel reports, on every
attempt within the [race retry limit](#_11-limits), that it could not rule out
a concurrent rename, the walk **must** fail with `raceRetryExhausted`. It
**must not** fall back to the component walk.

_Rationale:_ libpathrs measured about a 0.1% failure rate at 128 retries under
an all-cores rename storm, and a silent fallback after a few retries, as in
cap-std, would violate [`VFR4`](#vfr4-never-downgrade-a-lookup)
([`linux-openat2` § dimension 2](../../../research/safe-path-traversal/linux-openat2.md)).

## 9. Deletion (`VFD`)

`removeTree(name)` removes the named entry and, if it is a directory,
everything beneath it. Each requirement's check is listed in
[testing.md](./testing.md#deletion-vfd).

<a id="vfd1-bounded-explicit-stack"></a>
**VFD1: Bounded, explicit stack.** `removeTree` **must** hold the directories
it descends into on an explicit stack of at most the
[removal depth limit](#_11-limits), not on the call stack. Meeting a
directory deeper than the limit **must** fail with `depthExceeded` and leave
everything outside the named entry untouched.

<a id="vfd2-never-descend-a-link"></a>
**VFD2: Never descend a link.** `removeTree` **must** classify each entry by
opening it as a directory without following it
([`VFO2`](#vfo2-the-named-entry-is-never-followed)). A symbolic link or
name-surrogate reparse point is removed as an entry and never entered, under
every policy.

<a id="vfd3-listing-until-empty"></a>
**VFD3: Listing until empty.** `removeTree` **must** list each directory
through its own handle ([`VFO7`](#vfo7-listing)) and list it again until a
listing yields no entries, because removing entries during a listing can make
the listing skip some. When removing an emptied directory finds new entries in
it, `removeTree` lists it again, up to the [re-listing limit](#_11-limits),
and then fails with `notEmpty`.

<a id="vfd4-vanished-entries"></a>
**VFD4: Vanished entries.** An entry that is gone when `removeTree` removes or
opens it, with `notFound`, **must not** be an error.

<a id="vfd5-partial-progress-is-the-failure-state"></a>
**VFD5: Partial progress is the failure state.** On any other failure,
`removeTree` **must** stop and return it. Entries already removed stay
removed, and no entry outside the named one is affected.

## 10. Errors (`VFE`)

Every failure is a value of one error type, shared with the rest of
`sparkles:event-horizon`. Each requirement's check is listed in
[testing.md](./testing.md#errors-vfe).

<a id="vfe1-one-error-type"></a>
**VFE1: One error type.** Every operation of this interface **must** return
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

`IoError`, `IoResult`, `ErrorKind`, `OpKind`, `IoErrorStage` and `NoGcHook`
are defined in `sparkles.base.io.errors`. `sparkles:event-horizon` uses the
same types for every operation it performs
([event-horizon §9.1](../../event-horizon/SPEC.md#_9-1-ioerror-and-ioresult)).

<a id="vfe2-error-kinds"></a>
**VFE2: Error kinds.** `ErrorKind` **must** contain at least these members,
with these meanings. It also contains the network and process kinds, which
event-horizon's specification defines.

| Kind                 | Meaning                                                                                                           |
| -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `notFound`           | the named entry does not exist                                                                                    |
| `exists`             | a create found an entry already there                                                                             |
| `notADirectory`      | a directory was required and the entry is not one                                                                 |
| `isADirectory`       | a non-directory was required and the entry is a directory                                                         |
| `notEmpty`           | a directory removal found entries                                                                                 |
| `permission`         | the operating system denied access                                                                                |
| `busy`               | the entry is in use in a way that blocks the operation                                                            |
| `invalidName`        | a name failed [`VFO1`](#vfo1-names), or a link target failed [`VFO10`](#vfo10-symbolic-link-targets)              |
| `escapesRoot`        | the operation would leave the root: an absolute path, an absolute symbolic-link target, or a climb above the root |
| `dotDotRefused`      | a `..` component under the `reject` policy                                                                        |
| `symlinkRefused`     | a symbolic link or name-surrogate reparse point where the policy forbids one                                      |
| `symlinkLoop`        | more links followed than the symlink hop limit allows                                                             |
| `crossesMount`       | a step entered a different file system under `crossMounts = false`                                                |
| `nameTooLong`        | a name exceeds the [name length limit](#_11-limits)                                                               |
| `bufferTooSmall`     | a caller-supplied buffer cannot hold the result                                                                   |
| `depthExceeded`      | a walk or removal exceeded its depth limit                                                                        |
| `raceRetryExhausted` | the kernel reported a race on every attempt within the race retry limit                                           |
| `unsupported`        | the backend or platform cannot provide what was asked                                                             |
| `other`              | anything unclassified; `code` carries the detail                                                                  |

<a id="vfe3-the-same-kind-from-either-resolver"></a>
**VFE3: The same kind from either resolver.** A failure **must** carry the
same `kind` whichever resolver detected it
([`VFR1`](#vfr1-two-resolvers-one-result)); `code` may differ.

_Rationale:_ libpathrs makes its emulated resolver synthesise the kernel's
errno so callers need one error model
([libpathrs § dimension 6](../../../research/safe-path-traversal/libpathrs.md)).

<a id="vfe4-operation-kinds"></a>
**VFE4: Operation kinds.** `OpKind` **must** name every operation of
[§6](#_6-operations-vfo) distinctly: `openAt`, `mkdirAt`, `statAt`,
`readlinkAt`, `symlinkAt`, `unlinkAt`, `rmdirAt`, `renameAt`, `readDir`,
`read`, `write`, `fsync` and `close`, plus `resolve` for a whole-path lookup.

## 11. Limits

| Limit                  | Value                                                      | Exceeding it         |
| ---------------------- | ---------------------------------------------------------- | -------------------- |
| Name length            | 255 UTF-8 bytes on POSIX; 255 UTF-16 code units on Windows | `nameTooLong`        |
| Walk depth             | 64 entered directories, shared with the `..` handle stack  | `depthExceeded`      |
| Removal depth          | 64 directories                                             | `depthExceeded`      |
| Symlink hops           | 40 per walk                                                | `symlinkLoop`        |
| Spliced path           | 4096 bytes of remaining path per walk                      | `nameTooLong`        |
| Removal re-listing     | 16 per directory                                           | `notEmpty`           |
| Race retries           | 128 per whole-path call                                    | `raceRetryExhausted` |
| Windows delete retries | 50 per entry                                               | `busy` or `notEmpty` |

Every stack is a fixed-capacity buffer of the stated size; no operation
allocates from the GC. `MemVfs`'s arena is bounded separately
([`VFM4`](./backends.md#vfm4-arena)).
