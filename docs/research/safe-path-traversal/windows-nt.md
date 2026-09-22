# Windows NT native API

There is no `openat` on Windows, but `NtCreateFile` / `NtOpenFile` with an
`OBJECT_ATTRIBUTES.RootDirectory` handle is one — a name resolved relative to an
open directory — and the flag that makes it traversal-safe, `OBJ_DONT_REPARSE`,
is the whole-path `RESOLVE_NO_SYMLINKS`, not a per-component `O_NOFOLLOW`.

|                 |                                                                                                                                                                                                                                                                           |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | kernel mechanism                                                                                                                                                                                                                                                          |
| **Year**        | `OBJ_DONT_REPARSE` since Windows Vista; POSIX delete/rename (`FILE_DISPOSITION_INFORMATION_EX`, `FileRenameInformationEx`) since Windows 10 1607/1809                                                                                                                     |
| **Maintainers** | Microsoft (NT executive / ntdll)                                                                                                                                                                                                                                          |
| **Language**    | C (native API surfaced through `ntdll.dll`)                                                                                                                                                                                                                               |
| **License**     | proprietary (docs on Microsoft Learn); consumer code MIT/Apache/BSD as noted                                                                                                                                                                                              |
| **Venue**       | [`NtCreateFile`][ntcreatefile], [`OBJECT_ATTRIBUTES`][objattr], [`FILE_DISPOSITION_INFORMATION_EX`][filedisp], [`FILE_RENAME_INFORMATION`][filerename] on Microsoft Learn                                                                                                 |
| **Platforms**   | Windows                                                                                                                                                                                                                                                                   |
| **Primitive**   | `NtCreateFile`/`NtOpenFile` with `OBJECT_ATTRIBUTES{RootDirectory, ObjectName, Attributes}`                                                                                                                                                                               |
| **Source read** | Go [`root_windows.go`][go-root-win] / [`at_windows.go`][go-at-win]; Rust std [`windows.rs`][rust-win] / [`windows/remove_dir_all.rs`][rust-rda] / [`windows/dir.rs`][rust-dir]; cap-std [`windows/fs/`][capstd-createat]; Forshaw [`symboliclink-testing-tools`][forshaw] |

## Overview

### What it solves

A traversal-resistant open on a filesystem whose Win32 layer resolves the whole
string at once. Rust std's `remove_dir_all` was rewritten around this after
[CVE-2022-21658][rust-cve]; its module comment states the requirement directly
([`windows/remove_dir_all.rs`][rust-rda]):

```rust
//! - It must not be possible to trick this into deleting files outside of
//!   the parent directory (see CVE-2022-21658).
//! …
//! The first is handled by using the low-level `NtOpenFile` API to open a file
//! relative to a parent directory.
```

