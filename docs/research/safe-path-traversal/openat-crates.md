# `openat` and `openat-ext`

The minimal dirfd wrapper — one `O_PATH` descriptor, one `*at` syscall per
method, `O_NOFOLLOW` everywhere, and no path policy at all — plus the utility
layer CoreOS stacked on it before moving both to `cap-std`.

|                           |                                                                                                                                                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | library (two crates)                                                                                                                                                                                       |
| **Year**                  | `openat` 2016-12-10 → 2021-04-16 (v0.1.21); `openat-ext` 2019-08-20 → 2023-07-13 (v0.2.3, deprecated)                                                                                                      |
| **Authors / Maintainers** | Paul Colomiets (tailhook) — `openat`; Colin Walters and the CoreOS team — `openat-ext`                                                                                                                     |
| **Language**              | Rust (`openat`: raw `libc`, `unsafe` per call; `openat-ext`: `#![deny(unsafe_code)]` except one `syncfs`)                                                                                                  |
| **License**               | MIT OR Apache-2.0 (both)                                                                                                                                                                                   |
| **Repository**            | [`tailhook/openat`][openat-repo], [`coreos/openat-ext`][ext-repo]                                                                                                                                          |
| **Platforms**             | Unix only; `O_PATH` on Linux, `O_DIRECTORY` on FreeBSD, bare `O_CLOEXEC` elsewhere                                                                                                                         |
| **Primitive**             | `openat(dirfd, name, O_PATH \| O_CLOEXEC \| O_NOFOLLOW)` and siblings; no resolution algorithm                                                                                                             |
| **Source read**           | [`openat/src/lib.rs`][openat-lib], [`dir.rs`][openat-dir], [`list.rs`][openat-list], [`metadata.rs`][openat-meta], [`name.rs`][openat-name]; [`openat-ext/README.md`][ext-readme], [`src/lib.rs`][ext-lib] |

## Overview

### What it solves

`openat` is a binding, not a sandbox. Its own summary ([`README.md`][openat-readme]):

> The interface to `openat`, `symlinkat`, and other functions in `*at` family.
> […] This crate is a thin wrapper for the underlying system calls.

The module doc says what a `Dir` is and what it promises
([`src/lib.rs`][openat-lib]):

> Main concept here is a `Dir` which holds `O_PATH` file descriptor […]
> Note after opening file descriptors refer to same directory regardless of
> where it's moved or mounted (with `pivot_root` or `mount --move`). It may
> also be unmounted or be out of chroot and you will still be able to access
> files relative to it.

`openat-ext` exists because rpm-ostree needed more than the syscalls: "This
code originated from
`https://github.com/projectatomic/rpm-ostree/blob/016c1c5e627fc2a8cd3266ccda3a47a5f8992594/rust/src/openat_utils.rs`"
([`openat-ext/README.md`][ext-readme]). It adds "the common file utility
functions that many real applications need" — optional-open helpers,
`ensure_dir_all`, `remove_all`, reflink-aware copy, and an atomic-replace
`FileWriter`.

### Design philosophy

Safety is delegated to the caller in one sentence ([`src/lib.rs`][openat-lib]):

> Note that if path supplied to any method of dir is absolute the Dir file
> descriptor is ignored.
>
> Also while all methods of dir accept any path if you want to prevent certain
> symlink attacks and race condition you should only use a single-component
> path. I.e. open one part of a chain at a time.

That is the whole contract: the crate exposes the kernel's `*at` semantics
verbatim, and the only hardening it applies unconditionally is `O_NOFOLLOW` on
the final component. The one guard it wanted is a `TODO` on `Dir::open`:
"maybe accept only absolute paths?" ([`src/dir.rs`][openat-dir]).

## How it works

### The minimal wrapper

`Dir` is a newtype over `RawFd` ([`src/lib.rs`][openat-lib]). Every method is
`to_cstr(path)` followed by one libc call ([`src/dir.rs`][openat-dir]):

