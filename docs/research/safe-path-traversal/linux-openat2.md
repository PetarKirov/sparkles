# Linux `openat2(2)`

The kernel's answer to a decade of user-space symlink scoping: one whole-path
lookup whose `resolve` bitmask says which escapes are forbidden, with a
structure argument sized so that an unknown flag is an error rather than a
silently ignored bit.

|                           |                                                                                                                                                                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**                  | kernel mechanism                                                                                                                                                                                                                     |
| **Year**                  | Linux 5.6 (2020-03-29); `RESOLVE_CACHED` in 5.12; patch series 2019-07 → 2019-11 (v16)                                                                                                                                               |
| **Authors / Maintainers** | Aleksa Sarai (SUSE); prehistory David Drysdale's `O_BENEATH` (2014, Capsicum-inspired) and Al Viro's `AT_NO_JUMPS`                                                                                                                   |
| **Language**              | C (kernel VFS); wrapped here from Rust (`rustix`, `cap-std`, `libpathrs`) and Go (`x/sys/unix`)                                                                                                                                      |
| **License**               | GPL-2.0 (kernel)                                                                                                                                                                                                                     |
| **Venue**                 | LKML; LWN coverage [796868][lwn-796868], [804980][lwn-804980], [793075][lwn-793075], [796770][lwn-796770]; LPC 2020 [slides][lpc-pdf]                                                                                                |
| **Platforms**             | Linux ≥ 5.6 only; `ENOSYS` (or `EPERM` under seccomp) elsewhere                                                                                                                                                                      |
| **Primitive**             | In-kernel whole-path resolution under `struct open_how.resolve` restrictions; extensible-by-size argument (`E2BIG` / `EINVAL`)                                                                                                       |
| **Source read**           | [`openat2.2`][man-openat2], [`open_how.2type`][man-open-how], the LWN set, [`2020/08-LinuxPlumbers/openat2.pdf`][lpc-pdf], libpathrs [`docs/kernel-features.md`][lp-kernel-features], the rustix / cap-std / Go wrappers cited below |

## Overview

### What it solves

Every user-space "safe open" before 5.6 was a per-component walk that had to
re-verify the result through `/proc`. Sarai's cover letter
([LWN 793075][lwn-793075]) states the demand plainly:

> The need for some sort of control over VFS's path resolution (to avoid
> malicious paths resulting in inadvertent breakouts) has been a very
> long-standing desire of many userspace applications.

and names the customer: "Container runtimes, which currently need to do
symlink scoping in userspace when opening paths in a potentially malicious
container." The trigger LWN cites is the 2019 runc breakout: "hostile code
using the `/proc/PID/exe` link to open the runc binary for write access"
([LWN 796868][lwn-796868]).

### Design philosophy

Two decisions define the interface. First, **a new syscall rather than new
`openat` flags**, because the old call cannot tell you it ignored one
([LWN 796868][lwn-796868]):

> `openat()` doesn't check for unknown flags […] a program using a
> path-restricting flag needs to know whether the requested behavior is
> understood by the kernel or not; the alternative is to accept security
> vulnerabilities. […] So the only alternative is to create a new system call
> that does check its flags; thus `openat2()`.

Second, **the restrictions are lookup flags, not open flags**: the v16 posting
([LWN 804980][lwn-804980]) describes the `resolve` field as a separate mask
"that modify[ies] the way in which all components of a pathname will be
resolved" ([`open_how.2type`][man-open-how]), so `O_NOFOLLOW` (trailing
component only) and `RESOLVE_NO_SYMLINKS` (every component) stop being
confused. `RESOLVE_IN_ROOT` is pitched as "chroot(2)-like protection but
without the cost of a chroot(2)" ([LWN 796770][lwn-796770]).

## How it works

The argument is a versioned-by-size structure
([`open_how.2type`][man-open-how], `<linux/openat2.h>`):

```c
struct open_how {
    u64  flags;    /* O_* flags */
    u64  mode;     /* Mode for O_{CREAT,TMPFILE} */
    u64  resolve;  /* RESOLVE_* flags */
    /* ... */
};
```

