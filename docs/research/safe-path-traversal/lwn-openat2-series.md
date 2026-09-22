# LWN's coverage of `O_BENEATH` → `AT_NO_JUMPS` → `openat2`

The written record of why the `RESOLVE_*` flags are what they are: eight years
of LWN articles and archived patch postings in which each flag is proposed,
split, renamed, argued over and — in a few cases — dropped.

|                 |                                                                                                                                                                                                                                                                                                                      |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | Article series (LWN feature articles + LWN-archived mailing-list postings)                                                                                                                                                                                                                                           |
| **Years**       | 2014-11 → 2026-01                                                                                                                                                                                                                                                                                                    |
| **Authors**     | Jonathan Corbet, Nur Hussein, Chris Riddoch, Daroc Alden (articles); David Drysdale, Al Viro, Aleksa Sarai, Jens Axboe, Andrey Zhadchenko (the proposals they report)                                                                                                                                                |
| **Venue**       | [LWN.net][lwn-home]                                                                                                                                                                                                                                                                                                  |
| **Platforms**   | Linux VFS                                                                                                                                                                                                                                                                                                            |
| **Primitive**   | Lookup-restriction flags on `openat` / `openat2`: `O_BENEATH` (2014), `AT_NO_JUMPS` / `AT_BENEATH` / `AT_XDEV` / `AT_NO_SYMLINKS` (2017), `AT_*` set (2018), `RESOLVE_*` in `struct open_how` (2019–2020), `RESOLVE_CACHED` (2021), `RESOLVE_EMPTY_PATH` (2022, unmerged)                                            |
| **Source read** | [619146][lwn-619146], [723057][lwn-723057], [767547][lwn-767547], [793075][lwn-793075], [796770][lwn-796770], [796868][lwn-796868], [804980][lwn-804980], [843163][lwn-843163], [881153][lwn-881153], [899543][lwn-899543], [1050887][lwn-1050887]; the merged semantics checked against [`openat2(2)`][man-openat2] |

## Overview

### What it solves

The series documents one problem — restricting where a path lookup may go —
and the accumulating reasons the obvious fix (another `O_*` flag) was
inadequate. Corbet's 2019 article states the reason a whole new syscall was
needed ([796868][lwn-796868]):

> A program using a path-restricting flag needs to know whether the requested
> behavior is understood by the kernel or not; the alternative is to accept
> security vulnerabilities on kernels that do not implement those flags.

and the mechanism: "openat() doesn't check for unknown flags, and the number of
available bits for new flags is not large" — so `openat2` "checks for unknown
flags and returns -EINVAL". Sarai's `v16` cover letter ([804980][lwn-804980])
opens with the same grievance: "For a very long time, extending openat(2) with
new features has been incredibly frustrating."

### Design philosophy

Two ideas run through the record. First, **restriction must cover the whole
walk** — Drysdale's 2014 rule already said "Any symbolic links traversed while
resolving the path must meet the same conditions" ([619146][lwn-619146]), and
every later proposal keeps it. Second, **the primary consumer is a container
runtime** that cannot `chroot` or `fork`: "container runtimes, which currently
need to do symlink scoping in userspace when opening paths in a potentially
malicious container" ([796770][lwn-796770]); and, from the 2018 round, the Go
runtime "cannot do a raw clone() or fork()" safely, which is why the
`pivot_root`-and-walk-in-the-container alternative was rejected
([767547][lwn-767547]).

## How it works

The articles are best read as a timeline of flag semantics. Each row is what
the cited page says, not the merged kernel.

