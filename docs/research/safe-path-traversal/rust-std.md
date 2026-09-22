# Rust `std::fs` — `remove_dir_all` and the `Dir` handle

The standard library that shipped a check-then-recurse `remove_dir_all` for
seven years, rewrote it on `openat`/`O_NOFOLLOW`/`unlinkat` and `NtOpenFile`
after CVE-2022-21658, and is now — slowly, on nightly — growing a
directory-handle type whose stated non-goal is sandboxing.

|                           |                                                                                                                                                                                                                                                                  |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | runtime API                                                                                                                                                                                                                                                      |
| **Year**                  | fix 2022-01-20 (Rust 1.58.1); `Dir` tracking issue opened 2024-01-27, still unstable                                                                                                                                                                             |
| **Authors / Maintainers** | Rust libs team; CVE fix by Hans Kratz (report), reviewed by Florian Weimer; `dirfd` API driven by the8472, ChrisDenton, RalfJung                                                                                                                                 |
| **Language**              | Rust                                                                                                                                                                                                                                                             |
| **License**               | MIT OR Apache-2.0                                                                                                                                                                                                                                                |
| **Repository**            | [`rust-lang/rust`][rust-tree] at `3bf5c6d9`                                                                                                                                                                                                                      |
| **Platforms**             | Unix family (`openat`, `fdopendir`, `unlinkat`), Windows (`NtOpenFile`, `FILE_DISPOSITION_INFO_EX`), path-based fallback                                                                                                                                         |
| **Primitive**             | fd-relative open with `O_NOFOLLOW \| O_DIRECTORY`; `NtOpenFile` with `RootDirectory` + `FILE_OPEN_REPARSE_POINT`                                                                                                                                                 |
| **Source read**           | [`library/std/src/sys/fs/unix.rs`][unix-rs], [`unix/dir.rs`][unix-dir], [`windows.rs`][windows-rs], [`windows/remove_dir_all.rs`][win-rda], [`windows/dir.rs`][win-dir], [`common.rs`][common-rs], [`fs.rs`][fs-rs], the [advisory][cve], issue [#120426][issue] |

## Overview

### What it solves

Two things, at two different points in time. In 2022, a real vulnerability:
`remove_dir_all` followed symlinks under a race. The [advisory][cve] describes
the pre-fix code exactly:

> Instead of telling the system not to follow symlinks, the standard library
> first checked whether the thing it was about to delete was a symlink, and
> otherwise it would proceed to recursively delete the directory.

and the consequence:

> an attacker could create a directory and replace it with a symlink between
> the check and the actual deletion.

The attack is the textbook one — "create a symlink from `temp/foo` to
`sensitive/`, and wait for the privileged program to delete `foo/`" — and the
advisory is explicit that application code cannot paper over it, because the
race is inside the library. Rust 1.0.0 through 1.58.0 were affected; 1.58.1
shipped the fix, with "macOS before version 10.10 (Yosemite)" and "REDOX"
noted as platforms still lacking the required APIs.

The second thing, since 2024, is a general-purpose directory handle
(`std::fs::Dir`, feature `dirfd`), whose scope is narrower than a reader of
this catalog might hope. The tracking issue's first paragraph ([#120426][issue]):

> Sandboxing is a non-goal. If a platform supports upwards path traversal via
> `..` or symlinks then directory handles will not prevent that. Providing
> `O_BENEATH`-style traversal is left to 3rd-party crates or future extensions.

### Design philosophy

The module docs now open with a TOCTOU section that names the 2022 lesson
without naming the CVE ([`fs.rs`][fs-rs]):

> when removing a directory, if another process replaces the directory with a
> symbolic link between the check and the removal operation, the removal might
> affect the wrong location. This is why operations like `remove_dir_all` need
> to use atomic operations to prevent such race conditions.

The `Dir` type is framed as a _race-resistance_ and _portability_ feature, not
a security boundary. the8472 defends the platform fallback on those terms
([#120426][issue], 2024-01-28):

> `Dir` isn't just about security. It provides a handle to a directory that
> should keep working even if the directory gets renamed (granted, fallbacks
> don't provide this). It helps with performance. It allows replacing global
> process state (the _current working directory_) with local state.

and rules out a runtime fallback on tier-1 platforms in the same comment: "if
something blocks `openat` via seccomp on linux I do not intend to try `open`."

## How it works

### Unix: `remove_dir_all` after the CVE

The whole algorithm is the `remove_dir_impl` module at the bottom of
[`unix.rs`][unix-rs]. It is selected for every Unix target except `redox`,
`espidf`, `horizon`, `vita`, `nto`, `vxworks` and `miri`, which get the
path-based [`common.rs`][common-rs] version instead. The root is handled
first: `lstat`, and if it is a symlink, `unlink` it — that is the only
check-then-act left, and it is safe because the recursive part "does not
recurse into symlinks" (comment on `remove_dir_all_modern`). Every child is
then opened _relative to the parent fd_:

```rust
pub fn openat_nofollow_dironly(parent_fd: Option<RawFd>, p: &CStr) -> io::Result<OwnedFd> {
    let fd = cvt_r(|| unsafe {
        openat(
            parent_fd.unwrap_or(libc::AT_FDCWD),
            p.as_ptr(),
            libc::O_CLOEXEC | libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_DIRECTORY,
        )
    })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}
```

`remove_dir_all_recursive(parent_fd, name)` tries that open. `ENOTDIR` or
`ELOOP` means "not a directory — don't traverse further" (the comment notes
"for symlinks, older Linux kernels may return `ELOOP` instead of `ENOTDIR`"),
so the entry is `unlinkat(parent_fd, name, 0)`-ed. Otherwise the fd is handed
to `fdopendir` (`fdreaddir`, which gives up `OwnedFd` ownership because
`closedir` will close it) and iterated; children with `d_type == DT_DIR`
recurse, `DT_UNKNOWN` also recurses rather than risking `unlink` on a directory
("This however can causing orphaned directories requiring an fsck e.g. on
Solaris and Illumos"), everything else is `unlinkat(fd, name, 0)`. After the
loop, `unlinkat(parent_fd, name, AT_REMOVEDIR)` removes the now-empty
directory, with `ENOENT` ignored at every step.

### Windows: `NtOpenFile` relative to a parent handle

[`windows/remove_dir_all.rs`][win-rda] states its two goals in the module
comment — "It must not be possible to trick this into deleting files outside
of the parent directory (see CVE-2022-21658)" and "It should not fail if many
threads or processes call `remove_dir_all` on the same path" — and its answer
to the first:

> The first is handled by using the low-level `NtOpenFile` API to open a file
> relative to a parent directory.

`open_link_no_reparse(parent, name, access, options)` fills an
`OBJECT_ATTRIBUTES` with `RootDirectory: parent.as_raw_handle()`,
`Attributes: OBJ_DONT_REPARSE`, and ORs `FILE_OPEN_REPARSE_POINT` into the
create options, "because unfortunately opening a file relative to a parent is
not supported by win32 functions." `OBJ_DONT_REPARSE` "may not be available in
earlier versions of Windows", so an `INVALID_PARAMETER` on the first call
flips a process-wide `AtomicU32` to `0` and retries without it — a one-time,
downgrade-only probe. The walk (`remove_dir_all_iterative`) is explicit-stack,
not recursive: `fill_dir_buff` pages `FileIdBothDirectoryInfo` records through
`GetFileInformationByHandleEx`, directories are pushed onto `dirlist`
(`open_dir` asks for `SYNCHRONIZE | FILE_LIST_DIRECTORY`), and files are
opened with `DELETE` access and deleted through the handle. The root is
opened with `CreateFileW` + `FILE_FLAG_BACKUP_SEMANTICS |
FILE_FLAG_OPEN_REPARSE_POINT` and rejected with `ERROR_DIRECTORY` if
`FILE_ATTRIBUTE_DIRECTORY` is unset ([`windows.rs`][windows-rs] `remove_dir_all`).

Deletion is the delete-on-close-versus-POSIX choice, made per handle
([`windows.rs`][windows-rs] `File::delete`):

```rust
fn delete(self) -> Result<(), WinError> {
    // If POSIX delete is not supported for this filesystem then fallback to win32 delete.
    match self.posix_delete() {
        Err(WinError::INVALID_PARAMETER)
        | Err(WinError::NOT_SUPPORTED)
        | Err(WinError::INVALID_FUNCTION) => self.win32_delete(),
        result => result,
    }
}
```

`posix_delete` sets `FILE_DISPOSITION_INFO_EX` with
`FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS |
FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE` — "supported for Windows 10
1607 (aka RS1) and later. However some filesystem drivers will not support it
even then, e.g. FAT32." `win32_delete` is the classic `FILE_DISPOSITION_INFO {
DeleteFile: true }`, where "The file won't actually be deleted until all file
handles are closed." Read-only files are therefore handled by the
`IGNORE_READONLY_ATTRIBUTE` flag on the POSIX path, not by clearing the
attribute first; the path-based `unlink` in the same file uses the same trick
as a fallback when `DeleteFileW` reports `ACCESS_DENIED`.

### `std::fs::Dir`

At the pinned SHA `pub struct Dir` exists in [`fs.rs`][fs-rs] under
`#[unstable(feature = "dirfd", issue = "120426")]`, with exactly two methods:
`Dir::open(path)` and `Dir::open_file(&self, path)` (both read-only). The
Unix backing type is `pub struct Dir(OwnedFd)` ([`unix/dir.rs`][unix-dir]),
opened with `O_CLOEXEC | O_DIRECTORY` plus the caller's access/creation bits
and `custom_flags`; `open_file` is `openat64(self.0.as_raw_fd(), path, flags,
mode)`. It implements `AsFd`, `AsRawFd`, `IntoRawFd`, `FromRawFd` and
`From<OwnedFd>`/`Into<OwnedFd>`. The Windows backing type wraps a `Handle`
opened by `CreateFileW` with `FILE_FLAG_BACKUP_SEMANTICS`; `open_file` builds
`OBJECT_ATTRIBUTES { RootDirectory: self.handle, .. }` and calls
`NtCreateFile` with `FILE_NON_DIRECTORY_FILE` — but first, "NtCreateFile will
fail if given an absolute path and a non-null RootDirectory", so an absolute
path is routed to plain `File::open` ([`windows/dir.rs`][win-dir]). The
[`common.rs`][common-rs] fallback is `pub struct Dir { path: PathBuf }`.

## Dimensions

### Dimension 1 — Threat model

For `remove_dir_all`: an unprivileged local user who can create entries under
a directory a privileged program will delete, and who can swap a directory for
a symlink mid-walk ([advisory][cve]). The Windows module adds a second,
non-adversarial concern — concurrent deleters of the same tree — and the
`DELETE_PENDING` limbo that creates ([`win-rda`][win-rda] module comment).
For `Dir`: races against a _renamed_ directory ("less vulnerable to TOCTOU
attacks and similar races", [#120426][issue]); an adversary who plants `..`
or a symlink is explicitly out of scope.

### Dimension 2 — Resolution primitive

Unix: `openat(parent_fd, name, O_NOFOLLOW | O_DIRECTORY)` — one component
per call, so the atomicity claim is per-component, and a component is never
a path with a `/` in it (names come from `readdir`). Windows:
`NtOpenFile` with `RootDirectory` set — the same per-component shape, one
`UNICODE_STRING` from a directory listing per call. `Dir::open_file` on both
platforms passes the caller's _whole_ relative path to `openat`/`NtCreateFile`,
so there the kernel resolves multiple components and the handle only pins the
starting point.

### Dimension 3 — Symlink and `..` policy

`remove_dir_all`: symlinks are refused at every level by `O_NOFOLLOW`
(`ELOOP`/`ENOTDIR` → `unlinkat`) and by `FILE_OPEN_REPARSE_POINT` +
`OBJ_DONT_REPARSE`; the root symlink is unlinked, never followed. `..` never
arises because names come from directory listings. `Dir`: symlinks are
followed unless the caller passes `O_NOFOLLOW` via `custom_flags`
(the8472: "Should be achievable via `Dir::open_with` combined with
`OpenOptionsExt`"; RalfJung: "So there are no plans for a portable 'open
without following symlinks'?" — [#120426][issue], 2026-06 and 2026-07); `..`
is allowed by design.

### Dimension 4 — Boundaries

Does not apply to mounts: there is no `st_dev` check and no
`RESOLVE_NO_XDEV`; a bind mount inside the tree is traversed and its contents
deleted. Windows reparse points are the one boundary that is enforced — every
tag, not only symlinks, because `FILE_OPEN_REPARSE_POINT` opens the reparse
point itself; `fill_dir_buff`'s comment observes that a symlink directory
"is simply an empty directory with some 'reparse' metadata attached", so
iterating one yields nothing and the link is then deleted as an empty
directory. Nothing in either implementation addresses procfs magic links,
alternate data streams or device names.

### Dimension 5 — Portability and fallback

Selection is compile-time, by target ([`unix.rs`][unix-rs] `cfg`): `redox`,
`espidf`, `horizon`, `vita`, `nto`, `vxworks` and `miri` get
[`common.rs`][common-rs], which is the pre-CVE algorithm — `symlink_metadata`
then `read_dir` + `remove_file`/`remove_dir` by full path. The public docs
name the consequence: on "**QNX**, **Redox OS**, **VxWorks**: This function
does not protect against TOCTOU races", and "**Miri**: Even when emulating
targets where the underlying implementation will protect against TOCTOU
races, Miri will not do so" ([`fs.rs`][fs-rs]). There is no runtime probe for
`openat` on Unix; the only runtime probe is Windows' `OBJ_DONT_REPARSE`
downgrade and the POSIX-delete → win32-delete fallback. `Dir` follows the
same rule: a `PathBuf` on platforms without handles, and (per the tracking
issue) no seccomp-triggered fallback on tier 1.

> [!NOTE]
> The brief expected a `weak!`-linked `openat`/`fdopendir` fallback for macOS
> before 10.10. At the pinned SHA it is gone: the only `weak!` uses in
> [`unix.rs`][unix-rs] are Android's `futimens`/`utimensat` (API level 19) and
> glibc 2.34's `__futimens64`/`__utimensat64`. The advisory's "macOS before
> 10.10" caveat describes the 1.58.1 code, not the current tree.

### Dimension 6 — Failure and partiality

`ENOENT` on any child is swallowed ("if one of these directories has already
been deleted, then we need to continue the loop, not return ok"), and
`ignore_notfound` wraps the final `AT_REMOVEDIR`; any other error aborts with
whatever has been deleted so far left deleted. The public contract spells out
the partial state: "This function may return `io::ErrorKind::DirectoryNotEmpty`
if the directory is concurrently written into, which typically indicates some
contents were removed but not all. `io::ErrorKind::NotFound` is only returned
if no removal occurs" ([`fs.rs`][fs-rs]). Windows retries `SHARING_VIOLATION`
on file deletes and `DIR_NOT_EMPTY` on directory deletes up to
`MAX_RETRIES = 50` spins of `thread::yield_now`, and maps
`STATUS_DELETE_PENDING` to a dedicated `DELETE_PENDING` error rather than the
generic `ACCESS_DENIED` it would otherwise become — then treats it as "already
gone" ([`win-rda`][win-rda]). A rename of a directory mid-walk is harmless on
both platforms: the open fd/handle keeps pointing at the same object and the
final `unlinkat`/delete is by name relative to the parent handle.

### Dimension 7 — Enumeration and deletion

Unix: recursive, one `openat` + `fdopendir` per directory, so fd usage and
stack depth are both proportional to tree depth with no cap; `DirStream`'s
`Drop` runs `closedir`, and a `debug_assert_fd_is_open` guards against the
fd having been closed out from under it. WASI collects the whole listing
before deleting anything, because "the WASIp1 API for reading directories is
not well-designed for handling mutations between invocations." Windows: an
explicit `dirlist` stack, so recursion depth is bounded by heap, and a
directory whose listing spans several `fill_dir_buff` pages is re-pushed with
`restart = false` to resume. No re-verification (`fstat` against a prior
`d_ino`) happens after `openat` on either platform — `O_NOFOLLOW |
O_DIRECTORY` and `FILE_OPEN_REPARSE_POINT` are the whole guarantee.
`ReadDir` itself is still path-based (`readdir` calls `opendir(path)`,
[`unix.rs`][unix-rs]); addisoncrump's observation that "there is no `open` on
`DirEntry`, you have to expand the path first and then open the full path"
([#120426][issue], 2025-03-20) remains true at this SHA.

## Strengths

- **The right primitive on tier-1 platforms**: `O_NOFOLLOW | O_DIRECTORY`
  relative to a parent fd, and `NtOpenFile` with `RootDirectory` +
  `FILE_OPEN_REPARSE_POINT` + `OBJ_DONT_REPARSE`, with no path ever rebuilt.
- **Windows deletion is unusually careful**: POSIX-semantics delete with
  `IGNORE_READONLY_ATTRIBUTE`, a documented win32 fallback, `DELETE_PENDING`
  disambiguated from `ACCESS_DENIED`, and bounded retries for concurrent deleters.
- **Honest documentation**: the platforms without protection are listed by
  name in the public docs, and the partial-failure contract is written down.
- **`Dir` is I/O-safe from day one**: `OwnedFd` inside, `AsFd`/`From<OwnedFd>`
  outside, so it interoperates with [rustix][rustix] and [cap-std][cap-std].

## Weaknesses

- **No containment**: `Dir` explicitly permits `..` and symlink escapes;
  `remove_dir_all` crosses mounts. Anyone needing a boundary must go to
  [cap-std][cap-std] or [libpathrs][libpathrs].
- **The fallback is the vulnerable algorithm**, chosen at compile time, with
  no runtime signal to the caller (the8472's `IS_RACEFREE` constant was floated
  in [#120426][issue] and not implemented).
- **`ReadDir` is path-based** and cannot be built from a `Dir`; the
  `fdopendir` ownership question ("the behavior is undefined" on any other
  use of the fd) is why the issue is still debating `getdents` versus
  `openat(dirfd, ".")` re-open (2026-09-19).
- **`Dir` surface is minimal** — `open` and `open_file` only; `open_dir`,
  `remove_*`, `rename`, `metadata_at` and the nofollow variant are all still
  open PRs or unresolved questions.
- **Unbounded recursion** and one fd per level on Unix.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                   | Trade-off                                                                           |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `openat` + `O_NOFOLLOW \| O_DIRECTORY` instead of `lstat` first | The kernel refuses the symlink atomically; no check-then-act window                         | `ELOOP`/`ENOTDIR` must both be treated as "not a directory" across kernel versions  |
| `DT_UNKNOWN` recurses rather than `unlink`s                     | `unlink` on a directory can orphan inodes on Solaris/Illumos                                | An extra `openat` per unknown-type entry                                            |
| `NtOpenFile` with `RootDirectory`, not Win32                    | Win32 has no relative open; `OBJ_DONT_REPARSE` + `FILE_OPEN_REPARSE_POINT` pin the parent   | Undocumented-ish NT API; `OBJ_DONT_REPARSE` probed at runtime and dropped on old OS |
| POSIX delete first, win32 delete as fallback                    | Immediate unlink and `IGNORE_READONLY_ATTRIBUTE`; older FS drivers (FAT32) lack it          | Three error codes to recognise as "unsupported"                                     |
| Compile-time platform fallback for `remove_dir_all`/`Dir`       | Basic operations must exist everywhere; those platforms lack privilege separation anyway    | The fallback is the CVE algorithm, and only the docs say so                         |
| Sandboxing a non-goal for `Dir`                                 | Keep the type small and portable; `O_BENEATH`-style policy left to crates                   | A `Dir` is not a boundary and must not be used as one                               |
| No `ReadDir` ⇄ `Dir` conversion yet                             | `fdopendir` makes the fd's other uses undefined; `getdents` rewrite or `openat(".")` needed | Every traversal that wants a handle still re-opens by path                          |

## Sources

- [Security advisory for CVE-2022-21658][cve] — the pre-fix check-then-recurse, the attack, affected versions, platforms left unprotected
- [`library/std/src/sys/fs/unix.rs`][unix-rs] — `remove_dir_impl`: `openat_nofollow_dironly`, `fdreaddir`, `remove_dir_all_recursive`, the `cfg` selecting the fallback, `readdir` by path
- [`library/std/src/sys/fs/unix/dir.rs`][unix-dir] — `Dir(OwnedFd)`, `O_DIRECTORY` open, `openat64` in `open_file`, fd trait impls
- [`library/std/src/sys/fs/windows/remove_dir_all.rs`][win-rda] — module rationale, `open_link_no_reparse`, `OBJ_DONT_REPARSE` probe, `remove_dir_all_iterative`, retry policy
- [`library/std/src/sys/fs/windows.rs`][windows-rs] — `File::delete`/`posix_delete`/`win32_delete`, `fill_dir_buff`, root open, `unlink` read-only fallback
- [`library/std/src/sys/fs/windows/dir.rs`][win-dir] — `Dir` over `NtCreateFile` with `RootDirectory`, absolute-path escape hatch
- [`library/std/src/sys/fs/common.rs`][common-rs] — the path-based fallback `remove_dir_all` and `Dir { path }`
- [`library/std/src/fs.rs`][fs-rs] — module TOCTOU section, `pub struct Dir`, `remove_dir_all` platform and partial-failure contract
- [Tracking issue #120426][issue] — proposed API, platform survey, the sandboxing non-goal, fallback debate, `fdopendir` ownership discussion

<!-- References -->

[rustix]: ./rustix.md
[cap-std]: ./cap-std.md
[libpathrs]: ./libpathrs.md
[cve]: https://blog.rust-lang.org/2022/01/20/cve-2022-21658.html
[issue]: https://github.com/rust-lang/rust/issues/120426
[rust-tree]: https://github.com/rust-lang/rust/tree/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src
[unix-rs]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/unix.rs
[unix-dir]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/unix/dir.rs
[windows-rs]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/windows.rs
[win-rda]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/windows/remove_dir_all.rs
[win-dir]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/windows/dir.rs
[common-rs]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/common.rs
[fs-rs]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/fs.rs
