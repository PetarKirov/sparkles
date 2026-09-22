# Tsafrir et al. 2008 — Portably Solving File TOCTTOU Races with Hardness Amplification

Hardness amplification, made to work. Where [Dean & Hu][dean-hu]'s k-Race
re-resolved the whole path every round — and [Borisov et al.][dean-hu]'s mazes
exploited exactly that — Tsafrir et al. resolve the path **one component at a
time**, `fchdir`-ing down it, so the race window stays in the defender's cache
and out of the attacker's reach. A portable, user-space `access`/`open` that
survives mazes and even a fully-synchronized hypothetical attacker.

|                 |                                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (USENIX FAST '08 Best Paper)                                                                                      |
| **Year**        | 2008 (February)                                                                                                         |
| **Authors**     | Dan Tsafrir (IBM Research), Tomer Hertz (Microsoft Research), David Wagner (UC Berkeley), Dilma Da Silva (IBM Research) |
| **Venue**       | FAST '08: 6th USENIX Conference on File and Storage Technologies, pp. 189–206                                           |
| **Language**    | C                                                                                                                       |
| **License**     | not stated (academic paper)                                                                                             |
| **Platforms**   | Solaris 8, Linux 2.4/2.6, AIX 5.3 (measured); portable POSIX in principle                                               |
| **Primitive**   | **column-oriented** (atom-by-atom) user-space path resolution + per-component k-Race (`atom_race`)                      |
| **Source read** | `tsafrir08-fast.pdf` ([canonical PDF][pdf]), all 18 pages; `cai09-mazes.pdf` intro (cross-ref only)                     |

## Overview

### What it solves

A portable, standard, user-mode `check_use` utility that binds a check and a use
into a pseudo-transaction on **existing** systems — no kernel change, no new
filesystem ([§1, p. 2][pdf]):

> We contend that the situation can potentially be greatly improved if
> programmers are able to use some portable, standard, generic, user-mode
> `check_use` utility function that, given a 'check' operation and a 'use'
> operation, would perform the two as a kind of "transaction", in a way that
> appears atomic for all relevant purposes.

The urgency is that mazes generalized the threat. Tsafrir et al. note the
insight [Borisov et al.][dean-hu] under-sold ([§1, p. 2][pdf]):

> mazes constitute a generic way to consistently win a large class of TOCTTOU
> races. This is true because any 'check' operation can be slowed down and
> single-stepped, if provided with a filesystem maze as an argument.

so the "usually narrow window of vulnerability (on the order of milliseconds)"
belief from [Wei & Pu][wei-pu] "is no longer true."

### Design philosophy

The key observation is that the traversal _order_ is a free variable
([§4, p. 7][pdf]). A name-based syscall is an `O(n)` walk over `n` components;
k-Race does that walk `k` times **row-oriented** — the whole path each round —
so the interval between two visits to component `f_i` is long enough for the
attacker to evict it from cache and win. Tsafrir et al. flip it to
**column-oriented**: resolve one component, `k`-strengthen _that atom_, descend,
repeat. The two visits to `f_i` are now adjacent, so "the respective inode would
most probably be continuously present in the cache throughout the k-race." The
race is made "fair" again — the attacker loses control of the window's duration.

```text
row-oriented (Dean & Hu):   /, f1, f2, f3,   /, f1, f2, f3     (whole path, K times)
column-oriented (this):     /, /, f1, f1, f2, f2, f3, f3       (each atom, K times, in place)
```

## How it works

### Column-oriented resolution

`access_open_2008` ([Figure 9, p. 12][pdf]) walks the path with only **relative,
single-component** names, `fchdir`-ing into each resolved directory so the next
`lstat`/`access`/`open` operate on an atom, never on a maze:

```c
while (true) {
    suffix = chop_1st(fname);                       // peel one component
    is_symlink(fname, target, &s, &is_sym);         // lstat — never follows
    fd = is_sym ? access_open_2008(target)          // recurse on the link target
                : atom_race(fname, &s);             // k-strengthen this atom
    if (suffix) { fchdir(fd); close(fd); fname = suffix; }
    else break;
}
```

Two helpers make it safe:

- `chop_1st` ([Figure 6][pdf]) returns the remainder as a _relative_ path,
  collapsing leading slashes, so no descendant call ever sees an absolute maze.
- `is_symlink` ([Figure 7][pdf]) `lstat`s the atom **without following it**; if a
  link, it reads the target for recursion; if a hard link, it records the inode
  as the reference point for the atom's race. Because `lstat` operates on a
  one-component name in the current directory, "we make sure that the invoker is
  not forced to go through a maze."

### The per-atom race

`atom_race` ([Figure 8, p. 12][pdf]) is Dean & Hu's loop scoped to one
component — an initial `access`+`open`+`fstat`, then `k` rounds each adding an
`lstat` that re-checks the atom is still a non-symlink (so the defense recovers
even if the attacker briefly wins the first race and injects a maze):

```c
for (i = 0; i < K; i++) {
    lstat(atom, &s1);  DO_CHK(!S_ISLNK(s1.st_mode));   // still a hard link?
    access(atom, mode);  fd2 = open(atom, O_RDONLY);  fstat(fd2, &s2);
    close(fd2);
    DO_CHK(DO_CMP(s0, &s1));  DO_CHK(DO_CMP(s0, &s2));  // s0 == s1 == s2
}
```

"The security of our algorithm is reduced to the security of `atom_race` (all
other functions are completely safe)."