| Date       | Page                                                                                    | Proposal                                                                                                                          | What changed                                                                                                                                                                                                                                                              |
| ---------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2014-11-05 | [619146][lwn-619146] Corbet, "open() flags: O_TMPFILE and O_BENEATH"                    | `O_BENEATH` on `openat`, from David Drysdale's Capsicum series                                                                    | "the provided path is constrained to not start with "/" or contain "../"" — a **syntactic** rule; symlinks must obey it too; sold as a seccomp companion. Never merged.                                                                                                   |
| 2017-05-17 | [723057][lwn-723057] Hussein, "Restricting pathname resolution with AT_NO_JUMPS"        | Al Viro's `AT_NO_JUMPS` for the `*at()` family                                                                                    | "It's not quite O_BENEATH, and IMO it's saner that way - a/b/c/../d is bloody well allowed, and so are relative symlinks that do not lead out of the subtree." Violations return `-ELOOP`. Split by discussion into `AT_BENEATH`, `AT_XDEV` (`-EXDEV`), `AT_NO_SYMLINKS`. |
| 2018-10-04 | [767547][lwn-767547] Corbet, "New AT\_ flags for restricting pathname lookup"           | Sarai's `AT_BENEATH`, `AT_XDEV`, `AT_NO_PROCLINK`, `AT_NO_SYMLINK`, `AT_THIS_ROOT`                                                | `AT_THIS_ROOT` ("chroot-like semantics") appears; `AT_NO_PROCLINK` is the first magic-link flag; the `..` argument is had (below).                                                                                                                                        |
| 2019-07-07 | [793075][lwn-793075] Sarai, "namei: openat2(2) path resolution restrictions" (`v9`)     | A **new syscall**; `LOOKUP_XDEV`, `LOOKUP_NO_MAGICLINKS`, `LOOKUP_BENEATH`, `LOOKUP_IN_ROOT`, `LOOKUP_NO_SYMLINKS`; `O_EMPTYPATH` | "LOOKUP_BENEATH implies LOOKUP_NO_MAGICLINKS, because it can trivially beam you around the filesystem"; "openat2(2) has the ability to further restrict re-opening of its own O_PATH fds".                                                                                |
| 2019-08-20 | [796770][lwn-796770] Sarai, "openat2(2)" (`RESEND v11`)                                 | Same set; magic-link mode semantics                                                                                               | "several semantics of file descriptor 're-opening' are now changed to prevent attacks like CVE-2019-5736 by restricting how magic-links can be resolved (based on their mode)"; "If a race is detected (as with LOOKUP_BENEATH) then an error is generated."              |
| 2019-08-22 | [796868][lwn-796868] Corbet, "Restricting path name lookup with openat2()"              | `struct open_how` with `upgrade_mask` union and `reserved[7]`; five `RESOLVE_*`                                                   | The design article; controversies below.                                                                                                                                                                                                                                  |
| 2019-11-16 | [804980][lwn-804980] Sarai, "open: introduce openat2(2) syscall" (`v16`)                | The near-final series                                                                                                             | `upgrade_mask` and `O_EMPTYPATH` gone; `-EAGAIN` on a detected `..` race; "Unlike openat(2), it is an error to provide openat2() unknown or conflicting flags."                                                                                                           |
| 2021-01-21 | [843163][lwn-843163] Corbet, "Avoiding blocking file-name lookups"                      | Jens Axboe's `LOOKUP_CACHED` → `RESOLVE_CACHED`                                                                                   | A performance flag for `io_uring`, not a security one: fail with `EAGAIN` rather than do I/O; merged in 5.12.                                                                                                                                                             |
| 2022-01-12 | [881153][lwn-881153] Zhadchenko, "fs/open: add new RESOLVE_EMPTY_PATH flag for openat2" | `RESOLVE_EMPTY_PATH`: re-open an `O_PATH` fd without procfs                                                                       | CRIU's use case; the `O_EMPTYPATH` idea back in `resolve` form. Not in the man page as of the read.                                                                                                                                                                       |
| 2022-07-07 | [899543][lwn-899543] Riddoch, "The trouble with symbolic links"                         | Jeremy Allison's sambaXP talk                                                                                                     | The user-space file server's view: `openat` walks are "The only reliable way"; prefers `MOUNT_NOSYMFOLLOW`.                                                                                                                                                               |
| 2026-01-06 | [1050887][lwn-1050887] Alden, "The difficulty of safe path traversal"                   | Sarai's LPC 2025 talk                                                                                                             | `RESOLVE_NO_DOTDOT` proposed; procfs magic links still unprotected by `RESOLVE_NO_XDEV`; seccomp blocks `openat2`.                                                                                                                                                        |

### The `open_how` struct across revisions

Corbet's 2019 article reproduces the `v12`-era struct ([796868][lwn-796868]):

```c
struct open_how {
    __u32 flags;
    union {
        __u16 mode;
        __u16 upgrade_mask;
    };
    __u16 resolve;
    __u64 reserved[7]; /* must be zeroed */
};
```

