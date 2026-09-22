# Linux procfs magic links

The one place where "did I stay inside the tree?" is not the question: a
privileged process writing `/proc/self/attr/exec` needs to hit _exactly that
file_, and an attacker who can mount can make any `/proc` path land somewhere
else.

|                           |                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | kernel mechanism (procfs magic links) and the mitigation ladder built on top                                                                                                                                                                                                                                                                                                                        |
| **Year**                  | `fsopen`/`open_tree` 5.2 (2019); `RESOLVE_NO_MAGICLINKS` 5.6 (2020); `STATX_MNT_ID` + `subset=pid` 5.8; `ino` in `fdinfo` 5.14; `STATX_MNT_ID_UNIQUE` 6.8 (2024); procfs overmount restrictions 6.12                                                                                                                                                                                                |
| **Authors / Maintainers** | Kernel VFS; the reference consumer is Aleksa Sarai's libpathrs (`ProcfsHandle`)                                                                                                                                                                                                                                                                                                                     |
| **Language**              | C (kernel); Rust (libpathrs)                                                                                                                                                                                                                                                                                                                                                                        |
| **License**               | GPL-2.0 (kernel); MPL-2.0 OR LGPL-3.0-or-later (libpathrs)                                                                                                                                                                                                                                                                                                                                          |
| **Repository**            | [`cyphar/libpathrs`][lp-procfs-rs]                                                                                                                                                                                                                                                                                                                                                                  |
| **Platforms**             | Linux; every step of the ladder degrades on older kernels or without `CAP_SYS_ADMIN`                                                                                                                                                                                                                                                                                                                |
| **Primitive**             | `nd_jump_link()` links (`/proc/<pid>/fd/*`, `/proc/<pid>/{exe,cwd,root}`) that resolve to an in-kernel object, not a path; refused by `RESOLVE_NO_MAGICLINKS`, verified by `statx` mount ids                                                                                                                                                                                                        |
| **Source read**           | [`docs/procfs-api.md`][lp-procfs-api], [`docs/kernel-features.md`][lp-kernel-features], [`docs/avoidable-vulnerabilities.md`][lp-avoidable], [`src/procfs.rs`][lp-procfs-rs], [`src/resolvers/procfs.rs`][lp-procfs-resolver], [`src/resolvers/opath/imp.rs`][lp-opath], [`src/utils/fd.rs`][lp-utils-fd], [FOSDEM 2026 slides][fosdem-pdf], [LPC 2020 slides][lpc-pdf], [LWN 1050887][lwn-1050887] |

## Overview

### What it solves

libpathrs's [`docs/procfs-api.md`][lp-procfs-api] lists why `/proc` is
different from every other filesystem:

> 1. As a mechanism for doing certain filesystem operations through
>    `/proc/self/fd/...` (and other similar magic-links) that cannot be done
>    by other means.
> 1. As a source of true information about processes and the general system
>    (such as by looking `/proc/$pid/status`).
> 1. As an administrative tool for managing processes (such as setting LSM
>    labels like `/proc/self/attr/apparmor/exec`).

and what a magic link actually is: "magic-links are symlinks that are not
resolved lexically, they are in-kernel objects that warp you to other files
without doing a regular path lookup". The consequence, from the module doc in
[`src/procfs.rs`][lp-procfs-rs]: "it is not sufficient that operations on
`/proc` paths do not escape the `/proc` filesystem -- it is absolutely
critical that operations through `/proc` operate **on the exact subpath that
the caller requested**."

### Design philosophy

Sarai's FOSDEM 2026 talk names the split this deep-dive is about
([slides][fosdem-pdf]): **"regular" path safety** — "a path component might
be swapped with a symlink or moved. Classic time-of-check-to-time-of-use
attacks abound" — versus **"strict" path safety** — "For certain
pseudo-filesystems we need to ensure we are operating on an exact path.
procfs is most critical. Overmounts or fake mounts can trick us into doing
dangerous operations or make operations a no-op." LWN's write-up of the runc
CVEs ([1050887][lwn-1050887]) carries his conclusion: "Every system call that
works with path names is potentially dangerous", hence "file-descriptor based
design, rather than relying on paths". [`docs/avoidable-vulnerabilities.md`][lp-avoidable]
files the strict class as "primarily a container-runtime-specific issue and
most people probably consider protecting against this to be a paranoid level
of hardening" — and then lists three CVEs under it.

