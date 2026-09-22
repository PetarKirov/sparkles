# Wei & Pu 2005 — TOCTTOU Vulnerabilities in UNIX-Style File Systems: An Anatomical Study

The paper that counted the attack surface: a model (`CUU`) that enumerates
**224 dangerous file-system call pairs** in Linux, plus a kernel monitor that
used the enumeration to find live TOCTTOU bugs in `rpm`, `vi` and `emacs`.

|                 |                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------ |
| **Kind**        | paper                                                                                      |
| **Year**        | 2005 (December)                                                                            |
| **Authors**     | Jinpeng Wei, Calton Pu — Georgia Institute of Technology                                   |
| **Venue**       | FAST '05: 4th USENIX Conference on File and Storage Technologies, pp. 155–167              |
| **Language**    | model is language-independent; tools are Linux kernel `printk` sensors + a daemon + XSLT   |
| **License**     | not stated (academic paper)                                                                |
| **Platforms**   | Linux (Red Hat 9, kernel 2.4.20); the model is written for "the Linux virtual file system" |
| **Primitive**   | the `CUU` model — `CU-call` × `Use-call` pair enumeration                                  |
| **Source read** | `wei05-anatomy.pdf` ([canonical PDF][pdf]), all 13 pages                                   |

## Overview

### What it solves

[Bishop & Dilger][bishop] defined the binding flaw and detected _some_
instances by pattern-matching. Wei and Pu ask the completeness question: given
Linux's file-system calls, exactly which pairs can race? Their framing widens
the classic "check then use" to "any two calls with a dependency"
([§2.1, p. 156][pdf]):

> Our model includes the original check-use system call pairs [...], plus
> use-use pairs. For example, a program may attempt to delete a file (instead
> of checking whether a file exists) before creating it. Consequently, the pair
> `<delete, create>` is also considered a (broadly defined) TOCTTOU pair.

That widening is what makes the count larger than Bishop's, and it is the same
extension [Tsafrir et al.][tsafrir] credit for catching the `rpm` `<open, open>`
bug that a pure check/use model would miss.

### Design philosophy

A TOCTTOU pair is not bad programming — it is inherent to the API
([§2.2, p. 157][pdf]):

> We say that TOCTTOU vulnerabilities are not due to bad programming practices,
> since in Group 1 the CU-call establishes the precondition that the file
> pathname does not exist and in Group 2 the CU-call establishes the
> precondition that the file pathname exists.

The method is anatomical rather than theoretical: enumerate the pairs from the
functional spec, then _dynamically_ monitor a running system for those pairs on
the same path, because "the attack programs are usually unavailable until the
vulnerabilities are discovered" and static analysis "cannot be applied
directly" ([§1, p. 156][pdf]).

## How it works

### The CUU enumeration

Two seed sets are selected from the Linux file-system calls that take a pathname
([§2.2, p. 156][pdf]) — calls that "do not follow symbolic links" such as
`swapon` are filtered out:

```text
CUSet  = { access, stat, open, creat, mknod, link, symlink, mkdir, unlink,
           rmdir, rename, execve, chmod, chown, truncate, utime, chdir,
           chroot, pivot_root, mount }
UseSet = { creat, mknod, mkdir, rename, link, symlink, open, execve, chdir,
           chroot, pivot_root, mount, chmod, chown, truncate, utime }
```

These are then partitioned by the kind of object each call touches, so that a
pair always agrees on object type (`<creat, chdir>` is meaningless — `creat`
makes a regular file, `chdir` wants a directory):

```text
CheckSet        = { stat, access }
CreationSet     = FileCreationSet ∪ LinkCreationSet ∪ DirCreationSet
RemoveSet       = FileRemoveSet   ∪ LinkRemoveSet   ∪ DirRemoveSet
NormalUseSet    = FileNormalUseSet ∪ DirNormalUseSet
```

Pairs split into **Group 1** (the CU-call establishes "does not exist" — a
`CheckSet`/`RemoveSet` call followed by a `CreationSet` call of the matching
type) and **Group 2** (the CU-call establishes "exists" — check or creation or
normal-use followed by a normal-use). The cross-product over the type-matched
subsets, laid out in Table 2 ([p. 157][pdf]), yields the headline number:

> A total of 224 pairs have been identified using this table.

