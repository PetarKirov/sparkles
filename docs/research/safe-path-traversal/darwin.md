# Darwin / XNU

The `*at` family arrived in macOS 10.10 with no `O_PATH` and no `openat2`; what
XNU added instead is a set of _flag_ bits — `O_NOFOLLOW_ANY`,
`AT_SYMLINK_NOFOLLOW_ANY`, and (in the current header) `O_RESOLVE_BENEATH` /
`AT_RESOLVE_BENEATH` — spread across `open`, `fstatat`, `renameatx_np`,
`clonefileat` and `getattrlistbulk`, so the same two ideas recur under five
spellings.

|                 |                                                                                                                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | kernel mechanism                                                                                                                                                                                                |
| **Year**        | `openat` family: macOS 10.10 (2014); `renameatx_np` / `clonefileat`: 10.12 (2016); `O_NOFOLLOW_ANY`, `*_RESOLVE_BENEATH`: present in the 2025 header, see Unverified                                            |
| **Maintainers** | Apple (XNU, `apple-oss-distributions`)                                                                                                                                                                          |
| **Language**    | C                                                                                                                                                                                                               |
| **License**     | APSL 2.0                                                                                                                                                                                                        |
| **Repository**  | [`apple-oss-distributions/xnu` at tag `xnu-12377.121.6`][xnu-tag]                                                                                                                                               |
| **Platforms**   | macOS, iOS, tvOS, watchOS, visionOS                                                                                                                                                                             |
| **Primitive**   | `openat(dirfd, …)` with `O_NOFOLLOW` per component, or whole-path `O_NOFOLLOW_ANY`; `AT_RESOLVE_BENEATH` on the `*at` calls                                                                                     |
| **Source read** | [`bsd/sys/fcntl.h`][fcntl-h], [`bsd/sys/stdio.h`][stdio-h], [`bsd/sys/clonefile.h`][clonefile-h], [`bsd/sys/attr.h`][attr-h], [`bsd/kern/syscalls.master`][syscalls-master]; the consumers listed under Sources |

## Overview

### What it solves

The same problem [`openat2`][linux-openat2] solves on Linux — resolving a path
relative to an already-open directory so that a rename or symlink swap between
two steps cannot redirect the walk — but with the policy expressed as bits on
the existing calls rather than as a new syscall with a `how` struct. The
header's own one-line explanations are the whole spec ([`fcntl.h`][fcntl-h]):

```c
#define O_NOFOLLOW      0x00000100      /* don't follow symlinks */
#define O_SYMLINK       0x00200000      /* allow open of a symlink */
#define O_RESOLVE_BENEATH 0x00001000    /* only for open(2), same value as FMARK */
#if __DARWIN_C_LEVEL >= __DARWIN_C_FULL
#define O_NOFOLLOW_ANY  0x20000000      /* no symlinks allowed in path */
#endif

#define AT_SYMLINK_NOFOLLOW     0x0020  /* Act on the symlink itself not the target */
#define AT_REMOVEDIR            0x0080  /* Path refers to directory */
#define AT_SYMLINK_NOFOLLOW_ANY 0x0800  /* Path should not contain any symlinks */
#define AT_RESOLVE_BENEATH      0x2000  /* Path must reside in the hierarchy beneath the starting directory */
```

`O_PATH`, `O_EMPTY_PATH` and `RESOLVE_NO_XDEV` have no counterpart: the strings
`O_PATH` and `O_EMPTY_PATH` do not appear in the header at all.

### Design philosophy

