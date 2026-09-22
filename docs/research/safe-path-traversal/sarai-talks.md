# Aleksa Sarai's path-resolution talks (2019–2025)

Six years of one argument, delivered by the person who wrote `openat2` and
`libpathrs`: path strings cannot be made safe in user space, the kernel has to
refuse the escape, and even then `/proc` needs its own, stricter discipline.

|                 |                                                                                                                                                                                                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | Talk series (five slide decks; recordings not consulted)                                                                                                                                                                                                          |
| **Years**       | 2019-09 (LPC) → 2020-01 (linux.conf.au) → 2020-08 (LPC) → 2024-09 (All Systems Go!) → 2025-12 (LPC)                                                                                                                                                               |
| **Author**      | Aleksa Sarai (SUSE; `runc` and `umoci` maintainer, `openat2` and `libpathrs` author)                                                                                                                                                                              |
| **License**     | CC BY-SA 4.0 ([`COPYING`][talks-license])                                                                                                                                                                                                                         |
| **Repository**  | [`cyphar/talks`][talks-repo] at `95d789ca651c269a9df90d20390069a8412c5024`                                                                                                                                                                                        |
| **Platforms**   | Linux (kernel VFS, procfs, the new mount API)                                                                                                                                                                                                                     |
| **Primitive**   | `openat2(2)` `RESOLVE_*` flags in the kernel; an `O_PATH` per-component emulation in `libpathrs` for kernels without it; a private `fsopen("proc")` handle for `/proc`                                                                                            |
| **Source read** | [`securing-path-resolution.pdf`][lpc19] (11 slides), [`securing-runtimes.pdf`][lca20] (38), [`openat2.pdf`][lpc20] (14), [`libpathrs.pdf`][asg24] (22), [`path-safety-in-the-trenches.pdf`][lpc25] (81); the `README.md` beside each deck for the recording links |

## Overview

### What it solves

The problem is stated the same way in every deck, and it is the three-line
escalation every other document in this catalog circles around
([`securing-path-resolution.pdf`][lpc19], slide 3):