with the objection it drew — "Requiring the use of a struct with 56 empty
bytes simply for 'reserve' seems unusual" — and Sarai's defence that the
struct then fits one 64-byte cache line. By `v16` ([804980][lwn-804980]) the
reserved block is gone in favour of a **caller-supplied size**: "openat2()
requires userspace to specify the size of struct open_how to allow both
forwards- and backwards-compatibility" and "All extensions must have their zero
values be a no-op, the kernel treats all extension fields not set by userspace
as zero." The merged layout is three 64-bit fields (`flags`, `mode`,
`resolve`) with `E2BIG` for "An extension that this kernel does not support"
([`openat2(2)`][man-openat2]).

### The five flags as merged

From the man page ([`openat2(2)`][man-openat2]), for comparison with the
proposals above:

- `RESOLVE_BENEATH` — "Do not permit the path resolution to succeed if any
  component of the resolution is not a descendant of the directory indicated
  by _dirfd_. This causes absolute symbolic links (and absolute values of
  _path_) to be rejected."
- `RESOLVE_IN_ROOT` — "Treat the directory referred to by _dirfd_ as the root
  directory while resolving _path_. Absolute symbolic links are interpreted
  relative to _dirfd_."
- `RESOLVE_NO_MAGICLINKS` — "Disallow all magic-link resolution during path
  resolution."
- `RESOLVE_NO_SYMLINKS` — "Disallow resolution of symbolic links during path
  resolution." (The `v16` cover letter adds: "This option implies
  RESOLVE_NO_MAGICLINKS.")
- `RESOLVE_NO_XDEV` — "Disallow traversal of mount points during path
  resolution (including all bind mounts)."
- `RESOLVE_CACHED` (since 5.12) — "Make the open operation fail unless all path
  components are already present in the kernel's lookup cache."

Errors: `EAGAIN` — "_how.resolve_ contains either **RESOLVE_IN_ROOT** or
**RESOLVE_BENEATH**, and the kernel could not ensure that a ".." component
didn't escape"; `EXDEV` — "an escape from the root during path resolution was
detected"; `ELOOP` — under `RESOLVE_NO_SYMLINKS`, "one of the path components
was a symbolic link (or magic link)".

### Dimension 1 — Threat model

Stated by each proposer in their own terms. Drysdale (2014): a sandboxed
process given "a directory to create files in" under seccomp
([619146][lwn-619146]). Viro (2017): "a web server could use file I/O system
calls that guaranteed that any given path will never break out of a certain
subdirectory tree", and "this could be very useful for Samba and other
userspace file servers!" ([723057][lwn-723057]). Sarai (2018–2019): "The
primary use case for these flags is to allow trusted programs to restrict how
untrusted paths are resolved" ([804980][lwn-804980]), specifically container
runtimes opening paths "in a potentially malicious container"
([796770][lwn-796770]); the 2019 article adds the magic-link adversary — "the
runc container breakout vulnerability reported in February was the result of
hostile code using the /proc/PID/exe link to open the runc binary for write
access" ([796868][lwn-796868]). Allison (2022): "For a non-trivial
application, for a regular person writing code on POSIX, you will have symlink
races in your code" ([899543][lwn-899543]) — the adversary is any local user
who can create a symlink in a directory the privileged program traverses.

### Dimension 2 — Resolution primitive

An in-kernel per-component check inside the existing walk, which is the
property the 2017 discussion valued: Viro's flag returns `-ELOOP` at the
offending component rather than pre-validating the string
([723057][lwn-723057]), the opposite of Drysdale's `"/"` / `"../"` textual
rule. The `v16` letter names the race-handling choice — the series' changelog
lists an "Enhanced commit message explaining why -EAGAIN is preferable for
path_is_under() race detection" ([804980][lwn-804980]) — which is the origin of
the man page's `EAGAIN`: the kernel does not retry a `..` whose parent moved
under it, it reports it and lets the caller retry. `RESOLVE_CACHED` is a
different kind of primitive on the same walk: "restrict lookups to the RCU-walk
path" so that "if I/O would be required, the openat2() call will fail with an
EAGAIN error" ([843163][lwn-843163]).

### Dimension 3 — Symlink and `..` policy

This is the dimension the record is richest on, because it was argued three
times.

- **2014.** `O_BENEATH` forbids `..` in the string and in every symlink
  target ([619146][lwn-619146]).
