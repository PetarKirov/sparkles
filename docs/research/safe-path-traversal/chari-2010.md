# Where Do You Want to Go Today? Escalating Privileges by Pathname Manipulation

The `safe_open` paper — a user-space, per-component `openat`/`fstat` resolver
whose security property survives races, because it is a property of _who could
have written the directories_, not of _when_ the checks ran.

|                 |                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------ |
| **Kind**        | Paper (defense)                                                                                        |
| **Year**        | 2010                                                                                                   |
| **Authors**     | Suresh Chari, Shai Halevi, Wietse Venema (IBM T.J. Watson Research Center)                             |
| **Venue**       | NDSS 2010                                                                                              |
| **Language**    | C (in-process `LD_PRELOAD` monitor, ~2000 lines)                                                       |
| **Platforms**   | Fedora Core 11, Ubuntu 9.04, FreeBSD 7.2, Debian 5.0, Solaris                                          |
| **Primitive**   | User-level pathname resolution over `openat`/`fstatat`/`readlinkat` with a per-directory _safety_ flag |
| **Dimension 2** | Defense: a safety invariant enforced per component, robust to races by non-adversarial parties only    |
| **Source read** | `chari10-safe-open.pdf` (16pp.); canonical [PDF][chari-pdf]                                            |

## Overview

### What it solves

Filename-based privilege escalation: an attacker who can write in some directory
along a path plants a symlink or hard link so that a privileged program opens a
file it never meant to — `/var/mail/root → /etc/passwd`, or the Solaris 10
`inetd` debug log under world-writable `/var/tmp` (CVE-2008-1684). The paper's
position is that per-application defenses are the wrong layer (p.1):

> We believe, however, that the application is fundamentally the wrong place to
> implement these safety mechanisms.

Instead it proposes a **library or filesystem-level** `safe-open` with one
provable guarantee (p.2-3):

> If a file has safe names for user U, then safe-open will not open it for U
> using an unsafe name.

Unlike the race-focused literature ([`dean-hu-2004-borisov-2005`][deanhu],
[`tsafrir-2008`][tsafrir], [`cai-2009`][cai]), the paper is explicit that it
does _not_ try to prevent races: "we modify the name-resolution procedure to
ensure that privilege-escalation cannot happen even if an attacker is able to
induce race conditions" (p.2).

### Design philosophy

The core concept is the **manipulators** of a name (p.4):

> In the context of POSIX systems, a manipulator of a path in a POSIX
> filesystem is any uid that has write permission in — or ownership of — any
> directory that is visited during resolution of that path.

From that: a name is **system-safe** if root is its only manipulator; **safe for
uid** if its only manipulators are root and that uid; otherwise **unsafe**. Ownership
counts as manipulation because an owner can `chmod` the directory; this also
gives the dynamic argument its teeth — "only manipulators of a path can add new
manipulators to it, and no manipulator can remove itself from the set of
manipulators of a path" (p.4), because only root can `chown`.

The procedure (p.6) is then a single flag threaded through a component walk:

> As long as the resolver only visits safe directories, we are in a safe mode,
> can follow symbolic links or `..`, and can open files with multiple hard links.
> However, once the resolver visits an unsafe directory, we switch to unsafe mode,
> and in the remainder of the path, disallow symbolic links or `..`, and refuse
> to open a file with multiple hard links.

It is a refinement of Postfix's `/var/mail` rule (never open a symlink or a
multi-link file), which the authors judge "too strict" (legitimate multi-link
files; trivial DoS by adding a hard link) _and_ "not strict enough" (an attacker
can symlink a _higher_ directory, `/tmp/amanda → /etc`).

## How it works

### The algorithm

The pseudo-code from Appendix B, Figs. 1-2 (p.15), lightly condensed and with
names kept verbatim. `lstatat` is the paper's alias for
`fstatat(…, AT_SYMLINK_NOFOLLOW)`.