> `open("/foo/bar/shadow", O_RDONLY)`
> – What if shadow is a symlink? (Just use O_NOFOLLOW.)
> – What if bar is a symlink? (Okay, let's sanitise the path then.)
> – Now what if bar gets replaced with a symlink during resolution?
>
> CVE-2017-1002101. CVE-2018-15664. CVE-2019-10152. CVE-2019-11246.
> – Many more examples, and probably countless more yet-undiscovered.
>
> Solution: Add flags that can restrict the entire resolution process.

The 2020 linux.conf.au deck adds the sentence that justifies a kernel change
rather than a library ([`securing-runtimes.pdf`][lca20], slide 15): "This is a
solveable problem in userspace, but almost nobody does it correctly." The 2025
deck reduces it to a slogan ([`path-safety-in-the-trenches.pdf`][lpc25],
slide 57): "Every pathname syscall is potentially dangerous."

### Design philosophy

Three commitments hold across all five decks:

1. **Restrict the whole walk, not the last component.** `O_NOFOLLOW` was never
   the answer; the flags are `RESOLVE_*`, applied to every component
   ([`lpc19`][lpc19] slide 7; [`lpc25`][lpc25] slide 10 calls
   `RESOLVE_NO_SYMLINKS` a "better O_NOFOLLOW (/ still escapes)").
2. **File descriptors, not strings.** "Requires the program to primarily use
   file descriptors" ([`lpc25`][lpc25] slide 10); the 2019 deck already warns
   that porting "Requires a bit of work, since 'strings as paths' no longer
   applies" (slide 9).
3. **`/proc` is a separate, harder problem** — "procfs is terrifying" (2020,
   slide 9), "really terrifying" (slide 11), "absolutely horrifying" (slide 12),
   and by 2025 a named category, "strict path safety", distinct from "regular
   path safety" ([`lpc25`][lpc25] slide 6).

## How it works

### 2019-09 — LPC, "Securing Path Resolution [openat2() and libpathrs]"

The deck presents the `v12` patch set (slide 2 points at
`https://lwn.net/Articles/796868/`, the LWN write-up covered in
[`lwn-openat2-series.md`][lwn]) and the pre-1.0 `openSUSE/libpathrs`. The
`open_how` on slide 6 is the **pre-merge** shape — note the `union` with
`upgrade_mask` and the 16-bit fields:

```c
int openat2(int dfd, const char *path,
            const struct open_how *how, size_t size);
struct open_how {
   u32 flags;           // open(2) flags
   union {
      u16 mode;         // open(2) mode
      u16 upgrade_mask; // restrict O_PATH upgrading
   };
   u16 resolve;         // RESOLVE_* flags
   // future fields go here
};
```

Slide 7 defines each flag by the kernel function it blocks —
`RESOLVE_NO_XDEV`: "Block vfsmount crossings"; `RESOLVE_NO_MAGICLINKS`: "Block
nd_jump_link() crossings"; `RESOLVE_NO_SYMLINKS`: "Block get_link() crossings";
`RESOLVE_BENEATH`: "Block nd_jump_root() and '/..'"; `RESOLVE_IN_ROOT`: "Scope
all root jumps to dirfd". Slides 4–5 carry two proposals that were later
**dropped**: obeying a magic link's `f_mode` on re-open (so an `O_RDONLY`
`/proc/self/exe` cannot be re-opened `O_WRONLY`, the CVE-2019-5736 primitive
spelled out on slide 11) and `O_EMPTYPATH` — `openat(fd, "", O_EMPTYPATH)`,
"`open("/proc/self/fd/...")` but without procfs". Slide 8 is the first
statement of why a library is needed at all: "Using openat2(RESOLVE_IN_ROOT)
correctly is non-trivial … No other syscalls support RESOLVE_IN_ROOT … How do we
deal with old kernels?"

### 2020-01 — linux.conf.au, "Securing Container Runtimes (How Hard Could It Be?)"

A CVE retrospective, one lesson per slide, that motivates the kernel work from
the runtime side. `docker cp` "didn't do any path sanitisation" (slide 7,
"CVE-2014-????"); CVE-2016-9962 — "We kept open a file descriptor to the root
filesystem while joining the container … Container could access host through
/proc/$pid/fd/$n" (slide 9); CVE-2018-15664 — "Path sanitisation isn't enough
if the attacker can change the paths underneath you … `RENAME_EXCHANGE` can be
used to swap ('symlink-exchange') a component. … Plain path sanitisation (as
used to fix the 2014 bugs) is insufficient" (slide 10); CVE-2019-5736 — "We
could be tricked into re-executing ourselves, pinning /proc/self/exe … `open`
(`/proc/self/exe`, `O_RDONLY`) then re-open it after the process dies" (slide 11);
CVE-2019-19921 — "you can use the symlink-exchange trick to mess with /proc …
the container runtime can be tricked into not setting security labels.
/proc/self/sched can be used as a no-op writeable procfs target" (slide 12).

The `open_how` on slide 16 is now the merged shape — three `u64` fields, no
union — and slide 17 lists four `RESOLVE_*` flags (`RESOLVE_BENEATH` is absent
from that slide). Slides 25–27 introduce the bind-mount problem that the rest of
the series never fully closes: "How do I make sure that I'm writing to the real
procfs file?" and, in full-screen type, "There is no way on Linux to be verify
if you've crossed a bind-mount (until openat2)." The appendix (slides 35–38)
sketches three procfs-free alternatives — magic-link re-open restriction,
`O_EMPTYPATH`, a built-in procfs handle (`AT_PROCFD` or `fsopen("procfs")` +
`fsmount`), and a pidfd-based `/proc/self`.

