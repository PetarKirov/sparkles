# Dean & Hu 2004 / Borisov et al. 2005 — the k-Race defense and its demolition

A matched pair, one file: Dean & Hu prove no portable _deterministic_ fix for
the `access(2)`/`open(2)` race exists, offer a _probabilistic_ one (make the
attacker win `2k+1` races), and Borisov, Johnson, Sastry & Wagner answer a year
later with the **filesystem maze**, which drives the per-race win probability to
≈ 1 and breaks it outright.

|                 |                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (two papers, one rebuttal arc)                                                                          |
| **Year**        | 2004 (Dean & Hu) / 2005 (Borisov et al.)                                                                      |
| **Authors**     | Drew Dean (SRI), Alan J. Hu (UBC) · Nikita Borisov, Rob Johnson, Naveen Sastry, David Wagner (UC Berkeley)    |
| **Venue**       | USENIX Security 2004, pp. 195–206 · USENIX Security 2005, pp. 303–314                                         |
| **Language**    | C                                                                                                             |
| **License**     | not stated (academic); Borisov et al. released attack code (`nikita.ca/research/races.tar.gz`)                |
| **Platforms**   | Linux, FreeBSD, Solaris, SunOS, OpenBSD (by source reading)                                                   |
| **Primitive**   | k-Race: `k` strengthening rounds of `access`+`open`+`fstat`-compare · attack: symlink mazes + `atime` polling |
| **Source read** | `dean04-access.pdf` ([Dean & Hu PDF][dh]), `borisov05-atime.pdf` ([Borisov PDF][bo]), both in full            |

## Overview

### What it solves

The `access`/`open` idiom is the archetypal setuid race: check the invoker's
rights with `access`, then `open` as root, and lose to any attacker who swaps
the name between the two. Dean & Hu first settle the folklore
([Abstract, p. 1][dh]):

> We prove the "folk theorem" that no portable, deterministic solution exists
> without changes to the system call interface, we present a probabilistic
> solution, and we examine the effect of increasing CPU speeds on the
> exploitability of the attack.

Borisov et al. set out to close the door the probabilistic solution left open
([Abstract, p. 1][bo]):

> Dean and Hu proposed a probabilistic countermeasure to the classic
> `access(2)`/`open(2)` TOCTTOU race condition [...] we describe an attack that
> succeeds with very high probability against their countermeasure. [...] We
> conclude that `access(2)` must never be used in privileged Unix programs.

### Design philosophy

Dean & Hu borrow **hardness amplification** from cryptology ([§4, p. 5][dh]):
a single race the attacker wins with probability `p < 1` is turned into a
compound event the attacker must win `2k+1` times, so the success probability
`p^(2k+1)` is driven negligible by choosing `k` large — "the same trade-off
behind modern cryptology." The entire security rests on one assumption, which
Borisov et al. name and then break: that `p` is bounded well below 1.

## How it works

### Dean & Hu: the impossibility proof

Model the defender's syscall sequence as a string `σ` over `{a, o}` (`a` = an
access-check call, `o` = any other, e.g. `open`) and the attacker's actions as a
string `τ` over `{g, b}` (`g` = swap in a _good_ file the real uid may access,
`b` = swap in a _bad_ one) ([§3, p. 4][dh]). If the attacker can win every race
(control the interleaving), then against `σ` containing `n` copies of `a`, the
attack `(gb)^n` brackets every `a` with a good file (so each check passes) and
every `o` with a bad file (so every other operation sees the target), with no
detectable inconsistency. Under the three stated assumptions — no fd-returning
check exists, no check atomically yields an unchangeable identifier, and the
attacker wins all races — "there is no way to write a setuid program that is
secure against the `access(2)`/`open(2)` race." `fstat` does not escape the
theorem: its buffer "contains permission information for the file only, but
doesn't consider the permissions through all directories on the file's path"
([§3, p. 4][dh]).

### Dean & Hu: the k-Race solution

Weaken the "wins all races" assumption to "wins each race with probability
`p`" ([§4, p. 5][dh]). After the ordinary `access`+`open`, run `k`
**strengthening rounds**, each an extra `access`+`open`+`fstat`, verifying
every descriptor is the same file:

```c
/* the strengthening loop (error handling elided) */
orig_inode = buffer.st_ino;  orig_device = buffer.st_dev;
for (i = 0; i < k; i++) {
    if (access("targetfile", R_OK) != 0)  /* return error */;
    rept_fd = open("targetfile", O_RDONLY);
    fstat(rept_fd, &buffer);  close(rept_fd);
    if (orig_inode != buffer.st_ino)   /* return error */;
    if (orig_device != buffer.st_dev)  /* return error */;
}
```

**Theorem 2**: the attacker must win at least `2k+1` races, giving success
≈ `p^(2k+1)`. Randomized `nanosleep` delays before each call foil
synchronization. Two caveats bound the guarantee: the calls "must be idempotent
and have no undesirable side effects", so `(O_CREAT | O_EXCL)` and devices like
tapes are excluded ([§4, p. 5][dh]).

### Dean & Hu: the measurements

The surprise is empirical ([§5.1–5.2, p. 6–7][dh]): on a modern uniprocessor
the _unstrengthened_ race is already extremely hard — **1 win in 1.5 M** on
Linux, **14 in 1 M** on FreeBSD — because a scheduling quantum runs so many
instructions that the ~15 user-mode instructions between the two syscalls pass
"quasi-atomically". A resurrected 40 MHz SPARCstation 2 won 1316/1M, confirming
the race was easier in the 1980s. But on a multiprocessor the quantum argument
fails: Solaris won **117 573 / 1 M** at `k=0`. Dean & Hu recommend `k=7`
(estimated success below `10^-15`) and warn that multi-/hyper-threaded CPUs make
the multiprocessor case the norm.

### Borisov et al.: why the assumption is false

The attack refutes `p < 1` with two ideas ([§4–5, p. 4–8][bo]):

- **Filesystem mazes.** A **chain** is the deepest nested directory a single
  path can name under `PATH_MAX`; chains are stitched with symbolic links so one
  lookup traverses far more directories than `PATH_MAX` bounds. `MAXPATHLEN`
  limits path _elements_, not directories _traversed_ (Table 2): under
  Linux 2.6's 40-symlink limit an attacker builds a name forcing the kernel to
  walk **over 80 000 directories / ~300 MB** off disk. If even one is
  uncached, the victim **sleeps on I/O** — the attacker now has ample time to
  win the race, deterministically. Mazes make the "somewhat hard" race a
  certainty (`p ≈ 1`).
- **`atime` polling + `sentry`.** "Unix updates the access time on any symbolic
  links it traverses during name resolution" ([§4, p. 4][bo]). A `sentry` link
  near the maze entrance, polled through a level of indirection that avoids
  pulling the maze into cache, tells the attacker exactly when the victim has
  begun each `access`/`open` — restoring the single-stepping synchronization
  the randomized delays were meant to prevent.

Against the **basic** deterministic k-Race the attacker alternates 16 mazes,
even-numbered ones pointing at a public file, odd ones at `/etc/shadow`, and
advances a `activemaze` link after each detected syscall.

### Borisov et al.: beating the randomized variant

Dean & Hu suggest randomizing whether each round does `access` or `open` so the
attacker cannot predict the sequence. Borisov et al. answer with **system-call
distinguishers** ([§7, p. 8–9][bo]): `access` transiently swaps the process's
effective (or, on Linux, filesystem) uid to the real uid, so an attacker reading
`/proc/<pid>/status` (or `psinfo` on Solaris) can tell _which_ call is in
flight — "if the victim's effective and real user IDs are equal, then it is
calling `access(2)`, otherwise it is calling `open(2)`." They toggle a shared
`target` link accordingly and win regardless of order.

### The results

```text
k-Race, recommended k = 7          Randomized k-Race, k = 100
  FreeBSD 4.10   92 / 100            Linux 2.6.8    19 / 100
  Linux 2.6.8    98 / 100            Solaris 9      77 / 100
  Solaris 9     100 / 100            FreeBSD       88 / 100
(Table 1, p. 1)                    (Table 3, p. 9; also k=1000: 83/100 by reusing mazes)
```

The attack wins **over 90 % on every OS** at the recommended `k=7`, scales to
`k=100` and even `k=1000`, and defeats the randomized variant — refuting Dean &
Hu's claim that faster CPUs would make the attack _harder_: mazes exploit the
disk/CPU gap, so "as this gap grows our attack will become more powerful."

### What broke, and what did not

