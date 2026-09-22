# gnulib `fts` (C)

The BSD file-tree walker rebuilt by coreutils around a _virtual_ working
directory — a ring of `openat`-relative directory fds instead of `chdir` — so
that `rm -r`, `chmod -R`, `chown -R` and `du` never leave the process's cwd,
never trust a path they built, and re-verify by `dev`/`ino` whenever a name
could have been swapped out from under them.

|                           |                                                                                                                                                                                                                                                                                                                                     |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**                  | library (gnulib module `fts`, consumed by coreutils)                                                                                                                                                                                                                                                                                |
| **Year**                  | BSD `fts` 1990–1994; gnulib fork 2004; `FTS_CWDFD` + `openat` emulation 2005–2006                                                                                                                                                                                                                                                   |
| **Authors / Maintainers** | Berkeley CSRG (original); Jim Meyering, Paul Eggert (gnulib)                                                                                                                                                                                                                                                                        |
| **Language**              | C                                                                                                                                                                                                                                                                                                                                   |
| **License**               | LGPL-2.1-or-later (`fts.c`, `fts-cycle.c`, `cycle-check.c`); GPL-3.0-or-later (`openat.c`, `openat-proc.c`, `chdir-long.c`, `save-cwd.c`)                                                                                                                                                                                           |
| **Repository**            | [`coreutils/gnulib`][gnulib-tree]; consumer [`coreutils/coreutils` `src/remove.c`][remove-c]                                                                                                                                                                                                                                        |
| **Platforms**             | POSIX; `FTS_CWDFD` degrades to `FTS_NOCHDIR` where `openat` is neither native nor emulable                                                                                                                                                                                                                                          |
| **Primitive**             | `openat(dirfd, name, O_DIRECTORY \| O_NOFOLLOW \| …)` + `fstatat(AT_SYMLINK_NOFOLLOW)` + `unlinkat`, with `fstat` `dev`/`ino` re-check on every `..` ascent                                                                                                                                                                         |
| **Source read**           | [`lib/fts.c`][fts-c], [`lib/fts.in.h`][fts-h], [`lib/fts-cycle.c`][fts-cycle-c], [`lib/cycle-check.c`][cycle-check-c], [`lib/openat.c`][openat-c], [`lib/openat-proc.c`][openat-proc-c], [`lib/openat-priv.h`][openat-priv-h], [`lib/opendirat.c`][opendirat-c], [`lib/chdir-long.c`][chdir-long-c], [`lib/save-cwd.c`][save-cwd-c] |

## Overview

### What it solves

Recursive file operations in coreutils. `rm -r` in particular must delete an
arbitrarily deep tree while an unprivileged user who owns part of it may be
renaming directories, replacing them with symlinks, or racing the tool toward
a file outside the tree. The header states the two properties the flag buys
([`lib/fts.in.h`][fts-h]):

> Use this flag to enable semantics with which the parent application may be
> made both more efficient and more robust. Whereas the default is to visit
> each directory in a recursive traversal (via chdir), using this flag makes it
> so the initial working directory is never changed. Instead, these functions
> perform the traversal via a virtual working directory, maintained through the
> file descriptor member, fts_cwd_fd.

coreutils' `rm` opens its walk exactly that way ([`src/remove.c`][remove-c]):

```c
int bit_flags = (FTS_CWDFD | FTS_NOSTAT | FTS_PHYSICAL);
if (x->one_file_system)
  bit_flags |= FTS_XDEV;
FTS *fts = xfts_open (file, bit_flags, NULL);
```

and removes through the same fd — `unlinkat (fts->fts_cwd_fd, ent->fts_accpath, flag)`
with `flag = is_dir ? AT_REMOVEDIR : 0` — so no absolute path is ever
re-resolved between the walk and the unlink.

### Design philosophy

The one function that moves the walker between directories carries the whole
threat model in its comment ([`lib/fts.c`][fts-c], `fts_safe_changedir`):

> Change to dir specified by fd or file name without getting tricked by someone
> changing the world out from underneath us. Assumes p->fts_statp->st_dev and
> p->fts_statp->st_ino are filled in.

The strategy is: (1) never resolve more than one component per syscall, from
an fd you already hold; (2) refuse symlinks at the open (`O_NOFOLLOW`) where
the kernel can, and (3) where it cannot — the name `..`, logical walks, hosts
without a working `O_NOFOLLOW` — compare the opened fd's `dev`/`ino` against
the `stat` taken earlier and fail with a deliberately uninformative `ENOENT`
("disinformation", the code says). The original BSD rationale for holding a
root fd survives unchanged in `fts_open`: "Slashes, symbolic links, and `..`
are all fairly nasty problems."