### 2020-08 — LPC, "openat2(2): what's next?"

Status: "openat2(2) in Linux 5.6. Only main missing pieces are related to
magic-link hardening" (slide 2). The talk is an RFC on `/proc`. The "easy-ish"
half (slide 6): `/proc` is verifiable — "`fstatfs(2)` as well as `PROC_ROOT_INO`
(1)" — and `/proc/self/attr/exec` can be opened with
`openat2(RESOLVE_NO_XDEV|RESOLVE_NO_SYMLINKS)`; "Without openat2(2), not
possible without races." The hard half (slide 7): "Being sure that
/proc/self/{fd/$n,exe} is legit. Not currently possible, even with openat2(2).
Cannot use RESOLVE_NO_XDEV (blocks most magic-links). Attackers can bind-mount
on top of procfs symlinks." Three proposals are put to the room (slides 8–11):
`RESOLVE_ONLY_MAGICLINKS` ("clearly a hack"), distinct replacement APIs
(`O_EMPTYPATH`, `process_get_resource`), and a **process-local procfs** —
"Unprivileged fsopen("procfs") with subset=pidfs,hidepid=4 … Seems like the
'neatest' solution". Slide 13 records the assumption `libpathrs` rests on:
"libpathrs is designed around re-opening file descriptors in a context where we
assume a handle is safe after we've checked it" — and asks whether userspace
may rely on "mounts don't affect existing handles". Slide 14 asks for a
`readlinkat2` so an `O_PATH` symlink can be read without
`/proc/self/fd/$n`.

### 2024-09 — All Systems Go!, "libpathrs: securing path operations for system tools"

The library talk. Slide 4 sets the two implementations side by side —
`openat2` "(since Linux 5.6)" with `IN_ROOT` that "'just works' for most cases"
versus `openat(O_PATH)` "(since Linux 2.6.39-ish)": "Manually do lookup with
O_PATH handles, emulating what openat2 does. `..` and `/` components are usually
verified through /proc/self/fd." Slide 5 is a prior-art census: "LXC and Incus
use openat2 with an O_PATH fallback. Docker and containerd use chroot for some
things. runc and umoci use filepath-securejoin for most things. systemd has a
custom O_PATH resolver (chaseat). Golang are working on their own version."
Slide 6 is the reason the library grew an operation vocabulary rather than one
`open`: "Symlink following behaviour is inconsistent. Some care is needed for
syscalls without AT_EMPTY_PATH. Some operations are a bit more complicated to
implement (mkdir -p, rm -r, etc)." Slide 8 shows the Rust API —
`Root::open`, `root.resolve("/etc/passwd")?.reopen(OpenFlags::O_RDONLY)?`,
`create_file`, `mkdir_all`, `remove_all` — and slide 10 explains `reopen`:
"This is not just dup! It's a proper race-free open." The procfs API (slides
13–16) states its goal and its floor: "Detecting attackers is the primary goal,
followed by resiliency. Private procfs instance with fsopen and open_tree if
possible. Can't be used for unprivileged programs…"; "For magic-links, we need:
statx mount ID support (Linux 5.8) for bind-mounts. fsopen or open_tree (Linux
5.1) for race safety." Slide 22 lists wished-for kernel flags: `RESOLVE_NO_BLOCK`
(NO_REMOTE?), file-type restriction, `RESOLVE_NO_DOTDOT`, and an atomic
`O_MKNOD`.

### 2025-12 — LPC, "Path Safety 'in the Trenches'"

The post-mortem deck. Slide 8 lists thirteen CVEs (2017–2025) under "surely
this isn't that common…"; slide 11 versus 12–13 is the whole method in two
snippets — the six unsafe string calls, then:

```c
int root = open("/rootfs", O_DIRECTORY|O_PATH);
struct open_how how = { .resolve = RESOLVE_IN_ROOT };
how.flags = O_CREAT|O_TRUNC|O_RDWR;
how.mode = 0755;
int fd1 = openat2(root, "/etc/foo", &how, sizeof(how));
```