## How it works

The FOSDEM deck's "(un)safety" slide is four ordinary-looking lines:

```c
int lfd = open("/proc/self/attr/exec", O_RDWR);
dprintf(lfd, "exec docker-default\n");
int pfd = open("/proc/sys/net/ipv4/ping_group_range", O_RDWR);
int reopen = open("/proc/thread-self/fd/123", O_RDWR);
execve("/proc/self/exe", ...);
```

Each is a **confused deputy**: the privileged caller names a path, the
attacker owns the mount table the path is resolved against, so a bind mount
over `attr/exec` turns the label write into a write to an attacker file, and
a bind mount over `fd/123` makes the `O_PATH` re-open land elsewhere. That is
how CVE-2019-16884 and CVE-2019-19921 worked ([`procfs-api.md`][lp-procfs-api]);
LWN describes CVE-2025-31133 / CVE-2025-52565 as "using a mount and a
symbolic link to trick runc into giving a container access to
`/proc/sys/kernel/core_pattern`", after which the kernel "launches the
configured core-dump handler [with] full privileges in the root namespace"
([LWN 1050887][lwn-1050887]).

The `O_PATH` re-open is the case `openat2` cannot cover on its own: a magic
link _is_ a mount crossing, so `RESOLVE_NO_XDEV` "blocks most magic-links"
and the LPC 2020 deck records "Being sure that `/proc/self/{fd/$n,exe}` is
legit. Not currently possible, even with `openat2(2)`" ([slides][lpc-pdf]).
The three proposals floated there — `RESOLVE_ONLY_MAGICLINKS`, replacing each
magic link with a dedicated API (`openat($n, "", O_EMPTYPATH)`,
`process_get_resource`), or a process-local procfs via unprivileged
`fsopen("procfs")` with `subset=pid,hidepid=4` — are the design space; what
shipped is the third, for the privileged.

### The mitigation ladder

[`docs/kernel-features.md`][lp-kernel-features] is the authoritative table;
condensed:

| Feature                 | Kernel | Used for                                                                                                      | Fallback (quoted)                                                                                                          |
| ----------------------- | ------ | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `open_tree(2)`          | 5.2    | Private copy of the host `/proc` ("in most cases this will also strip any overmounts"); needs `CAP_SYS_ADMIN` | "Open a regular handle to `/proc`. This can lead to certain race attacks if the attacker can dynamically create mounts."   |
| `fsopen(2)`             | 5.2    | "a completely fresh copy of `/proc`"; needs `CAP_SYS_ADMIN`                                                   | `open_tree`, then a recursive `open_tree` that "preserves the overmounts" so libpathrs can at least detect and reject them |
| `openat2(2)`            | 5.6    | "used extensively by libpathrs to safely do path lookups"                                                     | "Userspace emulated path lookups."                                                                                         |
| `subset=pid`            | 5.8    | An `fsopen` procfs without "global procfs files that would be dangerous"; such handles are cached             | Uncached handles, "possibly causing substantially higher syscall usage"                                                    |
| `STATX_MNT_ID`          | 5.8    | "verify whether there are bind-mounts on top of `/proc`"                                                      | Parse `/proc/thread-self/fdinfo/$fd`; "guaranteed to be safe" only with `openat2`                                          |
| `ino` field in `fdinfo` | 5.14   | Harden the `RESOLVE_NO_XDEV` emulation                                                                        | "**None**" — `mnt_id` alone "is static and attacker-known"                                                                 |
| `STATX_MNT_ID_UNIQUE`   | 6.8    | Same as `STATX_MNT_ID` "but allows us to protect against mount ID recycling"                                  | `STATX_MNT_ID`                                                                                                             |

`ProcfsHandleBuilder::build` ([`src/procfs.rs`][lp-procfs-rs]) walks the
ladder top-down:

```rust
let procfs = ProcfsHandle::new_fsopen(self.subset_pid)
    .or_else(|_| ProcfsHandle::new_open_tree(OpenTreeFlags::empty()))
    .or_else(|_| ProcfsHandle::new_open_tree(OpenTreeFlags::AT_RECURSIVE))
```

with the plain-`/proc` constructor documented as "NOT safe against racing
attackers and overmounts". Every handle is validated by `verify_is_procfs`
(`fstatfs` → `PROC_SUPER_MAGIC`, else `EXDEV`) and `verify_is_procfs_root`
(inode == `PROC_ROOT_INO`; "If this check ever stops working, it's a kernel
regression").

### Two open paths

`ProcfsHandle::open` force-sets `O_NOFOLLOW`, "_will not follow any magic
links_", and "implies `RESOLVE_NO_XDEV`" — the openat2 resolver in
[`src/resolvers/procfs.rs`][lp-procfs-resolver] passes
`RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV`. That is the FOSDEM
"strict path safety" recipe verbatim:

```c
int procfd = open("/proc", O_DIRECTORY|O_PATH);
/* check PROC_SUPER_MAGIC and PROC_ROOT_INO */
struct open_how how = { .flags = O_WRONLY,
                        .resolve = RESOLVE_BENEATH|RESOLVE_NO_XDEV };
int lfd = openat2(procfd, "self/attr/exec", &how, sizeof(how));
```

`ProcfsHandle::open_follow` is the only way to _follow_ a magic link, and it
only permits a **trailing** one: it opens the parent with
`O_PATH | O_DIRECTORY`, fetches the parent's mount id, checks the trailing
component is on the same mount (`verify_same_mnt`), and only then calls
`openat_follow`. The source is candid about the limit: "This check is only
safe if there are no racing mounts, so only for the
`ProcfsHandle::{new_fsopen,new_open_tree}` cases", and the ELOOP-based
pre-check "is not safe against races -- an attacker could bind-mount a
magic-link over a regular symlink to trigger ELOOP and then unmount it after
this point. As always, `fsopen(2)` is needed for true safety here"
([`src/procfs.rs`][lp-procfs-rs]).

## Dimensions

### Dimension 1 — Threat model

An attacker who controls the **mount table** the victim resolves `/proc`
against — container root, or anything with `CAP_SYS_ADMIN` in a user
namespace — placing bind mounts over specific procfs files or over magic
links. Overmounts also occur benignly: `lxcfs` overmounts `/proc/meminfo` and
`/proc/cpuinfo`, so "using `ProcfsBase::ProcRoot` may result in errors on such
systems for non-privileged users, even in the absence of an active attack",
whereas "there are no benevolent tools which create mounts in `/proc/self`"
([`src/procfs.rs`][lp-procfs-rs]). Linux 6.12 "introduced several
restrictions on such mounts" with plans to block most overmounts inside
`/proc/self`; the handle remains "useful for older kernels".

### Dimension 2 — Resolution primitive

Three stacked: a _detached_ procfs (`fsopen`/`open_tree`) so there is no
shared mount table to race; `openat2(RESOLVE_BENEATH|NO_MAGICLINKS|NO_XDEV)`
for the lookup (the [`openat2` deep-dive][openat2] covers the flags); `statx(STATX_MNT_ID_UNIQUE)` to prove the final object is on
the handle's mount. [`src/utils/fd.rs`][lp-utils-fd] spells the preference
order — `STATX_MNT_ID_UNIQUE` (0x4000, 6.8) "provides a globally" unique id,
then `STATX_MNT_ID` (5.8), then `fdinfo`.

### Dimension 3 — Symlink and `..` policy

Magic links as _components_ are refused unconditionally ("`open_follow` will
not permit a magic-link to be a path component (ie. `/proc/self/root/etc/passwd`)");
trailing ones only through `open_follow`. `..` is refused outright by the
`O_PATH` fallback resolver ("cannot walk into '..' with restricted procfs
resolver", `EXDEV`), and callers are told not to use it even on `openat2`
kernels because "using `..` could result in application errors when running
on pre-5.6 kernels" ([`src/procfs.rs`][lp-procfs-rs]). Regular relative
symlinks inside procfs are followed; absolute link targets are treated as
magic links and refused, since "procfs does not (and cannot) contain regular
absolute symlinks to paths within procfs" ([`resolvers/procfs.rs`][lp-procfs-resolver]).

### Dimension 4 — Boundaries

The whole subject is a boundary problem. Mount crossings: `RESOLVE_NO_XDEV`
in-kernel, `verify_same_mnt` in emulation, both reporting `EXDEV` so "any
failure looks like an `openat2(2)` failure". Filesystem type: `PROC_SUPER_MAGIC`
and `PROC_ROOT_INO`. Masked procfs: with `subset=pid` a global file may be
absent, so `open` on `ENOENT` retries through a temporary _unmasked_ handle
built for that call. Kernel fallback for the missing `statfsat`: none — "There
is no 'statfsat' so we can't check that the `f_type` is `PROC_SUPER_MAGIC`"
on the trailing magic link, and an attacker "can construct any magic-link
they like with procfs", so the check would not help anyway.

### Dimension 5 — Portability and fallback

Without `openat2`, [`resolvers/procfs.rs`][lp-procfs-resolver]'s
`opath_resolve` walks components with `openat(O_PATH|O_NOFOLLOW)`, checks the
mount id after each, and emulates `RESOLVE_NO_MAGICLINKS` by pattern: absolute
targets, and targets whose `:`/`[`/`]` characters spell `":[]"` (anon-inode
names such as `pipe:[123]`), are rejected with `ELOOP`. The comment
enumerates every stock procfs symlink as of Linux 6.17 to justify the
heuristic. Without `CAP_SYS_ADMIN` there is no detached procfs, and the docs
say so: "your security relies on you having privileges to be able to call
`fsopen(2)`" ([`procfs-api.md`][lp-procfs-api]). Without `STATX_MNT_ID` the
`fdinfo` `mnt_id` is "static and attacker-known", so an overmounted fake
`fdinfo` can hide a mount — the one rung with no fallback.

### Dimension 6 — Failure and partiality

Every mismatch is surfaced as an errno that mirrors the kernel's: `EXDEV` for
a foreign mount, `ELOOP` for a suspected magic link, `ENOENT` from a masked
procfs (retried unmasked once). A `readlink` through the handle returns a path
that "MUST NOT be used for actual filesystem operations because it's possible
for an attacker to move the file or change one of the path components to a
symlink" ([`procfs-api.md`][lp-procfs-api]) — diagnostics only. Once an fd is
obtained the mount table can no longer affect it, which is the assumption the
LPC deck asks the kernel to keep: "libpathrs is designed around re-opening
file descriptors in a context where we assume a handle is safe after we've
checked it" ([slides][lpc-pdf]).

### Dimension 7 — Enumeration and deletion

Does not apply, because nothing is enumerated or removed through procfs; the
handle exists to open or read one named file. Where procfs enters a
_tree-removal_ design is indirectly: the pre-`openat2` `opath` resolver's
`check_current` compares `readlink(/proc/self/fd/$n)` of the current
directory against the expected path and re-checks that "the root should not
have moved" ([`opath/imp.rs`][lp-opath]) — so any fallback walker that
deletes as it goes inherits this deep-dive's requirement of a trustworthy
`/proc`.

## Strengths

- **Names the second threat class** ("strict") and separates it from
  TOCTTOU, so a tool can decide which one it is defending against.
- **Detached procfs removes the race** rather than detecting it — for
  callers that can `fsopen`.
- **`subset=pid` handles are cacheable** and leak-safe by construction.
- Every check emits the same errno the kernel would, so callers need one
  error model across kernel versions.

## Weaknesses

- **True safety for magic links needs `CAP_SYS_ADMIN`**; unprivileged users
  get detection with races.
- **Benign overmounts (`lxcfs`) are indistinguishable from attacks** under
  `ProcRoot`.
- The magic-link heuristic in the fallback is a string pattern (`":[]"`) over
  `readlink` output.
- No `statfsat`, no `readlinkat2`, no `RESOLVE_EMPTY_PATH`: the kernel still
  lacks the primitives the LPC 2020 deck asked for, so re-opening an `O_PATH`
  fd remains a `/proc` operation.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                       | Trade-off                                                                            |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Refuse magic links as components; allow only trailing via `open_follow` | A magic link is an uncontrolled jump; a trailing one can still be mount-checked | `/proc/self/root/...` style paths are impossible                                     |
| Build a private procfs (`fsopen` → `open_tree`) before falling back     | Detached mount table cannot be raced                                            | Needs `CAP_SYS_ADMIN`; RHEL 8's broken new-mount-API backport forced a `>= 5.2` gate |
| Verify by mount id (`STATX_MNT_ID_UNIQUE`) not by path                  | Ids survive rename; unique ids survive recycling                                | Three fallbacks, the last (`fdinfo`) attacker-influenceable                          |
| Always imply `RESOLVE_NO_XDEV` for procfs opens                         | An overmount is exactly a mount crossing                                        | Breaks under benign `lxcfs` overmounts                                               |
| Retry `ENOENT` through an unmasked handle                               | `subset=pid` hides global files by design                                       | A second, uncached handle per miss                                                   |
| Emit kernel errnos from emulated checks                                 | One error model for callers                                                     | Emulated and real `EXDEV` are indistinguishable to the caller                        |

## Sources

- [`docs/procfs-api.md`][lp-procfs-api] — the three uses of `/proc`, the magic-link definition, the privilege caveat, the "unsafe path" warning
- [`docs/kernel-features.md`][lp-kernel-features] — the per-kernel feature/fallback ladder
- [`docs/avoidable-vulnerabilities.md`][lp-avoidable] — the "classic" vs "strict" CVE lists
- [`src/procfs.rs`][lp-procfs-rs] — `ProcfsHandle`, the constructor chain, `open`/`open_follow`, `verify_*`, the `lxcfs` and Linux 6.12 notes
- [`src/resolvers/procfs.rs`][lp-procfs-resolver] — `RESOLVE_BENEATH|NO_MAGICLINKS|NO_XDEV`, the `O_PATH` fallback and its magic-link heuristic
- [`src/resolvers/opath/imp.rs`][lp-opath] — `check_current` via `readlink(/proc/self/fd/$n)`
- [`src/utils/fd.rs`][lp-utils-fd] — `fetch_mnt_id` preference order
- [`2026/01-fosdem/path-safety-in-the-trenches.pdf`][fosdem-pdf] — the regular/strict split and the `openat2` recipe
- [`2020/08-LinuxPlumbers/openat2.pdf`][lpc-pdf] — the procfs gap and the three proposals
- [LWN 1050887][lwn-1050887] — the runc CVE-2025-31133 / CVE-2025-52565 mechanics and Sarai's conclusions

> [!NOTE]
> **Unverified.** Both slide decks were read via `pdftotext`; one LPC slide is
> garbled in extraction. The Linux 6.12 overmount-restriction series and the
> LWN 934460 procfs article are cited only through libpathrs's doc comment,
> not read directly. CVE details beyond what `procfs-api.md` and LWN 1050887
> state were not consulted.

<!-- References -->

[openat2]: ./linux-openat2.md
[lp-procfs-api]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/procfs-api.md
[lp-kernel-features]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/kernel-features.md
[lp-avoidable]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/docs/avoidable-vulnerabilities.md
[lp-procfs-rs]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/procfs.rs
[lp-procfs-resolver]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/procfs.rs
[lp-opath]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/resolvers/opath/imp.rs
[lp-utils-fd]: https://github.com/cyphar/libpathrs/blob/6acffea4cfbba1226aa33a8fcc98c500da8478b8/src/utils/fd.rs
[fosdem-pdf]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2026/01-fosdem/path-safety-in-the-trenches.pdf
[lpc-pdf]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2020/08-LinuxPlumbers/openat2.pdf
[lwn-1050887]: https://lwn.net/Articles/1050887/