## How it works

`fts_open` validates flags (`FTS_NOCHDIR` and `FTS_CWDFD` are mutually
exclusive; `FTS_LOGICAL` forces `FTS_NOCHDIR` and clears `FTS_CWDFD` — "symbolic
links are too hard"), then initialises `fts_cwd_fd = AT_FDCWD` and an
`I_ring` of parent fds ([`lib/fts.c`][fts-c]):

```c
sp->fts_cwd_fd = AT_FDCWD;
if ( ISSET(FTS_CWDFD) && ! HAVE_OPENAT_SUPPORT
     && openat_needs_fchdir ())
  {
    SET(FTS_NOCHDIR);
    CLR(FTS_CWDFD);
  }
…
i_ring_init (&sp->fts_fd_ring, -1);
```

Every directory open goes through `diropen` / `fts_opendir`, both of which
are `openat` relative to the virtual cwd with the flags spelled out:

```c
int open_flags = (O_SEARCH | O_CLOEXEC | O_DIRECTORY | O_NOCTTY | O_NONBLOCK
                  | (ISSET (FTS_PHYSICAL) ? O_NOFOLLOW : 0));

int fd = (ISSET (FTS_CWDFD)
          ? openat (sp->fts_cwd_fd, dir, open_flags)
          : open (dir, open_flags));
```

`fts_build` opens the child directory with `opendirat` (an `openat` +
`fdopendir` pair, [`lib/opendirat.c`][opendirat-c]), then — because the `DIR*`
will be closed while the fd must outlive it — duplicates the fd above
`STDERR_FILENO` and "descends" by handing it to `fts_safe_changedir`:

```c
if (ISSET(FTS_CWDFD))
  dir_fd = fcntl (dir_fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
if (dir_fd < 0 || fts_safe_changedir(sp, cur, dir_fd, NULL)) {
```

Descending pushes the old `fts_cwd_fd` onto the ring (`cwd_advance_fd`, which
closes whichever fd the fixed-size ring displaces); ascending pops it back,
skipping both the `openat("..")` and the `fstat` comparison:

```c
if (fd < 0 && is_dotdot && ISSET (FTS_CWDFD))
  {
    /* When possible, skip the diropen and subsequent fstat+dev/ino
       comparison.  I.e., when changing to parent directory
       (chdir ("..")), use a file descriptor from the ring and
       save the overhead of diropen+fstat, as well as avoiding
       failure when we lack "x" access to the virtual cwd.  */
```

When the ring has already evicted the parent (the tree is deeper than the ring
is long), `..` is opened by name and re-verified:

```c
if (ISSET(FTS_LOGICAL) || ! HAVE_WORKING_O_NOFOLLOW
    || (dir && streq (dir, "..")))
  {
    struct stat sb;
    if (fstat(newfd, &sb)) { ret = -1; goto bail; }
    if (p->fts_statp->st_dev != sb.st_dev
        || p->fts_statp->st_ino != sb.st_ino)
      {
        __set_errno (ENOENT);           /* disinformation */
        ret = -1;
        goto bail;
      }
  }
```

All per-entry `stat`s are `fstatat (sp->fts_cwd_fd, p->fts_accpath, sbp, flags)`
with `AT_SYMLINK_NOFOLLOW` unless the walk is logical (`fts_stat`). Under
`FTS_CWDFD`, `fts_accpath` is the bare entry name, never a joined path.

### Dimension 1 — Threat model

In scope: a directory replaced by a symlink between `readdir` and descent
(`O_NOFOLLOW` on the open); the parent renamed or swapped while the walker is
below it (the `..` `dev`/`ino` check, or no `..` at all via the fd ring);
directory cycles from hard links, corrupt filesystems, or `-L` symlink loops
(`fts-cycle.c`); a directory deleted while its `DIR*` is open (`ENOENT` from
`readdir` — the comment notes glibc before 2.3 did not absorb it); mount
crossing (`FTS_XDEV` / `FTS_MOUNT`); and pathological breadth (a
`FTS_MAX_READDIR_ENTRIES` = 100000 batch cap, because 4,000,000 entries "requires
~1GiB of memory"). The adversary is an unprivileged local user who owns part
of the tree `root` is operating on. Out of scope: the top-level argument
itself (a command-line symlink is followed only with `FTS_COMFOLLOW`, and the
first component is opened by a full path), and anything the kernel resolves
inside one `openat` call.

### Dimension 2 — Resolution primitive

`openat(dirfd, single_name, O_DIRECTORY | O_NOFOLLOW | O_SEARCH | O_CLOEXEC | O_NOCTTY | O_NONBLOCK)`,
one component per call; `fstatat(dirfd, name, AT_SYMLINK_NOFOLLOW)`;
`unlinkat(dirfd, name, AT_REMOVEDIR?)` in the consumer. Atomicity claimed:
per component, plus a post-open identity check for the one component
(`..`) whose name can legally change meaning. There is no whole-path
atomicity and none is needed — no whole path exists in `FTS_CWDFD` mode.

### Dimension 3 — Symlink and `..` policy

`FTS_PHYSICAL` (what `rm`, `chmod -R`, `chown -R` use) never follows a
symlink below the root: `O_NOFOLLOW` at the open and `AT_SYMLINK_NOFOLLOW` at
the stat. `FTS_LOGICAL` (`chown -L`) follows everything, disables the
fd-relative mode entirely, and switches cycle detection to the "tight" hash
table. `..` is never rejected — it _is_ the ascent — but it is preferentially
replaced by a popped fd, and when opened by name it is verified against the
parent's recorded `dev`/`ino`. `FTS_SEEDOT` merely reports `.`/`..` entries;
`ISDOT` entries are otherwise skipped in `fts_build`.

### Dimension 4 — Boundaries

`FTS_XDEV` does a post-order visit without descending when `st_dev` differs
from the root's `fts_dev`; `FTS_MOUNT` skips such entries outright. Both
compare `st_dev` from the deferred `fstatat`, so a bind mount that appears
_after_ the parent was stat'ed is caught at the child. `fts_build` re-`fstat`s
a directory right after opening it "to reveal eventual changes caused by a
submount triggered by the traversal" — but only under `FTS_TIGHT_CYCLE_CHECK`,
i.e. for `find` and `du`, not `rm`. procfs is special-cased only for
performance (`S_MAGIC_PROC` disables the `st_nlink` leaf optimisation, citing
Debian bug 143111). No magic-link, ADS, or reparse-point awareness — this is
POSIX-only code.

### Dimension 5 — Portability and fallback

Three tiers, decided at `fts_open`:

| Host capability                                  | Mode                      | What is lost                                                        |
| ------------------------------------------------ | ------------------------- | ------------------------------------------------------------------- |
| native `openat`                                  | `FTS_CWDFD`               | nothing                                                             |
| no `openat`, but `/proc/self/fd/N/name` resolves | `FTS_CWDFD` via emulation | each `openat` costs an `open` of a synthesised `/proc` path         |
| neither (`openat_needs_fchdir()` true)           | forced `FTS_NOCHDIR`      | fd-relative safety; full relative paths are rebuilt and re-resolved |

The emulation is `openat_permissive` in [`lib/openat.c`][openat-c]: build
`"/proc/self/fd/%d/"` + name ([`lib/openat-proc.c`][openat-proc-c], which first
probes that `/proc/self/fd/N/../fd` resolves correctly because "Solaris 10
/proc/self/fd mishandles `..`"), `open` it, and only on an `EXPECTED_ERRNO`
(`ENOTDIR`, `ENOENT`, `EPERM`, `EACCES`, `ENOSYS`, `EOPNOTSUPP`) fall through to
`save_cwd` → `fchdir(fd)` → `open(file)` → `restore_cwd`. `save_cwd`
([`lib/save-cwd.c`][save-cwd-c]) prefers an `open(".", O_SEARCH)` fd and falls
back to `getcwd`; a failed restore is fatal (`openat_restore_fail`) because
the process is now in an unknown directory. `chdir_long`
([`lib/chdir-long.c`][chdir-long-c]) exists for the same era: it splits a
longer-than-`PATH_MAX` name into `openat`-advanced chunks so a deep tree can be
re-entered at all. Where `O_NOFOLLOW` is absent or broken
(`HAVE_WORKING_O_NOFOLLOW` false), every descent pays the `fstat` identity check
instead.

### Dimension 6 — Failure and partiality

Per-node: `fts_info` carries `FTS_DNR` (unreadable), `FTS_NS` (stat failed),
`FTS_ERR` (with `fts_errno`), `FTS_DC` (cycle). A failed descent sets
`FTS_DONTCHDIR` and rewrites the children's `fts_accpath` to the parent's so
the names still come out right; the error surfaces at the post-order visit.
`readdir` errors mid-directory become `FTS_ERR` if some entries were read,
`FTS_DNR` otherwise. Global: `FTS_STOP` after a failed ascent or `ENOMEM`, and
`fts_read` then returns `NULL` with `errno` set (0 on clean EOF). State left
behind: the initial cwd is untouched in `FTS_CWDFD` mode by construction;
`fts_close` closes the virtual cwd and drains the ring. In the consumer,
`excise` maps `EROFS` on a now-missing file to `ENOENT` and treats
`ignorable_missing` as `RM_OK`, so a directory removed by someone else mid-walk
is not an error ([`src/remove.c`][remove-c]).

### Dimension 7 — Enumeration and deletion

`fts_build` reads one directory from an fd (`opendirat`), records `d_ino` and
`d_type` per entry (deferring `stat` under `FTS_DEFER_STAT`/`FTS_NOSTAT`, and
skipping it entirely when `d_type` proves the entry is not a directory), sorts
by inode above 10000 entries on filesystems where that helps, and batches at
100000 entries — leaving `fts_dirp` open so `fts_read` can resume. Depth is
bounded only by memory; the fd cost is O(ring size), not O(depth), because the
ring evicts and the ascent re-opens `..` with a `dev`/`ino` check. Cycle
detection ([`lib/fts-cycle.c`][fts-cycle-c]) is either the tight per-active-dir
`dev`/`ino` hash (`FTS_TIGHT_CYCLE_CHECK`, required for `du`, forced for
`FTS_LOGICAL`) or the constant-memory lazy check
([`lib/cycle-check.c`][cycle-check-c]): record the `dev`/`ino` at every
power-of-two descent count and compare on every descent — "some of the
directories in the cycle may be processed twice before the cycle is
detected", which the header says is acceptable for `chown -R` but not `du`.
Deletion is the consumer's job; `rm` does `unlinkat(fts_cwd_fd, name)` on
every non-directory in pre-order and on the directory itself at `FTS_DP`.

## Strengths

- **cwd is never changed**, so the walker is safe in multi-threaded and
  library contexts and cannot strand the process in a deleted directory.
- **No path is rebuilt** under `FTS_CWDFD`; every operation is `(dirfd, name)`.
- **`..` is either an fd pop or a verified open** — the only historically
  exploitable ascent is closed both cheaply and correctly.
- **Graceful degradation is explicit** (`openat_needs_fchdir`, `HAVE_WORKING_O_NOFOLLOW`),
  not silent.
- The lazy cycle check costs O(1) memory and still terminates.

## Weaknesses

- **`..` by name is still a name.** After ring eviction the parent is re-opened
  by `openat(cwd, "..")` and compared — a mount or bind that changed what `..`
  means is detected, not prevented. The catalog's `openat2` subjects
  ([`linux-openat2.md`][openat2]) avoid the ascent altogether.
- **No defence inside a single component**: a name that is a symlink to a
  directory is refused by `O_NOFOLLOW`, but nothing checks for a bind mount
  swapped in at the same name — `FTS_XDEV` is opt-in (`rm --one-file-system`).
- **Lazy cycle detection revisits directories** before detecting the cycle,
  by design.
- The `/proc/self/fd` emulation is a full-path `open` and therefore inherits
  every race the design otherwise avoids; it is a fallback, not a peer.
- POSIX-only: no junction, reparse-point, or magic-link vocabulary
  ([`windows-nt.md`][windows], [`linux-procfs-magic-links.md`][magic]).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                       | Trade-off                                                             |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Virtual cwd fd (`FTS_CWDFD`) instead of `fchdir`                 | Process cwd untouched; robust and (per the header) more efficient                               | A ring of open fds; consumers must be rewritten to `*at` calls        |
| Bounded fd ring with `..` re-open on eviction                    | O(1) fds regardless of depth                                                                    | Deep trees pay `openat("..")` + `fstat` per ascent                    |
| `O_NOFOLLOW` on every descent, `fstat` `dev`/`ino` only for `..` | Let the kernel refuse symlinks; pay the extra syscall only where a name is inherently ambiguous | Hosts without working `O_NOFOLLOW` pay the check everywhere           |
| `ENOENT` "disinformation" on identity mismatch                   | Do not tell an attacker the check fired                                                         | Callers cannot distinguish a race from a genuinely vanished directory |
| `FTS_LOGICAL` forces `FTS_NOCHDIR`                               | Following symlinks makes fd-relative bookkeeping unsound ("too hard")                           | `chown -L` gets none of the hardening                                 |
| Two cycle detectors, chosen per tool                             | `du` cannot double-count; `rm`/`chown` can tolerate a revisit                                   | Two code paths; the lazy one can process part of a cycle twice        |
| `/proc/self/fd` emulation before `fchdir` emulation              | Avoid changing cwd even without `openat`                                                        | The emulation re-resolves a full path and is only as safe as `/proc`  |
| Defer `stat` until an entry is processed (`FTS_DEFER_STAT`)      | Locality, and inode-simulating filesystems flush name caches early                              | Comparison functions may not read `fts_statp`                         |

## Sources

- [`lib/fts.c`][fts-c] — `diropen`, `fts_opendir`, `cwd_advance_fd`, `fts_build`, `fts_stat`, `fts_safe_changedir`, the `readdir` `ENOENT` note, the 100000-entry batch cap
- [`lib/fts.in.h`][fts-h] — flag documentation for `FTS_CWDFD`, `FTS_NOCHDIR`, `FTS_PHYSICAL`, `FTS_TIGHT_CYCLE_CHECK`, `FTS_DEFER_STAT`; the `fts_fd_ring` and `fts_cycle` members
- [`lib/fts-cycle.c`][fts-cycle-c] — `enter_dir`/`leave_dir`: the active-dir `dev`/`ino` hash versus the lazy state
- [`lib/cycle-check.c`][cycle-check-c] — the power-of-two lazy cycle check
- [`lib/openat.c`][openat-c] — `rpl_openat` (trailing-slash and `O_DIRECTORY` workarounds) and `openat_permissive` (the `/proc` → `save_cwd`/`fchdir` emulation), `openat_needs_fchdir`
- [`lib/openat-proc.c`][openat-proc-c] — `openat_proc_name` and the Solaris 10 `..` probe
- [`lib/openat-priv.h`][openat-priv-h] — `EXPECTED_ERRNO`, the alloca bound
- [`lib/opendirat.c`][opendirat-c] — `openat` + `fdopendir` with the flag set
- [`lib/chdir-long.c`][chdir-long-c] — `PATH_MAX`-chunked `openat` descent
- [`lib/save-cwd.c`][save-cwd-c] — fd-first cwd save with `getcwd` fallback
- [`src/remove.c`][remove-c] (coreutils) — the `FTS_CWDFD | FTS_NOSTAT | FTS_PHYSICAL` open, `unlinkat(fts_cwd_fd, …)`, `EROFS`→`ENOENT`

> [!NOTE]
> **Unverified.** The brief asked for a comment block "near the top of `fts.c`
> explaining the directory-swap race hardening" and for Jim Meyering's 2005
> `rm -r` rationale; neither string ("Meyering", "race", "swap", "rm -r")
> occurs in `lib/fts.c` at the pinned SHA — the only in-tree rationale is the
> `fts_safe_changedir` comment and the `FTS_CWDFD` header text quoted above.
> `src/remove.c` and `NEWS` were read through `WebFetch` at coreutils commit
> `71ea30a7422125dd644f8f0c389dda98aee907fc` (the latest commit touching
> `src/remove.c` on 2026-01-18), not from a local clone; the quotes from it are
> as returned by that fetch. The `NEWS` fetch surfaced only "du, chmod, chgrp
> and chown started using fts in 6.0" and "rm by the rewrite to use fts"
> under 8.0, not a race-hardening entry.

<!-- References -->

[openat2]: ./linux-openat2.md
[magic]: ./linux-procfs-magic-links.md
[windows]: ./windows-nt.md
[gnulib-tree]: https://github.com/coreutils/gnulib/tree/eb72eb6f75f5621c5d648acd11467fd124584617/lib
[fts-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/fts.c
[fts-h]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/fts.in.h
[fts-cycle-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/fts-cycle.c
[cycle-check-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/cycle-check.c
[openat-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/openat.c
[openat-proc-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/openat-proc.c
[openat-priv-h]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/openat-priv.h
[opendirat-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/opendirat.c
[chdir-long-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/chdir-long.c
[save-cwd-c]: https://github.com/coreutils/gnulib/blob/eb72eb6f75f5621c5d648acd11467fd124584617/lib/save-cwd.c
[remove-c]: https://github.com/coreutils/coreutils/blob/71ea30a7422125dd644f8f0c389dda98aee907fc/src/remove.c