Precisely broken: the **probabilistic `access`/`open` k-Race**, deterministic
and randomized, and by extension any user-space defense that assumes an
attacker cannot reliably win a filesystem race. The maze tools are general —
"applicable to other Unix filesystem races, such as the `stat(2)`/`open(2)` race
common in insecure temporary file creation."

Explicitly _not_ broken ([§8, p. 9][bo]): the **`fork`/`open` + `setuid`-drop**
approach still gives deterministic security (a child permanently drops privilege,
`open`s, and passes the fd back over a Unix-domain socket) — and Borisov et al.
show it is _faster_ than k-Race at `k=100`. Kernel help remains sound: Dean &
Hu's proposed **`O_RUID`** flag (open using the real uid) and portable
privilege-dropping would fix it with `open`'s performance. Their verdict is not
"file races are unwinnable" but "`access` must never be used; use the operating
system to enforce the check when it opens the file."

### Dimension 1 — threat model

An unprivileged local user versus a setuid-root program using `access`/`open`,
on both uni- and multiprocessors. In scope: symlink swaps between the two calls;
and, uniquely for this arc, **algorithmic manipulation of the lookup itself** —
mazes are a directory-walk-time attack that makes the victim sleep on I/O, and
`atime`/`/proc` side channels that single-step it. The adversary needs only the
ability to create directories and symlinks on the same filesystem and to read
`/proc`. Out of scope: attacks needing root, and (for the defense) the temp-file
`(O_CREAT|O_EXCL)` creation race, which the idempotence caveat excludes.

### Dimension 2 — resolution primitive and its atomicity claim

k-Race's primitive is **repeated check-and-compare**: `access`+`open`+`fstat`,
`k` times, asserting `st_ino`/`st_dev` (and `st_gen` if available) are stable
across every `open`. Its atomicity claim is **probabilistic, not real** — no
single operation is atomic; instead the compound is made hard to attack with
probability ≈ `1 - p^(2k+1)`. Borisov et al.'s contribution is to show that
claim is void because `p → 1`: the sequence is not even approximately atomic
once the attacker can single-step it. The maze is not a resolution primitive but
an anti-primitive — it weaponizes the kernel's own multi-component,
symlink-following lookup against the defender.

### Dimension 3 — symlink and `..` policy

k-Race has none — it re-resolves the same name every round and only compares the
resulting inode, which is exactly what mazes exploit (each re-resolution walks a
new, uncached maze). The attack is _built_ from symlinks: chains linked into
mazes, `sentry` links for `atime` timing, `activedir`/`target` links toggled
between public and secret files. The 40-symlink `ELOOP` limit is treated as a
parameter to design around, not a defense. `..` plays no role.

### Dimension 4 — boundaries

Mount and procfs boundaries are attack _tools_, not defended edges: the maze
lives on the same local filesystem as the target (Borisov et al. note NFS
behaves differently and `noatime` mounts disable the `atime` channel, but the
`/proc` distinguishers work instead), and `/proc/<pid>/status` / `psinfo` is the
side channel that reads the victim's in-flight syscall. No `st_dev`/`RESOLVE_*`
style boundary check exists in either paper — the defense predates them.

### Dimension 5 — portability and fallback

Portability is the whole point of k-Race — "a highly portable probabilistic
solution that works under the existing system call interface" ([Abstract][dh]) —
and its whole vulnerability, since it must re-resolve names the kernel controls.
Both papers agree the deterministic fallbacks are the real answers but are
non-portable: `O_RUID` needs a kernel change; `setuid`-juggling "can be made to
work, but is generally not portable" because the `setuid` family "is its own
rats nest" with silent-failure semantics ([§2.2, p. 3][dh]); `fork`/`open`
works cross-platform but "`fork(2)` is a relatively expensive system call."
Borisov et al. suggest hiding these behind a libc wrapper.

### Dimension 6 — failure and partiality

k-Race fails **closed**: any inode/device mismatch returns an error and no file
descriptor. Its real partiality is silent _insecurity_ — it returns a valid fd
believing it verified access, when under a maze attack it has been single-stepped
into opening the secret file. The attack's own robustness is quantified across
machines and disk layouts (Table 3): "extremely sensitive to the target
machine's state" in the basic form, "robust" once mazes are used. `EAGAIN`/rename
races during a walk are not a concern — the walk is the attacker's instrument.

