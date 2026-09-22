# FreeBSD and OpenBSD

Two BSDs, two opposite shapes: FreeBSD puts the restriction on the _lookup_
(`O_RESOLVE_BENEATH`, Capsicum capability mode) and reports `ENOTCAPABLE`;
OpenBSD puts it on the _process_ (`unveil`, `pledge`) and kills it with
`SIGABRT`.

|                           |                                                                                                                                                                                                             |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | kernel mechanism (two operating systems)                                                                                                                                                                    |
| **Year**                  | Capsicum FreeBSD 9.0 (2012); `O_RESOLVE_BENEATH` present in the FreeBSD 13.0 `open(2)`, absent in 12.0; `O_PATH`/`O_EMPTY_PATH` present in 14.0, absent in 13.0; `pledge` OpenBSD 5.9; `unveil` OpenBSD 6.4 |
| **Authors / Maintainers** | Capsicum: Robert Watson, Jonathan Anderson (Cambridge), Ben Laurie, Kris Kennaway (Google), Pawel Jakub Dawidek; OpenBSD project for `pledge`/`unveil`                                                      |
| **Language**              | C                                                                                                                                                                                                           |
| **License**               | BSD-2-Clause (FreeBSD); ISC/BSD (OpenBSD)                                                                                                                                                                   |
| **Venue**                 | [`open(2)`][fbsd-open], [`unlinkat(2)`][fbsd-unlinkat], [`capsicum(4)`][fbsd-capsicum], [`cap_enter(2)`][fbsd-cap-enter]; [`unveil(2)`][obsd-unveil], [`pledge(2)`][obsd-pledge]                            |
| **Platforms**             | FreeBSD 13+ (`*_RESOLVE_BENEATH`), 14+ (`O_PATH`); OpenBSD 5.9+/6.4+                                                                                                                                        |
| **Primitive**             | FreeBSD: per-call `O_RESOLVE_BENEATH` / `AT_RESOLVE_BENEATH` and process-wide `cap_enter`; OpenBSD: process-wide path allow-list plus syscall promises                                                      |
| **Source read**           | The man pages above (current, plus the 12.0 / 13.0 / 14.0 `manpath` variants of `open(2)`); cap-std [`freebsd/fs/`][capstd-fbsd-dir]; rustix [`libc/fs/types.rs`][rustix-types]                             |

## Overview

### What it solves

FreeBSD's flag is Linux's `RESOLVE_BENEATH` with one sentence more
([`open(2)`][fbsd-open]):

> `O_RESOLVE_BENEATH` returns `ENOTCAPABLE` if any intermediate component of
> the specified relative path does not reside in the directory hierarchy
> beneath the starting directory. Absolute paths or even the temporal escape
> from beneath of the starting directory is not allowed.

"Temporal escape" is the `..`-then-back-down case; Linux allows it under
`RESOLVE_BENEATH` and FreeBSD does not. The flag is the _opt-in_ form of what
[`capsicum(4)`][fbsd-capsicum] capability mode imposes on every `*at` call: a
"process mode, entered by invoking `cap_enter(2)`, in which access to global
OS namespaces (such as the file system and PID namespaces) is restricted",
where "the `openat(2)` family of system calls are constrained so that they can
only operate on objects under the provided file descriptor."

OpenBSD's `unveil(2)` is not a lookup restriction at all ([`unveil(2)`][obsd-unveil]):

> The first call to `unveil()` removes visibility of the entire filesystem
> from all other filesystem-related system calls (such as `open(2)`,
> `chmod(2)` and `rename(2)`), except for the specified path and permissions.

### Design philosophy

Capsicum is the origin of `O_BENEATH`: the v16 `openat2` posting says its
`RESOLVE_BENEATH` semantics "follow FreeBSD's `O_BENEATH`" and credits David
Drysdale's Capsicum-derived 2014 proposal ([LWN 804980][lwn-804980]) —
FreeBSD is where the idea that a directory fd is a _capability_ whose
authority a path must not exceed was first shipped as an OS-wide mode:
"only explicitly delegated rights, referenced by memory mappings or file
descriptors, may be used" ([`capsicum(4)`][fbsd-capsicum]). `cap_enter` is
irreversible and inherited: "Future process descendants created with
`fork(2)` or `pdfork(2)` will be placed in capability mode from inception"
([`cap_enter(2)`][fbsd-cap-enter]).