The kernel compares its own `ksize` with the caller's `usize`
([`openat2.2`][man-openat2]): "If `ksize` is larger than `usize` […] the
kernel treats all of the extension fields not provided by the user-space
application as having zero values"; if smaller, "the kernel can safely ignore
the unsupported extension fields if they are all-zero. If any unsupported
extension fields are nonzero, then -1 is returned and `errno` is set to
`E2BIG`." Unknown bits inside a known field are `EINVAL`. Callers are told to
"zero-fill `struct open_how`". Every wrapper surveyed passes
`sizeof(struct open_how)` = 24 explicitly: rustix's raw backend
([`linux_raw/fs/syscalls.rs`][rustix-raw]) and libc backend
([`libc/fs/syscalls.rs`][rustix-libc], `SYS_OPENAT2 = 437`), Go's vendored
`x/sys` ([`syscall_linux.go`][go-xsys-openat2], `SizeofOpenHow = 0x18` in
[`ztypes_linux.go`][go-xsys-types]), and libpathrs
([`src/syscalls.rs`][lp-syscalls]).

The bit values, from rustix ([`libc/fs/types.rs`][rustix-types]) and Go
([`ztypes_linux.go`][go-xsys-types]):

```rust
const NO_XDEV       = 0x01;
const NO_MAGICLINKS = 0x02;
const NO_SYMLINKS   = 0x04;
const BENEATH       = 0x08;
const IN_ROOT       = 0x10;
const CACHED        = 0x20;   // since Linux 5.12
```

### The flag table

Guarantees are quoted from [`openat2.2`][man-openat2]; the "does not
guarantee" column is what the man page, the LPC slides and the wrappers had
to add on top.