and, for a `mkdir`, an `O_DIRECTORY|O_PATH` `openat2` of the parent followed by
`mkdirat(dfd, "bar", 0755)` (slide 13). Slide 14 names the `O_PATH` fallback's
cost: "Implement per-component lookups in userspace (very finicky). … Usually
needs readlink("/proc/self/fd/$n") verification. See: systemd's chaseat, Go's
os.Root, libpathrs."

"Strict" safety is worked as a sequence of near-identical slides (20–30) in
which one token at a time is highlighted: `RESOLVE_BENEATH|RESOLVE_NO_XDEV`
from an `O_PATH` `/proc` handle is enough for `self/attr/exec` (slide 20); for a
magic link it is **not** — slide 23 highlights `RESOLVE_NO_XDEV` as the flag
that breaks `thread-self/fd/123`, slide 26 highlights "validate no overmounts"
as the step still missing after opening `thread-self/fd` as a directory, and
slides 28–30 replace `open("/proc")` with `fsopen("proc")` + `fsconfig` +
`fsmount` and mark the comment "for open_tree(2) -- validate no overmounts".
The `libpathrs` answer (slide 31) is `pathrs_proc_open(PATHRS_PROC_SELF, "attr/exec", O_WRONLY)`
and `pathrs_reopen(123, O_RDWR)`.