### The hypothetical attacker experiment

Rather than claim immunity, the authors stack the deck for the attacker
([§5–6, p. 8–10][pdf]). An **exposed defender** publishes its next syscall
through a shared-memory variable; a **synchronized attacker** polls it and acts
with perfect, instantaneous knowledge — far stronger than a maze. They then
measure `p` (per-round win probability) and `t` (round duration) on five
multiprocessors and compute the expected time to `k` consecutive wins,
`B_k = t · p^(-k)` (Equation 1). Result ([§6.2, p. 8–9][pdf]): even with this
ideal attacker, `k=9` pushes the expected attack time to **53 years to millions
of years** across the machines — because slowing the defender (raising `p`) also
raises `t`, so "the attacker inevitably contributes [...] to making `B_k`
larger." Overhead is linear in path length and modest (Figure 14).

### `openat` would simplify it

The `fchdir` dance has a cost the authors flag ([§4.1, p. 11][pdf]): it mutates
the process-wide working directory, so `access_open_2008` "is inadequate for
multithreaded applications if some other thread [...] requires the working
directory to remain unchanged." Their fix is the primitive the rest of this
catalog is built on:

> We note in passing that the relatively new system call `openat` (which opens a
> filepath relative to a given directory file descriptor) would solve this
> problem, as it will eliminate the need for using `fchdir`; `openat` is
> proposed for inclusion in the next revision of POSIX.

### Generalization: `check_use`

Section 7 lifts `access_open` into a generic `check_use` taking
pointer-to-function checks (`F_chk^dir`, `F_chk^link`, `F_chk^last`) and a use
(`F_use^last`), so a garbage collector can refuse any symlinked component or a
caller can enforce arbitrary per-component credential checks. The authors also
sketch a **fully deterministic** user-mode `access` — walk column-oriented,
`fchdir` only into hard-link atoms, and decide access from each atom's `stat`
ownership/permission bits — noting the probabilistic loop can then be dropped
entirely. A limitation is stated plainly: "Like the maze-attack, our approach
works on already-existing-files only" — the temp-file creation race is
unresolved.

### Cross-reference: Cai et al. 2009 later broke this

The brief asks whether this defense depends on things Cai et al. 2009 attacked.
It does. Cai, Gui & Johnson's "Exploiting Unix File-System Races via Algorithmic
Complexity Attacks" (IEEE S&P 2009) targets exactly the property Tsafrir et al.
rely on — that a one-component `lstat` stays cached and fast
([cai09-mazes.pdf][cai-pdf], Abstract & §5.1): "Atomic k-race avoids sleeping on
I/O with very high probability, so a maze attack is not feasible. Instead, our
attack uses an **algorithmic complexity attack on the kernel's filename
resolution algorithm**," loading a name-cache hash bucket with colliding
filenames so even a single-component lookup runs slow, and pairing it with
`SIGSTOP`/`SIGCONT` to single-step the victim. Cai et al. conclude "atomic
k-race is insecure." (Their randomized-variant attack was left open.) The Cai
deep-dive is `cai-2009.md`, written separately.

### Dimension 1 — threat model