A companion paper is cited for the completeness proof ("A formal proof of the
completeness of `CUU` is out of the scope of this paper").

### The detection framework

Four components ([§3.2, p. 158–159][pdf]):

1. **Sensors** — plug-in code in every `CUSet`/`UseSet` kernel entry, recording
   call name, full pathname, and the environment (`pid`, `uid`, `euid`, …) into
   a circular `printk` ring buffer. They pre-filter by dropping calls under
   root-owned system directories that no normal user can alter — the
   **immune-directory** list of Table 4 (`/bin`, `/etc`, `/usr/bin`, …), the
   single biggest false-positive reducer.
2. **Collector** — a daemon that drains the ring buffer to XML.
3. **Analyzer** — sorts records by pathname and matches consecutive calls
   against the Table 2 pair list, in four XSLT rounds.
4. **Inspector** — decides real exploitability by checking the call's arguments
   (`chmod` mode, `chown` owner), the pathname's directory writability, and
   `euid == 0`. Its templates (Table 5) are one signature per attack scenario.

The measured window between the two `open`s in `rpm` is a few milliseconds —
"relatively narrow (less than 5%)" of total runtime ([§4.2.1, p. 160][pdf]) —
which is the number [Tsafrir et al.][tsafrir] later quote as the belief mazes
overturned.

### Dimension 1 — threat model

An unprivileged local user versus a root-privileged utility that manipulates a
file **outside** the immune directories — i.e. in `/tmp`, `/var/tmp`, or the
user's own home ([§3.1, p. 158][pdf]): "even though the victim is running at a
higher level of privilege, the attacker must have sufficient privileges to
operate on the shared file attributes, e.g. creation or deletion." In scope are
symlink swaps, hard links, and delete/recreate on any pathname component the
attacker controls; the classification is by system-call pair, not by mechanism.
Out of scope: the paper states its own limits explicitly — uniprocessor
scheduling only ("Multiprocessors, hyper-threaded uniprocessors, or multi-core
processors are beyond the scope"), and vulnerabilities where no precondition is
established (a program that `creat`s a known temp name without a prior `stat`)
"may happen outside the CUU model" ([§5.1, p. 164][pdf]).

### Dimension 2 — resolution primitive and its atomicity claim

Does not apply as a _defense_ — this is an attack-surface and detection paper.
Its atomicity statement is the diagnosis, not a cure ([§1, p. 155][pdf]):
"Because the two steps are not executed atomically, a local attacker [...] can
exploit the window of vulnerability between the two steps." The paper is
explicit that prevention is future work: the `CUU` model "also suggests online
defense mechanisms similar to pseudo-transactions [...] beyond the scope of this
paper" ([§7, p. 166][pdf]). Detection is post-hoc dynamic monitoring, atomic
with respect to nothing.

### Dimension 3 — symlink and `..` policy

The model has no symlink or `..` policy of its own; it treats symlink following
as _the_ attack channel and filters out calls that do not follow links
(`swapon`). The demonstrated exploits are almost all symlink swaps: `vi`
replaces the saved file "with a symbolic link to `/etc/passwd`"
([§4.3.2, p. 163][pdf]); `esd` is attacked by pre-creating `/tmp/.esd` as a
symlink so its `mkdir`/`chmod 777` lands on the attacker's home directory
([§4.4, p. 164][pdf]).

### Dimension 4 — boundaries

The only boundary is the **immune-directory** filter (Table 4): root-owned
directories whose contents a normal user cannot change are declared safe and
dropped before analysis. The paper is candid that this is incomplete — a
false-positive source is "newly created root-owned directories under
`/usr/local`" not in the static list ([§5.2, p. 165][pdf]). Mounts, procfs
magic links, and special filesystems are not modelled.

### Dimension 5 — portability and fallback

Does not apply directly (no defensive primitive to fall back from). The model is
claimed "programming language-independent" and the tools "work without changes
or access to application source code" ([§7, p. 166][pdf]), but the
implementation is Linux-2.4-specific kernel instrumentation. The enumeration
itself is tied to the Linux syscall set; a different kernel would need its own
`CUSet`/`UseSet`.

### Dimension 6 — failure and partiality

Two honest failure catalogs. **False negatives** ([§5.1][pdf]): dynamic
monitoring "only covers the execution paths exercised by the workloads", and
the model misses vulnerabilities where no precondition is established. **False
positives** ([§5.2][pdf]): an incomplete immune list, test cases that
themselves use `/tmp`, coincidental unrelated calls on the same file from two
processes, and pairs that are unexploitable in context (`rpm --addsign`'s
`<stat, open>` can open `/etc/shadow` but "`rpm` can not process `/etc/shadow`
because it is not in the format recognizable by `rpm`"). Filter tuning dropped
one experiment's false-positive rate "from 75% to 27%".

### Dimension 7 — enumeration and deletion

Does not apply as a defended operation, but the paper's most instructive attack
_is_ a save-then-fix sequence. `vi` saving as root ([§4.3, p. 162][pdf])
renames the original to a backup, creates a new file with the original name
(owned by root), then `chown`s it back to the user — an `<open, chown>` window
in which the attacker symlinks the name to `/etc/passwd`, so `vi` chowns the
password file. `gedit` does the same but via a temp file `rename`d into place,
"a very short time that reduces the probability of successful attack" — a design
difference that changes exploitability without changing correctness, exactly the
kind of walk/rename hazard fd-relative enumeration removes.

## Strengths

- **The 224-pair enumeration** is the field's reference count for "how big is
  the TOCTTOU surface", cited by [Tsafrir et al.][tsafrir] and every survey
  since.
- **Use/use pairs** widen Bishop's check/use frame and are what catch the
  real `rpm` `<open, open>` bug.
- **Live bugs, quantified**: previously-unreported races in `rpm` (85% success),
  `vi`, `emacs`, `gedit`, `esd`, with measured windows and success rates.
- The **immune-directory filter** is a practical, still-used heuristic for
  cutting monitoring noise.

## Weaknesses

- **Detection, not prevention** — the tool tells you a race happened; it closes
  nothing. Prevention is deferred to future work.
- **Coverage-bound**: dynamic monitoring only sees exercised paths, so absence
  of a report proves nothing.
- **Uniprocessor-only** analysis; the authors' own later work
  ("Multiprocessors may reduce system dependability…") shows SMP changes the
  odds sharply.
- Kernel-instrumentation overhead is real where it matters: up to **144% on
  `stat`** and 46% on `mkdir` in a vulnerable directory (Table 8), though only
  a few percent amortised over application benchmarks.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                           | Trade-off                                                             |
| ----------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Broaden TOCTTOU to include use/use pairs              | Catches races (like `rpm` `<open, open>`) a check/use model misses  | Larger pair count; some pairs are semantically implausible and pruned |
| Type-match the two sets before crossing them          | `<creat, chdir>` cannot race — different object kinds               | The 224 count depends on the partitioning choices                     |
| Detect dynamically via kernel sensors, not statically | Attack programs are unavailable; runtime state (names, uids) needed | Coverage-limited; kernel overhead; per-kernel port                    |
| Filter root-owned immune directories in the kernel    | Files a normal user cannot alter cannot be attacked                 | Static list goes stale (`/usr/local`), causing false positives        |
| One Inspector template per attack scenario            | Turns "a pair fired" into "a real, profitable exploit"              | Must be extended by hand as new scenarios appear                      |

## Sources

- [Wei & Pu, "TOCTTOU Vulnerabilities in UNIX-Style File Systems: An Anatomical Study", FAST '05][pdf] — §2.1 broad TOCTTOU definition; §2.2 `CUSet`/`UseSet` and the 224-pair Table 2; §3.1 immune directories (Table 4); §3.2 the sensor/collector/analyzer/inspector framework; §4.2 the `rpm` `<open, open>` exploit (85%); §4.3 the `vi` `<open, chown>` exploit; §4.4 `emacs`/`gedit`/`esd`; §5 false negatives and positives; §5.3 overhead (Table 8)
- [Bishop & Dilger 1996][bishop] — the check/use model this generalizes
- [Tsafrir et al. 2008][tsafrir] — cites the enumeration and the "milliseconds" window belief

<!-- References -->

[pdf]: https://www.usenix.org/legacy/event/fast05/tech/full_papers/wei/wei.pdf
[bishop]: ./bishop-dilger-1996.md
[tsafrir]: ./tsafrir-2008.md