```rust
#[cfg(target_os="linux")]
const BASE_OPEN_FLAGS: libc::c_int = libc::O_PATH|libc::O_CLOEXEC;
#[cfg(target_os="freebsd")]
const BASE_OPEN_FLAGS: libc::c_int = libc::O_DIRECTORY|libc::O_CLOEXEC;
#[cfg(not(any(target_os="linux", target_os="freebsd")))]
const BASE_OPEN_FLAGS: libc::c_int = libc::O_CLOEXEC;

fn _open(path: &CStr) -> io::Result<Dir> {           // Dir::open
    let fd = unsafe { libc::open(path.as_ptr(), BASE_OPEN_FLAGS) };
    …
}
fn _sub_dir(&self, path: &CStr) -> io::Result<Dir> { // Dir::sub_dir
    let fd = unsafe { libc::openat(self.0, path.as_ptr(),
                                   BASE_OPEN_FLAGS|libc::O_NOFOLLOW) };
    …
}
fn _open_file(&self, path: &CStr, flags: libc::c_int, mode: libc::mode_t)
    -> io::Result<File>
{
    let res = libc::openat(self.0, path.as_ptr(),
                           flags|libc::O_CLOEXEC|libc::O_NOFOLLOW,
                           mode as libc::c_uint);
    …
}
```

| Method                                  | Syscall                                                                                                      | Note                                                                                                                             |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `Dir::open(path)`                       | `open(path, O_PATH \| O_CLOEXEC)`                                                                            | No `O_DIRECTORY` on Linux — `test_open_file` expects opening a _file_ to succeed, and only FreeBSD panics with "Not a directory" |
| `sub_dir(name)`                         | `openat(fd, name, O_PATH \| O_CLOEXEC \| O_NOFOLLOW)`                                                        | "does not resolve symlinks by default, so you may have to call `read_link`"                                                      |
| `open_file` / `write_file` / `new_file` | `openat(fd, name, flags \| O_CLOEXEC \| O_NOFOLLOW)`                                                         | `new_file` is `O_CREAT \| O_EXCL`; a symlink at the destination makes `write_file` fail                                          |
| `new_unnamed_file` / `link_file_at`     | `openat(fd, ".", O_TMPFILE \| O_WRONLY)`; `linkat(AT_FDCWD, "/proc/self/fd/N", fd, name, AT_SYMLINK_FOLLOW)` | Linux only; needs `/proc`                                                                                                        |
| `list_dir(name)` / `list_self()`        | `openat(fd, name, O_DIRECTORY \| O_CLOEXEC)` → `fdopendir`; `dup(fd)` → `fdopendir`                          | `list_dir` has **no** `O_NOFOLLOW`; `DirIter` skips `.` and `..`, reads `d_type`                                                 |
| `metadata(name)`                        | `fstatat(fd, name, AT_SYMLINK_NOFOLLOW)`                                                                     | "If the destination path is a symlink, this will return the metadata of the symlink itself"                                      |
| `read_link`, `symlink`, `create_dir`    | `readlinkat` (4096-byte buffer), `symlinkat`, `mkdirat`                                                      |                                                                                                                                  |
| `remove_file` / `remove_dir`            | `unlinkat(fd, name, 0 / AT_REMOVEDIR)`                                                                       |                                                                                                                                  |
| `local_rename` / `rename` / `hardlink`  | `renameat`, `linkat(…, 0)`                                                                                   |                                                                                                                                  |
| `local_exchange` / `rename_flags`       | `syscall(SYS_renameat2, …, RENAME_EXCHANGE)`                                                                 | Linux only                                                                                                                       |
| `recover_path()`                        | `readlink("/proc/self/fd/N")`                                                                                | "they sometimes may not be available so use with care"                                                                           |
| `from_raw_fd_checked(fd)`               | `fstat` + `S_IFDIR` check                                                                                    | the only place the crate checks that the fd _is_ a directory                                                                     |

`AsPath` ([`src/name.rs`][openat-name]) converts `&Path`, `&str`, `String`,
`&CStr` and `&Entry` to a `CStr`, returning `None` on an embedded NUL, which
`to_cstr` turns into `InvalidInput` "nul byte in file name". An `&Entry` from
`list_dir` is passed straight through — "the latter is faster as underlying
system call wants `CString` and we keep that in entry".

### What `openat-ext` adds

`OpenatDirExt` is a trait on `openat::Dir` ([`src/lib.rs`][ext-lib]). The
methods worth reading for this catalog:

- **`open_file_optional`, `metadata_optional`, `sub_dir_optional`,
  `remove_file_optional`, `remove_dir_optional`, `exists`** — each maps
  `io::ErrorKind::NotFound` to `Ok(None)`/`Ok(false)`, because "Checking for
  nonexistent files (`ENOENT`) is by far the most common case of inspecting
  error codes in Unix."