An unprivileged local user versus a setuid-root program, on uni- and
multiprocessors (the evaluation uses multiprocessors "to increase the attackers'
chances"). In scope: the maze attack in full — symlink chains, `atime`
single-stepping, `/proc` distinguishers — plus a stronger _hypothetical_
attacker with perfect synchronization via shared memory. Three canonical
examples frame it ([Figure 2, p. 3][pdf]): a `/tmp` garbage collector
(`lstat`/`unlink`), a mail server (`lstat`/`open` append), and the setuid
`access`/`open`. Out of scope: file **creation** races (temp files), explicitly
left unresolved, and multithreaded callers that need a stable working directory
(a limitation `openat` would lift).

### Dimension 2 — resolution primitive and its atomicity claim

The primitive is **user-space column-oriented resolution** with a per-atom
k-Race. Its atomicity claim is still probabilistic but now well-founded: each
atom's check-and-use races only against a single cached component, so `p` stays
small _and_ any attempt to raise it (a maze on that atom) raises `t`
proportionally, making `B_k` grow. The `DO_CMP(s0, s1)` / `DO_CMP(s0, s2)`
invariant "insures that all three stat structures are equal" — the atom `lstat`d,
opened, and re-opened are one inode — so an adversary is "deterministically
force[d] to win a race involving a non-symlink atom, on each round." The
deterministic user-mode `access` variant of §7 drops the probabilistic loop
entirely on systems with only classic uid/gid/mode permissions.

### Dimension 3 — symlink and `..` policy

Symlinks are handled by **explicit recursion, never by the kernel**:
`is_symlink` uses `lstat` (which does not follow) to detect a link, then
`access_open_2008` recurses on the link target as its own column-oriented walk.
This is the paper's core safety property — the defender never hands the kernel a
composite, symlink-laden name, so it can never be sent into a maze. Circular
symlinks are handled "in the exact same manner as it is done within the kernel,
that is, by counting the number of traversed symbolic links" ([§4.1, p. 11][pdf]).
`..` is not special-cased; components are consumed literally left to right with
`fchdir`.

### Dimension 4 — boundaries

No mount/procfs/`st_dev` boundary check — the defense is about atomicity of
check-and-use, not about confining resolution to a subtree. (Confinement is what
[`RESOLVE_BENEATH`][openat2] later adds in-kernel.) Because every atom is
resolved relative to the current directory via `fchdir`, the walk _could_ be
bounded by a caller who supplies per-component checks through the `check_use`
`F_chk^dir` hook, but the paper does not frame this as a boundary mechanism.

### Dimension 5 — portability and fallback

Portability is the thesis: a pure-POSIX, user-mode routine ("all source code
included, as an indication of its simplicity") needing no kernel change, in
contrast to the non-portable `O_RUID`, privilege-dropping, and fd-passing fixes
it surveys and rejects (§2.2–2.3). The self-identified fallback improvement is
`openat`, which would remove the `fchdir` working-directory mutation and make
the routine thread-safe. The deterministic §7 variant is portable only where
access control is plain user/group/other bits — with ACLs it "may lead to
incorrect access decisions", a caveat [Cai et al.][cai-pdf] later echo.

### Dimension 6 — failure and partiality

Fails **closed**: `DO_SYS`/`DO_CHK`/`DO_CMP` return `-1` on any syscall failure
or inode mismatch, and the implementation notes ([§4.1][pdf]) list the real-world
partiality it must handle — set `errno` to `EACCES` appropriately, close
already-opened descriptors on error, and **save/restore the working directory**
around the call to undo `fchdir`'s side effect. Truncation is special-cased:
open without `O_TRUNC` then `ftruncate` the descriptor, so a check-failing caller
never truncates the target; `O_CREAT` is forbidden (creation races are out of
scope). The recovery `lstat` in `atom_race` means that even if the attacker wins
the first race and injects a maze, the next round detects the atom is now a
symlink and fails.

### Dimension 7 — enumeration and deletion

Does not apply as an enumeration API, but the `/tmp` garbage collector of
Figure 2a is a **deletion** scenario the generalized `check_use` solves cleanly
([§7, p. 10][pdf]): define `F_chk^dir`/`F_chk^last` to return 0, `F_chk^link` to
return `-1`, and `F_use^last` to `unlink` the atom — any symlinked component then
fails the walk, "insuring all deleted files are under the `/tmp/` directory."
Crucially, because deletion happens on a hard-link atom reached by `fchdir`, "it
does not matter whether the last (unlinked) atom is juggled by the attacker" —
the worst case is deleting an attacker-created link, not the target. This is the
component-verified, fd-relative deletion shape that `remove_dir_all`-style
routines later adopt.

## Strengths

- **Defeats mazes with the same idiom that mazes broke** — column-oriented
  traversal keeps the race window cached and small, turning k-Race's fatal flaw
  into its strength.
- **Honest, adversary-favoring evaluation**: a perfectly-synchronized shared-memory
  attacker still needs 53 years to millions of years at `k=9`.
- **Portable, self-contained, no kernel change** — all source in the paper; a
  drop-in `access_open` and a generalizable `check_use`.
- **Points directly at `openat`** as the primitive that removes the `fchdir`
  wart — the seam every modern dirfd API is built on.

## Weaknesses

- **Later broken.** [Cai et al. 2009][cai-pdf] slow a single-component lookup via
  a name-cache algorithmic-complexity attack (not a maze), refuting the "atom
  stays cached" premise and declaring atomic k-race insecure.
- **`fchdir` mutates the process working directory** — not thread-safe without
  `openat`, which was not yet ubiquitous.
- **Existing files only** — the temp-file creation race is explicitly unsolved.
- The deterministic §7 variant is correct only for classic uid/gid/mode
  permissions; **ACLs and capabilities** can make its user-space access decision
  wrong.
- Still a workaround for a broken API — the authors' own conclusion is "The
  POSIX API is broken."

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                    | Trade-off                                                                                 |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Column-oriented traversal (atom-by-atom, `k` times each)          | Keeps each component cached between its two visits, denying the maze window  | More syscalls than row-oriented; broken later by a name-cache complexity attack           |
| Resolve symlinks by explicit `lstat` + recursion, never in-kernel | The defender never hands the kernel a composite name that could be a maze    | Re-implements kernel path resolution (loop counting, absolute-path handling) in userspace |
| `fchdir` into each hard-link atom                                 | Guarantees the next call operates on a single component in a known directory | Mutates the shared working directory — unsafe for other threads                           |
| Per-atom `s0 == s1 == s2` invariant                               | Forces the attacker to win a race on a non-symlink atom every round          | Adds an `lstat` per round for maze-injection recovery                                     |
| Evaluate against a shared-memory synchronized attacker            | Proves robustness beyond real mazes, not just against them                   | Not a formal proof; assumes real attackers cannot do better                               |
| Generalize to a pointer-to-function `check_use`                   | One utility solves GC, mail-append, and setuid races                         | Programmers must supply correct per-component check predicates                            |

## Sources

- [Tsafrir, Hertz, Wagner & Da Silva, "Portably Solving File TOCTTOU Races with Hardness Amplification", FAST '08][pdf] — §1 the `check_use` goal and maze generalization; §2 the three canonical examples and surveyed solutions; §3 K-Race recap and the maze; §4 column-oriented traversal, `chop_1st`/`is_symlink`/`atom_race`/`access_open_2008` (Figures 6–9); §4.1 the `openat` remark and implementation caveats; §5–6 the exposed-defender / synchronized-attacker experiment and `B_k` results; §7 `check_use` generalization, deterministic variant, and the creation-race limitation
- [Cai, Gui & Johnson, "Exploiting Unix File-System Races via Algorithmic Complexity Attacks", IEEE S&P 2009][cai-pdf] — the name-cache complexity attack that breaks atomic k-race (own deep-dive: [`cai-2009.md`][cai])
- [Dean & Hu 2004 / Borisov et al. 2005][dean-hu] — the k-Race this repairs and the mazes it withstands
- [Wei & Pu 2005][wei-pu] — the "milliseconds window" framing this overturns
- [Bishop & Dilger 1996][bishop] — the original binding-flaw model

<!-- References -->

[pdf]: https://www.usenix.org/legacy/event/fast08/tech/full_papers/tsafrir/tsafrir.pdf
[cai-pdf]: https://doi.org/10.1109/SP.2009.10
[bishop]: ./bishop-dilger-1996.md
[wei-pu]: ./wei-pu-2005.md
[dean-hu]: ./dean-hu-2004-borisov-2005.md
[cai]: ./cai-2009.md
[openat2]: ./linux-openat2.md