```c
/* Resolve pathname, invoke action on final component */
safe_lookup(dirhandle, path, is_safe_wd, lookup_flags, action_func, action_args)
{
    if (path is empty) return ENOENT;
    if (path is absolute) {
        dirhandle = open("/", O_RDONLY) or return error;
        fst = result of lstat("/") or return error;
        skip leading "/" in path, and replace path by "." if the result is empty;
    } else
        fst = result of fstat(dirhandle) or return error;
    while (true) {
        /* check dirhandle permissions */
        if (fst.owner not in [root, euid]
            || anyone not in [root, euid] can write)
            is_safe_wd = false;

        split path into first and suffix, and replace all-slashes suffix by ".";
        lst = result of lstatat(dirhandle, first) or return error;

        if (first component is final pathname component)
            return action_func(dirhandle, first, is_safe_wd, action_args);

        if (first component is a symlink) {
            newpath = readlinkat(dirhandle, first) or return error;
            check dirhandle permissions again, and return EACCES if unsafe;
            if (suffix == null)              /* symlink at end of pathname */
                return safe_lookup(dirhandle, newpath, is_safe_wd, lookup_flags,
                                   action_func, action_args);
            [newhandle, fst] = safe_lookup(dirhandle, newpath, is_safe_wd,
                                           lookup_flags, null, null) or return error;
        } else {
            newhandle = openat(dirhandle, first, O_RDONLY) or return error;
            check dirhandle permissions again, and update is_safe_wd if unsafe;
            if (!is_safe_wd && name is "..") return EACCES;
            fst = result of fstat(newhandle) or return error;
            if (first component is not a directory) return ENOTDIR;
            lst = result of lstatat(dirhandle, first) or return error;
            if (lst does not match fst) return EACCES;
            if (suffix == null) return [newhandle, fst];  /* end of readlinkat result */
        }
        path = suffix;
        dirhandle = newhandle;
    }
}

/* Call-back to open the final pathname component */
open_action_func(dirhandle, name, is_safe_wd, open_flags)
{
    truncate = (open_flags & O_TRUNC);
    flags = (open_flags & ~O_TRUNC);
    filehandle = openat(dirhandle, name, flags) or return error;
    fst = fstat(filehandle) or return error;
    lst = lstatat(dirhandle, name) or return error;
    if (fst and lst don't match) return EACCESS;
    check dirhandle permissions again, and update is_safe_wd if unsafe;
    if (!is_safe_wd && name is "..") return EACCES;
    if (!is_safe_wd && fst is not a directory && fst has multiple hard links)
        return EACCES;
    if (truncate) ftruncate(filehandle, 0) or return error;
    return filehandle;
}
```

Four things to notice, all load-bearing for a dirfd module:

1. **Every step is relative to the previous handle** (`openat`, `lstatat`,
   `readlinkat` on `dirhandle`), never to a re-resolved string.
2. **Symlinks are never opened**: the component is `lstatat`-ed first, and a
   symlink's target text is fed back through `safe_lookup` _from the current
   handle_ — an absolute target restarts at `/` with `is_safe_wd` reset only by
   what `/` itself looks like.
3. **The `lstat-open-fstat-lstat` pattern** substitutes for `O_NOFOLLOW` where it
   is unavailable: after `openat`, `fstat` of the new handle is compared to
   `lstatat` of the name, and a mismatch is `EACCES` (§4.1, p.8).