| Flag                    | Kernel | Guarantees                                                                                                                                                                                       | Does **not** guarantee                                                                                                                                              |
| ----------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RESOLVE_NO_XDEV`       | 5.6    | "Disallow traversal of mount points during path resolution (including all bind mounts)" — `EXDEV`                                                                                                | Nothing about symlinks; it also "blocks most magic-links" as a side effect ([LPC slides][lpc-pdf]), so it cannot be combined with a magic-link open                 |
| `RESOLVE_NO_MAGICLINKS` | 5.6    | "Disallow all magic-link resolution" — implemented "by blocking the usage of `nd_jump_link()`" ([LWN 796770][lwn-796770]); with `O_PATH\|O_NOFOLLOW` a trailing magic link yields an `O_PATH` fd | Nothing about ordinary symlinks or mounts; see [procfs magic links][procfs]                                                                                         |
| `RESOLVE_NO_SYMLINKS`   | 5.6    | "Disallow resolution of symbolic links during path resolution. This option implies `RESOLVE_NO_MAGICLINKS`" — `ELOOP`                                                                            | `..` and mounts are unrestricted                                                                                                                                    |
| `RESOLVE_BENEATH`       | 5.6    | No component "is not a descendant of the directory indicated by `dirfd`"; absolute paths and absolute symlinks rejected (`EXDEV`); "Currently, this flag also disables magic-link resolution"    | `..` that stays beneath is allowed; mounts may be crossed; the escape check for `..` can fail closed with `EAGAIN`                                                  |
| `RESOLVE_IN_ROOT`       | 5.6    | "as though the calling process had used `chroot(2)`": absolute paths and symlinks re-rooted at `dirfd`, `/..` stays at `dirfd`; also disables magic links                                        | That `dirfd` itself stays put — libpathrs's fallback separately errors "root moved during lookup" ([`opath/imp.rs`][lp-opath]); no mount restriction; not a sandbox |
| `RESOLVE_CACHED`        | 5.12   | Fail with `EAGAIN` "unless all path components are already present in the kernel's lookup cache"                                                                                                 | Any security property — it is a non-blocking hint                                                                                                                   |

> [!NOTE]
> `RESOLVE_EMPTY_PATH` ("If pathname is an empty string, open the file referred
> by dirfd") was proposed on 2022-01-12 for CRIU, because "If you have an
> opened `O_PATH` file, currently there is no way to re-open it with other
> flags with openat/openat2" ([LWN 881153][lwn-881153]). None of the sources
> read here shows it merged; see the final note.

## Dimensions

### Dimension 1 — Threat model

Symlink swap at any component, a `..` whose parent is renamed mid-lookup,
bind mounts placed inside the tree, and procfs magic links. The adversary is
an unprivileged local user or a container's root with the ability to write
the tree being opened; the runc `/proc/PID/exe` case is the motivating
example ([LWN 796868][lwn-796868]). Out of scope: an attacker who can move
`dirfd` itself, and an attacker who controls the mount table under `/proc`
(the [procfs][procfs] deep-dive).

### Dimension 2 — Resolution primitive

Whole-path, in-kernel, one syscall. The kernel holds the VFS locks user space
cannot, but it still does not promise atomicity against `rename`: for
`RESOLVE_BENEATH`/`RESOLVE_IN_ROOT` the man page defines `EAGAIN` as "the
kernel could not ensure that a `..` component didn't escape (due to a race
condition or potential attack). The caller may choose to retry." Two
wrappers chose different retry budgets. libpathrs
([`src/syscalls.rs`][lp-syscalls]) retries only scoped lookups
(`how.is_scoped_lookup()`) up to `MAX_RETRIES = 128`, arguing "with 128
retries you only have a ~0.1% chance of hitting the error path (even with an
attacker pounding on rename on all cores)". cap-std
([`linux/fs/open_impl.rs`][capstd-linux]) loops `for _ in 0..4`, admitting
"The actual number here is currently an arbitrarily chosen guess."

### Dimension 3 — Symlink and `..` policy

Selected per flag (table above). Two facts matter for a directory-handle
design. `RESOLVE_BENEATH` **permits** `..` as long as the walk never leaves
`dirfd`; only `RESOLVE_NO_SYMLINKS` removes symlinks entirely, and it is the
one flag that "differs from the `O_NOFOLLOW` flag in that it prevents
following a link at any point in the lookup process"
([LWN 796868][lwn-796868]). And `RESOLVE_IN_ROOT` re-interprets absolute
symlinks instead of rejecting them, which is what a container rootfs needs
and what a build-tree walker usually does not.

### Dimension 4 — Boundaries

Mounts: `RESOLVE_NO_XDEV`, or nothing. procfs: `RESOLVE_NO_MAGICLINKS`, which
`BENEATH` and `IN_ROOT` currently imply. What no flag does is verify that a
path _inside_ a mount is the file you meant — an overmount on `/proc/self`
passes every `RESOLVE_*` check. The LPC 2020 slides list that as the
remaining gap: "Being sure that `/proc/self/{fd/$n,exe}` is legit. Not
currently possible, even with openat2(2). Cannot use `RESOLVE_NO_XDEV`
(blocks most magic-links)" ([`openat2.pdf`][lpc-pdf]). Automount and
"remote fs" restrictions are named as "might be useful" and were not added.

### Dimension 5 — Portability and fallback

Detection is by errno, and the two errnos disagree on permanence. cap-std
treats `ENOSYS` as final (`INVALID.store(true)`) but `EPERM` — "used by some
`seccomp` sandboxes to indicate that `openat2` is unimplemented" — only as
"exit the loop and use the fallback", because `EPERM` also means a failed
`O_NOATIME` or a file seal ([`open_impl.rs`][capstd-linux]); on Android it
does not even probe, because the seccomp policy "prevents us from even
detecting whether `openat2` is supported". libpathrs caches a **one-way**
failure: "A process can always add seccomp-bpf filters to itself that would
cause `openat2(2)` to start failing", so a past success proves nothing
([`src/syscalls.rs`][lp-syscalls], `SAW_OPENAT2_FAILURE`).

The fallbacks are the pre-5.6 walks. libpathrs's `opath` resolver is "an
emulated version of `openat2(RESOLVE_IN_ROOT)`" done "through shameless abuse
of procfs and `O_PATH` magic-links", verifying "the path of the final file
descriptor is what we expected […] through `readlink(/proc/self/fd/$n)`"
([`opath/imp.rs`][lp-opath]). Go's `os.Root` never calls `openat2` at all:
[`root_unix.go`][go-root-unix] opens each component with
`O_NOFOLLOW|O_CLOEXEC`, and on `..` [`root_openat.go`][go-root-openat]
restarts from the root — "We can't `openat(dir, "..")` to move up to the
parent directory, because `dir` may have moved since we opened it" — bounded
by `maxSteps = 255` and `maxRestarts = 8`. The only `Openat2` in the Go tree
at this SHA is the vendored `x/sys` binding ([`syscall_linux.go`][go-xsys-openat2]).

What is lost without the syscall: atomicity across components, the `EAGAIN`
signal, and — for libpathrs — a `/proc` dependency the kernel path never had
(the [`kernel-features.md`][lp-kernel-features] table's "Fallback" column is
the definitive list).

### Dimension 6 — Failure and partiality

`openat2` either returns an fd or nothing; there is no partial state. Errors
carry meaning per flag: `EXDEV` for an escape (`BENEATH`/`IN_ROOT`) _and_ for a
mount crossing (`NO_XDEV`); `ELOOP` for a refused symlink or magic link;
`EAGAIN` for the `..` race or a cache miss; `E2BIG`/`EINVAL` for an
unsupported or unknown request. cap-std maps `EXDEV` to a single
`escape_attempt()` error ([`open_impl.rs`][capstd-linux]). libpathrs's
`resolve_partial` ([`resolvers/openat2.rs`][lp-openat2]) turns a failed open
into a longest-resolvable-prefix by re-issuing `openat2` on each ancestor —
and stops on a safety violation "to avoid some possible weird bug in libpathrs
being exploited to return some result to `Root::mkdir_all`".

### Dimension 7 — Enumeration and deletion

Does not apply, because `openat2` opens; it neither lists nor unlinks. What it
contributes to a `remove_dir_all` is the _directory handle_ the walk then uses
with `openat`/`unlinkat`. libpathrs always adds `RESOLVE_IN_ROOT |
RESOLVE_NO_MAGICLINKS` and opens with `O_PATH` to obtain such a handle
([`resolvers/openat2.rs`][lp-openat2]); cap-std adds `BENEATH |
NO_MAGICLINKS` and returns the fd for every subsequent `*at` call
([`open_impl.rs`][capstd-linux]). Depth and fd limits are the caller's.

## Strengths

- **Fails closed on unknown requests** — `E2BIG`/`EINVAL` instead of the
  silent flag drop that made `O_BENEATH`-style proposals unsafe to depend on.
- **One syscall replaces a `/proc`-verified component walk**; the kernel's
  locks make the `..` race detectable (`EAGAIN`) instead of exploitable.
- **Lookup restrictions are orthogonal** — `NO_SYMLINKS`, `NO_XDEV`,
  `NO_MAGICLINKS`, `BENEATH`/`IN_ROOT` compose freely.
- Adopted by every surveyed Rust wrapper at the raw-syscall level, with
  identical `sizeof` versioning.

## Weaknesses

- **`EAGAIN` is a real failure mode**, not a theoretical one — both wrappers
  carry retry loops with hand-picked budgets (4 vs 128).
- **No "exact file" guarantee**: overmounts inside the scope pass; procfs
  needs a second mechanism ([procfs][procfs]).
- **Linux ≥ 5.6 only, and seccomp-filtered on Android**; every consumer ships
  the pre-5.6 walk anyway, so `openat2` is an accelerator, not a replacement.
- `RESOLVE_IN_ROOT` does not pin the root; a moved `dirfd` is the caller's
  problem.
- No `readlinkat2`: "Given an open `O_PATH` symlink, we cannot currently
  readlink it" ([LPC slides][lpc-pdf]).

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                                 | Trade-off                                                                    |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| New syscall instead of new `openat` flags                   | `openat` ignores unknown flags; a security flag must be known-honoured                    | Every caller needs an `ENOSYS`/`EPERM` fallback path                         |
| `struct open_how` versioned by `size`                       | Add fields later with zero-as-no-op; `E2BIG` when the kernel is older than the header     | Callers must zero-fill and pass `sizeof`; a `u64` per field                  |
| Separate `resolve` mask from `flags`                        | Lookup-wide rules (`NO_SYMLINKS`) vs trailing-component `O_NOFOLLOW` stop being conflated | Two vocabularies to learn                                                    |
| `EAGAIN` on a `..` rename race rather than a blocking retry | Keep the kernel path lock-free and non-blocking                                           | User space owns the retry policy and its budget                              |
| `RESOLVE_BENEATH` allows in-scope `..`                      | Match FreeBSD `O_BENEATH` semantics ([LWN 804980][lwn-804980])                            | `..` still needs the race check above                                        |
| `BENEATH`/`IN_ROOT` imply `NO_MAGICLINKS` "currently"       | A magic link is a jump the scope cannot see                                               | Scoped opens of `/proc/self/fd/N` need the unscoped path in [procfs][procfs] |

## Sources

- [`openat2.2`][man-openat2] — flag semantics, `EAGAIN` for `..`, `E2BIG`/`EINVAL` extension rules, Linux 5.6
- [`open_how.2type`][man-open-how] — the structure and the `resolve` field's definition
- [LWN 796868][lwn-796868] — why a new syscall; the `O_BENEATH` 2014 prehistory; `NO_SYMLINKS` vs `O_NOFOLLOW`
- [LWN 804980][lwn-804980] — v16 posting: `RESOLVE_BENEATH` "follow[s] FreeBSD's `O_BENEATH`", `AT_NO_JUMPS`, `ksize`/`usize`
- [LWN 793075][lwn-793075], [LWN 796770][lwn-796770] — Sarai's cover letters: motivation, `LOOKUP_*` internals, `nd_jump_link()`
- [LWN 881153][lwn-881153] — the `RESOLVE_EMPTY_PATH` proposal for `O_PATH` re-opening
- [`2020/08-LinuxPlumbers/openat2.pdf`][lpc-pdf] — "what's next": the procfs gap, `readlinkat2`, magic-link re-open restrictions
- [`docs/kernel-features.md`][lp-kernel-features] — per-kernel-version feature/fallback table
- [`src/syscalls.rs`][lp-syscalls], [`src/resolvers/openat2.rs`][lp-openat2], [`src/resolvers/opath/imp.rs`][lp-opath] — libpathrs's retry budget, one-way failure cache, partial resolution, and emulation
- [`cap-primitives/src/rustix/linux/fs/open_impl.rs`][capstd-linux] — cap-std's 4-retry loop, `EPERM`/`ENOSYS` handling, Android note
- [`src/fs/openat2.rs`][rustix-openat2], [`linux_raw/fs/syscalls.rs`][rustix-raw], [`libc/fs/syscalls.rs`][rustix-libc], [`libc/fs/types.rs`][rustix-types] — rustix's binding and flag values
- [`src/os/root_unix.go`][go-root-unix], [`src/os/root_openat.go`][go-root-openat] — Go's `os.Root` does not use `openat2`
- [`x/sys/unix/syscall_linux.go`][go-xsys-openat2], [`ztypes_linux.go`][go-xsys-types] — the only `Openat2` in the Go tree

> [!NOTE]
> **Unverified.** The LPC 2020 deck was read via `pdftotext`; one slide's
> text is garbled in extraction and is not quoted. The merge status of
> `RESOLVE_EMPTY_PATH` is not established by any source read here. The 2014
> `O_BENEATH` patch text was seen only through LWN's summaries, not the LKML
> posting.

<!-- References -->

[procfs]: ./linux-procfs-magic-links.md
[man-openat2]: https://man7.org/linux/man-pages/man2/openat2.2.html
[man-open-how]: https://man7.org/linux/man-pages/man2/open_how.2type.html
[lwn-796868]: https://lwn.net/Articles/796868/
[lwn-804980]: https://lwn.net/Articles/804980/
[lwn-793075]: https://lwn.net/Articles/793075/
[lwn-796770]: https://lwn.net/Articles/796770/
[lwn-881153]: https://lwn.net/Articles/881153/
[lpc-pdf]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2020/08-LinuxPlumbers/openat2.pdf
[lp-kernel-features]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/kernel-features.md
[lp-syscalls]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/syscalls.rs
[lp-openat2]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/openat2.rs
[lp-opath]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/opath/imp.rs
[capstd-linux]: https://github.com/bytecodealliance/cap-std/blob/b7acf8e8807fe3fab991884d2208b7e03d35a409/cap-primitives/src/rustix/linux/fs/open_impl.rs
[rustix-openat2]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/fs/openat2.rs
[rustix-raw]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/linux_raw/fs/syscalls.rs
[rustix-libc]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/syscalls.rs
[rustix-types]: https://github.com/bytecodealliance/rustix/blob/287214b889865d8e1406a0ee71cc409b6f6191c8/src/backend/libc/fs/types.rs
[go-root-unix]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_unix.go
[go-root-openat]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/os/root_openat.go
[go-xsys-openat2]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/cmd/vendor/golang.org/x/sys/unix/syscall_linux.go
[go-xsys-types]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/cmd/vendor/golang.org/x/sys/unix/ztypes_linux.go
