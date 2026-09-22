# Protecting Applications Against TOCTTOU Races by User-Space Caching of File Metadata

DynaRace — the "make the unmodified binary safe" answer: a transparent
name-to-inode cache and a four-state machine, woven in by binary translation,
that rewrites `access`/`open`/`stat` into an `openat`-based walk and terminates
the process when a file's identity changes under it.

|                 |                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------- |
| **Kind**        | Paper (defense)                                                                                                 |
| **Year**        | 2012                                                                                                            |
| **Authors**     | Mathias Payer, Thomas R. Gross (ETH Zurich)                                                                     |
| **Venue**       | VEE '12 (ACM SIGPLAN/SIGOPS Virtual Execution Environments)                                                     |
| **Language**    | C, on the `libdetox` dynamic binary translator                                                                  |
| **License**     | Open source (module of `libdetox`; the paper's `nebelwelt.net` link — see Unverified)                           |
| **Platforms**   | Linux (32-bit Ubuntu 10.04/10.10, Core i7)                                                                      |
| **Primitive**   | Per-process mapping cache `filename → (inode, device, parent)` + state machine, enforced via `openat`/`fstat64` |
| **Dimension 2** | Defense: deterministic identity enforcement between consecutive syscalls on the same name                       |
| **Source read** | `payer12-dynarace.pdf` (12pp.); canonical [PDF][payer-pdf]                                                      |

## Overview

### What it solves

The gap left by user-mode path resolution ([`tsafrir-2008`][tsafrir]): that
approach is "practical, portable" and deterministic, but "a programmer must
manually identify and modify all pairs of system calls that are vulnerable to
TOCTTOU races" (p.2). DynaRace removes the programmer from the loop — it
protects **unmodified applications and libraries** by intercepting every
file-based syscall and checking it against cached metadata. The abstract's
diagnosis (p.1):

> The mapping between filename and inode and device is volatile and can provide
> the necessary preconditions for an exploit. Applications use filenames as the
> primary attribute to identify files but the mapping between filenames and
> inode and device can be changed by an attacker.

And the paper's note on why the `*at` calls alone do not finish the job (p.1):

> If used properly the new system calls solve the problem of race conditions in
> the path to the final file atom, but they do not solve the problem of race
> conditions if the final file atom is a symbolic link.

### Design philosophy

Two ideas (§3, p.3): (i) a **chain of trust** of known directories from `/` to
the file's directory, built by opening each atom relative to the previous one,
so the `*at` calls can be used; and (ii) a **thread-local transparent mapping**
of file statistics for every accessed, opened, stated or modified file.
Equality of two files is "same inode number, device id, and parent directory
for existing files"; for non-existent files, "same parent directory and an error
code" (§3.1, p.3). The metadata of a file carries a pointer to its directory's
metadata — a file "is always verified alongside the directory that it is in."

Rather than enumerate vulnerable syscall _pairs_ (Wei & Pu's CUU model,
[`wei-pu-2005`][weipu]), which "misses the opportunity to detect race
conditions dynamically between any combination of system calls," DynaRace
tracks _all_ file syscalls through one state machine and so "provides complete
coverage" (§7.2, p.10).

## How it works

Each accessed file has a state; the transitions (Fig. 3 and §3.1, p.3-4) are:

| From      | On **test** (`access`, `stat*`) | On **use** (`open`, `creat`, `chmod`) | On **close** (`close`, `unlink`) |
| --------- | ------------------------------- | ------------------------------------- | -------------------------------- |
| `new`     | → `update` (insert metadata)    | → `enforce` (insert, then pin)        | —                                |
| `update`  | → `update` (refresh)            | → `enforce` (**check**)               | —                                |
| `enforce` | → `enforce` (**check**)         | → `enforce` (**check**)               | → `retire` when last fd closes   |
| `retire`  | → `update` (check and _warn_)   | → `enforce` (check and _warn_)        | —                                |

Syscalls are grouped: **test** (`access`, `stat*` — gather metadata, no
change), **use** (`open`, `creat`, `chmod` — modify the file or its metadata),
**close** (`close`, `unlink`, `unlinkat`). Transitions into `update` refresh the
cache; any transition into or within `enforce` _checks_ the cache and terminates
the application on mismatch; `retire` (all fds closed) drops the guarantee so
that ownership transfers such as **log rotation** keep working (§3.1, p.4) — a
retired file may be swapped by another process without a violation, and the next
`access` prints a warning rather than aborting.

File resolution (§3.2, p.4) mirrors Tsafrir's `chk_use`, but with `openat`:

1. Split the path into a directory path and a final atom; rewrite relative
   paths to absolute via `getcwd`.
2. **Directory authentication** (§4.2.1): recursively open each directory
   relative to its parent, comparing to (or inserting into) the cache; returns
   an open dirfd. Because it uses `openat`, "this setup removes the need to
   change the current working directory of the process … and allows DynaRace to
   support multiple concurrent threads" (p.5).
3. **File authentication** (§4.2.2): `openat(dirfd, atom)` + `fstat64`; cache
   hit → verify or update per state; miss → insert.
4. Handler-specific rewrite: `access` is reimplemented from the `stat64`
   result (there is no fd-based `access`); `open` with `O_CREAT` gets `O_EXCL`
   forced; **`O_TRUNC` is removed and the truncation delayed until after
   authentication** (p.6) — the same hygiene as [`chari-2010`][chari]'s
   `ftruncate`-after-check; `chmod` becomes `fchmod` on the verified fd.

Implementation choices (§5): binary translation (`libdetox`) over a kernel
module ("the risk of potentially exploitable code in the kernel is not worth
the advantage of the lower overhead"), over a patched libc (a third-party library
issuing raw syscalls "breaks the security of the race detection"), and over
`ptrace` (stop-per-syscall cost or code injection).

**Overhead** (§6.1, Table 3): microbenchmarks of 1M iterations — `access` 3.8×,
`open`/`close` 3.6×, a `access`+`creat`+`open` sequence 4.4× native. The
authors' framing: "around 3-4x (for raw system call performance)" on the
_metadata_ syscalls only, with "no overhead in the access to a file's data."
End-to-end on Apache 2.2 (Table 4): DynaRace adds roughly 6% over `libdetox`
alone (which itself costs 12-26% on PHP, −6 to −14% on static files due to
trace linearization).

Worked exploit: X.org CVE-2011-4029 (§6.4) — `open(O_CREAT|O_EXCL)` on
`/tmp/.tXn-lock`, `write`, then `chmod(tmp, 0444)` on the _name_; an attacker
who unlinks and relinks the lock between `write` and `chmod` gets any file made
world-readable. Under DynaRace the lock file is in `enforce` after the `open`,
so the `chmod` sees a metadata mismatch and the process dies.

### Dimension 1 — Threat model

An attacker with **user access, no root, no hardware access** (§2.1), racing a
privileged application to swap the file behind a name — hard-link swap
(`unlink`+`link`), symlink in the path or at the final atom, directory
rename+symlink (the Mazières `/tmp/x` garbage-collector race, Table 1), and
mazes (§7.4) are all in scope. **DoS is explicitly out of the attack model** —
DynaRace's response to a detected race is to terminate, which an attacker can
provoke at will. The protection runs at the application's own privilege level.

### Dimension 2 — Resolution primitive (the defense/attack mechanism and its atomicity claim)

A user-space **component walk over `openat` + `fstat64`**, backed by a cache
whose entries are checked on every subsequent syscall naming the same
path. The atomicity claim is **deterministic, not probabilistic**: "DynaRace
deterministically solves the problem of file-based race conditions for
unmodified applications" (p.1); "an attacker can change the files before the
permissions are checked but never between the permission check and the system
call that uses the checked file" (§6.3.1, p.9). What is atomic is the _pair_
`(check on fd/identity, use on the same fd)` — the walk itself is per-component,
and the guarantee is that identity mismatches are _detected_, not that they are
prevented.

### Dimension 3 — Symlink and `..` policy

Symlinks are the motivating case — a symlink at the final atom is exactly what
`openat` alone does not close — but the paper does not state an explicit
follow/refuse rule; safety comes from the identity check after `openat` rather
than from `O_NOFOLLOW`. `..` is not discussed; relative paths are normalized to
absolute via `getcwd` before the walk, which resolves `..` lexically in user
space.

### Dimension 4 — Boundaries

Device id is part of identity, so a bind-mount or cross-device swap changes the
cached `(inode, dev)` tuple and is caught as a mismatch. Mount crossings, procfs
and magic links are not otherwise addressed. The cache is per-process and
thread-local; the paper notes directories have only two states (accessible /
error).

### Dimension 5 — Portability and fallback

Linux-only in practice (i386, `fstat64`, `libdetox`), but the approach is
stated to coexist with applications already using `*at` calls, which "are
handled just like regular file-based system calls" (§4.3.4). There is no
fallback without `openat`: it is the enabling primitive (the `chk_use`
ancestor used `fchdir`). The prototype implements only `stat`, `access`,
`open`, `creat`, `chmod`, `close` — "emits a warning and terminates the
application if an unimplemented system call is used" (§4.1, p.5).

### Dimension 6 — Failure and partiality

Detection is a **process kill** with a race warning; there is no recovery and no
error return to the application. Two warning classes are logged: a file changed
by an external process (an attack that was stopped) and a file used without
prior validation (a protocol violation). The paper's own limitations section
(§8, p.11) is candid about what this breaks:

- **Concurrent directory modification**: if a process holds a file in `enforce`
  and another process moves or renames its parent directory, "the directory
  verification will fail and an error is thrown."
- **Two processes on one file**: both cannot hold it in `enforce`; the second
  is terminated on mismatch. "DynaRace limits the number of modifiers of each
  file to a single process."
- **Retirement of fd-less operations** (`chmod`, `chown`): no `close` ever
  signals disuse, so such files stay in `enforce` forever; a timer-based
  retirement is proposed but "opens a new window of opportunity for an attacker
  to delay the application until the timer runs out" (§8.1).
- **Log rotation** works only through the `retire` state, i.e. after the file
  is closed — the check on reopen warns rather than enforces.

### Dimension 7 — Enumeration and deletion

Does not apply, because DynaRace guards individual syscalls on named files; it
neither walks nor deletes trees. The `readdir`-based garbage-collector race in
Table 1 is presented as a _victim_, and the defense would catch the
`unlink("/tmp/x/passwd")` only if `/tmp/x` had been authenticated into the
directory cache by the preceding `lstat` — which is the mechanism, but the paper
does not evaluate a recursive delete.

## Strengths

- **Zero application changes** — the only surveyed defense that retrofits
  race safety onto binaries and their libraries alike.
- **Deterministic and `openat`-based**, hence thread-safe where `chk_use`'s
  `fchdir` was not; and the whole-syscall-set state machine catches pairs no
  static list enumerates.
- **Concrete hygiene** worth copying: force `O_EXCL` with `O_CREAT`; defer
  `O_TRUNC` to `ftruncate` after identity is confirmed; `chmod` → `fchmod` on
  the verified fd.

## Weaknesses

- **Terminate-on-mismatch** is a denial-of-service lever handed to the attacker,
  and the paper excludes DoS from its model rather than solving it.
- **Single-writer semantics**: legitimate concurrent access, directory renames
  by other processes, and log rotation all collide with `enforce`.
- **Cost and coverage**: 3-4× on metadata syscalls, a six-syscall prototype,
  and a binary-translation dependency (`libdetox`) that is itself a large
  trusted component.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                         | Trade-off                                                                     |
| ---------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Cache identity `(inode, dev, parent)` per name | Volatile name→inode mapping is the root cause; pin it per process | Inode reuse across filesystems weakens identity (see [`raducu-2022`][raducu]) |
| Four-state machine over _all_ file syscalls    | Complete pair coverage without a pre-enumerated list              | Files in `enforce` block legitimate concurrent modification                   |
| `retire` state on last `close`                 | Lets log rotation and ownership transfer work                     | fd-less `use` calls never retire; timer fix reopens a race                    |
| Binary translation, not kernel or libc         | No kernel attack surface; catches raw syscalls from any library   | 3-4× metadata-syscall overhead; `libdetox` in the TCB                         |
| Kill the process on mismatch                   | Deterministic, no partial state                                   | Attacker-triggerable DoS, excluded from the model                             |

## Sources

- [`payer12-dynarace.pdf`][payer-pdf] — attack model and background (§2,
  p.2); states and file resolution (§3, p.3-4); directory/file authentication
  and syscall handlers (§4, p.5-6); implementation alternatives (§5, p.6-7);
  overhead and Apache study (§6.1-6.2, p.7-8); usage scenarios and X.org CVE
  (§6.3-6.4, p.8-9); related work incl. mazes and hardness amplification
  (§7, p.9-10); limitations (§8, p.11).

> [!NOTE]
> **Unverified.** The paper gives the source location as
> `http://nebelwelt.net/projects/libdetox` (p.5, p.11); [`raducu-2022`][raducu]
> marks the DynaRace artifact as "no longer available" (its Table 3, entry
> `[45]`, dagger footnote). Neither URL was fetched for this deep-dive.

<!-- References -->

[payer-pdf]: https://hexhive.epfl.ch/publications/files/12VEE.pdf
[tsafrir]: ./tsafrir-2008.md
[weipu]: ./wei-pu-2005.md
[chari]: ./chari-2010.md
[raducu]: ./raducu-2022.md