Go's proposal thread names the equivalence outright: "Windows has
`NtCreateFile`, which can act quite a bit like openat" and "Windows provides an
equivalent (`NtCreateFile` with `ObjectAttributes` including a `RootDirectory`)"
([golang/go#67002][go-67002]).

### Design philosophy

The relative-open is the standard `OBJECT_ATTRIBUTES` mechanism, not a
file-specific one: `RootDirectory` "Optionally specifies a handle to the root
object directory … If this value is non-NULL, the ObjectName member specifies a
file name relative to this directory" ([`NtCreateFile`][ntcreatefile]). Because
that handle pins the directory, the parent cannot be renamed out from under the
walk while it is held. The safety flag is a namespace-parse option:
`OBJ_DONT_REPARSE` — "no reparse points will be followed when parsing the name …
If any reparses are encountered the attempt will fail and return a
`STATUS_REPARSE_POINT_ENCOUNTERED` result. This can be used to determine if
there are any reparse points in the object's path, in security scenarios"
([`OBJECT_ATTRIBUTES`][objattr]).

## How it works

Go's `Openat` is the clearest single mapping ([`at_windows.go`][go-at-win]).
The `O_NOFOLLOW_ANY` open flag becomes an object-attribute bit, and the
final-component-only `O_FILE_FLAG_OPEN_REPARSE_POINT` becomes a create-option:

```go
objAttrs := &OBJECT_ATTRIBUTES{}
if flag&O_NOFOLLOW_ANY != 0 {
    objAttrs.Attributes |= OBJ_DONT_REPARSE
}
…
if fileFlags&O_FILE_FLAG_POSIX_SEMANTICS == 0 {
    objAttrs.Attributes |= OBJ_CASE_INSENSITIVE
}
```

and the mapping the survey depends on ([`at_windows.go`][go-at-win]):

```go
case STATUS_REPARSE_POINT_ENCOUNTERED:
    return syscall.ELOOP
```

The POSIX-primitive → NT mapping used across all three consumers:

| POSIX primitive                          | NT equivalent                                                                  | Caveat                                                                                                     |
| ---------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `openat`                                 | `NtCreateFile` with `OBJECT_ATTRIBUTES.RootDirectory`                          | absolute `ObjectName` requires `RootDirectory == NULL`; NT path syntax, not Win32                          |
| `O_NOFOLLOW` (leaf)                      | `FILE_OPEN_REPARSE_POINT` create-option                                        | opens the link itself; final component only                                                                |
| `O_NOFOLLOW_ANY` / `RESOLVE_NO_SYMLINKS` | `OBJ_DONT_REPARSE` attribute                                                   | whole path; not on Windows < ~Vista → retry without it (cap-std, Rust)                                     |
| `RESOLVE_BENEATH`                        | (none) — `RootDirectory` + reject `..`, or `OBJ_DONT_REPARSE` + lexical        | `..` is resolved lexically by the parser (see [Dimension 3](#dimension-3--symlink-and--policy))            |
| `unlinkat`                               | open + `FILE_DISPOSITION_INFORMATION_EX` (`FileDispositionInformationEx`)      | no `unlinkat` syscall; delete is handle-based                                                              |
| `renameat`                               | open + `FILE_RENAME_INFORMATION{Ex}` with `RootDirectory`                      | rename is handle-based; POSIX semantics need 1607+                                                         |
| `fdopendir`/readdir                      | `NtQueryDirectoryFile` / `GetFileInformationByHandleEx` (`FILE_ID_*_DIR_INFO`) | directory-symlink opened by handle iterates as empty (see [Dim 7](#dimension-7--enumeration-and-deletion)) |
| `st_dev` / `st_ino`                      | `FILE_ID_INFO` (`VolumeSerialNumber` + 128-bit `FileId`) / by-handle info      | `nFileIndex*` from `GetFileInformationByHandle` on older paths                                             |

### Dimension 1 — Threat model

Symlink swap and directory rename during a walk, plus the Windows-only reparse
zoo. The Forshaw `symboliclink-testing-tools` are the attack catalogue this
model is built against ([`README.txt`][forshaw]): `BaitAndSwitch` "uses OPLOCKs
to catch when a process wants to open a file and switches a symbolic link out
from under it" — a TOCTOU win over an NTFS path; `CreateMountPoint` /
`DeleteMountPoint` create and remove junctions ("sometimes known as junctions or
reparse points"); `CreateSymlink` makes object-manager symlinks "without
administrator privileges", reachable as `\RPC Control\name` even from many
sandboxes; `CreateDosDeviceSymlink` maps DOS device names. The tools' own
caveats are threat-model notes: an object-manager symlink "only last[s] until
all referencing handles have been closed", and a junction "can be pointed at a
file … opened as a file as long as the caller specifies
`FILE_FLAG_BACKUP_SEMANTICS`".

### Dimension 2 — Resolution primitive

Two layers, chosen by whether the whole-path bit is available. cap-std's
`CreateFileAtW` builds the `OBJECT_ATTRIBUTES` by hand and hands it to
`NtCreateFile`, with `RootDirectory = dir` set from the parent handle
([`create_file_at_w.rs`][capstd-createat]); Rust std's `nt_create_file` does the
same for its `Dir` type, noting "NtCreateFile will fail if given an absolute
path and a non-null RootDirectory" and so short-circuiting absolute paths to a
normal `File::open` ([`windows/dir.rs`][rust-dir]). The atomicity claim is
per-open: the directory handle is pinned for the life of the call, and with
`OBJ_DONT_REPARSE` the parse either completes without crossing a reparse point
or fails whole. Without it, safety reduces to "open each component by handle and
re-verify", the same per-component shape as Unix.

### Dimension 3 — Symlink and `..` policy

`OBJ_DONT_REPARSE` refuses _any_ reparse point anywhere in the parsed name — a
whole-path `RESOLVE_NO_SYMLINKS`, stricter than `O_NOFOLLOW`. But `..` is a
parser quirk, not a lookup: the Go proposal author found that `NtCreateFile`
"will resolve `..` path components _only_ if a symlink appears somewhere in the
path", so `s/../f` (where `s` is a symlink) opens `a/f` while `a/b/../f` is an
error ([golang/go#67002][go-67002]). Consequently every consumer resolves `..`
lexically before touching the filesystem. Go's `rootCleanPath` prepends `\\?\?\`,
calls `GetFullPathName`, and rejects the result unless it still begins with that
prefix — "We want to detect paths which use .. components to escape the root …
by ensuring the cleaned path still begins with `\\?\?\`" ([`root_windows.go`][go-root-win]).
cap-std pops a `Normal` component for each `ParentDir` in its own component list
because "Windows resolves `..` before doing filesystem lookups"
([`create_file_at_w.rs`][capstd-createat], and the manual walk in
[`fs/manually/open.rs`][capstd-manual]).

### Dimension 4 — Boundaries

The boundary vocabulary is reparse _tags_, not devices. A stat classifies a name
by `FileAttributeTagInfo`: Go reads it via `GetFileInformationByHandleEx`, and
`isReparseTagNameSurrogate` treats a tag as a name surrogate iff
`ReparseTag & 0x20000000 != 0` — "True for `IO_REPARSE_TAG_SYMLINK` and
`IO_REPARSE_TAG_MOUNT_POINT`" ([`types_windows.go`][go-types-win]). Go maps other
tags explicitly: `IO_REPARSE_TAG_AF_UNIX` → socket, `IO_REPARSE_TAG_DEDUP` →
regular (dedup files "remain similar in most respects to regular files"), and
everything else → `ModeIrregular`; an `APPEXECLINK` reparse point "is not a
symlink, so `os.Readlink` should return an error" ([`os_windows_test.go`][go-types-win]).
Forshaw's tag table enumerates the zoo (`IO_REPARSE_TAG_MOUNT_POINT` `0xA0000003`,
`IO_REPARSE_TAG_SYMLINK` `0xA000000C`, HSM, SIS, WIM, DEDUP, NFS,
`FILE_PLACEHOLDER` …) ([`ReparsePoint.cpp`][forshaw-reparse]). Alternate data
streams (`name:stream`), DOS device names (`NUL`, `COM1`), `\??\` per-user
DosDevices, 8.3 short names and per-directory case-insensitivity are all name
tricks the string parser sees but the handle-relative walk does not fully
neutralize — Go's `os.Root` documents that "file names may not reference Windows
reserved device names such as NUL and COM1" as an explicit restriction
([`root.go`][go-root-src]); `BaitAndSwitch`'s notes exploit exactly the 8.3 /
`GetLongPathName` seam ([`README.txt`][forshaw]). There is no `st_dev`-style
mount check; identity is `FILE_ID_INFO` (`VolumeSerialNumber` + 128-bit
`FileId`, class `0x12`) or the by-handle `dwVolumeSerialNumber` + `nFileIndex*`
that cap-std compares in `is_same_file` ([`is_same_file.rs`][capstd-same]).

### Dimension 5 — Portability and fallback

`OBJ_DONT_REPARSE` is not on the oldest supported Windows, so it is probed and
dropped. Rust std stores it in an atomic and retries once on
`INVALID_PARAMETER`: "The `OBJ_DONT_REPARSE` attribute ensures that we haven't
been tricked into following a symlink. However, it may not be available in
earlier versions of Windows … Retry without OBJ_DONT_REPARSE if it's not
supported" ([`windows/remove_dir_all.rs`][rust-rda]). The deeper fallback is the
absence of `unlinkat`/`renameat`: the Go thread records "Note that Windows does
not provide (AFAIK) an `unlinkat` counterpart. It will have to be emulated"
([golang/go#67002][go-67002]), which is why deletion and rename go through a
handle and a `SetInformationFile` class rather than a syscall.

### Dimension 6 — Failure and partiality

Delete has a limbo state the code must special-case. Between marking a file's
disposition and its last handle closing, opens fail with `STATUS_DELETE_PENDING`;
Rust maps it deliberately — "We make a special exception for
`STATUS_DELETE_PENDING` because otherwise this will be mapped to
`ERROR_ACCESS_DENIED`" — and treats both a pending delete and "not found" as
success while walking ([`windows/remove_dir_all.rs`][rust-rda]). It then retries
on `SHARING_VIOLATION` and `DIR_NOT_EMPTY` up to `MAX_RETRIES = 50`, because a
file "isn't actually deleted until the file is closed" and the parent's own
delete may race the children's. Go's `Deleteat` first tries POSIX delete
(`FILE_DISPOSITION_DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE`) and, on
`STATUS_INVALID_INFO_CLASS`/`INVALID_PARAMETER`/`NOT_SUPPORTED` (FAT32, old
Windows), falls back to the classic `FILE_DISPOSITION_INFO`
([`at_windows.go`][go-at-win]). Under POSIX semantics "the link is removed from
the visible namespace as soon as the POSIX delete handle has been closed, but
the file's data streams remain accessible by other existing handles"
([`FILE_DISPOSITION_INFORMATION_EX`][filedisp]).

### Dimension 7 — Enumeration and deletion

Deletion opens by handle with `FILE_OPEN_REPARSE_POINT` so a link is never
entered, sets disposition, and closes to force the delete. Rust's iterative
remover pushes directories onto a stack, opening each child directory relative
to its parent with `open_link_no_reparse` (which OR-s in `OBJ_DONT_REPARSE` and
`FILE_OPEN_REPARSE_POINT`, share mode `DELETE|READ|WRITE`), and lists via
`GetFileInformationByHandleEx` with `FileIdBothDirectoryInfo`
([`windows/remove_dir_all.rs`][rust-rda]). A crucial fact from Rust's `DirBuff`
comment: opening a _directory symlink_ by handle and iterating it "will always
iterate an empty directory regardless of the target", so a reparse-point
directory cannot leak its target's children ([`windows.rs`][rust-win]). Go's
`removeAllFrom` mirrors the Unix loop but on Windows opens the parent
`O_WRONLY|O_RDWR` (mapped to `FILE_READ_ATTRIBUTES`) because "the process might
not have read permission on the parent directory, but still can delete files in
it" ([`removeall_at.go`][go-removeall]). cap-std, lacking a real relative
unlink, drops the directory handle and calls `fs::remove_dir` on the path it
recovered with `GetFinalPathNameByHandleW`, accepting the window: "There is a
window here in which another process could remove or rename a directory with
this path after the handle is dropped … this appears to be unavoidable"
([`remove_open_dir_impl.rs`][capstd-removeopen], [`get_path.rs`][capstd-getpath]).
cap-std also drops `FILE_SHARE_DELETE` when opening directories "to prevent
directories from being deleted or renamed underneath cap-std's sandboxed path
lookups" ([`oflags.rs`][capstd-oflags]).

## Strengths

- **A genuine relative open** via `RootDirectory` that pins the parent for the
  call's duration.
- **`OBJ_DONT_REPARSE` is whole-path**, refusing symlink, junction, AppExecLink
  and cloud-placeholder reparses in one bit, and reports which by failing with
  `STATUS_REPARSE_POINT_ENCOUNTERED`.
- **Handle-based delete/rename with POSIX semantics** (`FileDispositionInformationEx`,
  `FileRenameInformationEx`) — a name vanishes at handle close while open readers
  keep working, matching Unix unlink.
- **Rich per-entry directory info** (`FILE_ID_*_DIR_INFO`) and 128-bit file
  identity (`FILE_ID_INFO`).

## Weaknesses

- **No `openat`, `unlinkat`, or `renameat` syscalls** — every safe op is
  `NtCreateFile`/`NtOpenFile` + `SetInformationFile`, more code and more
  failure paths.
- **`..` is a lexical parser feature**, only triggered by a symlink in the
  path; callers must clean it themselves or risk surprising semantics.
- **`OBJ_DONT_REPARSE` needs a version probe** and a racy per-component fallback
  on old Windows.
- **NT vs Win32 name normalization** (trailing dots/spaces, DOS device names,
  `\??\`, 8.3 short names, `name:stream` ADS, per-directory case-insensitivity)
  is a large residual attack surface the handle walk does not fully close.
- **Delete-pending limbo** forces retry loops (`STATUS_DELETE_PENDING`,
  `SHARING_VIOLATION`, `DIR_NOT_EMPTY`) that can still fail under contention.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                               | Trade-off                                                                     |
| ---------------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `NtCreateFile` + `RootDirectory` as `openat`               | Only native way to open relative to a directory handle  | Undocumented-ish native API; NT path syntax; absolute name forbids a root     |
| `OBJ_DONT_REPARSE` for whole-path no-follow                | One bit refuses the entire reparse zoo, and reports it  | Not on old Windows → atomic probe + fallback to per-component                 |
| Resolve `..` lexically before opening                      | The parser only handles `..` when a symlink is present  | New, non-kernel path semantics the caller owns                                |
| Handle-based POSIX delete (`FileDispositionInformationEx`) | Unlink-while-open; ignore read-only like Unix           | 1607/1809 floor; FAT32 unsupported → classic-disposition fallback             |
| `FILE_OPEN_REPARSE_POINT` on every delete/enumerate open   | Never enter a link; a directory symlink lists empty     | Must classify tags afterward to distinguish symlink vs mount vs AppExecLink   |
| Drop `FILE_SHARE_DELETE` on directory handles (cap-std)    | Stop the sandboxed ancestor chain being renamed/deleted | Removing an opened directory then needs a by-name reopen with a TOCTOU window |

## Sources

- [`NtCreateFile`][ntcreatefile] — `RootDirectory`/`ObjectName` relative-open, `FILE_OPEN_REPARSE_POINT`, share modes, the "never returns STATUS_REPARSE" note
- [`OBJECT_ATTRIBUTES`][objattr] — `OBJ_DONT_REPARSE` = `STATUS_REPARSE_POINT_ENCOUNTERED`, `OBJ_CASE_INSENSITIVE`, `OBJ_INHERIT`
- [`FILE_DISPOSITION_INFORMATION_EX`][filedisp] — POSIX-delete flags and the visible-namespace-vs-data-stream semantics
- [`FILE_RENAME_INFORMATION`][filerename] — `RootDirectory`-relative rename, `FILE_RENAME_POSIX_SEMANTICS`, DELETE-access requirement
- Go [`root_windows.go`][go-root-win], [`at_windows.go`][go-at-win], [`reparse_windows.go`][go-reparse], [`types_windows.go`][go-types-win], [`removeall_at.go`][go-removeall], [`root.go`][go-root-src] — the whole mapping and `..` cleaning
- Rust std [`windows.rs`][rust-win], [`windows/remove_dir_all.rs`][rust-rda], [`windows/dir.rs`][rust-dir], [`pal/windows/c.rs`][rust-c] — CVE-2022-21658 remover, `Dir`, `OBJ_DONT_REPARSE` probe
- cap-std [`create_file_at_w.rs`][capstd-createat], [`open_unchecked.rs`][capstd-open], [`oflags.rs`][capstd-oflags], [`remove_open_dir_impl.rs`][capstd-removeopen], [`get_path.rs`][capstd-getpath], [`is_same_file.rs`][capstd-same], [`fs/manually/open.rs`][capstd-manual]
- Forshaw [`symboliclink-testing-tools`][forshaw] ([`README.txt`][forshaw], [`ReparsePoint.cpp`][forshaw-reparse]) — junction/object-manager/DOS-device symlink and oplock TOCTOU tools
- [golang/go#67002][go-67002], [rust-lang/rust CVE-2022-21658][rust-cve] — proposal discussion and the advisory that motivated the NT remover

> [!NOTE]
> **Unverified.** `NtCreateFile` / `OBJECT_ATTRIBUTES` on Microsoft Learn carry
> no `req.target-min-winverclnt` value, so the exact Windows version that first
> shipped `OBJ_DONT_REPARSE` could not be pinned from the docs (attributed to
> Vista here from consumer comments, not a primary version statement). The
> `FILE_DISPOSITION_INFORMATION_EX` availability floors (1607 for
> `FileDispositionInformationEx`/`POSIX_SEMANTICS`, 1809 for
> `IGNORE_READONLY_ATTRIBUTE`) come from Go's in-code comments
> ([`at_windows.go`][go-at-win]), not the Learn page. The Forshaw tools were
> read as source and READMEs; they were not built or run, and their "works back
> to XP/2000" claims are the authors', unverified here. RedirectionGuard (the
> per-directory reparse-mitigation named in the brief) is not present in any
> surveyed source and is therefore omitted rather than described.

<!-- References -->

[ntcreatefile]: https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile
[objattr]: https://learn.microsoft.com/en-us/windows/win32/api/ntdef/ns-ntdef-_object_attributes
[filedisp]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-_file_disposition_information_ex
[filerename]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
[rust-cve]: https://blog.rust-lang.org/2022/01/20/cve-2022-21658.html
[go-67002]: https://github.com/golang/go/issues/67002
[go-root-win]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_windows.go
[go-at-win]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/syscall/windows/at_windows.go
[go-reparse]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/syscall/windows/reparse_windows.go
[go-types-win]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/types_windows.go
[go-removeall]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/removeall_at.go
[go-root-src]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root.go
[rust-win]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/windows.rs
[rust-rda]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/windows/remove_dir_all.rs
[rust-dir]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/fs/windows/dir.rs
[rust-c]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/windows/c.rs
[capstd-createat]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/create_file_at_w.rs
[capstd-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/open_unchecked.rs
[capstd-oflags]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/oflags.rs
[capstd-removeopen]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/remove_open_dir_impl.rs
[capstd-getpath]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/get_path.rs
[capstd-same]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/windows/fs/is_same_file.rs
[capstd-manual]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/fs/manually/open.rs
[forshaw]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/README.txt
[forshaw-reparse]: https://github.com/googleprojectzero/symboliclink-testing-tools/blob/00c0fe4cefcd2a62c887fe6117abc02bc98bb9fb/CommonUtils/ReparsePoint.cpp