4. **Directory permissions are re-checked after every use** ("check dirhandle
   permissions again"), narrowing the only check/use window the authors
   acknowledge.

Side-effect hygiene at the leaf (§4.4, p.9): `O_TRUNC` is stripped and replaced
by `ftruncate` _after_ the identity check, so an unexpected target is never
truncated; and because opening a FIFO or tty could block forever, the
application must supply `O_NONBLOCK` itself.

### The proof, in one paragraph

Consider a file with both a safe and an unsafe name (§3, p.6-7). If it has more
than one hard link, resolving the unsafe name arrives at the final directory in
unsafe mode and the multi-link refusal fires. If it has exactly one, its
"canonical path" `/dir1/…/dirn/foo` consists entirely of safe directories, and
the unsafe name must visit some unsafe directory off that path; to rejoin it,
the resolver would have to follow a symlink or `..` while unsafe — which it
refuses. The dynamic-permission extension (§3.2) shows the same holds while an
attacker (a different, non-root euid) changes permissions arbitrarily, provided
neither root nor the victim's uid concurrently modifies any examined element.

### Dimension 1 — Threat model

Adversary: a local **non-root user with a different euid than the victim**, who
can create hard links, symlinks, or rename/move entries in any directory they
can write or own — including moving _other users'_ files into sticky `/tmp`
(footnote 4). Attacks in scope: symlink to a file or a _directory_ higher up,
hard-link aliasing, `..` climbing out of an unsafe subtree, and all of these
under concurrent permission changes. **Explicitly out of scope**: same-euid
adversaries ("virtually impossible" to protect against in POSIX, §6.3), group-
privilege escalation between processes of one uid, races induced by root or the
victim uid itself, and denial of service.

### Dimension 2 — Resolution primitive (the defense/attack mechanism and its atomicity claim)

User-level, **per-component** resolution over the POSIX `*at` family. The
atomicity claim is deliberately modest: the resolver "is not particularly
vulnerable to filesystem-based adversarial race conditions, in that it would
correctly label safe/unsafe directories regardless of concurrent actions of any
attacker (as long as the euid of the attacker is neither root nor the victim's
euid)" (§4.1, p.8). Only two check/use windows exist: (A) never opening a symlink
— closed by `O_NOFOLLOW` or the `lstat-open-fstat-lstat` pattern; and (B)
between checking a directory's permissions and using it — open only to races by
_non-adversarial_ processes, since an adversary cannot change permissions on a
directory it does not manipulate. The property is therefore **race-tolerant by
construction**, not race-free by timing — the opposite design bet from
[`tsafrir-2008`][tsafrir], and the one [`cai-2009`][cai] later vindicated.

### Dimension 3 — Symlink and `..` policy

Mode-dependent. In **safe** mode symlinks (relative or absolute) and `..` are
followed — via `readlinkat` and recursive `safe_lookup`, never by the kernel.
In **unsafe** mode both are refused with `EACCES`, as is opening a non-directory
with `st_nlink > 1`. `..` is handled in user space and only ever as a name
looked up relative to the current `dirhandle`. Section 6.1 offers a **more
permissive** two-flag variant: a _sticky_ unsafe flag plus a _resettable_ one
that returns to safe whenever an absolute symlink restarts at `/` (or after any
`..`); the final open is refused only if the sticky flag is unsafe and the file
is multi-linked, or if the two flags disagree — which preserves the guarantee
while allowing the symlink-heavy web tree that broke the strict version (§5.5).

### Dimension 4 — Boundaries

Mount points are the acknowledged hole: the guarantee holds "as long as all the
mount points are system-safe," but "breaks if we have the same filesystem
mounted in several directories, some safe and others not" — bind/loopback
mounts and NFS exports let a file have a safe name the resolver cannot see from
its unsafe one (§3, p.6). Directory hard links are assumed absent (footnote 9:
MacOS is the "notable exception"). procfs magic links, `st_dev` checks and
Windows semantics are not treated. Group permissions are handled coarsely — any
group-write makes a directory unsafe for everyone (§6.3) — and the authors note
this lets an administrator _disable_ the protection for a subtree by making its
root root-group-writable.

### Dimension 5 — Portability and fallback

Written against POSIX.1-2008 `openat`/`readlinkat`/`fstatat`. Without them, the
paper emulates with a synchronized `fchdir` to the current handle and back,
with signals suspended (§4.2) — which is neither thread-safe nor cheap, and is
the historical reason the `*at` calls exist. Two further portability costs:
each intermediate directory is opened `O_RDONLY`, so the caller needs **read**
permission on every non-final component, not just search (`O_SEARCH` would fix
this, §4.3); and `safe-rename`/`safe-link` "can be problematic" without
`renameat`/`linkat`, since a process has one cwd. The prototype only checks
absolute and cwd-relative paths; per-handle safety state for arbitrary
`openat` dirfds is designed (Appendix A: a "safe for" uid per handle,
propagated across `dup`/`fork`/IPC) but not implemented.

### Dimension 6 — Failure and partiality

Every refusal is `EACCES` (or the underlying `errno`), and — because every
component is opened `O_RDONLY` and the leaf is opened without `O_TRUNC` — a
refusal leaves no side effect other than an fd that is closed. The `O_TRUNC`
deferral is the concrete instance: truncation happens only after the fd's
identity is confirmed. Rename races during the walk by an adversary are
harmless to the _guarantee_ (they cannot make an unsafe directory safe);
rename races by root/victim are the residual window. The paper's own
whole-system measurement found a "surprisingly small number" of policy
violations — FreeBSD `man` (pages owned by user `man`), the FreeBSD package
manager following `..` when removing a temp tree, Fedora's group-writable
`/var/lib/gdm` — and uncovered latent root-writes-in-unprivileged-dir bugs in
CUPS, MySQL, HAL, Tomcat, `lockdev`, XAMPP (§5.3).

### Dimension 7 — Enumeration and deletion

Does not apply as a walker, because the paper resolves one pathname per call.
It does, however, generalize the leaf action: `safe-create` (`O_CREAT|O_EXCL`
on the final handle), `safe-unlink`, `safe-mkdir`, `safe-chmod`, with the note
that primitives which do not follow a final symlink (`unlink`, `mkdir`) "must of
course behave accordingly" (§4.5, p.9). The FreeBSD package manager's `..`
warnings during recursive temp-tree removal are the one place enumeration shows
up — and the two-flag variant is the proposed fix.

## Strengths

- **A stated, proved property** that is independent of timing — the only
  defense in this catalog whose correctness argument does not mention the
  scheduler.
- **The per-component `openat` walk written down**, with the exact identity
  check (`fstat` vs `lstatat`) and the `O_TRUNC` deferral — a direct template for
  a dirfd module's fallback path.
- **Whole-system evidence**: run as a shim under three OSes' boot, desktop and
  server workloads, it found almost nothing legitimate it would break, and
  several real latent vulnerabilities.

## Weaknesses

- **Trust is by uid, not by handle.** "Safe for U" collapses when the victim
  and attacker share a uid (containers, setgid helpers), and the group-write
  rule is all-or-nothing.
- **Multi-mount blindness** — bind mounts and NFS break the proof; a modern
  resolver needs `st_dev`/`RESOLVE_NO_XDEV`-style boundaries the paper lacks.
- **Read permission on every component** and a user-space symlink re-walk make
  it heavier than the kernel's own lookup; the kernel implementation the authors
  say is "preferable" is what [`linux-openat2`][openat2] eventually became.
- **dirfd-relative resolution unimplemented** in the prototype — the case a
  directory-handle module cares about most.

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                               | Trade-off                                                                                 |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Define safety by _manipulators_ (owner ∪ writers), not by symlink presence | Captures higher-directory attacks Postfix's rule misses; monotone under attacker action | Ownership counts as manipulation, so legitimately owner-run trees (FreeBSD `man`) trip it |
| Prove a guarantee that tolerates races rather than prevents them           | Escapes the probabilistic arms race of k-race                                           | Root/victim-uid concurrent `chmod` remains an unproved window                             |
| Refuse symlinks, `..`, multi-link files only _after_ going unsafe          | Safe names keep full POSIX semantics; strict rule reserved for hostile subtrees         | Still too strict for symlink-rich shared trees — hence the two-flag variant               |
| Strip `O_TRUNC`, `ftruncate` after identity check                          | Never truncate a file you have not yet identified                                       | Two syscalls where `open` did one                                                         |
| Open intermediates `O_RDONLY` for `fstat`/`openat`                         | Portable in 2010; identity via `fstat`                                                  | Requires read, not just search, on every directory until `O_SEARCH`                       |

## Sources

- [`chari10-safe-open.pdf`][chari-pdf] — manipulators and safe names (§2.1,
  p.4); the basic procedure (§2.2, p.6); the security guarantee and proofs
  (§3, p.6-8); race windows, thread safety, read permission, `O_TRUNC` (§4,
  p.8-9); experimental validation and latent vulnerabilities (§5, p.9-11);
  permissive two-flag variant and group discussion (§6, p.11-13); relative
  paths / per-handle safety (Appendix A, p.14); pseudo-code (Appendix B,
  p.15); in-process monitor (Appendix C, p.16).

<!-- References -->

[chari-pdf]: http://ftp.porcupine.org/pub/security/ndss-2010.pdf
[deanhu]: ./dean-hu-2004-borisov-2005.md
[tsafrir]: ./tsafrir-2008.md
[cai]: ./cai-2009.md
[openat2]: ./linux-openat2.md
