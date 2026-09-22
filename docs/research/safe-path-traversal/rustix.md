# rustix

The binding layer under [cap-std][cap-std] and much of the Rust systems
ecosystem: every `*at` call, `openat2` with its `ResolveFlags`, and a
directory iterator that reads from an fd — with I/O safety as the one policy
it does impose.

|                           |                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | library (syscall bindings)                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Year**                  | 2021–; version 1.1.5 at the pinned SHA (2026-09-16)                                                                                                                                                                                                                                                                                                                                                                              |
| **Authors / Maintainers** | Dan Gohman (sunfishcode), Bytecode Alliance                                                                                                                                                                                                                                                                                                                                                                                      |
| **Language**              | Rust (`no_std`-capable; `alloc` feature gates `Dir`)                                                                                                                                                                                                                                                                                                                                                                             |
| **License**               | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT                                                                                                                                                                                                                                                                                                                                                                              |
| **Repository**            | [`bytecodealliance/rustix`][rustix-tree] at `287214b8`                                                                                                                                                                                                                                                                                                                                                                           |
| **Platforms**             | Linux (`linux_raw` backend, no libc), every libc Unix, WASI, Redox; Windows only for `net`                                                                                                                                                                                                                                                                                                                                       |
| **Primitive**             | `openat`/`openat2(dirfd, path, open_how)` returning `OwnedFd`; `Dir` over `getdents64` or `fdopendir`                                                                                                                                                                                                                                                                                                                            |
| **Source read**           | [`src/fs/at.rs`][at-rs], [`src/fs/openat2.rs`][openat2-rs], [`src/fs/dir.rs`][dir-rs], [`src/fs/raw_dir.rs`][raw-dir], [`src/fs/special.rs`][special-rs], [`src/backend/linux_raw/fs/dir.rs`][lr-dir], [`src/backend/libc/fs/dir.rs`][libc-dir], [`…/linux_raw/fs/syscalls.rs`][lr-sys], [`…/libc/fs/syscalls.rs`][libc-sys], [`…/libc/fs/types.rs`][libc-types], [`…/linux_raw/fs/types.rs`][lr-types], issue [#100][issue-100] |

## Overview

### What it solves

Making raw syscalls usable from safe Rust without changing what they do. The
[README][readme]:

> `rustix` provides efficient memory-safe and I/O-safe wrappers to POSIX-like,
> Unix-like, Linux, and Winsock syscall-like APIs, with configurable backends.
> It uses Rust references, slices, and return values instead of raw pointers,
> and I/O safety types instead of raw file descriptors, providing memory
> safety, I/O safety, and provenance.

The same paragraph sends policy elsewhere: "for higher-level and more portable
APIs built on this functionality, see the `cap-std`, `memfd`, `timerfd`, and
`io-streams` crates". For this catalog that sentence is the finding: rustix
**provides every primitive** a safe traverser needs and **decides nothing**
about symlinks, `..`, mounts or deletion order.

### Design philosophy

One transformation per API, enumerated in [`src/lib.rs`][lib-rs]:

> File descriptors are passed and returned via `AsFd` and `OwnedFd` instead of
> bare integers, ensuring I/O safety.

plus de-multiplexing (`fcntl`, `ioctl`), non-variadic `openat`, `bitflags`
instead of bare integers, and `Result` instead of `errno`. The `*at` module's
own framing is equally terse ([`at.rs`][at-rs]): "The `dirfd` argument to
these functions may be a file descriptor for a directory, the special value
`CWD`, or the special value `ABS`."

## How it works

### The `*at` surface

[`at.rs`][at-rs] is a flat list of `pub fn` wrappers, each `#[inline]`, each
taking `dirfd: Fd where Fd: AsFd` and `path: P where P: path::Arg`:
`openat`, `readlinkat` (+ `readlinkat_raw`), `mkdirat`, `linkat`, `unlinkat`,
`renameat`, `renameat_with` (= `renameat2`, Linux/Apple/Redox), `symlinkat`,
`statat`, `accessat`, `utimensat`, `chmodat`, `fclonefileat` (Apple),
`mknodat`, `mkfifoat`, `chownat`. `path::Arg::into_with_c_str` converts any
string type to a `CStr` (stack-buffered up to `SMALL_PATH_BUFFER_SIZE`) and
the backend does the call:

```rust
pub fn openat<P: path::Arg, Fd: AsFd>(
    dirfd: Fd, path: P, oflags: OFlags, create_mode: Mode,
) -> io::Result<OwnedFd> {
    path.into_with_c_str(|path| {
        backend::fs::syscalls::openat(dirfd.as_fd(), path, oflags, create_mode)
    })
}
```

Two special `dirfd` values live in [`special.rs`][special-rs]: `CWD`
(`AT_FDCWD`, a `BorrowedFd<'static>`) and `ABS`, "a file descriptor which
refers to no directory, which can be used as the directory argument in `*at`
functions such as `openat`, which causes them to fail with `BADF` if the
accompanying path is not absolute" — the `-EBADF` convention the comment
attributes to lxc. `ABS` is the closest rustix comes to a policy knob: a
caller can _forbid_ relative resolution, but not restrict it.

### `openat2`

[`openat2.rs`][openat2-rs] is 24 lines:
`openat2(dirfd, path, oflags, mode, resolve: ResolveFlags) -> io::Result<OwnedFd>`.
`ResolveFlags` carries the
six kernel bits — `NO_XDEV`, `NO_MAGICLINKS`, `NO_SYMLINKS`, `BENEATH`,
`IN_ROOT`, `CACHED` ("since Linux 5.12") — plus `const _ = !0` so unknown
future bits pass through ([`lr-types`][lr-types], [`libc-types`][libc-types]).
Both backends build the `open_how` struct themselves and issue syscall 437
directly — the libc backend declares `fn openat2(...) via SYS_OPENAT2` with
`const SYS_OPENAT2 = 437` hard-coded ([`libc-sys`][libc-sys]) because no libc
exposes a wrapper; the `linux_raw` backend adds one detail worth copying
([`lr-sys`][lr-sys]):

```rust
// Enable support for large files, but not with `O_PATH` because
// `openat2` doesn't like those flags together.
if !flags.contains(OFlags::PATH) {
    flags |= OFlags::from_bits_retain(c::O_LARGEFILE);
}
```

`openat2` is stricter than `openat` about unknown/contradictory flags, so the
`O_LARGEFILE` the libc `openat` silently adds becomes an `EINVAL` here.

Outside Linux the same idea appears as target-gated flag constants:
`AtFlags::RESOLVE_BENEATH` (`AT_RESOLVE_BENEATH`) and
`OFlags::RESOLVE_BENEATH` (`O_RESOLVE_BENEATH`) on FreeBSD, `OFlags::NOFOLLOW_ANY`
(`O_NOFOLLOW_ANY`) on Apple, `OFlags::SYMLINK` on Apple/Redox
([`libc-types`][libc-types]). Nothing unifies them; a portable "beneath"
open is left to [cap-std][cap-std].

### `Dir`: iterating from an fd

[`src/fs/dir.rs`][dir-rs] is a re-export; the two backends differ in kind.

**`linux_raw`** ([`lr-dir`][lr-dir]) holds `fd: OwnedFd`, a `Vec<u8>`, and a
position, and never touches libc: `read()` decodes `linux_dirent64` records
with unaligned loads, `read_more()` calls `getdents` with a buffer that grows
from 32 to 1024 entries ("directories can contain more entries than we can
allocate contiguous memory for, so we'll always need to cap the size"),
`rewind()` and `seek()` are `lseek(SEEK_SET)`. `fd()` — `#[doc(alias =
"dirfd")]` — returns `BorrowedFd<'a>` borrowed from `&'a self`.

**libc** ([`libc-dir`][libc-dir]) holds `NonNull<c::DIR>` from `fdopendir`
and calls `readdir64`/`rewinddir`/`seekdir`/`closedir`. Two constructors
exist on both backends and they answer the `dup` question the same way:

```rust
/// Take ownership of `fd` and construct a `Dir` that reads entries from
/// the given directory file descriptor.
pub fn new<Fd: Into<OwnedFd>>(fd: Fd) -> io::Result<Self>

/// Borrow `fd` and construct a `Dir` that reads entries from the given
/// directory file descriptor.
pub fn read_from<Fd: AsFd>(fd: Fd) -> io::Result<Self>
```

`new` consumes the `OwnedFd` — after `fdopendir` "the file descriptor is
under the control of the system", so ownership must move. `read_from` does
not `dup`; it re-opens:

> Given an arbitrary `OwnedFd`, it's impossible to know whether the user
> holds a `dup`'d copy which could continue to modify the file description
> state, which would cause Undefined Behavior after our call to `fdopendir`.
> To prevent this, we obtain an independent `OwnedFd`.

i.e. `openat(fd, ".", fcntl_getfl(fd) | CLOEXEC)`. A `dup` shares the open
file description (and its offset, which `readdir` advances); `openat(".")`
creates a fresh one. If `.` no longer exists (`ENOENT`, directory removed) the
libc backend falls back to `dup` and marks `any_errors` so the iterator
yields nothing. This is the exact question the Rust `std` `Dir` issue reached
in 2026-09 ([rust-std][rust-std]); rustix answered it in code years earlier.

**`RawDir`** ([`raw-dir`][raw-dir]) is the allocation-free variant on both
backends: `RawDir<'buf, Fd: AsFd>` over a caller-supplied
`&mut [MaybeUninit<u8>]`, refilled by `getdents64` (the libc backend also declares
it `via SYS_getdents64`, [`libc-sys`][libc-sys]); entries borrow from the
buffer, so `next()` cannot be `Iterator::next` "until GAT support" lands.
A `compile_fail` doctest pins that an entry cannot outlive the buffer.

### I/O safety

rustix predates and helped motivate RFC 3128; it links the RFC from
[`lib.rs`][lib-rs] and the [README][readme]. What the model buys a
traverser: a `Dir::fd()` is a `BorrowedFd<'a>` tied to the `Dir`'s lifetime,
an `openat(dirfd, …)` takes `impl AsFd` so a caller cannot pass an integer
that some other code may have closed and the kernel reused, and every
constructor that assumes exclusive control (`Dir::new`) takes `OwnedFd` by
value. The `_read_from` comment above is I/O safety reasoning applied to
`fdopendir`: the type system proves nobody else _closes_ the fd, but cannot
prove nobody holds a `dup`, hence the re-open. Issue [#100][issue-100] shows
the model's edge: `std::process::Command` lets non-`CLOEXEC` descriptors
leak into a child, which "has the shape of an I/O safety violation", and in
2025-01-27 sunfishcode closed it — "I'm not currently pursuing setting
`CLOEXEC` automatically … I don't think there's anything we can do about this
issue, given the current state of platform APIs". `Dir::_read_from` therefore
adds `OFlags::CLOEXEC` itself; `openat` does not.

## Dimensions

### Dimension 1 — Threat model

Does not apply, because rustix has none of its own: it neither follows nor
refuses symlinks, and its documentation describes each function by the
syscall it wraps. The one adversary it does model is _in-process_: code that
closes or `dup`s an fd another component relies on (I/O safety, and the
`_read_from` re-open). Cross-process races are the caller's problem, with
`openat2`'s `ResolveFlags` as the tool.

### Dimension 2 — Resolution primitive

Provides, does not decide: `openat` (per-component kernel walk, no
restrictions), `openat2` (kernel walk under `ResolveFlags`, atomic with
respect to the whole path — the only whole-path atomic primitive in the
catalog that a caller can reach from safe code), and the rest of the `*at`
family for stat/unlink/rename/mkdir relative to a dirfd. The `ABS` sentinel
lets a caller assert a path is absolute at the syscall.

### Dimension 3 — Symlink and `..` policy

Provides the flags, decides nothing: `OFlags::NOFOLLOW`,
`AtFlags::SYMLINK_NOFOLLOW`, `ResolveFlags::NO_SYMLINKS`/`BENEATH`/`IN_ROOT`
on Linux, `AT_RESOLVE_BENEATH`/`O_RESOLVE_BENEATH` on FreeBSD,
`O_NOFOLLOW_ANY` on Apple. `..` is passed to the kernel verbatim; there is no
user-space path normalisation anywhere in `src/fs/`.

### Dimension 4 — Boundaries

`ResolveFlags::NO_XDEV` and `NO_MAGICLINKS` are exposed with the kernel's
semantics and no wrapper. `Dir::statfs`/`statvfs` return the filesystem of
the open fd, which is what an `st_dev`-style check needs. No Windows
filesystem support at all — "the rest of the APIs do not support Windows"
([README][readme]) — so reparse points, ADS and device names do not arise.

### Dimension 5 — Portability and fallback

Compile-time by target and backend. `openat2` exists only under
`linux_kernel`/`linux_raw_dep`; a caller on an older kernel receives
`Errno::NOSYS` from the syscall and must fall back itself — rustix does not
emulate. `RESOLVE_BENEATH` on FreeBSD and `NOFOLLOW_ANY` on Apple are
separate constants on separate types, so a portable caller writes the
`cfg` ladder. `Dir` needs `alloc`; `RawDir` does not. The libc backend
reaches for raw `syscall()` (`SYS_OPENAT2 = 437`, `SYS_getdents64`) exactly
where libc has no wrapper, so the presence of a libc does not lose
`openat2` or fd-based enumeration.

### Dimension 6 — Failure and partiality

Every function returns `io::Result<_>` with `io::Errno`; `io::retry_on_intr`
wraps `getdents` and `lseek` in the `linux_raw` `Dir`. Both `Dir` backends
latch `any_errors` — after one failed `read()` the iterator returns `None`
rather than looping on a broken stream — and the `linux_raw` test
`dir_iterator_handles_io_errors` proves it by `dup2`-ing a _file_ over the
`Dir`'s fd mid-iteration. `read_more` maps `Errno::NOENT` from `getdents`
(directory deleted under the iterator) to end-of-stream. No multi-step
operation exists, so there is no partial state to report.

### Dimension 7 — Enumeration and deletion

Enumeration: `Dir` (fd-owning, `getdents64` or `fdopendir`) and `RawDir`
(borrowed buffer, `getdents64`), both yielding `d_type`, `d_ino`, `d_off`
and the name as `CStr`. Deletion: `unlinkat(dirfd, path, AtFlags::REMOVEDIR)`
per entry. There is no `remove_dir_all`; composing `Dir` + `openat(…,
NOFOLLOW | DIRECTORY)` + `unlinkat` into the shape [rust-std][rust-std] ships
is left to the caller (cap-std does exactly this).

## Strengths

- **Complete primitive coverage**: every `*at` call, `openat2` with all six
  `ResolveFlags`, FreeBSD `RESOLVE_BENEATH`, Apple `NOFOLLOW_ANY`, `getdents64`
  — reachable from safe code, no libc required on Linux.
- **The `fdopendir` ownership problem is solved correctly**: `new` consumes,
  `read_from` re-opens via `openat(".")` instead of `dup`, with the reasoning
  written down.
- **I/O safety throughout**: `BorrowedFd` from `Dir::fd()`, `OwnedFd` from
  every open; a dirfd cannot be closed out from under a borrower.
- **`RawDir`** gives fd-relative enumeration with zero heap allocation and
  borrowed names — the shape a `@nogc` D walker wants.
- **`O_LARGEFILE` ∧ `O_PATH` under `openat2`** is a documented trap, handled.

## Weaknesses

- **No policy, by design** — a caller gets no help choosing between
  `RESOLVE_BENEATH`, `RESOLVE_IN_ROOT`, `NOFOLLOW`, or the user-space walk when
  `openat2` is `ENOSYS`.
- **No cross-platform "beneath"** — FreeBSD's and Linux's flags live on
  different types and Apple has only `NOFOLLOW_ANY`.
- **No Windows filesystem backend**, so the `NtCreateFile`-relative half of
  a portable design must come from elsewhere ([rust-std][rust-std] or
  [cap-std][cap-std]).
- **`openat` does not add `CLOEXEC`** (issue [#100][issue-100], closed
  won't-fix), so a forgotten flag leaks a dirfd into every child process.
- **`Dir` requires `alloc`** and copies each name into a `CString`.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                                | Trade-off                                                                 |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| One wrapper per syscall, semantics unchanged      | A binding must not surprise; policy belongs in `cap-std` and friends                     | Every safety decision is repeated by every consumer                       |
| `OwnedFd`/`BorrowedFd` everywhere (RFC 3128)      | Closing or reusing an fd out from under a holder becomes a type error                    | Cannot express "no other `dup` exists", hence the `openat(".")` re-open   |
| `Dir::read_from` re-opens rather than `dup`s      | `fdopendir` makes the shared file description's other uses undefined                     | One extra syscall; `ENOENT` on a removed directory needs a `dup` fallback |
| `linux_raw` `Dir` on `getdents64`, no libc `DIR*` | No ownership handoff, no `readdir` global state, `seek` on 32-bit works                  | Hand-decoded `linux_dirent64` with unaligned loads                        |
| `openat2` via raw syscall 437 in both backends    | No libc wrapper exists; the `open_how` struct is stable ABI                              | `ENOSYS` is the caller's fallback signal, not rustix's                    |
| `ResolveFlags` carries `const _ = !0`             | Forward-compatible with kernel bits rustix does not know yet                             | No compile-time rejection of a nonsense bit                               |
| `ABS` sentinel (`-EBADF` as `dirfd`)              | Lets a caller _require_ an absolute path at the syscall, matching lxc's convention       | Undocumented kernel convention, relied on as stable                       |
| `CLOEXEC` not added automatically                 | Platforms cannot set it atomically everywhere; changing `openat` semantics is surprising | Descriptor leaks to children remain a caller footgun                      |

## Sources

- [`src/fs/at.rs`][at-rs] — the `*at` surface, `Arg` conversion, `dirfd` contract (`CWD`/`ABS`)
- [`src/fs/openat2.rs`][openat2-rs] — `openat2` signature
- [`src/backend/linux_raw/fs/types.rs`][lr-types], [`src/backend/libc/fs/types.rs`][libc-types] — `ResolveFlags`, `AtFlags::RESOLVE_BENEATH`, `OFlags::RESOLVE_BENEATH`/`NOFOLLOW_ANY`/`SYMLINK`
- [`src/backend/linux_raw/fs/syscalls.rs`][lr-sys], [`src/backend/libc/fs/syscalls.rs`][libc-sys] — `open_how` construction, syscall 437, the `O_LARGEFILE`/`O_PATH` exclusion, `getdents64`
- [`src/backend/linux_raw/fs/dir.rs`][lr-dir] — libc-free `Dir`, buffer policy, `any_errors` latch, the `dup2` test
- [`src/backend/libc/fs/dir.rs`][libc-dir] — `fdopendir` ownership, the `read_from` re-open rationale and `ENOENT` fallback
- [`src/fs/raw_dir.rs`][raw-dir] — `RawDir` allocation-free enumeration
- [`src/fs/special.rs`][special-rs] — `CWD` and `ABS`
- [`src/lib.rs`][lib-rs], [`README.md`][readme] — I/O safety framing and the pointer to `cap-std` for policy
- [Issue #100][issue-100] — `CLOEXEC` and `Command`: the boundary of what I/O safety can guarantee

<!-- References -->

[cap-std]: ./cap-std.md
[rust-std]: ./rust-std.md
[issue-100]: https://github.com/bytecodealliance/rustix/issues/100
[rustix-tree]: https://github.com/bytecodealliance/rustix/tree/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs
[readme]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/README.md
[lib-rs]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/lib.rs
[at-rs]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/at.rs
[openat2-rs]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/openat2.rs
[dir-rs]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/dir.rs
[raw-dir]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/raw_dir.rs
[special-rs]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/special.rs
[lr-dir]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/linux_raw/fs/dir.rs
[libc-dir]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/dir.rs
[lr-sys]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/linux_raw/fs/syscalls.rs
[libc-sys]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/syscalls.rs
[lr-types]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/linux_raw/fs/types.rs
[libc-types]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/types.rs
