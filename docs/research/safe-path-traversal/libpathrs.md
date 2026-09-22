# libpathrs

The reference implementation of "safe path resolution inside an untrusted
directory" on Linux — `openat2(RESOLVE_IN_ROOT)` in the kernel when it exists,
an `O_PATH` component walk cross-checked through `/proc/self/fd` when it does
not, and a hardened `procfs` layer so that the cross-check itself cannot be
fooled.

|                           |                                                                                                                                                                                                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | library (Rust core; C ABI; Go and Python bindings)                                                                                                                                                                                                                               |
| **Year**                  | 2019 (first release `0.0.0` 2020-01-05; `0.2.6` 2026-09-05)                                                                                                                                                                                                                      |
| **Authors / Maintainers** | Aleksa Sarai (`cyphar`); copyright SUSE LLC 2019–2025, Aleksa Sarai 2026                                                                                                                                                                                                         |
| **Language**              | Rust (`#![forbid(unsafe_code)]` in the API modules; `unsafe` confined to `syscalls.rs`)                                                                                                                                                                                          |
| **License**               | `MPL-2.0 OR LGPL-3.0-or-later` (core); `MPL-2.0` (bindings, examples)                                                                                                                                                                                                            |
| **Repository**            | [`cyphar/libpathrs`][repo] at `6acffea4`                                                                                                                                                                                                                                         |
| **Platforms**             | Linux only ("in theory back to Linux 2.6.39"; recommended ≥ 5.6, all hardening ≥ 6.8)                                                                                                                                                                                            |
| **Primitive**             | `openat2(2)` with `RESOLVE_IN_ROOT \| RESOLVE_NO_MAGICLINKS`; fallback `openat(O_PATH \| O_NOFOLLOW)` per component + `readlink(/proc/thread-self/fd/N)` verification                                                                                                            |
| **Source read**           | `README.md`, `docs/*.md`, `src/root.rs`, `src/resolvers.rs`, `src/resolvers/{openat2,procfs}.rs`, `src/resolvers/opath/{imp,symlink_stack}.rs`, `src/flags.rs`, `src/handle.rs`, `src/procfs.rs`, `src/utils/{fd,dir}.rs`, `src/syscalls.rs`, `include/pathrs.h`, `CHANGELOG.md` |

## Overview

### What it solves

Every operation a program does "under" a directory it does not fully trust —
a container rootfs, an unpacked archive, a user-supplied tree — is a chance
for an attacker who can rename or symlink inside that tree to redirect the
operation outside it. libpathrs's framing ([`README.md`][readme]):

> This library implements a set of C-friendly APIs (written in Rust) to make
> path resolution within a potentially-untrusted directory safe on GNU/Linux.
> There are countless examples of security vulnerabilities caused by bad
> handling of paths; this library provides an easy-to-use set of VFS APIs to
> avoid those kinds of issues.

