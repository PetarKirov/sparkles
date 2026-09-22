# filepath-securejoin

The Go library that container runtimes standardised on for "join this
untrusted path under that root" — and the clearest record in the survey of
why a function that returns a _string_ can never be made race-safe, and what
replaced it.

|                           |                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**                  | library                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **Year**                  | 2017 (`0.1.0` 2017-07-19); `pathrs-lite` 2024–2025; `0.7.0` 2025-06-17 (per `CHANGELOG.md`)                                                                                                                                                                                                                                                                                                                                                      |
| **Authors / Maintainers** | Aleksa Sarai (`cyphar`); `join.go` derived from Docker (2014–2015) and the Go authors; SUSE LLC                                                                                                                                                                                                                                                                                                                                                  |
| **Language**              | Go (module `github.com/cyphar/filepath-securejoin`)                                                                                                                                                                                                                                                                                                                                                                                              |
| **License**               | `BSD-3-Clause AND MPL-2.0` (legacy API BSD; `pathrs-lite` MPL-2.0)                                                                                                                                                                                                                                                                                                                                                                               |
| **Repository**            | [`cyphar/filepath-securejoin`][repo] at `9e667caf`                                                                                                                                                                                                                                                                                                                                                                                               |
| **Platforms**             | `SecureJoin`: portable (incl. Windows volume handling); `pathrs-lite`: Linux only                                                                                                                                                                                                                                                                                                                                                                |
| **Primitive**             | legacy: lexical walk with `Lstat`/`Readlink`; modern: `openat2(RESOLVE_IN_ROOT)` with an `O_PATH` + `/proc/self/fd` emulated fallback, ported from [libpathrs][libpathrs]                                                                                                                                                                                                                                                                        |
| **Source read**           | `README.md`, `doc.go`, `join.go`, `vfs.go`, `CHANGELOG.md`, `pathrs-lite/{README.md,open.go,mkdir.go,open_purego.go,open_libpathrs.go}`, `pathrs-lite/internal/gopathrs/{lookup_linux,mkdir_linux,openat2_linux,open_linux}.go`, `pathrs-lite/internal/procfs/{procfs_linux,procfs_lookup_linux}.go`, `pathrs-lite/internal/fd/{openat2_linux,at_linux,fd_linux}.go`, `pathrs-lite/internal/linux/openat2_linux.go`, `internal/consts/consts.go` |

## Overview

### What it solves