- **2017.** Viro rejects that as unsaner: "a/b/c/../d is bloody well allowed,
  and so are relative symlinks that do not lead out of the subtree." Linus
  Torvalds wanted "Separate handling for absolute vs. relative symlinks" and "A
  dedicated `AT_NO_SYMLINKS` flag forbidding all symbolic links"; Viro's
  precedence rule — "AT_NO_SYMLINKS take precedence since it was convenient to
  implement" — and "dangling symlinks allowed only with `AT_SYMLINK_NOFOLLOW`"
  close the round ([723057][lwn-723057]).
- **2018.** Jann Horn objects that permitting bounded `..` weakens the flag
  against directory-traversal bugs; Sarai answers with a measurement — "37% of
  all the symbolic links on his system contained '..'" — and keeps bounded
  `..` ([767547][lwn-767547]).
- **2019.** `RESOLVE_IN_ROOT` inherits the bounded rule: "Absolute paths will
  begin relative to the starting directory, and "../" will not proceed above
  that directory" ([796868][lwn-796868]). `RESOLVE_NO_SYMLINKS` is
  whole-walk, "unlike O_NOFOLLOW which only applies to the final component".
- **2025.** The strict variant returns as a request: `RESOLVE_NO_DOTDOT`
  "Would ban ".." entirely", with Sarai's caveat that "you should still combine
  RESOLVE_NO_DOTDOT with RESOLVE_BENEATH because of absolute symlinks"
  ([1050887][lwn-1050887]).

### Dimension 4 — Boundaries

**Mounts.** Andy Lutomirski asked in 2017 for the mount-crossing rule to be
separable from containment; Viro answered with `AT_XDEV` returning `-EXDEV`,
and Linus: "mount point crossing might be splittable too". On bind mounts Viro
"confirmed untestable" — a bind mount is indistinguishable from the original
during a walk ([723057][lwn-723057]), which is why `RESOLVE_NO_XDEV` blocks
"all bind mounts" rather than trying to classify them. A 2019 commenter warned
that "use of RESOLVE_NO_XDEV in particular seems like a disaster waiting to
happen unless it is done in specific response to user request"
([796868][lwn-796868]).