The [`docs/avoidable-vulnerabilities.md`][avoidable] catalogue behind that
sentence is reproduced in [Dimension 1](#dimension-1--threat-model).

### Design philosophy

Three commitments recur through the source:

1. **A path string is never the result of an operation; a file descriptor is.**
   `Root::resolve` returns a `Handle` (an `O_PATH` fd), not a canonical path,
   and the C API was redesigned in 0.1.0 to be "file descriptor based,
   removing the need for complicated freeing logic and matching what most
   kernel APIs actually look like" ([`CHANGELOG.md`][changelog]).
2. **Prefer the kernel; emulate only what the kernel refuses.** The
   `openat2` resolver is the default; the `O_PATH` walk exists so that
   "libpathrs will function on very old kernels" and under seccomp filters,
   with the module doc admitting it "will fail in fewer cases because it has
   access to in-kernel locks" ([`opath/imp.rs`][opath-imp]).
3. **Detect and refuse rather than tolerate.** The `Root` docs: "If at any
   point an attack is detected during the execution of a `Root` method, an
   error will be returned. The method of attack detection is multi-layered
   and operates through explicit `/proc/self/fd` checks as well as (in the
   case of the native backend) kernel-space checks that will trigger `-EXDEV`
   in certain attack scenarios" ([`root.rs`][root]).

## How it works

The public surface is small. A `Root` wraps an `O_PATH | O_DIRECTORY` fd plus
a `Resolver` (backend + `ResolverFlags`); `RootRef` is the `BorrowedFd`
twin for callers that already own the fd. Every method is implemented on
`RootRef` and forwarded from `Root` ([`root.rs`][root]):

| Method                           | Mechanism                                                                                                                                                                               |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Root::open(path)`               | `openat(AT_FDCWD, path, O_PATH \| O_DIRECTORY)`; the root path must be "a fully-resolved pathname with no symlink components"                                                           |
| `resolve(path)`                  | `resolver.resolve(root, path, no_follow_trailing = false)` → `Handle`; trailing symlinks followed, all symlinks scoped to the root                                                      |
| `resolve_nofollow(path)`         | same with `no_follow_trailing = true` → an `O_PATH \| O_NOFOLLOW` handle to the symlink itself                                                                                          |
| `open_subpath(path, flags)`      | one-shot `openat2` (no intermediate `Handle`); `O_CREAT`/`O_EXCL` rejected; emulated on the fallback path as resolve + `reopen`                                                         |
| `readlink(path)`                 | `resolve_nofollow` then `readlinkat(fd, "")`; result explicitly "not modified to be safe outside of the root"                                                                           |
| `create(path, InodeType)`        | `resolve_parent` (resolve the dirname, split off a slash-free basename) then `mknodat`/`mkdirat`/`symlinkat`/`linkat` on `(dirfd, name)`                                                |
| `create_file(path, flags, perm)` | `resolve_parent` then `openat(dir, name, flags \| O_CREAT, mode)` — the only inode type with an atomic create+open; `O_TMPFILE` resolves the directory instead                          |
| `mkdir_all(path, perm)`          | `resolve_partial` to the deepest existing component, then `mkdirat` + `openat(O_NOFOLLOW \| O_DIRECTORY)` per remaining component ([Dimension 6](#dimension-6--failure-and-partiality)) |
| `remove_file` / `remove_dir`     | `resolve_parent` then `unlinkat(dir, name, 0 \| AT_REMOVEDIR)`                                                                                                                          |
| `remove_all(path)`               | `resolve_parent` then `utils::remove_all(dir, name)` ([Dimension 7](#dimension-7--enumeration-and-deletion))                                                                            |
| `rename(src, dst, RenameFlags)`  | `resolve_exists_parent` for both sides, then `renameat2`; trailing-slash rules mirror the kernel's                                                                                      |
| `Handle::reopen(flags)`          | `openat(/proc/thread-self/fd/N, flags)` through a `ProcfsHandle` ([below](#why-resolution-yields-an-o_path-handle))                                                                     |

### Why resolution yields an `O_PATH` handle

`resolve` deliberately does not open the file for I/O. Opening with real
access flags has side effects — a FIFO blocks, a TTY can become the
controlling terminal, a device node runs its driver's `open` — so the walk
is done with `O_PATH` (no I/O permission, no side effects) and the upgrade is
a separate, explicit step. The upgrade cannot be a second lookup by name
(that would reopen the race), so it goes through the one magic-link that
re-opens an fd _by identity_ ([`utils/fd.rs`][utils-fd]):

```rust
fn reopen(&self, procfs: &ProcfsHandle, mut flags: OpenFlags) -> Result<OwnedFd, Error> {
    // ... symlink handles cannot be reopened (ELOOP) ...
    flags.remove(OpenFlags::O_NOFOLLOW);
    // TODO: Add support for O_EMPTYPATH once that exists...
    procfs
        .open_follow(ProcfsBase::ProcThreadSelf, proc_subpath(fd)?, flags)
        .map(OwnedFd::from)
}
```

The `TODO` names the missing kernel primitive: there is no
`open(fd, "", O_EMPTYPATH)`, so `/proc/self/fd/N` is the only way to turn an
`O_PATH` fd into a readable one — which is why libpathrs needs a hardened
`procfs` layer at all. `reopen` always sets `O_CLOEXEC` and `O_NOCTTY`
([`handle.rs`][handle]).

### The `openat2` resolver

[`resolvers/openat2.rs`][res-openat2] is a thin wrapper: every call sets
`RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS` plus the user's `ResolverFlags`
(today only `NO_SYMLINKS`), and `O_PATH` (`| O_NOFOLLOW` for
`resolve_nofollow`). The syscall wrapper retries `EAGAIN` up to 128 times for
scoped lookups only ([`syscalls.rs`][syscalls]):

```rust
// openat2(2) can fail with -EAGAIN if there was a racing rename or
// mount *anywhere on the system*. This can happen pretty frequently, so
// what we do is attempt the openat2(2) a couple of times.
//
// Based on some fairly extensive tests, with 128 retries you only have
// a ~0.1% chance of hitting the error path (even with an attacker
// pounding on rename on all cores).
const MAX_RETRIES: u8 = 128;
```

### The `O_PATH` fallback resolver

[`resolvers/opath/imp.rs`][opath-imp] is the interesting part for anyone who
must ship without `openat2`. `do_resolve` keeps three pieces of state: the
`root` fd (cloned once), a `current` fd, and `expected_path` — the lexical
path _relative to the root_ that `current` should have, containing no
symlink components. The walk:

1. Pop the next component from a `VecDeque`. `""` becomes `"."`; `"."` is
   still opened (so `file/.` yields the kernel's `ENOTDIR`); `".."` is
   applied **lexically** to `expected_path` — if `pop()` fails the walk is
   at the root, so `current` is reset to the root clone and the component is
   skipped. Any other component is pushed onto `expected_path` and rejected
   if it contains `/`.
2. `openat(current, part, O_PATH | O_NOFOLLOW)`. On error, return
   `PartialLookup::Partial { handle: current, remaining, last_error }`.
3. **If the component was `..`, call `check_current` immediately.** The
   comment: "The safety argument for only needing to check `..` is identical
   to the kernel implementation (namely, walking down is safe
   by-definition). However, unlike the in-kernel version we don't have the
   luxury of only doing this check when there was a racing rename — we have
   to do it every time."
4. `fstat` the new fd. Not a symlink → `current = next`, continue.
5. Symlink: if it is the last component and `no_follow_trailing`, stop with
   the link handle. If `NO_SYMLINKS` was requested, return a partial with a
   synthesized `ELOOP`. Run `may_follow_link` (below). Bump
   `symlink_traversals`; at `MAX_SYMLINK_TRAVERSALS = 128` synthesize
   `ELOOP`. `readlinkat(next, "")`. **If the target is absolute and `next`
   sits on a "magic-link filesystem" (`PROC_SUPER_MAGIC` or apparmorfs),
   fail with `ELOOP` — an emulated `RESOLVE_NO_MAGICLINKS`.** Otherwise pop
   the link's name off `expected_path`, prepend the target's components to
   the queue, and if the target was absolute reset `current` to the root and
   `expected_path` to `/`.
6. After the loop, `check_current` once more on the final handle.

`check_current` is the whole safety argument of the fallback
([`opath/imp.rs`][opath-imp]): it reads `readlink(/proc/thread-self/fd/N)`
for the root, joins `expected_path` onto it, reads the same for `current`,
and demands byte equality — then re-reads the root's path and demands it has
not moved. Both reads go through a `ProcfsHandle` so the check cannot be
answered by an attacker-mounted `/proc`.

`may_follow_link` emulates two kernel policies the userspace walk would
otherwise bypass: an `ST_NOSYMFOLLOW` mount yields `ELOOP`, and
`fs.protected_symlinks` is re-implemented (sticky world-writable directory,
link owner ≠ follower, link owner ≠ directory owner → `EACCES`). The sysctl
is read once and, since 0.2.5, "we now conservatively assume that
`fs.protected_symlinks` is enabled if we cannot access the file for any
reason" ([`CHANGELOG.md`][changelog]).

`resolve_partial` additionally threads a `SymlinkStack`
([`symlink_stack.rs`][symlink-stack]) so that a dangling symlink _inside_ a
symlink chain reports the `(dir, remaining)` of the **first** symlink
entered — "effectively making the symlink resolution all-or-nothing", to
match what `openat2` returns to `mkdir_all`.

### The `procfs` layer

Because both `reopen` and `check_current` depend on `/proc`, a fake or
overmounted `/proc` would defeat them. [`procfs.rs`][procfs] builds a
`ProcfsHandle` by trying, in order, `fsopen("proc")` + `fsconfig(subset=pid,
hidepid=ptraceable)` + `fsmount`, then `open_tree(OPEN_TREE_CLONE)`, then
`open_tree(... | AT_RECURSIVE)`, then a plain `open("/proc")`; every
candidate is verified to be a procfs root (`f_type == PROC_SUPER_MAGIC`,
`st_ino == PROC_ROOT_INO`). Lookups inside it use a third, more restrictive
resolver ([`resolvers/procfs.rs`][res-procfs]) — no `..`, no absolute
symlinks, and no mount crossings — with `openat2(RESOLVE_BENEATH |
RESOLVE_NO_XDEV | RESOLVE_NO_MAGICLINKS)` when available and per-component
`statx(STATX_MNT_ID_UNIQUE | STATX_MNT_ID)` (falling back to the `mnt_id`
field of `fdinfo`) otherwise ([`utils/fd.rs`][utils-fd]). Only handles that
are both `subset=pid` and detached are cached process-wide, because a leaked
unrestricted `/proc` fd is exactly the [CVE-2024-21626][cve-2024-21626] shape
([`CHANGELOG.md`][changelog], 0.2.0).

### Bindings

The C ABI ([`include/pathrs.h`][header]) is fd-based: `pathrs_open_root`,
`pathrs_inroot_{resolve,resolve_nofollow,open,readlink,rename,rmdir,unlink,
remove_all,creat,mkdir,mkdir_all,mknod,symlink,hardlink}`, `pathrs_reopen`,
`pathrs_proc_{open,openat,readlink,readlinkat}`, `pathrs_procfs_open`; errors
are negative ints decoded by `pathrs_errorinfo`. Go bindings live in
[`go-pathrs/`][go-pathrs] (module `cyphar.com/go-pathrs`; `contrib/bindings/go`
is an identical copy) and Python in [`contrib/bindings/python`][py-bindings];
[`e2e-tests/`][e2e] runs the same language-agnostic test set through all of
them.

### Dimension 1 — Threat model

The adversary is an unprivileged local user (or container root) who can
**rename, symlink, and race** inside the tree below `Root`, and — for the
"strict" tier — one who can **modify the mount table** the process sees.
In scope: symlink swap, directory rename mid-walk (including moving the
root itself, which is detected as `SafetyViolation: root moved during
lookup`), absolute-symlink escape, `..` escape, procfs magic links, and
overmounts on `/proc`. Explicitly out of scope: an attacker-controlled
directory _above_ the root ("it is considered a **very bad idea** to open a
`Root` inside a possibly-attacker-controlled directory tree", [`root.rs`][root]),
hard links (`InodeType::Hardlink` is restricted to targets inside the same
root, and nothing prevents a pre-existing hard link out of the tree), and
Windows.

[`docs/avoidable-vulnerabilities.md`][avoidable] names the following as bugs
"that we believe would've been avoided if the project in question had used
libpathrs". The document gives one reason per tier, not per CVE:

| Tier                | Reason given by the document                                                                                                                           | CVEs / advisories named                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Classic path safety | "classic symlink traversal or similar time-of-check-time-of-use bugs. Most Unix programs are at risk of having bugs of this nature"                    | docker/docker#5656 (2014); CVE-2017-1002101; CVE-2018-15664; CVE-2019-16884; CVE-2019-19921; CVE-2021-30465; CVE-2023-27561; CVE-2023-28642; CVE-2024-1753; CVE-2024-45310; CVE-2024-0132; CVE-2024-0133; CVE-2024-9676; CVE-2024-12086/12087/12088; CVE-2024-12747; CVE-2025-31133; CVE-2025-52565; CVE-2026-23954; CVE-2026-33711; CVE-2026-33897; CVE-2026-33945; CVE-2026-39860; CVE-2026-29518 and CVE-2026-43619; RedSun and BlueHammer (2026, Windows — "usage of libpathrs itself would not have avoided the issue, but being forced to write file-handle-based code … would've"); CVE-2026-46703; CVE-2026-48749/48750/48752/48753/48769; CVE-2026-53783/53784/53785/53793/53795/53796/53797/53799/53800/53801/53802/53803; CVE-2026-63125; CVE-2026-63343; CVE-2026-70460; CVE-2026-81493/81494/81495/81496/81497/81500; CVE-2026-85706 |
| Strict path safety  | "a privileged process operating on pseudofilesystems like `/proc` in a context where an attacker may be able to modify the mount table of the process" | CVE-2019-16884; CVE-2019-19921; CVE-2025-52881                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

Two of these are explained in the source itself: CVE-2019-16884 and
CVE-2019-19921 are the motivating cases for `ProcfsHandle` — "a maliciously
configured `/proc` could be used to trick administrative processes into
doing unexpected operations" ([`procfs.rs`][procfs]).

### Dimension 2 — Resolution primitive

Two backends behind one `Resolver` ([`resolvers.rs`][resolvers]):

| Backend         | Primitive                                                                            | Atomicity claimed                                                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KernelOpenat2` | one `openat2(root, path, RESOLVE_IN_ROOT \| RESOLVE_NO_MAGICLINKS [\| NO_SYMLINKS])` | whole-path, in-kernel; races surface as `EAGAIN` (retried ≤ 128×) or `EXDEV`                                                                                          |
| `EmulatedOpath` | per-component `openat(O_PATH \| O_NOFOLLOW)` + `fstat` + `readlinkat(fd, "")`        | per-component only; the post-hoc `/proc/self/fd` comparison proves "the path was safe at least one point in time" ([`opath/imp.rs`][opath-imp]), not that it still is |

The `resolve` contract is the weaker of the two, stated for both: "the path
is guaranteed to have been reachable from the root of the directory tree
and thus have been inside the root at one point in the resolution"
([`root.rs`][root]).

### Dimension 3 — Symlink and `..` policy

Symlinks are **followed and re-rooted**: an absolute target restarts at the
`Root`, never at `/`. `ResolverFlags::NO_SYMLINKS` (= `RESOLVE_NO_SYMLINKS`,
the only flag defined in [`flags.rs`][flags]) refuses them with `ELOOP`.
Trailing-symlink following is a per-call choice (`resolve` vs
`resolve_nofollow`).

`..` is **resolved, not rejected**: in the kernel by `RESOLVE_IN_ROOT`; in
the fallback lexically against `expected_path` with a mandatory
`/proc/self/fd` re-check after every `..` step, and a reset to the root fd
when it would climb above it. `mkdir_all` is the one exception — any `..`
among the _yet-to-be-created_ components is refused with `ENOENT`, because
"`..` could erase dangling symlinks and produce a path that doesn't match
what the user asked for" ([`root.rs`][root]).

### Dimension 4 — Boundaries

- **Mounts.** `Root` lookups do **not** set `RESOLVE_NO_XDEV`; bind mounts
  inside the root are traversed (a `TODO` in [`utils/fd.rs`][utils-fd] notes
  `RESOLVE_NO_XDEV` support for `Root::resolve` is future work). The
  `procfs` resolver is the opposite: mount crossings are always forbidden.
- **Magic links.** `RESOLVE_NO_MAGICLINKS` is unconditional in the kernel
  backend; the fallback refuses any absolute symlink found on a
  `DANGEROUS_FILESYSTEMS` member (`PROC_SUPER_MAGIC`, apparmorfs
  `0x5a3c69f0`), a list documented as "correct from the introduction of
  `nd_jump_link()` in Linux 3.6 up to Linux 6.11" but not provably
  exhaustive ([`utils/fd.rs`][utils-fd]). Opening a magic link on purpose is
  a separate API, `ProcfsHandle::open_follow`, which only permits a
  _trailing_ magic link and verifies the parent and link share a mount ID.
- **procfs overmounts.** Detected per component via `STATX_MNT_ID_UNIQUE`
  (6.8) → `STATX_MNT_ID` (5.8) → `fdinfo` `mnt_id` (with the `ino` field,
  5.14, used to reject a forged `fdinfo`). Table in
  [`docs/kernel-features.md`][kernel-features].
- **Windows reparse points / ADS / device names** — do not apply; Linux
  only.

### Dimension 5 — Portability and fallback

Backend choice is lazy and one-way ([`syscalls.rs`][syscalls]): `Resolver::default`
picks `KernelOpenat2` unless a trivial `openat2` has _already_ been seen to
fail; on any `openat2` error the code probes `openat2(AT_FDCWD, ".")`, and
only if the probe fails does it fall back to `opath`. Success is never
cached — "A process can always add seccomp-bpf filters to itself that would
cause `openat2(2)` to start failing" — while failure is, so a seccomp filter
applied mid-life degrades gracefully instead of erroring.

What each missing feature costs, verbatim from
[`docs/kernel-features.md`][kernel-features]:

| Feature                 | Min. kernel | Fallback                                                                                                 |
| ----------------------- | ----------- | -------------------------------------------------------------------------------------------------------- |
| `/proc/thread-self`     | 3.17        | `/proc/self/task/$tid`, then `/proc/self`                                                                |
| `open_tree(2)`          | 5.2         | plain `open("/proc")` — "can lead to certain race attacks if the attacker can dynamically create mounts" |
| `fsopen(2)`             | 5.2         | `open_tree`; with locked overmounts, a recursive clone "that preserves the overmounts"                   |
| `openat2(2)`            | 5.6         | "Userspace emulated path lookups"                                                                        |
| `subset=pid`            | 5.8         | no caching of the procfs handle ("substantially higher syscall usage")                                   |
| `STATX_MNT_ID`          | 5.8         | parse `fdinfo`; safe with `openat2`, otherwise "unsafe opens that could be fooled by bind-mounts"        |
| `ino` field in `fdinfo` | 5.14        | **None** — an attacker "could (via a somewhat complicated attack) overmount fake `fdinfo` files"         |
| `STATX_MNT_ID_UNIQUE`   | 6.8         | `STATX_MNT_ID` (vulnerable to mount-ID recycling)                                                        |

RHEL 8's broken backport of the new mount API is special-cased: the
`fsopen`/`open_tree` path is refused on any kernel reporting < 5.2
([`procfs.rs`][procfs], `HAS_UNBROKEN_MOUNT_API`).

### Dimension 6 — Failure and partiality

Errors are a structured `Error` with an `ErrorKind` (`OsError(errno)`,
`SafetyViolation`, `InvalidArgument`, `NotSupported`, `InternalError`, …) and
a `can_retry` helper added in 0.2.1 so callers can loop on `EAGAIN` with
their own deadline ([`CHANGELOG.md`][changelog]). The emulated resolver
synthesizes the kernel's errno (`ELOOP`, `ENOTDIR`, `EXDEV`) so both backends
look alike to callers.

`resolve_partial` returns `PartialLookup::{Complete, Partial { handle,
remaining, last_error }}`; a `SafetyViolation` is never downgraded to a
partial result "to avoid some possible weird bug in libpathrs being
exploited to return some result to `Root::mkdir_all`"
([`resolvers/openat2.rs`][res-openat2]). On the kernel backend a partial
lookup is a linear retry over `path.partial_ancestors()` (a bisect is a
`TODO`).

`mkdir_all` documents its own non-atomicity: "If an error occurs, it is
possible for any number of the directories in `path` to have been created
despite this method returning an error." `EEXIST` from `mkdirat` is tolerated
(a racing `mkdir_all` wins; the following `openat(O_DIRECTORY)` re-checks the
type), and the newly opened directory is **not** verified against expected
owner/mode/emptiness — a deliberate retreat, since "POSIX ACLs and
filesystem-specific mount options can affect ownership and modes in
unexpected ways" and "some pseudofilesystems (like cgroupfs) create non-empty
directories" ([`root.rs`][root]; the check was removed in 0.1.1, #71).

`create_file` is the one creation that _is_ atomic (`O_CREAT` on the
resolved parent). Everything else is "resolve the parent, then act on
`(dirfd, basename)`", which is race-free with respect to the path prefix but
not the final component.

### Dimension 7 — Enumeration and deletion

`utils::remove_all(dirfd, name)` ([`utils/dir.rs`][utils-dir]) is
fd-relative throughout:

1. Refuse a `name` containing `/`.
2. Fast path: `unlinkat(dirfd, name, 0)`, then `unlinkat(..., AT_REMOVEDIR)`;
   `ENOENT` counts as success.
3. Otherwise `openat(dirfd, name, O_DIRECTORY)` (no `O_NOFOLLOW` needed — a
   symlink would have been unlinked in step 2), then **loop**: take a fresh
   `Dir::read_from` iterator, skip `.`/`..`, recurse `remove_all(&subdir,
child)` for every entry, and repeat until a fresh iterator is empty —
   "deleting entries while iterating over a directory can lead to the
   iterator skipping components".
4. `unlinkat(dirfd, name, AT_REMOVEDIR)` again, `ENOENT` ignored.

There is no `st_dev`/mount check during deletion (a bind mount inside the
tree is descended into), no explicit depth or fd budget (recursion holds one
directory fd per level), and the DoS of an attacker continuously creating
entries is acknowledged and accepted. Since 0.2.0 concurrent `remove_all`
calls on the same tree all succeed.

## Strengths

- **The most complete safety argument in the survey**, written down in the
  code: why only `..` needs a check, why the check must run every time in
  userspace, why the check itself needs a trusted `/proc`.
- **Kernel-first with an honest fallback** — the `O_PATH` walk mirrors
  `openat2`'s errno and partial-lookup semantics closely enough that
  `mkdir_all` is backend-agnostic.
- **`O_PATH` handle + `reopen` split** removes an entire class of side-effect
  bugs (FIFO, TTY, device opens) from the resolution step.
- **Strict-tier procfs handling** (`fsopen`/`open_tree` private mounts,
  mount-ID verification, `subset=pid` caching) that no other surveyed
  library attempts.
- **fd-based C ABI with symbol versioning**, Go and Python bindings tested
  end-to-end against the same suite.

## Weaknesses

- **Linux only**, by design; the fallback's dependence on `/proc/self/fd`
  cannot be ported.
- **The fallback is only as trustworthy as `/proc`**: below 5.6 without
  `STATX_MNT_ID`, and below 5.14 without `fdinfo`'s `ino`, the document
  itself rates the protection as bypassable by a sufficiently motivated
  mount-capable attacker.
- **`RESOLVE_NO_XDEV` is not exposed for `Root`** — a bind mount inside the
  root is silently traversed.
- **Magic-link filesystem detection is a hard-coded list** of two
  `f_type`s; an out-of-tree filesystem using `nd_jump_link()` would defeat
  the emulated `RESOLVE_NO_MAGICLINKS`.
- **Moving the root is fatal**, even innocently ("This restriction might be
  relaxed in the future").
- **`remove_all` has no fd/depth bound** and descends into mounts.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                   | Trade-off                                                                                         |
| ------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Return an `O_PATH` `Handle`, reopen via `/proc/self/fd`       | No side effects during resolution; reopen by identity, not by name          | Hard dependency on a trustworthy `/proc`; two syscalls instead of one; no `O_EMPTYPATH` yet       |
| `RESOLVE_IN_ROOT`, not `RESOLVE_BENEATH`                      | Container semantics: absolute symlinks re-root instead of failing           | Unsuited to the "reject anything that looks like an escape" policy Go's `os.Root` chose           |
| Emulate `openat2` in userspace                                | Old kernels and seccomp'd processes still get scoped lookups                | Weaker atomicity; every `..` costs two `readlink`s through procfs                                 |
| Check only after `..` and at the end                          | Same argument as the kernel: descending cannot escape                       | A rename between the final check and the caller's use is still possible (the contract says so)    |
| Cache the procfs handle only if `subset=pid` **and** detached | Amortise `fsopen` cost without turning a leaked fd into a CVE-2024-21626    | Unprivileged processes pay a full handle build per operation                                      |
| Never verify `mkdir_all`'s created directories                | ACLs, mount options, cgroupfs made the check produce false positives        | An attacker may pre-create or swap the final directory (which `mkdir -p` semantics already allow) |
| One-way `openat2` failure cache                               | A seccomp filter can arrive after startup, so success is not sticky         | First failure after a genuine `openat2` error costs one probe syscall                             |
| `SafetyViolation` never becomes a partial result              | Defence in depth against a resolver bug being laundered through `mkdir_all` | A benign race during partial lookup surfaces as an error instead of a retry                       |

## Sources

- [`README.md`][readme] — positioning, kernel-support policy, examples in Rust/C/Go
- [`docs/avoidable-vulnerabilities.md`][avoidable] — the CVE catalogue and its two tiers
- [`docs/kernel-features.md`][kernel-features] — feature/fallback matrix
- [`docs/procfs-api.md`][procfs-api] — why `/proc` needs stricter rules; magic-link and readlink examples
- [`src/root.rs`][root] — `Root`/`RootRef` API, `resolve_parent`, `mkdir_all`, `rename`
- [`src/handle.rs`][handle] — `Handle`/`HandleRef`, `reopen` contract
- [`src/resolvers.rs`][resolvers] — backend selection, `PartialLookup`, fallback dispatch
- [`src/resolvers/openat2.rs`][res-openat2] — kernel backend, partial lookup by ancestors
- [`src/resolvers/opath/imp.rs`][opath-imp] — the emulated walk, `check_current`, `may_follow_link`
- [`src/resolvers/opath/symlink_stack.rs`][symlink-stack] — all-or-nothing symlink partial results
- [`src/resolvers/procfs.rs`][res-procfs] — the restricted procfs resolver
- [`src/procfs.rs`][procfs] — `ProcfsHandle`, builder order, caching policy, `open_follow`
- [`src/utils/fd.rs`][utils-fd] — `reopen`, `as_unsafe_path`, `DANGEROUS_FILESYSTEMS`, `fetch_mnt_id`
- [`src/utils/dir.rs`][utils-dir] — `remove_all`
- [`src/syscalls.rs`][syscalls] — `openat2_follow` retry loop, one-way failure cache
- [`src/flags.rs`][flags] — `OpenFlags`, `RenameFlags`, `ResolverFlags`
- [`include/pathrs.h`][header] — the C ABI
- [`CHANGELOG.md`][changelog] — 0.0.0 (2020) → 0.2.6 (2026-09-05)
- Siblings: [`filepath-securejoin`][securejoin] (the Go port), [`linux-openat2`][openat2], [procfs magic links][magic-links], [Sarai's talks][talks], [Go `os.Root`][go-root]

> [!NOTE]
> **Unverified.** The per-CVE mechanisms in `avoidable-vulnerabilities.md`
> were not read (the document links advisories without describing them), so
> the table above reproduces the document's tier-level reasoning only. The
> FOSDEM 2026 talk it cites for the "strict"/"classic" terminology was not
> watched. Kernel commit references quoted from source comments
> (`b5fb63c18315`, `a481f4d91783`, `7bc3fa0172a4`, `ee2e3f50629f`) were not
> checked against a kernel tree.

<!-- References -->

[repo]: https://github.com/cyphar/libpathrs/tree/6acffea4cfbba1226aa33a8fcc98c500da8478b8
[readme]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/README.md
[avoidable]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/avoidable-vulnerabilities.md
[kernel-features]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/kernel-features.md
[procfs-api]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/procfs-api.md
[root]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/root.rs
[handle]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/handle.rs
[resolvers]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers.rs
[res-openat2]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/openat2.rs
[res-procfs]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/procfs.rs
[opath-imp]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/opath/imp.rs
[symlink-stack]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/opath/symlink_stack.rs
[procfs]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/procfs.rs
[utils-fd]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/utils/fd.rs
[utils-dir]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/utils/dir.rs
[syscalls]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/syscalls.rs
[flags]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/flags.rs
[header]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/include/pathrs.h
[go-pathrs]: https://github.com/cyphar/libpathrs/tree/6acffea4cfbba1226aa33a8fcc98c500da8478b8/go-pathrs
[py-bindings]: https://github.com/cyphar/libpathrs/tree/6acffea4cfbba1226aa33a8fcc98c500da8478b8/contrib/bindings/python
[e2e]: https://github.com/cyphar/libpathrs/tree/6acffea4cfbba1226aa33a8fcc98c500da8478b8/e2e-tests
[changelog]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/CHANGELOG.md
[cve-2024-21626]: https://github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv
[securejoin]: ./filepath-securejoin.md
[openat2]: ./linux-openat2.md
[magic-links]: ./linux-procfs-magic-links.md
[talks]: ./sarai-talks.md
[go-root]: ./go-os-root.md