### Dimension 7 — enumeration and deletion

Does not apply — neither paper walks or deletes a tree. The maze is the inverse:
a deliberately huge directory structure the _defender_ is forced to walk. The
one relevant crossover is that the maze tools "can be used to attack other Unix
filesystem races," including the temp-file creation race, so any enumeration or
deletion loop that re-resolves names is equally exposed.

## Strengths

- **Dean & Hu**: the impossibility proof is clean and correct — no portable
  deterministic fix exists without a kernel/API change — and reframes a race as
  a cryptographic hardness problem.
- The **uniprocessor measurements** are a genuinely counter-intuitive result:
  the classic race is nearly unwinnable on a fast single CPU, and the danger is
  the multiprocessor.
- **Borisov et al.**: mazes turn "hard to exploit" into "deterministic",
  overturning the milliseconds-window folklore for a whole class of races.
- The **general tooling** (mazes, synchronizers, distinguishers) outlives the
  specific target and informs later work ([Tsafrir][tsafrir], [Cai][cai]).

## Weaknesses

- **k-Race is broken.** >90 % attacker wins at the recommended `k=7`; the
  security assumption (`p < 1`) is false whenever the attacker can force I/O.
- **Randomization does not save it** — `/proc` and uid side channels distinguish
  the calls.
- Dean & Hu's speculative "one round of strengthening may be deterministic on
  Linux 2.4.18 as root" rests on "undocumented behavior of a particular kernel
  version" — they themselves "strongly urge that it not be used."
- The real fixes both papers endorse (`O_RUID`, privilege-drop, `fork`/`open`)
  are non-portable or slow — the gap [Tsafrir et al.][tsafrir] then try to close
  in user space.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                     | Trade-off                                                                        |
| ----------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Amplify hardness with `2k+1` races instead of a kernel change     | Portable; works under the existing API                        | Security rests on `p < 1`, which mazes falsify — the scheme is broken            |
| Verify with `fstat` inode/device compare each round               | Descriptor binding is immutable, so a mismatch reveals a swap | Re-resolving the _name_ each round is exactly what a maze slows and single-steps |
| Randomized `nanosleep` delays to prevent synchronization          | Denies the attacker a fixed timing                            | Defeated by `atime` polling and `/proc` syscall distinguishers                   |
| (Attack) Force the victim to sleep on I/O via a maze              | Guarantees the attacker gets scheduled inside the window      | Needs a large same-filesystem structure and uncached directories                 |
| (Attack) Read `/proc/<pid>/status` to distinguish `access`/`open` | Beats the randomized variant without predicting the sequence  | Relies on the transient real-uid swap `access` performs                          |
| Endorse `fork`/`open` + privilege-drop as the real fix            | Deterministic and, at `k=100`, faster than k-Race             | `fork` is costly; privilege-dropping is non-portable across Unixes               |

## Sources

- [Dean & Hu, "Fixing Races for Fun and Profit: How to use access(2)", USENIX Security 2004][dh] — §2.2 partial solutions and `O_RUID`; §3 the folk-theorem impossibility proof (`σ`/`τ` model); §4 k-Race and Theorem 2 (`2k+1` races); §5.1–5.2 uni- vs multiprocessor measurements and the `k=7` recommendation
- [Borisov, Johnson, Sastry & Wagner, "Fixing Races for Fun and Profit: How to abuse atime", USENIX Security 2005][bo] — §4 basic maze attack and `atime`/`sentry` synchronization; §5 chains, `MAXPATHLEN` vs directories traversed (Table 2), ~300 MB mazes; §7 system-call distinguishers via `/proc`; §8 the surviving `fork`/`open` and `O_RUID` defenses; Table 1/3 success rates
- [Bishop & Dilger 1996][bishop] — the binding-flaw frame both papers cite
- [Tsafrir et al. 2008][tsafrir] — restores hardness amplification against mazes; [Cai et al. 2009][cai] — later breaks that too

<!-- References -->

[dh]: https://www.usenix.org/legacy/event/sec04/tech/full_papers/dean/dean.pdf
[bo]: https://www.usenix.org/legacy/event/sec05/tech/full_papers/borisov/borisov.pdf
[bishop]: ./bishop-dilger-1996.md
[tsafrir]: ./tsafrir-2008.md
[cai]: ./cai-2009.md