**Magic links.** First named in 2018 as `AT_NO_PROCLINK` ("symbolic links in
/proc, particularly those under fd/", [767547][lwn-767547]), generalised in
2019 to `NO_MAGICLINKS` because "it can trivially beam you around the
filesystem" ([793075][lwn-793075]). The 2019 series also tried to change
`open()` itself: "while previously the permission bits on the magic link
itself were ignored, now they are taken into account", plus `O_EMPTYPATH` and
an `upgrade_mask` with `UPGRADE_NOREAD` / `UPGRADE_NOWRITE` to "limit the
access that can be obtained by reopening in the future" ([796868][lwn-796868])
— none of which survived to `v16`. By 2026 the gap is still open:
"[RESOLVE_NO_XDEV] doesn't work for procfs's magic links... for some reason",
and "Most have been blocked since kernel version 6.12, but 'most' and 'all' are
different prospects" ([1050887][lwn-1050887]).

**`RESOLVE_IN_ROOT` versus `chroot`.** "causes the lookup process to behave as
if a chroot() to the starting point had been performed", with "Some work … to
make RESOLVE_IN_ROOT free of some of the race conditions that plague chroot()"
([796868][lwn-796868]); the `v9` letter: "This provides chroot(2)-like
protection but without the cost of a chroot(2) for each filesystem operation"
([793075][lwn-793075]).

### Dimension 5 — Portability and fallback

The articles record the two ways the primitive can be missing. Old kernels:
the unknown-flag argument above — `openat` would silently ignore a restriction,
`openat2` returns `EINVAL` (unknown) or `E2BIG` (too-new struct), so absence is
detectable. Seccomp: Christian Brauner in 2019 — "Yes, there's a problem for
seccomp with these syscalls since it can't filter pointer arguments currently"
([796868][lwn-796868]) — which by 2026 has become "openat2() is often blocked
by seccomp(), since one of the arguments is a pointer"
([1050887][lwn-1050887]). The fallback itself is not LWN's subject; Allison
names it — "The only reliable way to identify a file's path is to walk the
hierarchy using multiple calls to openat(). Everything else would be vulnerable
to race conditions" ([899543][lwn-899543]) — and Alden quotes Sarai calling it
"quite finicky, but you can do it" ([1050887][lwn-1050887]).

### Dimension 6 — Failure and partiality

Each flag has a distinct error so a caller can tell _why_ the walk stopped:
`-ELOOP` (2017 `AT_NO_JUMPS`; merged `RESOLVE_NO_SYMLINKS`), `-EXDEV` (2017
`AT_XDEV`; merged for both `NO_XDEV` and a detected `BENEATH` / `IN_ROOT`
escape), `-EAGAIN` (a `..` race the kernel could not rule out — "the kernel
could not ensure that a ".." component didn't escape", [`openat2(2)`][man-openat2])
and, for `RESOLVE_CACHED`, `-EAGAIN` meaning "retry without the flag where
blocking is tolerable" ([843163][lwn-843163]). The overloading of `EAGAIN` for
two unrelated conditions is visible in the record but not remarked on. The
`v16` changelog's move to `-EAGAIN` "for path_is_under() race detection"
([804980][lwn-804980]) is the decision that a rename race is the **caller's**
to retry, not the kernel's to spin on.

### Dimension 7 — Enumeration and deletion

Does not apply: the series is about a single `open`. The 2022 Allison article
is the only page that touches the wider API, and only to complain: "You cannot
create a new directory with open(), you cannot remove a file, unlink a file, or
delete a directory with an open() call" — hence `mkdirat`, `unlinkat`,
`renameat` and the rest, and his `/proc/self/fd/` trick for `setxattr`
([899543][lwn-899543]).

## Strengths

- **Every flag's semantics has a recorded argument** — `..` (three rounds),
  mount crossing (Lutomirski/Viro/Linus), magic links (Sarai) — so a new API
  can cite a reason rather than a habit.
- **The dropped proposals are visible**: `O_BENEATH`'s textual rule,
  `upgrade_mask`, `O_EMPTYPATH`, the magic-link `f_mode` change — each with the
  objection or the silence that killed it.
- The Brauner / seccomp remark of 2019 is an early, on-record warning that the
  security syscall would be filtered out by security policy.
- The 2026 article closes the loop: which flags are used in anger, what they
  still cannot do.

## Weaknesses

- **Three of the pages are raw patch postings**, not articles; the reasoning
  lives in their changelogs and must be read against the man page.
- The 2022 Allison piece never mentions `openat2` or `RESOLVE_NO_SYMLINKS` —
  a reader could come away thinking `MOUNT_NOSYMFOLLOW` is the state of the art.
- The `EAGAIN` double meaning (`..` race vs. `RESOLVE_CACHED` miss) is left to
  the reader.
- `RESOLVE_EMPTY_PATH` (2022) is an unmerged posting; its presence in this
  series should not be read as a kernel capability.

## Key design decisions and trade-offs

| Decision                                                      | Rationale (as recorded)                                                                                       | Trade-off (as recorded)                                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| New syscall, not new `openat` flags                           | `openat` ignores unknown flags; a missing restriction must be an error ([796868][lwn-796868])                 | Pointer argument defeats seccomp filtering (Brauner, 2019; [1050887][lwn-1050887])                        |
| Sized struct instead of `reserved[7]`                         | "56 empty bytes" objection; zero-means-no-op extension rule ([804980][lwn-804980])                            | Callers must pass `sizeof`; `E2BIG` is a new failure mode                                                 |
| Bounded `..` allowed (`a/b/../c`)                             | Viro: forbidding it is "not saner"; 37% of symlinks contain `..` ([723057][lwn-723057], [767547][lwn-767547]) | Directory-traversal validators want it banned (Horn 2018; `RESOLVE_NO_DOTDOT` 2025)                       |
| Report a `..` rename race as `-EAGAIN`                        | "why -EAGAIN is preferable for path_is_under() race detection" ([804980][lwn-804980])                         | Every caller needs a retry loop; `EAGAIN` also means a `RESOLVE_CACHED` miss                              |
| Split mount crossing from containment (`AT_XDEV` / `NO_XDEV`) | Lutomirski: web servers need containment but tolerate mounts ([723057][lwn-723057])                           | `NO_XDEV` blocks all bind mounts (untestable otherwise) and, in practice, procfs magic links              |
| Separate `NO_MAGICLINKS` from `NO_SYMLINKS`                   | Magic links "beam you around the filesystem"; `BENEATH` must imply it ([793075][lwn-793075])                  | `NO_SYMLINKS` implies `NO_MAGICLINKS`, so no "follow symlinks but not `/proc` links" mode                 |
| Drop `upgrade_mask` / `O_EMPTYPATH` / magic-link `f_mode`     | Not in `v16`; the record shows them present in `v9`–`v12` and absent after ([804980][lwn-804980])             | Re-opening through `/proc/self/fd` stays unrestricted; `RESOLVE_EMPTY_PATH` re-proposed in 2022, unmerged |

## Sources

- [LWN 619146][lwn-619146] — Corbet, 2014-11-05: `O_BENEATH`'s textual rule and Capsicum/seccomp motivation
- [LWN 723057][lwn-723057] — Hussein, 2017-05-17: Viro's `AT_NO_JUMPS`, the Lutomirski/Linus splits into `AT_BENEATH` / `AT_XDEV` / `AT_NO_SYMLINKS`, bind mounts untestable
- [LWN 767547][lwn-767547] — Corbet, 2018-10-04: Sarai's `AT_*` set, Horn on `..`, the 37% figure, Go cannot `fork`
- [LWN 793075][lwn-793075] — Sarai, 2019-07-07, `v9` posting: `LOOKUP_*` flags, `O_EMPTYPATH`, `BENEATH` implies `NO_MAGICLINKS`
- [LWN 796770][lwn-796770] — Sarai, 2019-08-20, `RESEND v11`: magic-link mode semantics, race → error
- [LWN 796868][lwn-796868] — Corbet, 2019-08-22: the `open_how` design, `upgrade_mask`, Brauner on seccomp, the `NO_XDEV` warning, `EINVAL` on unknown flags
- [LWN 804980][lwn-804980] — Sarai, 2019-11-16, `v16`: sized struct, `-EAGAIN` rationale, "error to provide … unknown or conflicting flags"
- [LWN 843163][lwn-843163] — Corbet, 2021-01-21: `RESOLVE_CACHED` as an `io_uring` performance flag
- [LWN 881153][lwn-881153] — Zhadchenko, 2022-01-12: `RESOLVE_EMPTY_PATH` for CRIU (unmerged)
- [LWN 899543][lwn-899543] — Riddoch, 2022-07-07: Allison's "pathnames as a concept are now utterly broken in POSIX"
- [LWN 1050887][lwn-1050887] — Alden, 2026-01-06: LPC 2025 report; `RESOLVE_NO_DOTDOT`, 6.12 overmount block, seccomp
- [`openat2(2)`][man-openat2] — the merged flag texts and the `EAGAIN` / `EXDEV` / `ELOOP` / `E2BIG` entries
- Sibling deep-dives: [`linux-openat2.md`][openat2] (the merged kernel code), [`sarai-talks.md`][talks] (the proposer's own decks), [`linux-procfs-magic-links.md`][magic]

> [!NOTE]
> **Unverified.** All LWN pages were read through a summarising fetch, not
> raw HTML; quotes are as the fetch returned them and were cross-checked
> against the man page where possible. The `v16` `open_how` layout as reported
> by that fetch (`__aligned_u64 flags; __u16 mode; __u16 __padding[3];
__aligned_u64 resolve`) differs from the merged three-`u64` layout and could
> not be confirmed against the raw posting. Comment threads under the articles
> were not read except where the fetch surfaced them (the "56 empty bytes" and
> `NO_XDEV` remarks on [796868][lwn-796868]). The 2018 article's "37%" figure
> and the 2017 attributions to Linus Torvalds and Andy Lutomirski are as the
> fetch reported them.

<!-- References -->

[lwn-home]: https://lwn.net/
[lwn-619146]: https://lwn.net/Articles/619146/
[lwn-723057]: https://lwn.net/Articles/723057/
[lwn-767547]: https://lwn.net/Articles/767547/
[lwn-793075]: https://lwn.net/Articles/793075/
[lwn-796770]: https://lwn.net/Articles/796770/
[lwn-796868]: https://lwn.net/Articles/796868/
[lwn-804980]: https://lwn.net/Articles/804980/
[lwn-843163]: https://lwn.net/Articles/843163/
[lwn-881153]: https://lwn.net/Articles/881153/
[lwn-899543]: https://lwn.net/Articles/899543/
[lwn-1050887]: https://lwn.net/Articles/1050887/
[man-openat2]: https://man7.org/linux/man-pages/man2/openat2.2.html
[openat2]: ./linux-openat2.md
[talks]: ./sarai-talks.md
[magic]: ./linux-procfs-magic-links.md