The two 2025 CVE walk-throughs are the most concrete attack narratives in the
series. CVE-2025-31133 / CVE-2025-52565 (slides 42–44): "`/volume` is a symlink
to `/dev`. Racing process swaps files in /volume with symlink to
/proc/sys/kernel/core_pattern … Bind-mount source becomes
/proc/sys/kernel/core_pattern, creating a rw bind-mount to a masked procfs
file." Fixes: "Mountpoint creation was moved to libpathrs (pathrs-lite).
Everything is now (mostly) file-descriptor-based." CVE-2025-52881 (slides
52–54): a bind mount onto `/foo/link/thread-self/attr/apparmor` where
"Racing process swaps /foo/link symlink between /proc and dummy directory. This
bypassed our anti-/proc mount checks" and the target `exec` file is a symlink to
`/proc/1/sched` (no-op) or `/proc/sysrq-trigger` ("crash – 'exec
docker-default'"). Fix: "Switch to libpathrs (pathrs-lite) procfs API for
writes. Also, audited all write paths for misdirectable writes." Slide 56
records the kernel side: "Blocking all magic-link overmounts would help a lot.
Most have been blocked since 6.12." Slides 59–68 add a war story: switching
`runc` to `fsopen("proc")` made AppArmor deny writes under `/proc/sys/net`
because `aa_path_name()` computed the path of the detached mount as "/" and
then "/sys/foo/bar", matching a `deny /sys/…` rule.

### Dimension 1 — Threat model

An unprivileged process **inside the container** (or one that controls the
container's image / config) racing a privileged runtime that operates on paths
under the container's rootfs. The named primitives are: a component replaced
by a symlink mid-walk (2019 slide 3; 2024 slide 3 "Any component can be renamed
or swapped to a symlink"), `RENAME_EXCHANGE` symlink-exchange (2020 slide 10),
magic-link re-open (`/proc/self/exe`, CVE-2019-5736), a fake or bind-mounted
`/proc` so a label write becomes a no-op (CVE-2019-16884, CVE-2019-19921, 2024
slide 12), and bind mounts on top of magic links ("even more undetectable",
2024 slide 12). The 2025 deck is explicit that `runc` "has no real threat
model" and "Most vulnerabilities have been 'misconfiguration' bugs" (slide 34),
and that "Most people still don't use user namespaces" — the 2020 deck's
opening slide is "PLEASE USE USER NAMESPACES (Folks who did were not vulnerable
to most of these bugs...)".

### Dimension 2 — Resolution primitive

`openat2(2)` with `struct open_how` — whole-walk restriction enforced inside
`link_path_walk`, so the atomicity claim is **per-component in the kernel, with
the escape check applied to every component** (2019 slide 7's mapping of each
flag to `nd_jump_link` / `get_link` / `nd_jump_root` is the claim in kernel
vocabulary). The fallback primitive is an `O_PATH`-per-component user-space walk
verified through `readlink("/proc/self/fd/$n")` (2024 slide 4; 2025 slide 14)
— no atomicity across components, only a post-hoc check. `libpathrs`'s
`reopen` (2024 slide 10) is the third primitive: from an `O_PATH` handle to a
usable fd via `/proc/self/fd`, "a proper race-free open".

### Dimension 3 — Symlink and `..` policy

Symlinks are followed but scoped: `RESOLVE_IN_ROOT` treats absolute targets as
rooted at `dirfd` ("chroot(2)-like lookups", 2025 slide 10); `RESOLVE_BENEATH`
rejects them; `RESOLVE_NO_SYMLINKS` refuses all. `..` is resolved in-kernel
under `BENEATH`/`IN_ROOT` and the series asks twice for a stricter
`RESOLVE_NO_DOTDOT` (2024 slide 22 "for extreme lookup restrictions"; 2025
slide 56). The user-space fallback verifies `..` and `/` "through
/proc/self/fd" (2024 slide 4). Dangling symlinks are a documented compatibility
casualty of fd-based code (2025 slide 70): "Previously we would expand dangling
symlinks … Some users depend on this behaviour… Emulating it with file
descriptors is quite hard."

### Dimension 4 — Boundaries

Mounts: `RESOLVE_NO_XDEV` is "particularly useful" (2024 slide 4) and the
**only** way to detect a bind mount (2020 slide 27) — but it cannot be used
on magic links (2020 slide 7; 2025 slide 23), which is the hole the whole
procfs sub-story exists for. The `/proc` root itself is verified by
`fstatfs` + `PROC_ROOT_INO` (2020 slide 6) and, once the mount API is usable,
replaced by a private `fsopen("proc")` instance so no attacker mount can sit
on it (2025 slides 28–30). Overmounts on magic links: "Most have been blocked
since 6.12" (2025 slide 56). Special inodes: after CVE-2025-31133 `runc` added
"much stricter validation of special inodes we use. Takeaway: 'Safe'
major:minor numbers are very handy" (2025 slide 44).

### Dimension 5 — Portability and fallback

`libpathrs` "Emulates openat2's RESOLVE_IN_ROOT on older kernels" (2020 slide 20) and "Transparently supports openat2 and the O_PATH fallback" (2025 slide
15); "Newer kernel features are automatically used if available" (2024 slide
7). The floors are stated as kernel versions: "O_PATH resolver needs Linux 5.8
to be safe"; `statx` mount IDs (5.8) for bind-mount detection; `fsopen` /
`open_tree` (5.1) for magic-link race safety; and "openat2 might be blocked due
to seccomp limitations" (2024 slide 16). What is lost without `openat2` is
bind-mount detection and atomicity of the escape check; what is lost without
privilege is the private procfs ("Can't be used for unprivileged programs…",
2024 slide 13). `RESOLVE_BENEATH` was not yet a `libpathrs` mode in 2024
("could easily be added", slide 7); `NO_XDEV` was "if users need it? We can use
name_to_handle_at for pre-openat2 kernels" (slide 19).

### Dimension 6 — Failure and partiality

The decks expose errors as `pathrs_errorinfo(liberr)` with `description` and
`saved_errno` (2024 slide 9; 2025 slide 73). Rename races during the kernel walk
are not discussed on the slides beyond the 2019 mapping of `BENEATH` to a
`nd_jump_root` block — the `-EAGAIN` retry contract lives in the patch cover
letters ([`lwn-openat2-series.md`][lwn]). For the emulated walk the 2020 deck
notes that `readlink` on an `O_PATH` symlink is impossible, forcing "racy retry
loops for readlink" (slide 14). Mid-operation state after failure is not
addressed.

### Dimension 7 — Enumeration and deletion

Present only as API surface: `root.mkdir_all(...)` and `root.remove_all("/foo/bar")`
on the 2024 (slide 8) and 2025 (slide 72) API slides, motivated by "Some
operations are a bit more complicated to implement (mkdir -p, rm -r, etc)"
(2024 slide 6). The algorithm — fd-relative `readdir`, re-verification after
each `openat`, depth and fd limits — is not on any slide; see
[`libpathrs.md`][libpathrs] for the implementation.

## Strengths

- **A single, consistent argument across six years**, each deck adding one
  layer: kernel flags (2019) → why sanitisation fails (2020) → `/proc` is
  separate (2020-08) → a library with a real operation vocabulary (2024) →
  post-mortems of that library's own consumer (2025).
- **Attacks are named and mechanised**: every CVE on the slides comes with the
  primitive that made it work (symlink-exchange, magic-link re-open, fake
  procfs, bind-mount onto a masked path).
- **Kernel floors are stated as version numbers**, which is exactly what a
  fallback design needs.
- The 2025 AppArmor / `d_path` story is a rare documented case of a hardening
  change (`fsopen("proc")`) breaking a security policy that keyed on paths.

## Weaknesses

- **Slides, not prose.** The `-EAGAIN` / `..` race semantics, the emulated
  walk's algorithm, and the `remove_all` shape are all absent; the decks must
  be read together with the patch postings and `libpathrs` source.
- **Several 2019 proposals never landed** (`upgrade_mask`, `O_EMPTYPATH`,
  magic-link `f_mode` enforcement) and the decks do not say so — a reader of
  the 2019 deck alone would design against a struct that does not exist.
- The procfs discussion is Linux-only and container-runtime-shaped; nothing
  transfers to another OS.
- The 2025 deck's animated sequence (slides 20–30) is legible only if one
  notices which token is highlighted on each near-duplicate slide.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                 | Trade-off                                                                               |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| New syscall with a sized struct rather than `openat` flags | `openat` ignores unknown flags, so a restriction could silently not apply                 | Pointer argument: "openat2 might be blocked due to seccomp limitations" (2024 slide 16) |
| Flags named by the kernel hook they block                  | Each flag maps to one VFS jump (`nd_jump_link`, `get_link`, `nd_jump_root`, vfsmount)     | `NO_XDEV` blocks magic links too, so it cannot guard `/proc/self/fd/$n` (2020 slide 7)  |
| `RESOLVE_IN_ROOT` over `chroot`                            | No privilege, no per-operation `chroot`, "just works for most cases" (2024 slide 4)       | Absolute symlinks silently re-rooted; dangling-symlink expansion lost (2025 slide 70)   |
| A library (`libpathrs`) rather than "just use `openat2`"   | Old kernels, other VFS syscalls, `mkdir -p` / `rm -r` shapes (2019 slide 8; 2024 slide 6) | "strings as paths no longer applies" — every consumer must be ported (2019 slide 9)     |
| `O_PATH` handle + `reopen` as the universal shape          | One race-free open per use; handles reusable (`ptmx` example, 2024 slide 10)              | Depends on `/proc/self/fd` re-open, which is itself the thing that must be verified     |
| Private `fsopen("proc")` instance for "strict" paths       | No attacker mount can exist on a mount you just created (2025 slides 28–30)               | Needs privilege; broke AppArmor path rules via `d_path` (2025 slides 59–68)             |
| Ask for `RESOLVE_NO_DOTDOT`                                | `BENEATH` permits `a/../b`, which some validators want to forbid outright                 | Not merged as of the 2025 deck; still "nice-to-have" (slide 56)                         |

## Sources

- [`2019/09-linux-plumbers/securing-path-resolution.pdf`][lpc19] — the `v12`-era `open_how` with `upgrade_mask`, the hook-by-hook `RESOLVE_*` definitions, `O_EMPTYPATH`, CVE-2019-5736 mechanics; [`README.md`][lpc19-readme] links the recording
- [`2020/01-linux-conf-au/securing-runtimes.pdf`][lca20] — the CVE retrospective (2014 → CVE-2019-19921), the merged `open_how`, "no way … to verify if you've crossed a bind-mount (until openat2)", the procfs appendix; [`README.md`][lca20-readme] lists this deck as "Securing Container Runtimes"
- [`2020/08-LinuxPlumbers/openat2.pdf`][lpc20] — `openat2` in 5.6, the three `/proc` proposals, the "mounts don't affect existing handles" assumption, `readlinkat2`; [`README.md`][lpc20-readme]
- [`2024/09-all-systems-go/libpathrs.pdf`][asg24] — `openat2` vs `O_PATH` emulation, the prior-art census, the Rust/C API, the procfs API and its kernel floors; [`README.md`][asg24-readme] and the [media.ccc.de recording][asg24-ccc]
- [`2025/12-lpc/path-safety-in-the-trenches.pdf`][lpc25] — regular vs strict safety, the CVE-2025 walk-throughs, `fsopen("proc")`, the 6.12 overmount block, the AppArmor `d_path` incident
- [LWN, "The difficulty of safe path traversal"][lwn-1050887] — the written report of the 2025 talk, covered in [`lwn-openat2-series.md`][lwn]

> [!NOTE]
> **Unverified.** The recordings (YouTube links in each `README.md`, the
> media.ccc.de page for 2024) were not watched; nothing here comes from spoken
> content. The user knew the 2020-01 talk as "Path Resolution and Race
> Conditions: How to Walk a Directory Safely"; the slide deck in the repository
> is titled "Securing Container Runtimes (How Hard Could It Be?)" and the
> `README.md` lists it under that name — the alternative title could not be
> confirmed from the repository. Several 2020 and 2025 slides are image-only
> or animated overlays (2020-01 slides 24, 26, 28–30 are glitch-art
> renderings of "let's have a chat about procfs", "what about bind-mounts?",
> "and then there's magic-links", "YOU CAN BIND-MOUNT OVER SYMLINKS"; 2025
> slides 23, 26 and 30 differ from their neighbours only by a highlighted token,
> read from a rendered image). Slide text was extracted with `pdftotext`; the
> 2020-08 PDF reported an xref reconstruction warning but extracted fully.

<!-- References -->

[talks-repo]: https://github.com/cyphar/talks/tree/95d789ca651c269a9df90d20390069a8412c5024
[talks-license]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/COPYING
[lpc19]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2019/09-linux-plumbers/securing-path-resolution.pdf
[lpc19-readme]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2019/09-linux-plumbers/README.md
[lca20]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2020/01-linux-conf-au/securing-runtimes.pdf
[lca20-readme]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2020/01-linux-conf-au/README.md
[lpc20]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2020/08-LinuxPlumbers/openat2.pdf
[lpc20-readme]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2020/08-LinuxPlumbers/README.md
[asg24]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2024/09-all-systems-go/libpathrs.pdf
[asg24-readme]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2024/09-all-systems-go/README.md
[asg24-ccc]: https://media.ccc.de/v/all-systems-go-2024-310-libpathrs-securing-path-operations-for-system-tools
[lpc25]: https://github.com/cyphar/talks/blob/95d789ca651c269a9df90d20390069a8412c5024/2025/12-lpc/path-safety-in-the-trenches.pdf
[lwn-1050887]: https://lwn.net/Articles/1050887/
[lwn]: ./lwn-openat2-series.md
[libpathrs]: ./libpathrs.md