Docker, runc, umoci and Kubernetes needed a `filepath.Join` that treats the
root as a chroot: symlinks inside the tree must resolve _relative to the
root_, and `..` must never climb above it. `SecureJoin` was written for that
and proposed for the standard library (go#20126, rejected). The
[`README.md`][readme] is unusually blunt about its own first API:

> The implementation was based on code that existed in several container
> runtimes. Unfortunately, this API is **fundamentally unsafe** against
> attackers that can modify path components after `SecureJoin` returns and
> before the caller uses the path, allowing for some fairly trivial TOCTOU
> attacks.

### Design philosophy

The modern half of the library is explicitly transitional. [`doc.go`][doc]:

> The new API is available in the `pathrs-lite` subpackage, and provide
> protections against racing attackers as well as several other key
> protections against attacks often seen by container runtimes. As the name
> suggests, `pathrs-lite` is a stripped down (pure Go) reimplementation of
> `libpathrs`. The main APIs provided are `OpenInRoot`, `MkdirAll`, and
> `procfs.Handle` — other APIs are not planned to be ported. The long-term
> goal is for users to migrate to `libpathrs` which is more fully-featured.

And on the standard library's later answer: "`os.Root` was added to the Go
stdlib that shares some of the goals of filepath-securejoin. However, its
design is intended to work like `openat2(RESOLVE_BENEATH)` which does not
fit the usecase of container runtimes and most system tools."

## How it works

### The legacy API: `SecureJoin`

[`join.go`][join] is a lexical walk over path components with a VFS
interface (`Lstat`, `Readlink`) for mocking ([`vfs.go`][vfs]):

```go
for remainingPath != "" {
    // ... pop `part` ...
    nextPath := filepath.Join(string(filepath.Separator), currentPath, part)
    fullPath := root + string(filepath.Separator) + nextPath
    fi, err := vfs.Lstat(fullPath)
    // Treat non-existent path components the same as non-symlinks (we
    // can't do any better here).
    if IsNotExist(err) || fi.Mode()&os.ModeSymlink == 0 {
        currentPath = nextPath
        continue
    }
    // ... readlink, prepend target to remainingPath ...
    if filepath.IsAbs(dest) { currentPath = "" }
}
return filepath.Join(root, filepath.Join(string(filepath.Separator), currentPath)), nil
```

`..` is neutralised by `filepath.Join("/", currentPath, part)` (it cannot
climb above `/`); symlink loops stop at `consts.MaxSymlinkLimit = 255`
([`consts.go`][consts]); a root containing `..` is refused (0.4.1). The
guarantee is precise and precisely useless against a racer — the doc
comment on `SecureJoinVFS`: "the guarantees provided by this function only
apply if the path components in the returned string are not modified (in
other words are not replaced with symlinks on the filesystem) after this
function has returned … There is no way to solve this problem with
`SecureJoinVFS` because the API is fundamentally wrong (you cannot return a
'safe' path string and guarantee it won't be modified afterwards)."

### The modern API: `pathrs-lite`

Five functions ([`open.go`][open], [`mkdir.go`][mkdir], [`open_purego.go`][open-purego]):

| Function                                  | Does                                                                                            |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `OpenInRoot(root, unsafePath)`            | opens `root` as `O_PATH \| O_DIRECTORY`, calls `OpenatInRoot`                                   |
| `OpenatInRoot(root *os.File, unsafePath)` | `completeLookupInRoot` → an `O_PATH` `*os.File` inside the root                                 |
| `Reopen(handle, flags)`                   | `procfs.ReopenFd`: `openat(/proc/thread-self/fd, "<n>", flags)` with overmount checks           |
| `MkdirAll(root, unsafePath, mode)`        | wrapper around `MkdirAllHandle`                                                                 |
| `MkdirAllHandle(root, unsafePath, mode)`  | `PartialLookupInRoot` + per-component `mkdirat` + re-open, returning the final directory handle |

Two build-tag backends implement the same surface: `open_purego.go` /
`mkdir_purego.go` (`linux && !libpathrs`) call the in-tree `gopathrs`
package; `open_libpathrs.go` / `mkdir_libpathrs.go` (`libpathrs`) call
`cyphar.com/go-pathrs` (`pathrs.RootFromFile(root).Resolve(path)`,
`pathrs.HandleFromFile(file).OpenFile(flags)`). The
[`pathrs-lite/README.md`][lite-readme]: "At build time, if you use the
`libpathrs` build tag then `pathrs-lite` will use `libpathrs` directly
instead of the pure Go implementation. The two backends are functionally
equivalent (and we have integration tests to verify this)."

`lookupInRoot` ([`lookup_linux.go`][lookup]) is the Go transcription of
libpathrs's `do_resolve` — same `symlinkStack`, same `..`-only check, same
`readlinkat(fd, "")`:

```go
// If we are operating on a .., make sure we haven't escaped.
// We only have to check for ".." here because walking down
// into a regular component component cannot cause you to
// escape. This mirrors the logic in RESOLVE_IN_ROOT, except we
// have to check every ".." rather than only checking after a
// rename or mount on the system.
if part == ".." {
    // Make sure the root hasn't moved.
    if err := procfs.CheckProcSelfFdPath(logicalRootPath, root); err != nil { ... }
    // Make sure the path is what we expect.
    fullPath := logicalRootPath + nextPath
    if err := procfs.CheckProcSelfFdPath(fullPath, currentDir); err != nil { ... }
}
```

One detail libpathrs does not have: `CheckProcSelfFdPath` first calls
`fd.IsDeadInode` (`st_nlink == 0`), because "there is an attacker deleting
directories during our walk, which could result in weird `/proc` values"
([`fd_linux.go`][fd-linux]); `MkdirAllHandle` runs the same check on the
deepest existing directory before creating anything.

### The `openat2` path and the downgrade rule

[`openat2_linux.go`][gopathrs-openat2] issues `openat2(root, path,
O_PATH | O_CLOEXEC, RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)` and, because the
`*os.File` name would otherwise be the unresolved input, rewrites it from
`ProcSelfFdReadlink`. The fallback decision in `lookupInRoot` is worth
quoting because it is the reverse of what one might expect:

> NOTE: If `openat2(2)` works normally but fails for this lookup, it is
> probably not a good idea to fall-back to the `O_PATH` resolver. An attacker
> could find a bug in the `O_PATH` resolver and unconditionally falling back
> to the `O_PATH` resolver would form a downgrade attack.

So `if handle, remainingPath, err := lookupOpenat2(...); err == nil ||
linux.HasOpenat2() { return ... }` — an `openat2` error is final unless the
probe in [`linux/openat2_linux.go`][linux-openat2] (a trivial
`openat2(AT_FDCWD, ".")`, with a one-way `sawOpenat2Error` flag) says the
syscall is unavailable. The retry wrapper ([`fd/openat2_linux.go`][fd-openat2])
retries `EAGAIN` **and** `EXDEV` for `RESOLVE_IN_ROOT`/`RESOLVE_BENEATH`
lookups, 128 times.

### Dimension 1 — Threat model

Same adversary as [libpathrs][libpathrs]: an unprivileged user or container
root who can rename/symlink inside the root and race the caller, plus (for
the procfs helpers) one who can shape the process's mount table. The
[`README.md`][readme] names the two protections the new API adds over
`SecureJoin`: `openat2` "to restrict lookups through magic-links and
bind-mounts (for certain operations)" and "hardening against a malicious
`/proc` mount to either detect or avoid being tricked by a `/proc` that is
not legitimate".

The CVEs the tree itself cites are: CVE-2019-19921 (the motivation given for
`Reopen`'s hardening — "in container runtimes it is possible for
higher-level runtimes to be tricked into configuring an unsafe `/proc`",
[`open_purego.go`][open-purego]); CVE-2024-21626 (the reason
`OpenUnsafeProcRoot` handles are dangerous to leak,
[`procfs_purego.go`][procfs-purego]); and GHSA-6xv5-86q9-7xr8, the one
vulnerability in this library itself — [`CHANGELOG.md`][changelog] 0.2.4
(2023-09-06): "a potential security issue in filepath-securejoin when used
on Windows … which could be used to generate paths outside of the provided
rootfs in certain cases", fixed by stripping volume names from every
component and every symlink target.

### Dimension 2 — Resolution primitive

| API            | Primitive                                                                                                             | Atomicity                                                                                                               |
| -------------- | --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `SecureJoin`   | `Lstat` + `Readlink` per component, purely lexical assembly                                                           | none — result is a string; non-existent components are treated as directories                                           |
| `OpenatInRoot` | `openat2(RESOLVE_IN_ROOT \| RESOLVE_NO_MAGICLINKS)`, else `openat(O_PATH \| O_NOFOLLOW)` walk + `/proc/self/fd` check | whole-path in-kernel, or per-component with post-hoc verification (as in libpathrs)                                     |
| `Reopen`       | `openat(procfs fd-dir, "<n>", flags)` with mount-ID equality on the magic link                                        | by fd identity; the overmount check is racy against a mount-capable attacker unless `/proc` is a private `fsopen` mount |

### Dimension 3 — Symlink and `..` policy

`SecureJoin` follows every symlink (re-rooting absolute ones) and treats a
dangling one as a directory. `pathrs-lite` follows and re-roots, but a
dangling or non-existent component is an error — the README stresses this
as the behavioural break: "Unlike `SecureJoin`, `OpenInRoot` will error out
as soon as it hits a dangling symlink or non-existent path … These
behaviours are at odds with how Linux treats non-existent paths and
dangling symlinks." `..` is resolved (lexically against `currentPath`, with
the `/proc` re-check) in lookups, and refused with `ENOENT` among the
yet-to-be-created components of `MkdirAllHandle`
([`mkdir_linux.go`][mkdir-linux]). The procfs resolver refuses `..`
outright — "it requires either `os.Root`-style replays, which is more
bug-prone; or procfs verification, which is not possible due to re-entrancy
issues" ([`procfs_lookup_linux.go`][procfs-lookup]).

### Dimension 4 — Boundaries

- **Mounts.** Root lookups do not set `RESOLVE_NO_XDEV`. `MkdirAllHandle`'s
  per-component re-open does use `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS |
RESOLVE_NO_XDEV` when `openat2` exists. The procfs resolver is
  mount-strict: `openat2(RESOLVE_BENEATH | RESOLVE_NO_XDEV |
RESOLVE_NO_MAGICLINKS)`, or per-component `Fstatfs == PROC_SUPER_MAGIC` +
  `statx` mount-ID equality with the root ([`procfs_lookup_linux.go`][procfs-lookup]).
- **Magic links.** `RESOLVE_NO_MAGICLINKS` in the kernel path; in the
  fallback the procfs resolver rejects absolute symlinks ("all absolute
  symlinks in procfs are magic-links"), while the general resolver has **no
  magic-link filesystem check** — unlike libpathrs's `DANGEROUS_FILESYSTEMS`
  list. Opening a magic link on purpose is unsupported: "you cannot open any
  `procfs` symlinks (most notably magic-links) using this API"
  ([`CHANGELOG.md`][changelog] 0.5.0).
- **`/proc` provenance.** `OpenProcRoot` tries `fsopen("proc")` with
  `subset=pid,hidepid=ptraceable`, then `open_tree(OPEN_TREE_CLONE)`, then
  `| AT_RECURSIVE`, then `open("/proc")`; each is verified as a procfs root
  (`f_type`, `st_ino == 1`). Only `subset=pid` handles are cached
  ([`procfs_linux.go`][procfs-linux]).
- **Windows.** Only `SecureJoin` runs there; it strips volume names
  (`C:` / `D:`) from input and from every symlink target so a link to
  another drive cannot escape. No reparse-tag, ADS or device-name handling.

### Dimension 5 — Portability and fallback

`pathrs-lite` is `//go:build linux`. Without `openat2` the `O_PATH` walk is
used; without `statx(STATX_MNT_ID)`, `GetMountID` returns `0` and the
overmount check degrades to "is it procfs at all"; without the new mount
API, `/proc` is the host's. The 0.5.0 changelog rates the result honestly:
"On older kernel versions, there is no effective protection (there is some
minimal protection against non-`procfs` filesystem components but a
sufficiently clever attacker can work around those)." The `libpathrs` build
tag is the escape hatch: distributors can swap the whole implementation
without touching call sites.

### Dimension 6 — Failure and partiality

Errors are wrapped `*os.PathError`s with sentinel bases
(`ErrPossibleBreakout`, `ErrDeletedInode`, `ErrInvalidDirectory`,
`errUnsafeProcfs`), and since 0.5.1 a genuine `unix.EAGAIN` after 128
retries "can be detected by callers" for their own deadline loop. Partial
lookups (`PartialLookupInRoot`) return `(deepest handle, remaining, err)`;
the `openat2` variant walks `unsafePath[:endIdx]` prefixes backwards on
`ENOENT`/`ENOTDIR` and returns any other error unchanged. `MkdirAllHandle`
tolerates `EEXIST` (0.3.5, runc#4543), leaves created prefixes on error,
and — after 0.3.3 removed the owner/mode/emptiness checks — does not verify
the directories it opens: "We used to try to verify this but it just lead to
a series of spurious errors" ([`mkdir_linux.go`][mkdir-linux]).

### Dimension 7 — Enumeration and deletion

Does not apply: `pathrs-lite` ports `OpenInRoot`, `MkdirAll` and the procfs
helpers only; there is no `RemoveAll` and "other APIs are not planned to be
ported" ([`doc.go`][doc]). Callers needing deletion are pointed at
[libpathrs][libpathrs]'s `Root::remove_all` or, since Go 1.21.11 / 1.22.4,
the race-fixed `os.RemoveAll`.

## Strengths

- **A documented before/after.** The same author, the same threat model,
  the string API and its fd replacement side by side in one tree.
- **Downgrade-attack awareness**: an `openat2` failure never silently
  becomes an `O_PATH` walk.
- **Drop-in migration to libpathrs** through a build tag, verified by
  integration tests.
- **`IsDeadInode` checks** catch an attacker deleting directories under
  the walk earlier than libpathrs does.
- Pure Go, no cgo, Go ≥ 1.18 — the reason Kubernetes and runc could adopt it.

## Weaknesses

- **`SecureJoin` is still exported** and still what most dependants call;
  the library can only document that it is unsafe.
- **Narrower than libpathrs**: no `RemoveAll`, no `Rename`, no `Create`, no
  magic-link opens, no emulated `fs.protected_symlinks`, no magic-link
  filesystem list in the general resolver.
- **Two implementations to keep in sync** (pure Go and the libpathrs
  binding), plus a third partial copy of the resolver for procfs.
- **Weak below Linux 5.8** by its own assessment.
- Go's runtime forces `runtime.LockOSThread` bookkeeping for
  `/proc/thread-self` handles (`ProcThreadSelfCloser`).

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                         | Trade-off                                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Keep `SecureJoin` but mark it unsafe                            | Thousands of dependants; breaking them helps nobody                                               | The unsafe function remains the most-used export                              |
| Port only `OpenInRoot`/`MkdirAll`/procfs                        | "transition tool"; libpathrs is the destination                                                   | No deletion, rename or create primitives in the Go tree                       |
| Error instead of falling back when `openat2` fails for a lookup | A bug in the emulated resolver must not be reachable by inducing `openat2` errors                 | A transient `openat2` error (after retries) is an error, not a slower success |
| Return `O_PATH` and require `Reopen`                            | "to provide useful features like PTY spawning and to avoid users accidentally opening bad inodes" | Every real open costs a `/proc` round-trip and a trusted procfs handle        |
| Refuse `..` and absolute symlinks in the procfs resolver        | Cannot use `/proc` to verify `/proc` (re-entrancy)                                                | Procfs subpaths must be programmer-controlled                                 |
| Reject dangling symlinks / missing components in the new API    | Match Linux semantics; `SecureJoin`'s "treat as directory" was the source of confusion            | Behavioural break for callers that relied on partial resolution               |
| `libpathrs` build tag                                           | Distributors opt the whole binary into the C library without changing dependants                  | Two backends must stay behaviourally identical                                |

## Sources

- [`README.md`][readme] — "fundamentally unsafe", the new-API contract, dangling-symlink notes
- [`doc.go`][doc] — legacy vs modern API, relationship to libpathrs and `os.Root`
- [`join.go`][join] / [`vfs.go`][vfs] — `SecureJoinVFS`, the VFS mock interface
- [`pathrs-lite/README.md`][lite-readme] — the `libpathrs` build tag
- [`pathrs-lite/open.go`][open], [`mkdir.go`][mkdir], [`open_purego.go`][open-purego], [`open_libpathrs.go`][open-libpathrs] — the public surface and its two backends
- [`gopathrs/lookup_linux.go`][lookup] — `lookupInRoot`, `symlinkStack`, the downgrade rule
- [`gopathrs/openat2_linux.go`][gopathrs-openat2] — `openat2` lookup and prefix-walk partial lookup
- [`gopathrs/mkdir_linux.go`][mkdir-linux] — `MkdirAllHandle`
- [`procfs/procfs_linux.go`][procfs-linux] — `Handle`, `fsopen`/`open_tree` order, `ReopenFd`, `CheckProcSelfFdPath`
- [`procfs/procfs_lookup_linux.go`][procfs-lookup] — the restricted procfs resolver
- [`fd/openat2_linux.go`][fd-openat2], [`fd/at_linux.go`][fd-at], [`fd/fd_linux.go`][fd-linux] — retry loop, `GetMountID`, `IsDeadInode`
- [`linux/openat2_linux.go`][linux-openat2] — `HasOpenat2` probe
- [`internal/consts/consts.go`][consts] — `MaxSymlinkLimit = 255`
- [`CHANGELOG.md`][changelog] — 0.1.0 (2017) → 0.7.0; 0.2.4 Windows advisory; 0.3.0 new API; 0.5.0 `pathrs-lite` split; 0.5.1 `EAGAIN`; 0.6.0 `libpathrs` tag
- Siblings: [libpathrs][libpathrs], [`linux-openat2`][openat2], [Go `os.Root`][go-root], [procfs magic links][magic-links]

> [!NOTE]
> **Unverified.** The `CHANGELOG.md` at this SHA lists `0.7.0` as
> `2025-06-17`, which precedes the `0.6.1` entry dated `2025-11-19`; the
> date is reproduced as written. The clone's `HEAD` commit is dated
> 2026-06-18. The `pathrs-lite/procfs/procfs_purego.go` public wrapper was
> only grepped for its CVE-2024-21626 comment, not read in full. The runc
> advisories for CVE-2019-5736 and CVE-2024-21626 are **not** named in this
> repository's `README.md` or `CHANGELOG.md` text (CVE-2024-21626 appears
> only as a reference-link definition and in a source comment), so no
> changelog quotation about them is possible.

<!-- References -->

[repo]: https://github.com/cyphar/filepath-securejoin/tree/9e667cafd6b022fac5ae8711ace2204eeec95207
[readme]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/README.md
[doc]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/doc.go
[join]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/join.go
[vfs]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/vfs.go
[changelog]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/CHANGELOG.md
[lite-readme]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/README.md
[open]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/open.go
[mkdir]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/mkdir.go
[open-purego]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/open_purego.go
[open-libpathrs]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/open_libpathrs.go
[lookup]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/gopathrs/lookup_linux.go
[gopathrs-openat2]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/gopathrs/openat2_linux.go
[mkdir-linux]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/gopathrs/mkdir_linux.go
[procfs-linux]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/procfs/procfs_linux.go
[procfs-lookup]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/procfs/procfs_lookup_linux.go
[procfs-purego]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/procfs/procfs_purego.go
[fd-openat2]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/fd/openat2_linux.go
[fd-at]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/fd/at_linux.go
[fd-linux]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/fd/fd_linux.go
[linux-openat2]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/pathrs-lite/internal/linux/openat2_linux.go
[consts]: https://github.com/cyphar/filepath-securejoin/blob/9e667cafd6b022fac5ae8711ace2204eeec95207/internal/consts/consts.go
[libpathrs]: ./libpathrs.md
[openat2]: ./linux-openat2.md
[go-root]: ./go-os-root.md
[magic-links]: ./linux-procfs-magic-links.md