- **`ensure_dir_all`** — one optimistic `mkdirat`; on `NotFound` it recurses on
  `Path::parent()` and `ensure_dir`s each prefix ("This is pessimistic,
  assuming no components exist. But we already handled the optimal case").
- **`remove_all`** — `unlinkat` first; on `EISDIR`, `list_dir` + `sub_dir` and
  recurse:

  ```rust
  pub(crate) fn remove_children(d: &openat::Dir, iter: openat::DirIter) -> io::Result<()> {
      for entry in iter {
          let entry = entry?;
          match d.get_file_type(&entry)? {
              openat::SimpleType::Dir => {
                  let subd = d.sub_dir(&entry)?;
                  remove_children(&subd, subd.list_dir(".")?)?;
                  let _ = d.remove_dir_optional(&entry)?;
              }
              _ => { let _ = d.remove_file_optional(entry.file_name())?; }
          }
      }
      Ok(())
  }
  ```

  `get_file_type` trusts `d_type` when present and falls back to `fstatat`;
  `sub_dir` is `O_NOFOLLOW`, so a symlink-to-directory entry classified
  `Symlink` is unlinked, not descended.

- **`FileWriter` / `new_file_writer` / `write_file_with`** — the atomic-replace
  pattern: try `new_unnamed_file` (`O_TMPFILE`); if that fails, `tempfile_in`
  creates `.tmp<8 random alphanumerics>.tmp` with `new_file` (`O_EXCL`), up to
  `TEMPFILE_ATTEMPTS = 100` times. `complete_with(dest, f)` flushes, runs `f`
  on the raw fd ("change the mode, extended attributes, or invoke `fchmod()`"),
  then for the `O_TMPFILE` case `link_file_at`s it under a fresh random name
  ("there's no `linkat(LINKAT_REPLACE)` yet, so we need to generate a tempfile
  as the penultimate step"), and finally `local_rename`s it over `dest`,
  unlinking the temp name on failure.
- **`copy_file` / `copy_file_at`** — open source `O_NOFOLLOW`, write through a
  `FileWriter` created `0o600`, `copy_file_range` with a `pread`/`pwrite`
  fallback on `ENOSYS`/`EXDEV`/`EINVAL`/`EPERM` (latching the `ENOSYS` in a
  static), `fchmod` to the source mode before the rename. "Symbolic links will
  not be followed; instead an error is returned."
- **`set_mode`** — `lstat`s and silently skips symlinks, because
  "`AT_SYMLINK_NOFOLLOW` used to short-circuit to `ENOTSUP` in older glibc
  versions, so we don't use it".
- **`syncfs`** — "does not work with `O_PATH` FDs, so `self` cannot be directly
  used" — it reopens `"."` to get a real fd first. This is the one
  `#[allow(unsafe_code)]` in the crate.

## Dimension 1 — Threat model

Not stated in either crate. `openat`'s only nod is the "single-component
path" advice in its module doc; `openat-ext` inherits it. In practice the
adversary these crates were written against is _the filesystem being moved
under you_ — the `pivot_root`/`mount --move` note — not a hostile local user
planting symlinks. Everything symlink-shaped that they do defend against
(`O_NOFOLLOW`, `AT_SYMLINK_NOFOLLOW`, `sub_dir` refusing links) is a property
of the final component only.

## Dimension 2 — Resolution primitive

The kernel's `openat` with a caller-supplied path. Atomicity is therefore
exactly the kernel's: whole-path, but with every intermediate component
resolved by ordinary namei rules (symlinks followed, `..` honoured, mounts
crossed). There is no resolver in either crate; nothing splits a path into
components; `openat2` and `RESOLVE_*` do not appear anywhere in
`openat/src/`.

## Dimension 3 — Symlink and `..` policy

Read from the code, not the docs:

- **`..`**: not rejected. `sub_dir("..")` opens the parent of the dirfd —
  wherever that currently is.
- **Absolute paths**: not rejected; the module doc says so ("the Dir file
  descriptor is ignored"). `Dir::open("/")` followed by any absolute path is
  the ambient filesystem.
- **Final-component symlinks**: refused by `O_NOFOLLOW` in `sub_dir`,
  `_open_file` (all of `open_file`, `write_file`, `append_file`, `new_file`,
  `update_file`), and by `AT_SYMLINK_NOFOLLOW` in `metadata`. **Not** refused
  by `list_dir` (`O_DIRECTORY | O_CLOEXEC` only), `create_dir`, `remove_*`,
  `rename`, or `hardlink` — for the last four the underlying syscalls do not
  follow the final component anyway.
- **Intermediate symlinks**: followed by the kernel in every method that takes
  a multi-component path. Hence the doc's "open one part of a chain at a
  time" — the safe usage is a caller-written component walk on top of
  `sub_dir`.
- `openat-ext` never walks components either: `ensure_dir_all` recurses over
  `Path::parent()` but each `mkdirat` still receives the full prefix.

## Dimension 4 — Boundaries

None. No `st_dev` comparison, no procfs check (the crate _uses_ `/proc/self/fd`
for `link_file_at` and `recover_path` without verifying it), no special
handling of magic links. `copy_to`'s `EXDEV` handling is about
`copy_file_range` across filesystems, not about traversal.

## Dimension 5 — Portability and fallback

The crate assumes `*at` and adapts only the base flags: `O_PATH` is Linux-only
("Some OS's (e.g., macOS) do not provide `O_PATH`, in which case the file
descriptor is of regular type"), FreeBSD gets `O_DIRECTORY`, and everything
else opens the directory `O_RDONLY`. `O_TMPFILE`, `link_file_at`,
`local_exchange` and `rename_flags` are `#[cfg(target_os="linux")]` with
always-`Err` stubs elsewhere. `openat-ext`'s `FileWriter` falls back from
`O_TMPFILE` to a named `O_EXCL` temp file on any error, and `copy_to` falls
back from `copy_file_range` to a userspace loop. No feature of either crate
depends on kernel version detection beyond those latches.

## Dimension 6 — Failure and partiality

Raw `io::Error::last_os_error()` from every call; `openat-ext` layers
`ErrorKind` matching on top. `remove_all` stops at the first error and leaves a
partially deleted tree. `FileWriter::complete_with` cleans up its temp name if
the final `renameat` fails, but not if the process dies between `linkat` and
`renameat` (the random `.tmp…` name is then orphaned). `local_rename_optional`
carries the honest note: "this isn't strictly an atomic operation, because
unfortunately `renameat` overloads `ENOENT` for multiple error cases".

## Dimension 7 — Enumeration and deletion

`DirIter` wraps `fdopendir` over an fd from `openat(O_DIRECTORY)` and yields
`Entry { name: CString, file_type: Option<SimpleType> }` from `readdir`,
skipping `.`/`..` by byte comparison ([`src/list.rs`][openat-list]). Readdir
errors are detected by zeroing `errno` before the call. `telldir`/`seekdir`/
`rewinddir` are exposed as `current_position`/`seek`/`rewind`.

Deletion is `openat-ext`'s `remove_children` above: fd-relative (`sub_dir` +
`list_dir(".")`), `d_type`-classified, `O_NOFOLLOW` on descent, no
re-verification of the opened child against the entry, no depth or fd limit.
The recursion holds one `Dir` and one `DirIter` per level.

## Why CoreOS built it — and left

`openat-ext` was rpm-ostree's `openat_utils.rs` promoted to a crate, and its
successor is named in the first line of both its README and its crate doc
([`openat-ext/README.md`][ext-readme]):

> # This project is deprecated
>
> Still maintained for now, but deprecated. Instead, we are focusing on
> [cap-std](https://docs.rs/cap-std/latest/cap_std/) and the successor to this
> crate is [cap-std-ext](https://docs.rs/cap-std-ext/latest/cap_std_ext/).

The `openat` side never announced a deprecation; its last commit (2021-04-16)
is a version bump, and the README still says "Status: Beta". [cap-std][capstd]'s
README explains the difference from its side: "`cap-std`'s `Dir` type performs
sandboxing, including for multiple-component paths. And `cap-std` supports
symlinks as long as they remain within the sandbox, while `openat` doesn't
support following symlinks."

## Strengths

- **Exactly the syscall surface, nothing hidden**: a reader can map every
  method to one `libc` call and know its flags.
- **`O_NOFOLLOW` by default** on every open of a file or subdirectory — the
  single most common symlink trap is closed without the caller asking.
- **`O_PATH` base handles** cost no read permission and cannot be used to read
  the directory by accident.
- `openat-ext` documents two idioms worth carrying: `ENOENT → Option`, and
  the `O_TMPFILE → linkat → renameat` atomic-replace ladder with its named-temp
  fallback.

## Weaknesses

- **No containment at all**: `..`, absolute paths and intermediate symlinks all
  resolve wherever the kernel takes them; the doc pushes the component walk
  onto the caller and provides no helper for it.
- **`list_dir` lacks `O_NOFOLLOW`**, unlike every other opener in the crate.
- **`Dir::open` does not require a directory** on Linux; only
  `from_raw_fd_checked` checks `S_IFDIR`.
- **`/proc` is assumed**, not verified, for `link_file_at` and `recover_path`.
- **`remove_all` is best-effort**: stops on first error, no re-verification,
  trusts `d_type`.
- Unmaintained (`openat`) and deprecated (`openat-ext`).

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                              | Trade-off                                                                                    |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Thin `*at` wrapper, no resolver                   | "This crate is a thin wrapper for the underlying system calls"                         | Every multi-component path is unsandboxed; safety is a usage discipline                      |
| `O_PATH \| O_CLOEXEC` base handle on Linux        | Survives `pivot_root`/`mount --move`; no read permission needed                        | `syncfs`, `fdopendir` etc. need a re-open of `"."`; not portable, so three `cfg` variants    |
| `O_NOFOLLOW` on `sub_dir` and every file open     | Closes the final-component symlink swap                                                | Legitimate final symlinks need a manual `read_link`; `list_dir` was left out                 |
| `metadata` = `fstatat(AT_SYMLINK_NOFOLLOW)`       | Consistent with the openers                                                            | No following variant; callers `read_link` and re-stat                                        |
| `&Entry` accepted as a path                       | The `CString` from `readdir` is reused without copying                                 | `Entry` is bound to the directory it was read from only by convention                        |
| `openat-ext`: `O_TMPFILE` → `linkat` → `renameat` | Content is complete and mode-set before it has a name                                  | Needs `/proc`; two random names per write; orphaned temp on crash between the last two steps |
| `openat-ext`: `ENOENT → Ok(None)`                 | The dominant error-inspection case in Unix code                                        | `renameat`'s overloaded `ENOENT` makes `local_rename_optional` non-atomic                    |
| Deprecate in favour of `cap-std` / `cap-std-ext`  | Multi-component sandboxing and in-sandbox symlink following without a hand-rolled walk | A heavier dependency; `cap-std-ext` re-implements the atomic-write helpers on the new `Dir`  |

## Sources

- [`openat/README.md`][openat-readme] — "thin wrapper", beta status, pointer to `openat-ext`
- [`openat/src/lib.rs`][openat-lib] — `O_PATH` concept, the `pivot_root` note, the absolute-path and single-component caveats
- [`openat/src/dir.rs`][openat-dir] — `BASE_OPEN_FLAGS`, every method's flags, `new_unnamed_file`/`link_file_at`, `from_raw_fd_checked`, the `TODO(tailhook)`
- [`openat/src/list.rs`][openat-list] — `fdopendir`, `.`/`..` skipping, `d_type` mapping, `errno` reset
- [`openat/src/metadata.rs`][openat-meta], [`openat/src/name.rs`][openat-name] — `Metadata` over raw `stat`; `AsPath` and the NUL check
- [`openat-ext/README.md`][ext-readme] — the deprecation notice and the rpm-ostree origin
- [`openat-ext/src/lib.rs`][ext-lib] — `OpenatDirExt`, `remove_children`, `FileWriter`, `tempfile_in`, `copy_to`, `set_mode`, `syncfs`
- [cap-std][capstd] `README.md` — the "Similar crates" comparison with `openat`

<!-- References -->

[capstd]: ./cap-std.md
[openat-repo]: https://github.com/tailhook/openat/tree/d17e6288c2fb707601ff584a885c220031e94971
[openat-readme]: https://github.com/tailhook/openat/blob/d17e6288c2fb707601ff584a885c220031e94971/README.md
[openat-lib]: https://github.com/tailhook/openat/blob/d17e6288c2fb707601ff584a885c220031e94971/src/lib.rs
[openat-dir]: https://github.com/tailhook/openat/blob/d17e6288c2fb707601ff584a885c220031e94971/src/dir.rs
[openat-list]: https://github.com/tailhook/openat/blob/d17e6288c2fb707601ff584a885c220031e94971/src/list.rs
[openat-meta]: https://github.com/tailhook/openat/blob/d17e6288c2fb707601ff584a885c220031e94971/src/metadata.rs
[openat-name]: https://github.com/tailhook/openat/blob/d17e6288c2fb707601ff584a885c220031e94971/src/name.rs
[ext-repo]: https://github.com/coreos/openat-ext/tree/34502fe72315f127ff6e72b0649551017ff897ec
[ext-readme]: https://github.com/coreos/openat-ext/blob/34502fe72315f127ff6e72b0649551017ff897ec/README.md
[ext-lib]: https://github.com/coreos/openat-ext/blob/34502fe72315f127ff6e72b0649551017ff897ec/src/lib.rs