OpenBSD's philosophy is enforcement by termination. `pledge(2)` promises name
subsystems (`rpath`: "path traversal, reading struct stat, and opening files
for read"; `wpath`, `cpath`, `dpath` widen it), and "most attempts to use
operations in that subsystem result in the process being killed with an
uncatchable `SIGABRT`" ([`pledge(2)`][obsd-pledge]). `unveil` narrows
_which paths_ the promised operations may reach, and the two lock together:
"future calls to `unveil()` can be disabled by passing two `NULL` arguments,
or with a `pledge(2)` call which lacks the `unveil` promise"
([`unveil(2)`][obsd-unveil]).

## How it works

### FreeBSD

The `open(2)` capability-mode paragraph has itself tightened between
releases. FreeBSD 12.0: `path` "must not be an absolute path and must not
contain `..` components". Current: "must not contain `..` components which
cause the path resolution to escape the directory hierarchy starting at `fd`.
Additionally, no symbolic link in `path` may target absolute path or contain
escaping `..` components. `fd` must not be `AT_FDCWD`." Violations return
`ENOTCAPABLE`. `AT_RESOLVE_BENEATH` carries the same rule to `unlinkat`,
`fstatat`, `utimensat` and friends: "Only walk paths below the directory
specified by the `fd` descriptor" ([`unlinkat(2)`][fbsd-unlinkat]).

FreeBSD 14 adds the Linux-style path handle — and the re-open Linux still
lacks ([`open(2)`, 14.0][fbsd-open]): `O_PATH` "returns a file descriptor
that can be used as a directory file descriptor for `openat(2)`" whose "other
functionality […] is limited to the descriptor-level operations", and
`O_EMPTY_PATH` (`openat` only) means "A file descriptor created with the
`O_PATH` flag can be opened into normal (operable) file descriptor by
specifying it as the `fd` argument to `openat()` with empty path". No
`/proc/self/fd` round-trip, hence none of the [procfs][procfs] confused-deputy
surface.

cap-std's FreeBSD backend shows the flag in use and its one wrinkle
([`freebsd/fs/check.rs`][capstd-fbsd-check]):

```rust
// `RESOLVE_BENEATH` was introduced in FreeBSD 13, but opening `..` within
// the root directory re-opened the root directory. In FreeBSD 14, it fails
// as cap-std expects.
if let Err(Errno::NOTCAPABLE) = statat(root, cstr!(".."), AtFlags::RESOLVE_BENEATH) {
    WORKING.store(true, Relaxed);
```

The probe uses the `AT_` spelling deliberately: "Unknown `O_` flags get
ignored but `AT_` flags have strict checks, so we use that" — the same
silent-ignore hazard that motivated Linux's separate syscall. With the probe
green, [`open_impl.rs`][capstd-fbsd-open] ORs `OFlags::RESOLVE_BENEATH` into
every open and maps `Errno::NOTCAPABLE` to `errors::escape_attempt()`;
[`remove_dir_impl.rs`][capstd-fbsd-rmdir] calls
`unlinkat(start, path, AtFlags::RESOLVE_BENEATH | AtFlags::REMOVEDIR)`;
[`stat_impl.rs`][capstd-fbsd-stat] adds `SYMLINK_NOFOLLOW` on top. The
dispatch comment in [`fs/mod.rs`][capstd-fs-mod] pairs the platforms: "On
FreeBSD, use optimized implementations based on
`O_RESOLVE_BENEATH`/`AT_RESOLVE_BENEATH` and `O_PATH` when available." rustix
exposes all three constants under `cfg(target_os = "freebsd")` —
`OFlags::RESOLVE_BENEATH`, `OFlags::EMPTY_PATH`, `AtFlags::RESOLVE_BENEATH`
([`libc/fs/types.rs`][rustix-types]) — and Go's `x/sys` has
`O_RESOLVE_BENEATH = 0x800000` ([`zerrors_freebsd_amd64.go`][go-fbsd-errors]).

### OpenBSD

`unveil(path, permissions)` with `r`, `w`, `x`, `c`, each tied to a pledge
promise (`c` "allows creation and removal" via `cpath`/`dpath`/`unix`). The
matching rule is the design's whole substance ([`unveil(2)`][obsd-unveil]):

> Directories are remembered at the time of a call to `unveil()`. This means
> that a directory that is removed and recreated after a call to `unveil()`
> will appear to not exist.
>
> Non-directory paths are remembered by name within their containing
> directory, and so may be created, removed, or re-created after a call to
> `unveil()` and still appear to exist.

So a directory grant is bound to the directory object (rename-proof, but
recreate-blind), and a file grant is bound to a name within that object.
Errors: `ENOENT` when "no unveil() permissions qualify the requested path",
`EACCES` on a permission mismatch, `EPERM` for widening or post-lock calls.

## Dimensions

### Dimension 1 — Threat model

FreeBSD: the same as Linux `RESOLVE_BENEATH` — `..` climbs and absolute
symlinks out of a directory capability, by an adversary who writes the
subtree; in capability mode, additionally _the process itself_ after
compromise (Capsicum's sandboxing goal). OpenBSD: a compromised process; the
kernel does not care who moved what, only whether the object reached is in
the unveiled set.

### Dimension 2 — Resolution primitive

FreeBSD: per-lookup, in-kernel, whole-path, on `open(2)` and every `*at`
call via `AT_RESOLVE_BENEATH`. OpenBSD: not a lookup primitive; a
process-wide filter applied to every filesystem syscall's _result_
(`unveil`) plus a syscall allow-list (`pledge`). There is no scoped-open call
to wrap.

### Dimension 3 — Symlink and `..` policy

FreeBSD refuses absolute symlink targets, escaping `..`, and "even the
temporal escape" — stricter than Linux, which permits an in-scope round trip.
The FreeBSD 13→14 change cap-std probes for is exactly `..` _at_ the root:
13 re-opened the root, 14 returns `ENOTCAPABLE`. OpenBSD's man page says
nothing about symlinks or `..`; the directory-object rule above is the only
stated mechanism (see the final note).

### Dimension 4 — Boundaries

FreeBSD has no `RESOLVE_NO_XDEV` analogue in these pages, no magic links, and
a procfs that is optional; `O_PATH` re-open via `O_EMPTY_PATH` removes the
Linux `/proc/self/fd` dependency. Capability mode blocks `AT_FDCWD` and every
absolute path, so the boundary is the set of fds the process holds. OpenBSD:
the unveiled set is the boundary; mounts and pseudo-filesystems are not
distinguished in the page.

### Dimension 5 — Portability and fallback

FreeBSD < 13 has no `*_RESOLVE_BENEATH` and, worse, ignores the unknown
`O_` bit; cap-std therefore probes with `AT_` and otherwise falls back to
`manually::open`/`via_parent` ([`open_impl.rs`][capstd-fbsd-open],
[`remove_dir_impl.rs`][capstd-fbsd-rmdir]). The FreeBSD 13 `..`-at-root
quirk means "13 has the flag" is not "13 is safe for a root handle", which is
why the probe checks behaviour, not presence. OpenBSD has no fallback and
needs none — the feature is a policy the kernel enforces or the process is
not running on OpenBSD.

### Dimension 6 — Failure and partiality

FreeBSD: `ENOTCAPABLE` for a scope violation (cap-std's tests expect the
text "Capabilities insufficient" ([`tests/fs_additional.rs`][capstd-tests]));
the call fails before any effect. OpenBSD: `pledge` violations kill with
`SIGABRT` (an `error` promise downgrades that to `ENOSYS`); `unveil`
violations are `ENOENT`/`EACCES`, i.e. the file appears absent — partial
tree walks silently skip what they may not see.

### Dimension 7 — Enumeration and deletion

Does not apply as a kernel primitive on either system. FreeBSD supplies the
per-entry building block — `unlinkat(fd, name, AT_RESOLVE_BENEATH |
AT_REMOVEDIR)` as cap-std uses it — and leaves the walk to user space.
OpenBSD's `c` permission gates removal per unveiled path; there is no
fd-relative scoping distinct from the global policy.

## Strengths

- **The original**: `O_BENEATH`/Capsicum is where Linux's `RESOLVE_BENEATH`
  semantics come from.
- `AT_RESOLVE_BENEATH` on the whole `*at` family, not only `open` — Linux
  scopes only `openat2`.
- **`O_EMPTY_PATH`** re-opens an `O_PATH` fd without procfs.
- OpenBSD's model needs no per-call discipline: one `unveil`/`pledge` prologue
  covers every later syscall.

## Weaknesses

- Unknown `O_` flags are still ignored on FreeBSD; consumers must probe with
  `AT_` flags to know the kernel honours the restriction.
- The FreeBSD 13 `..`-at-root behaviour silently differed from 14.
- No mount-crossing control in the surveyed FreeBSD pages.
- OpenBSD's `unveil` is documented at the level of "directories remembered",
  without stating symlink or `..` semantics; a library cannot reason about
  races from the man page alone.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                             | Trade-off                                                              |
| ------------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Refuse "temporal escape" (`../x` back into scope)             | A capability's authority is a subtree; leaving it at all is an escape | Stricter than Linux; some legitimate relative paths fail               |
| Put the flag on every `*at` call (`AT_RESOLVE_BENEATH`)       | Capsicum already constrains the whole family in capability mode       | Two spellings (`O_`/`AT_`) with different unknown-flag behaviour       |
| `O_PATH` + `O_EMPTY_PATH` re-open (14.0)                      | Avoid procfs for fd re-opening                                        | Arrived a decade after Linux `O_PATH`, without Linux's `openat2`       |
| `cap_enter` irreversible and inherited                        | A sandbox that can be exited is not one                               | Whole-process; cannot scope one lookup                                 |
| OpenBSD: allow-list paths at process start, kill on violation | Simplicity; no per-call API to misuse                                 | No fd-relative scoping; directory grants die with the directory object |

## Sources

- FreeBSD [`open(2)`][fbsd-open] (current; 12.0, 13.0, 14.0 `manpath` variants) — `O_RESOLVE_BENEATH`, `O_PATH`, `O_EMPTY_PATH`, the capability-mode paragraph, HISTORY
- FreeBSD [`unlinkat(2)`][fbsd-unlinkat] — `AT_RESOLVE_BENEATH`
- FreeBSD [`capsicum(4)`][fbsd-capsicum], [`cap_enter(2)`][fbsd-cap-enter] — capability mode, `*at` constraint, authorship, FreeBSD 9.0
- OpenBSD [`unveil(2)`][obsd-unveil], [`pledge(2)`][obsd-pledge] — semantics, errors, OpenBSD 6.4 / 5.9
- [LWN 804980][lwn-804980] — `RESOLVE_BENEATH` "follow[s] FreeBSD's `O_BENEATH`"
- cap-std [`freebsd/fs/check.rs`][capstd-fbsd-check], [`open_impl.rs`][capstd-fbsd-open], [`remove_dir_impl.rs`][capstd-fbsd-rmdir], [`stat_impl.rs`][capstd-fbsd-stat], [`fs/mod.rs`][capstd-fs-mod], [`tests/fs_additional.rs`][capstd-tests] — the probe, the fallback, `ENOTCAPABLE` mapping
- rustix [`libc/fs/types.rs`][rustix-types] — FreeBSD-gated `RESOLVE_BENEATH`/`EMPTY_PATH` constants
- Go [`zerrors_freebsd_amd64.go`][go-fbsd-errors] — `O_RESOLVE_BENEATH = 0x800000`

> [!NOTE]
> **Unverified.** The FreeBSD release that added `O_RESOLVE_BENEATH` is
> inferred from the 12.0-vs-13.0 man-page diff and cap-std's comment; the
> 12.0/13.0/14.0 release notes do not mention it. The pre-13 `O_BENEATH`
> spelling appears only in the Linux v16 posting, never in a FreeBSD man
> page fetched here. `unveil`'s symlink and `..` behaviour is not stated in
> its man page and is not asserted above.

<!-- References -->

[procfs]: ./linux-procfs-magic-links.md
[fbsd-open]: https://man.freebsd.org/cgi/man.cgi?query=open&sektion=2
[fbsd-unlinkat]: https://man.freebsd.org/cgi/man.cgi?query=unlinkat&sektion=2
[fbsd-capsicum]: https://man.freebsd.org/cgi/man.cgi?query=capsicum&sektion=4
[fbsd-cap-enter]: https://man.freebsd.org/cgi/man.cgi?query=cap_enter&sektion=2
[obsd-unveil]: https://man.openbsd.org/unveil.2
[obsd-pledge]: https://man.openbsd.org/pledge.2
[lwn-804980]: https://lwn.net/Articles/804980/
[capstd-fbsd-dir]: https://github.com/bytecodealliance/cap-std/tree/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs
[capstd-fbsd-check]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs/check.rs
[capstd-fbsd-open]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs/open_impl.rs
[capstd-fbsd-rmdir]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs/remove_dir_impl.rs
[capstd-fbsd-stat]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/freebsd/fs/stat_impl.rs
[capstd-fs-mod]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/fs/mod.rs
[capstd-tests]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/tests/fs_additional.rs
[rustix-types]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/types.rs
[go-fbsd-errors]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/cmd/vendor/golang.org/x/sys/unix/zerrors_freebsd_amd64.go