Every `*at` call is an ordinary libc entry point with a fixed availability
floor — `openat` is declared `__OSX_AVAILABLE_STARTING(__MAC_10_10,
__IPHONE_8_0)` ([`fcntl.h`][fcntl-h]) and sits in the syscall table as
`463 … { int openat(int fd, user_addr_t path, int flags, int mode) NO_SYSCALL_STUB; }`
([`syscalls.master`][syscalls-master]). The Darwin-specific extensions are
non-POSIX (`_np`) and gated to 10.12: `renameatx_np` and `clonefileat` are both
`__OSX_AVAILABLE(10.12) __IOS_AVAILABLE(10.0)` ([`stdio.h`][stdio-h],
[`clonefile.h`][clonefile-h]). Consumers therefore treat the platform as
"`openat` is always there, everything richer is weak-linked" — see
[Dimension 5](#dimension-5--portability-and-fallback).

## How it works

The `*at` surface, by syscall number ([`syscalls.master`][syscalls-master]):

| Syscall                                                    | Number  | Note                                                                           |
| ---------------------------------------------------------- | ------- | ------------------------------------------------------------------------------ |
| `openat` / `openat_nocancel`                               | 463/464 | the base primitive                                                             |
| `renameat`                                                 | 465     | 10.10                                                                          |
| `faccessat`, `fchmodat`, `fchownat`                        | 466–468 |                                                                                |
| `fstatat`, `fstatat64`                                     | 469/470 |                                                                                |
| `linkat`, `unlinkat`, `readlinkat`, `symlinkat`, `mkdirat` | 471–475 |                                                                                |
| `getattrlistat`                                            | 476     | `attrlist`-based stat relative to a dirfd                                      |
| `getattrlistbulk`                                          | 461     | bulk directory enumeration on a dirfd (`int dirfd, struct attrlist *alist, …`) |
| `clonefileat` / `fclonefileat`                             | 462/517 | APFS clone relative to dirfds                                                  |
| `renameatx_np`                                             | 488     | `renameat` plus a `u_int flags` word                                           |
| `getdirentries64`                                          | 344     | what `fdopendir`/`readdir` sit on                                              |
| `freadlink`                                                | 551     | `readlink` on an `O_SYMLINK` fd                                                |
| `openbyid_np`, `fsgetpath`                                 | 479/427 | open by `(fsid, objid)`; path back from an id                                  |

The three extension headers each carry the same two policy bits under a local
name. `renameatx_np` ([`stdio.h`][stdio-h]):

```c
#define RENAME_SECLUDE                  0x00000001
#define RENAME_SWAP                     0x00000002
#define RENAME_EXCL                     0x00000004
#define RENAME_RESERVED1                0x00000008
#define RENAME_NOFOLLOW_ANY             0x00000010
#define RENAME_RESOLVE_BENEATH          0x00000020
```

`clonefileat` ([`clonefile.h`][clonefile-h]) has `CLONE_NOFOLLOW` (`0x0001`),
`CLONE_NOFOLLOW_ANY` (`0x0008`, "Don't follow any symbolic links in the path")
and `CLONE_RESOLVE_BENEATH` (`0x0010`, "path must reside in the hierarchy
beneath the starting directory"). `getattrlistbulk` / `getattrlistat`
([`attr.h`][attr-h]) take `FSOPT_NOFOLLOW` (`0x1`), `FSOPT_NOFOLLOW_ANY`
(`0x800`), `FSOPT_RESOLVE_BENEATH` (`0x1000`) and `FSOPT_UNIQUE` (`0x2000`), and
require `ATTR_BULK_REQUIRED (ATTR_CMN_NAME | ATTR_CMN_RETURNED_ATTRS)` so a
per-entry `ATTR_CMN_ERROR` (`0x20000000`) can be reported inline instead of
failing the whole batch.

### Dimension 1 — Threat model

The in-scope adversary is whoever can write to a directory the walk passes
through: a symlink swap or a directory rename between two components. What the
surveyed consumers explicitly leave _out_ of scope is instructive. Go's
`os.Root` documents that on Unix, `Chmod`, `Chown` and `Chtimes` "are vulnerable
to a race condition. If the target of the operation is changed from a regular
file to a symlink while the operation is in progress, the operation may be
performed on the link rather than the link target" — because `fchmodat` with
`AT_SYMLINK_NOFOLLOW` acts on the link and without it follows it; there is no
"fail if symlink" mode. The comment concludes: "We may act on the wrong file,
but that file will be contained within the root" ([`root_unix.go`][go-root-unix]).
Mount crossings, `/proc`-style special files and device nodes are documented as
_not_ prohibited ([`root.go`][go-root]).

### Dimension 2 — Resolution primitive

Two atomicity levels are available. With plain `openat` + `O_NOFOLLOW` the
atomicity is per component: Go opens each intermediate with
`O_NOFOLLOW|O_CLOEXEC|O_DIRECTORY` and, on `ELOOP`/`ENOTDIR`, reads the link
itself with `readlinkat` and re-injects its target into the component list
([`root_unix.go`][go-root-unix] `rootOpenDir`, `checkSymlink`). Go binds these
as libSystem trampolines — `//go:cgo_import_dynamic libc_readlinkat readlinkat
"/usr/lib/libSystem.B.dylib"` ([`at_darwin.go`][go-at-darwin]) — never raw
syscall numbers, so the kernel ABI is not a contract Go relies on.

`O_NOFOLLOW_ANY` and `AT_RESOLVE_BENEATH` lift that to whole-path atomicity
inside one call. The vendored `golang.org/x/sys` carries `O_NOFOLLOW_ANY =
0x20000000` and `RENAME_NOFOLLOW_ANY = 0x10` ([`zerrors_darwin_arm64.go`][go-zerrors]),
and rustix exposes `OFlags::NOFOLLOW_ANY` under `#[cfg(apple)]`
([`types.rs`][rustix-types]) — but neither `os.Root` nor `std::fs` uses them at
the surveyed revisions; every consumer walks per component. (The `os.Root`
proposal discussed a portable `O_NOFOLLOW_ANY` "emulated with successive
`openat` calls with `O_NOFOLLOW`" on platforms lacking it; see
[`go-os-root.md`][go-os-root].)

### Dimension 3 — Symlink and `..` policy

Symlinks are followed but confined, by user-space re-resolution of the link
text. `..` is handled without ever asking the kernel: Go's walker deletes the
preceding component lexically and restarts from the root fd, because
"We can't `openat(dir, "..")` to move up to the parent directory, because dir
may have moved since we opened it" ([`root_openat.go`][go-root-openat]).
cap-std keeps the stack of parent handles instead and pops one per `..`, so
"even if the directory is concurrently moved, we don't have to worry about `..`
leaving the sandbox" ([`manually/open.rs`][capstd-manual-open]).

`O_SYMLINK` is the Darwin-specific inverse of `O_NOFOLLOW`: it opens the link
itself as an fd (`freadlink` then reads it), which is how a link can be
`fstat`-ed and read by handle rather than by name.

### Dimension 4 — Boundaries

Nothing in [`fcntl.h`][fcntl-h] restricts mount crossing; the only boundary
flags are the `*_RESOLVE_BENEATH` family, which bound the walk to a directory,
not to a device. Device identity comes from `ATTR_CMN_DEVID` (`0x2`) /
`ATTR_CMN_FSID` (`0x4`) / `ATTR_CMN_FILEID` (`0x02000000`) in `attr.h`, or from
`st_dev`/`st_ino` in `fstatat`. cap-std reads `st_birthtime` on macOS where
Linux has no creation time ([`metadata_ext.rs`][capstd-metadata]) and
resolves a handle back to a path with `getpath` (`F_GETPATH`) — the Darwin
answer to `/proc/self/fd/N` ([`darwin/fs/file_path.rs`][capstd-file-path]).

### Dimension 5 — Portability and fallback

The floor is 10.10, so `openat` is unconditional; the two 10.12 extensions are
weak-linked. rustix's `renameat2` on Apple platforms does
`weak! { fn renameatx_np(…) }`, calls it if present, and otherwise falls back to
plain `rename` — but only when flags are empty and both dirfds are `AT_FDCWD`,
returning `ENOSYS` in every other case rather than silently dropping the
`RENAME_EXCL`/`RENAME_SWAP` semantics ([`syscalls.rs`][rustix-syscalls]). cap-std
notes "MacOS prior to 10.12 don't support `fclonefileat`" and caches the
availability in a global after the first `ENOSYS`-style failure
([`copy_impl.rs`][capstd-copy]); Rust std's `copy` on `target_vendor = "apple"`
tries `fclonefileat` first and falls through to `fcopyfile` on
`ENOTSUP | EEXIST | EXDEV` ([`unix.rs`][rust-unix]).

What is lost without `O_PATH`: cap-std's `target_o_path()` returns
`OFlags::empty()` for macOS/iOS ([`dir_utils.rs`][capstd-dir-utils]), so every
intermediate directory in a walk is opened `O_RDONLY|O_DIRECTORY` — a real read
handle, which fails on a directory the caller may traverse but not list. `rsync`
is likewise skipped on Apple targets ([`oflags.rs`][capstd-oflags]).

### Dimension 6 — Failure and partiality

Go maps `ENOTSUP`/`EOPNOTSUPP` from an intermediate open to `ENOTDIR`, and
converts `ELOOP` to `EEXIST` for `O_CREATE|O_EXCL` on a dangling link so it
matches `ErrExists` ([`root_unix.go`][go-root-unix]). A `..`-triggered restart
is bounded: `maxSteps = 255`, `maxRestarts = 8`, and the walk fails with
`ENAMETOOLONG` only when _both_ are exceeded ([`root_openat.go`][go-root-openat]).
Rust's `remove_dir_all` treats `ENOENT` on a child as "already deleted by a
concurrent caller" and continues ([`unix.rs`][rust-unix]).

### Dimension 7 — Enumeration and deletion

Rust's `remove_dir_all_recursive` is the canonical shape: `openat(parent,
name, O_CLOEXEC|O_RDONLY|O_NOFOLLOW|O_DIRECTORY)`, hand the fd to `fdopendir`,
recurse on `d_type == DT_DIR`, `unlinkat(fd, child, 0)` otherwise, and
`unlinkat(parent, name, AT_REMOVEDIR)` last; a symlink shows up as
`ENOTDIR | ELOOP` and is unlinked rather than entered ([`unix.rs`][rust-unix]).
Go's `removeAllFrom` does the same over `Readdirnames(1024)` batches, closing
and re-opening the directory between batches because deleting entries "may have
caused the OS to reshuffle it" ([`removeall_at.go`][go-removeall]). On Darwin,
Go's `Getdirentries` is itself "simulated using `fdopendir`/`readdir_r`/`closedir`",
duplicating the fd via `openat(fd, ".", O_RDONLY, 0)` because `fdopendir`
takes ownership ([`syscall_darwin.go`][go-syscall-darwin]). Rust's
directory-handle tracking issue records `getattrlistbulk` as the native
readdir on macOS and iOS ([rust-lang/rust#120426][rust-120426]).

## Strengths

- **`openat` is unconditional** (10.10 floor), and the whole `*at` family is
  present, so the per-component walk needs no fallback.
- **Whole-path policy exists as bits**: `O_NOFOLLOW_ANY`,
  `AT_SYMLINK_NOFOLLOW_ANY`, `*_RESOLVE_BENEATH` — repeated on `rename`,
  `clonefile` and `getattrlist` so each op can be bounded, not only `open`.
- **Handle→path is a real syscall** (`F_GETPATH`, `fsgetpath`), not a procfs
  convention.
- **`getattrlistbulk` returns per-entry errors** (`ATTR_CMN_ERROR`) inside one
  bulk call.

## Weaknesses

- **No `O_PATH`**: an intermediate directory must be opened for reading.
- **No mount boundary** (`RESOLVE_NO_XDEV` has no counterpart); only device ids
  after the fact.
- **The same policy under five names** (`O_`, `AT_`, `RENAME_`, `CLONE_`,
  `FSOPT_`), with different bit values each time.
- **Nothing surveyed uses the whole-path bits**: Go, Rust std and cap-std all
  walk per component on Darwin, so the extra atomicity is unexercised in
  practice.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                       | Trade-off                                                             |
| -------------------------------------------------- | ----------------------------------------------- | --------------------------------------------------------------------- |
| Policy as flag bits on existing calls              | No new syscall or `how` struct; per-op bounding | Five parallel namings; feature detection is per flag, not per syscall |
| `O_NOFOLLOW_ANY` rather than `RESOLVE_NO_SYMLINKS` | Fits the `O_` word                              | Gated behind `__DARWIN_C_FULL`; no `AT_`-style symmetry until later   |
| No `O_PATH`                                        | Handles are always real opens                   | Traverse-only directories cannot be held as walk anchors              |
| `renameatx_np` with `RENAME_EXCL` / `RENAME_SWAP`  | Atomic no-replace and exchange                  | `_np`, 10.12+, must be weak-linked                                    |
| `getattrlistbulk` over `getdents`                  | Typed attributes per entry, inline errors       | An Apple-only enumeration API; libc `readdir` is a wrapper            |
| `F_GETPATH` / `fsgetpath` for handle→path          | No procfs dependency                            | Path is advisory: it can be stale by the time it is used              |

## Sources

- [`bsd/sys/fcntl.h`][fcntl-h] — `O_NOFOLLOW`, `O_SYMLINK`, `O_NOFOLLOW_ANY`, `O_RESOLVE_BENEATH`, `AT_*`, `openat` availability
- [`bsd/sys/stdio.h`][stdio-h] — `RENAME_*`, `renameat` (10.10), `renameatx_np` (10.12)
- [`bsd/sys/clonefile.h`][clonefile-h] — `CLONE_*`, `clonefileat` / `fclonefileat` (10.12)
- [`bsd/sys/attr.h`][attr-h] — `FSOPT_*`, `ATTR_BULK_REQUIRED`, `ATTR_CMN_ERROR`
- [`bsd/kern/syscalls.master`][syscalls-master] — syscall numbers for the whole `*at` family
- [`src/os/root_unix.go`][go-root-unix], [`root_openat.go`][go-root-openat], [`root.go`][go-root], [`removeall_at.go`][go-removeall] — the per-component walk and its documented races
- [`src/internal/syscall/unix/at_darwin.go`][go-at-darwin], [`src/syscall/syscall_darwin.go`][go-syscall-darwin], [`zerrors_darwin_arm64.go`][go-zerrors] — libSystem trampolines; `O_NOFOLLOW_ANY` known but unused
- [`library/std/src/sys/fs/unix.rs`][rust-unix] — `remove_dir_all` over `openat`/`fdopendir`/`unlinkat`; `fclonefileat` copy
- [`src/backend/libc/fs/syscalls.rs`][rustix-syscalls], [`types.rs`][rustix-types], [`src/fs/at.rs`][rustix-at] — `NOFOLLOW_ANY`, `RenameFlags`, weak `renameatx_np`
- cap-std [`rustix/fs/dir_utils.rs`][capstd-dir-utils], [`oflags.rs`][capstd-oflags], [`copy_impl.rs`][capstd-copy], [`metadata_ext.rs`][capstd-metadata], [`darwin/fs/file_path.rs`][capstd-file-path], [`fs/manually/open.rs`][capstd-manual-open]
- [rust-lang/rust#120426][rust-120426] — platform survey naming `getattrlistbulk` as macOS readdir

> [!NOTE]
> **Unverified.** The header at this tag carries no availability macro on the
> `O_NOFOLLOW_ANY`, `AT_SYMLINK_NOFOLLOW_ANY`, `O_RESOLVE_BENEATH` or
> `AT_RESOLVE_BENEATH` defines, so the macOS versions that introduced them
> (the brief's "macOS 11+" for `O_NOFOLLOW_ANY`) could not be confirmed from
> the source read. The brief also anticipated a weak-linked pre-10.10 `openat`
> fallback in Rust std; at revision `3bf5c6d` no such code exists (std's
> `weak!` uses in `fs/unix.rs` are Android and glibc-2.34 time functions), and
> the only Darwin weak link found is rustix's `renameatx_np`. Firmlinks and
> the APFS volume-group layout are not covered because no surveyed consumer
> handles them.

<!-- References -->

[linux-openat2]: ./linux-openat2.md
[go-os-root]: ./go-os-root.md
[xnu-tag]: https://github.com/apple-oss-distributions/xnu/tree/ac9718fb1af618d5ce8678d0dc6e8a58f252216f
[fcntl-h]: https://github.com/apple-oss-distributions/xnu/blob/ac9718fb1af618d5ce8678d0dc6e8a58f252216f/bsd/sys/fcntl.h
[stdio-h]: https://github.com/apple-oss-distributions/xnu/blob/ac9718fb1af618d5ce8678d0dc6e8a58f252216f/bsd/sys/stdio.h
[clonefile-h]: https://github.com/apple-oss-distributions/xnu/blob/ac9718fb1af618d5ce8678d0dc6e8a58f252216f/bsd/sys/clonefile.h
[attr-h]: https://github.com/apple-oss-distributions/xnu/blob/ac9718fb1af618d5ce8678d0dc6e8a58f252216f/bsd/sys/attr.h
[syscalls-master]: https://github.com/apple-oss-distributions/xnu/blob/ac9718fb1af618d5ce8678d0dc6e8a58f252216f/bsd/kern/syscalls.master
[go-root-unix]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_unix.go
[go-root-openat]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_openat.go
[go-root]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root.go
[go-removeall]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/removeall_at.go
[go-at-darwin]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/syscall/unix/at_darwin.go
[go-syscall-darwin]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/syscall/syscall_darwin.go
[go-zerrors]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/cmd/vendor/golang.org/x/sys/unix/zerrors_darwin_arm64.go
[rust-unix]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/unix.rs
[rust-120426]: https://github.com/rust-lang/rust/issues/120426
[rustix-syscalls]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/syscalls.rs
[rustix-types]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/types.rs
[rustix-at]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/at.rs
[capstd-dir-utils]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/dir_utils.rs
[capstd-oflags]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/oflags.rs
[capstd-copy]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/copy_impl.rs
[capstd-metadata]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/metadata_ext.rs
[capstd-file-path]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/darwin/fs/file_path.rs
[capstd-manual-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/manually/open.rs
