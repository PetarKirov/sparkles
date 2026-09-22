# Exploiting Concurrency Vulnerabilities in System Call Wrappers

Why "check the arguments in a wrapper, use them in the kernel" is not a race you
can shrink — it is a race the architecture creates, and only atomic copy-in or
in-kernel integration removes it.

|                 |                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------- |
| **Kind**        | Paper (attack)                                                                           |
| **Year**        | 2007                                                                                     |
| **Author**      | Robert N. M. Watson (University of Cambridge)                                            |
| **Venue**       | 1st USENIX Workshop on Offensive Technologies (WOOT '07)                                 |
| **Systems**     | GSWTK 1.6.3 (FreeBSD 4.11), Systrace (NetBSD 3.1/4.0, OpenBSD 4.0), CerbNG (FreeBSD 4.8) |
| **Primitive**   | Non-atomic argument copy between a syscall wrapper and the kernel it protects            |
| **Dimension 2** | Attack: the wrapper's precondition check is not atomic with the kernel's use             |
| **Source read** | `watson07-woot.pdf` (8pp.); canonical [PDF][woot-pdf]                                    |

## Overview

### What it solves

Nothing — this is an attack paper, and its target is a whole class of defensive
tools: **system-call interposition** frameworks that hook the syscall trap and
inspect or rewrite arguments before the kernel runs the call. The paper's claim
is that these frameworks share a structural race with the kernel they wrap, and
that the race is exploitable in practice with a 100% success rate against every
package tested.

The framing that the rest of the survey hangs on ([`concepts.md`][concepts])
is the rejection of the atomic-syscall assumption (p.3):

> In contrast to the assumption of atomic system calls made in previous
> considerations of race conditions, the key to our approach is non-atomicity
> between the kernel and system call wrappers.

A wrapper "appears to meet" Anderson's reference-monitor criteria — it runs in
the kernel's protection domain, sits in the syscall path, and is small — but the
resemblance is what Watson calls a "misleading visual congruence" (Fig. 1). A
real reference monitor is atomic with the operation it guards; a wrapper is not.

### Design philosophy

The paper's method is to find a security-relevant resource crossed by a trust
boundary and accessed concurrently by wrapper and kernel, then race it. The one
resource that matters for path traversal is **process memory holding indirect
syscall arguments** — file paths above all (p.3):

> Indirect arguments are referenced by pointers, often passed as direct
> arguments, and copied on-demand by kernel services: for example, file paths
> are copied and resolved by `namei()`. Indirect arguments are copied after the
> precondition hook, so wrappers copy them independently from the kernel,
> opening a race window between the two copy operations.

That single sentence is the whole problem for a "check-then-open" design: the
wrapper reads the path string to make its decision, the kernel reads the same
string again to act, and nothing holds the string still between the two reads.

## How it works

Watson names three **classes of race**, distinguished by what the attacker
manipulates:

- **Synchronization bugs in wrapper logic** — ordinary data races inside the
  wrapper (improper locking). Portable, but the least interesting.
- **Syntactic race conditions** — the attacker changes the _literal bytes_ of an
  argument (the path string) between the wrapper's copy and the kernel's copy.
  These "do not depend on kernel and wrapper internals, and are hence portable
  across wrapper frameworks and operating systems" (p.3), so the paper focuses
  here.
- **Semantic race conditions** — the attacker changes the _interpretation_ of an
  unchanged argument (e.g. swaps what a path resolves to via a symlink or rename
  mid-`namei()`), rather than the bytes.

Crossed with the outcome, the paper introduces three timing categories, two of
them new to the literature (p.4):

- **TOCTTOU** — time-of-check-to-time-of-use: the classic; the check is
  non-atomic with the guarded operation.
- **TOATTOU** — time-of-**audit**-to-time-of-use: the audit trail diverges from
  the real access, so an attacker masks activity from an IDS.
- **TORTTOU** — time-of-**replacement**-to-time-of-use, "unique to wrappers":
  the attacker modifies an argument _after_ the wrapper has rewritten it but
  _before_ the kernel reads it, defeating a wrapper that substitutes a safe
  value.

The exploit mechanics turn on forcing a scheduling window:

```text
UP (uniprocessor): page the argument to disk, so the kernel's copyin() faults
  and sleeps — a window of "several million instruction cycles" (p.4). Even a
  single-argument call is attackable, because copyin() itself sleeps part-way
  through when user data spans multiple pages.

MP (multiprocessor): a second CPU spins watching shared memory for the wrapper's
  replacement, then overwrites it — inter-CPU windows of 10K-100K cycles (p.4).
```

Measured windows: GSWTK (kernel-only) 5K–15K cycles; Systrace (user-space policy
process) over 100K; Sudo-under-Systrace's `execve()` arguments over 430K cycles
(p.4-5). The order-of-magnitude spread "did not lead to measurable differences in
attack cost: we had a 100% success rate in exploiting races across packages."

Concrete results: of 23 GSWTK wrappers, 16 had one or more vulnerabilities
(Table 1) — including precondition TOCTTOU bypasses of a pathname-database
execution authorizer and postcondition TOATTOU races that hide paths from
intrusion-detection wrappers. Against Systrace, both Sudo monitor mode and the
Sysjail containment tool were bypassed (masking `execve()` audit; replacing the
`bind()` IP to escape network confinement). CerbNG's VM write-protection of
argument pages had holes of its own.

### Dimension 1 — Threat model

An **unprivileged local user** racing a privileged victim that runs behind a
syscall wrapper. The attacker needs only concurrent execution with the kernel:
a second thread/process sharing memory (via inheritance, `minherit`, `rfork`,
`clone`), plus either the ability to induce paging (UP) or a second CPU (MP).
In scope: syntactic argument races (path bytes swapped), semantic races (path
_meaning_ swapped by symlink/rename during `namei()`), and audit evasion.
Symlink swap and directory rename mid-walk are the vehicles for the semantic
case. Out of scope: any attacker who already has kernel-level code execution
(there is nothing to escalate).

### Dimension 2 — Resolution primitive (the defense/attack mechanism and its atomicity claim)

The _defensive_ primitive under attack is the wrapper's precondition hook: it
copies the path argument in, decides, and passes control to the kernel, whose
`namei()` then copies and resolves the path **a second time**. The wrapper's
atomicity claim is implicit — that its view of the argument is the kernel's view
— and the paper's entire contribution is to falsify it. There is no
per-component or whole-path atomicity anywhere; the wrapper and kernel perform
two independent copy-ins of the same user memory with a schedulable gap between.
This is the negative result that motivates in-kernel, lock-holding checks
([`chari-2010`][chari] moves the check into a user-space resolver over `openat`
instead; the kernel answer is [`linux-openat2`][openat2], which resolves the
whole path in one syscall with no user-space re-copy).

### Dimension 3 — Symlink and `..` policy

Not a policy the wrapper controls — that is the point. Path _interpretation_
(symlink following, `..` climbing) happens inside the kernel's `namei()`, after
and independently of whatever the wrapper inspected. A wrapper that inspects a
path string has no handle on the object that string will resolve to, so symlink
and `..` semantics are exactly the lever a **semantic** race pulls: swap a
component to a symlink between the wrapper's read and `namei()`'s read.

### Dimension 4 — Boundaries

The paper does not treat mount crossings, procfs magic links, or Windows reparse
points directly; its boundary is the **trust boundary between wrapper and
kernel**, and the resources it enumerates are file-system objects, shared
memory, and sockets, "as well as indirectly accessed kernel objects, such as
vnodes/inodes and kernel buffers" (p.3). The `bind()` address swap against
Sysjail is the closest thing to a boundary attack — escaping a network
confinement domain by racing the confining wrapper.

### Dimension 5 — Portability and fallback

Syntactic races are deliberately portable: "they do not depend on kernel and
wrapper internals." The paper demonstrates the same technique across FreeBSD,
NetBSD and OpenBSD and across three unrelated wrapper frameworks. The negative
lesson for portability is that mitigations do _not_ port cleanly: VM
write-protection of argument pages (Dawidek/CerbNG) "violates concurrent
programming assumptions" because legitimate threads store live data in the same
page as arguments, and protecting one physical page requires protecting all its
mappings and the address space against unmap/remap (p.6-7).

### Dimension 6 — Failure and partiality

The wrapper's failure mode is silent and total: the check passes on the value it
saw, the kernel acts on a different value, and no error is raised because from
each component's local view nothing went wrong. Watson's survey of mitigations
concludes they "protect only against syntactic vulnerability" — they can stop
argument _replacement_ but "do not synchronize with kernel services," so
semantic races survive every VM/caching scheme tested (p.7). None of the tested
systems handled the POSIX asynchronous-I/O case (arguments read _and_ written in
one call) correctly.

### Dimension 7 — Enumeration and deletion

Does not apply, because the paper studies the atomicity of a single guarded
syscall, not tree walking or recursive deletion. Its relevance to a
`remove_dir_all`-style walker is indirect but sharp: every `openat`/`unlinkat`
in such a walk is a check-then-use pair, and this paper is the proof that the
"check" and the "use" must share a handle (an fd), never a re-resolved path
string, or the walk inherits exactly this race.

## Strengths

- **Names the structural defect.** TORTTOU and the wrapper-vs-kernel
  non-atomicity framing are the paper's lasting contribution: it explains _why_
  a class of tools is unfixable in place, not just that instances have bugs.
- **Empirical and total.** 100% exploit success across three frameworks and four
  operating systems; 16 of 23 GSWTK wrappers vulnerable.
- **Kills the obvious mitigations.** Shows VM write-protection and in-kernel
  argument caching stop only syntactic races, at real correctness and
  performance cost.

## Weaknesses

- **No constructive defense.** The paper's answer ("integrate security checks
  with the kernel itself, atomically with respect to the object they control")
  is a direction, not an artifact; the constructive work is
  [`chari-2010`][chari] (user space) and [`linux-openat2`][openat2] (kernel).
- **Dated targets.** GSWTK/Systrace/CerbNG on early-2000s BSDs; the argument
  transfers, but the specific packages are historical.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                       | Trade-off                                                                      |
| --------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Attack syntactic (byte) races, not semantic ones    | Portable across kernels and wrappers; no internals needed       | Leaves the (also-exploitable) semantic symlink/rename races less explored      |
| Force windows via paging (UP) and a second CPU (MP) | Turns a microsecond race into a reliable one                    | Requires either swap/mmap pressure or an idle core — both cheap in practice    |
| Frame wrappers as _not_ reference monitors          | Explains the class defect rather than cataloguing instance bugs | The fix implied (kernel integration) abandons the interposition model entirely |

## Sources

- [`watson07-woot.pdf`][woot-pdf] — the paper: three race classes (syntactic /
  semantic / wrapper-state), TOCTTOU/TOATTOU/TORTTOU, the `namei()` re-copy race
  (p.3), UP paging and MP second-CPU exploits (p.4), and the mitigation survey
  (§8, p.6-7).

<!-- References -->

[woot-pdf]: https://www.usenix.org/legacy/events/woot07/tech/full_papers/watson/watson.pdf
[concepts]: ./concepts.md
[chari]: ./chari-2010.md
[openat2]: ./linux-openat2.md
