# Bishop & Dilger 1996 — Checking for Race Conditions in File Accesses

The paper that named the "TOCTTOU binding flaw" and stated, in a lemma, the
fact every later defense rests on: a path name is a chain of indirect pointers
any one of which an attacker may swap, while a file descriptor is a direct
pointer and cannot be rebound.

|                 |                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper                                                                                                    |
| **Year**        | 1996 (Spring; the underlying tech report is UC Davis CSE-95-8, 1995)                                     |
| **Authors**     | Matt Bishop, Michael Dilger — Department of Computer Science, UC Davis                                   |
| **Venue**       | _Computing Systems_ 9(2), pp. 131–152                                                                    |
| **Language**    | C is the analysed language; the prototype analyzer is a Perl script                                      |
| **License**     | not stated (academic paper); the `trustfile` library was offered by anonymous FTP                        |
| **Platforms**   | UNIX in general; the prototype targets SunOS and Solaris                                                 |
| **Primitive**   | the **programming condition** / **environmental condition** split and the `w(I, o)` trustworthiness test |
| **Source read** | `bishop96-racecond.pdf` ([canonical PDF][pdf]), all 20 pages                                             |

## Overview

### What it solves

Before this paper, file-system races were folklore: known from CERT advisories
(`xterm`, `binmail`, `passwd`) but without a vocabulary that said _which_
system-call pairs could race and _why_. Bishop and Dilger carve out a subclass
and give it a semantic definition ([§1, p. 1][pdf]):

> A subclass of TOCTTOU flaws, which we call TOCTTOU binding flaws, arise when
> object identifiers are fallaciously assumed to remain bound to an object.

The archetype is the `access(2)`/`open(2)` idiom in a setuid-root program
([§2, p. 2][pdf]): the check passes on `/tmp/X`, the attacker unlinks it and
hard-links `/etc/passwd` into its place, and `open` follows the same name to a
different object. Three real attacks are dissected — the `xterm` log-file
race, an `8LGM` `passwd(1)` attack that flips a _directory_ symlink between
four steps so that a temp file is created in one directory and renamed into
another, and the `binmail` mailbox race where an `lstat` "is a regular file"
check is invalidated before the append.

### Design philosophy

The whole analysis reduces to one distinction between the two ways UNIX names
an object ([§3.1, p. 7–8][pdf]):

> File path names are resolved by indirection, requiring the naming and
> accessing of at least one object other than the file being addressed. File
> descriptors are resolved by accessing the file being addressed. The former
> correspond to (multiply) indirect pointers to the object, the latter to
> pointers to the object.

and its consequence, which is the seed of every fd-relative API surveyed in
this catalog (`openat`, `openat2`, `os.Root`, `libpathrs`):

> Path names are indirect pointers, so one of the interior pointers may be
> switched. File descriptors are direct pointers and hence not subject to such
> fiddling.

The paper's other principle is that a flaw is only exploitable when **two
independent conditions hold at once** — the program must leave an interval, and
the environment must let an untrusted user act inside it. Detection is
therefore split into a static part (find intervals) and a site-specific part
(decide whether each interval's path is trustworthy on _this_ system).

## How it works

### The two conditions

Two events, the second depending on the first, define a **programming
interval** ([§3, p. 6][pdf]): "Call the existence of such an interval the
programming condition and the interval itself the programming interval." The
attacker must also be able to invalidate the first call's assumptions: "That
condition is the environmental condition. Both conditions must hold for there
to be an exploitable TOCTTOU binding flaw."

### The binding taxonomy

Which call pairs can bound an interval follows directly from how each call
names its object ([§3.1, p. 7–8][pdf]):

| First call names by | Second call names by                             | Binding flaw possible? |
| ------------------- | ------------------------------------------------ | ---------------------- |
| path name           | path name                                        | yes                    |
| path name           | descriptor, **not** obtained from that path      | yes                    |
| path name           | descriptor obtained by _that_ call (e.g. `open`) | no                     |
| descriptor          | descriptor                                       | no                     |

"If both use file descriptors, or one maps a name to a file descriptor that
the second uses, the possibility of a TOCTTOU binding flaw does not arise."

### The trustworthiness function

The environmental condition is made algorithmic ([§3.2, p. 8–9][pdf]). Users
are partitioned into trusted `T` and untrusted `U`; `w(I, o)` is true iff some
member of `U` can alter the binding of object `o` during interval `I`. Two
lemmas then say a path is only as trustworthy as its weakest component:

```text
Lemma 1.  w(I, d1/d2/.../dn/f) = w(I, d1) ∨ w(I, d2) ∨ ... ∨ w(I, dn) ∨ w(I, f)
Lemma 2.  for a symbolic link l to d1/.../da:  w(I, l) = w(I, d1) ∨ ... ∨ w(I, da)
```

The concrete test per component: the owner must be trusted, the object must not
be world-writable, and if the group has untrusted members it must not be
group-writable. Two footnotes carry the platform nuance that survives into
modern `protected_symlinks`-style policy: a sticky-bit directory may be
world-writable if the next component already exists, and when the target is
being _written_ "the trailing component of the object need not be checked"
(its contents are about to be replaced), whereas a target being _read_ must
itself be trustworthy.

### The prototype analyzer

A Perl script — "a proof-of-concept program only" ([§4, p. 10–11][pdf]) — that
pattern-matches pairs of path-taking calls with **lexically identical**
arguments inside one function, with no data-flow analysis, so it catches
`creat(tempfile,…); chown(tempfile,…)` but not the same pair through
`*newfile = tempfile`. Run on sendmail 8.6.10 it reported 24 intervals; manual
review found 5 that met the programming condition, all exploitable under
plausible policies ([Appendix 1–2][pdf]). The headline one is
`deliver.c` `2186:stat, 2262:chmod, filename`: the attacker swaps the mail file
for `/etc/pwd/shadow` between the `stat` and the `chmod`, and the shadow file
inherits the mail file's mode. The fix shipped in sendmail 8.7 "on all systems
with a `fchmod(2)` system call" ([Appendix 3, p. 20][pdf]) — i.e. by moving
the second operation onto the descriptor, exactly as the taxonomy prescribes.

### Limits of any analyzer

Section 5 applies Rice's theorem: the set of programs with an exploitable
binding flaw is undecidable, so every analyzer is _deficient_ (misses some),
_excessive_ (over-reports), or _incomplete_ (both). Precision would need "a
complete representation of the environment induced by the file system, and
knowledge of the pairs of system calls required for checks and uses" — which
calls are checks is "a product of the program" (`stat` can be either).
Section 6 sketches a dynamic analyzer that re-tests trustworthiness at both
ends of each interval, and notes it "does not prevent the TOCTTOU binding
flaws from being exploited."

### Dimension 1 — threat model

An unprivileged local user versus a **setuid-root** (or otherwise privileged)
program that names objects by path. In scope, each with a worked attack: a
hard-link swap of the final component (`xterm`, Figure 1); retargeting a
**directory** symlink between steps so that later components resolve elsewhere
(`passwd`, Figure 2 — in modern terms a rename mid-walk); delete-and-recreate
as a link (`binmail`, Figure 3); and, distinct from rebinding, changing the
_contents_ of a read target ([§3.2][pdf]). Out of scope entirely: mount
crossings, procfs, Windows, containers, and any adversary other than a user
with write access to a path component.

### Dimension 2 — resolution primitive and its atomicity claim

No new primitive is proposed; the mechanism is the taxonomy itself. Its
atomicity claim is the descriptor's: "the binding of the file descriptor to the
file cannot be changed by a second process" ([§3.1, p. 7][pdf]). A path lookup
is modelled as per-component indirection with "no caching of names to
addresses", so no path-based call is atomic with any other path-based call. The
sendmail fix (`chmod` → `fchmod`) is the paper's only prescriptive remedy, and
`trustfile` (an implementation of the §3.2 test) its only shipped tool. Bishop's
`faccess` suggestion, mentioned by [Tsafrir et al.][tsafrir] as "operate on a
file-descriptor rather than a file name", is not in this paper's text.

### Dimension 3 — symlink and `..` policy

Symbolic links are folded into the trust test by Lemma 2 — an "indirect alias"
is "semantically equivalent to the path it contains" — so a link is trusted iff
every component of its target is. There is no policy for refusing them.
`..` appears only as an obstacle to static analysis: `/tmp/X` and `../tmp/X`
may name the same object, "but that cannot be determined without knowledge of
the process' current working directory" ([§4, p. 10][pdf]).

### Dimension 4 — boundaries

Does not apply, beyond the sticky-bit footnotes ([p. 9][pdf]), which are
system-specific (SunOS, Solaris, IRIX, HP/UX). Mounts, special filesystems and
magic links are absent; the one boundary the paper notices is that a dynamic
analyzer cannot be precise because "references to disk block numbers will
bypass virtually all reasonable checks" ([§6, p. 14][pdf]).

### Dimension 5 — portability and fallback

The analysis is generic UNIX; the prototype is SunOS/Solaris because "the
availability of those systems in our environment dictated this choice". The
descriptor-based fix is itself conditional on the platform — sendmail 8.7 fixed
the race "on all systems with a `fchmod(2)` system call", a reminder that in
1996 the `f*` family was not universal. No fallback is discussed for systems
without it.

### Dimension 6 — failure and partiality

Does not apply to the analysis. The dynamic-analysis sketch ([§6, p. 13][pdf])
does enumerate the four trust outcomes across an interval (trustworthy at both
ends; at neither; only at the end — "an exploitable TOCTTOU binding flaw
existed" until a trusted user fixed it; only at the start — a trusted user
"should not have been trusted"), which is the closest the paper comes to a
mid-operation state model.

### Dimension 7 — enumeration and deletion

Does not apply — the paper never walks or removes a tree. The nearest case is
sendmail `main.c` `708:stat, 784:chdir, QueueDir` ([Appendix 2, p. 17][pdf]):
the ownership check on the queue directory and the `chdir` into it are
separated, so an attacker who can rebind the directory name makes sendmail list
`qf*` files in a protected directory. That is the walk-time directory-swap
hazard `fchdir`/`openat`-style enumeration exists to remove.

## Strengths

- **The definition still holds.** "Binding flaw" and the path-vs-descriptor
  taxonomy are the frame every later paper ([Wei & Pu][wei-pu],
  [Dean & Hu][dean-hu], [Tsafrir][tsafrir]) adopts, and the direct justification
  for dirfd-relative APIs.
- **Component-wise trust (Lemma 1)** anticipates the modern rule that a path is
  only as safe as its least-trusted ancestor — the reason `RESOLVE_BENEATH`
  and `SecureJoin` must check every component, not the leaf.
- **Honest about undecidability**: the precise/deficient/excessive/incomplete
  vocabulary and the Rice's-theorem argument set expectations for every static
  tool since.
- Real bug found, real fix shipped (sendmail 8.7, `fchmod`).

## Weaknesses

- **No defense beyond "use descriptors".** The trust test only says whether an
  interval _can_ be exploited on a given host; it does not close it.
- The prototype is a lexical Perl matcher with "no data flow analysis" and no
  inter-procedural view; 19 of 24 reports were false positives.
- Symlinks are only modelled for trust, never for depth, loops or `..` inside
  the target; mounts and special filesystems are not modelled at all.
- The threat model is 1996 UNIX: setuid binaries and world-writable `/tmp`.
  Containers, user namespaces and procfs magic links postdate it.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                         | Trade-off                                                                |
| ------------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Define the flaw by _binding_, not by "check then use"   | Separates what a static tool can find (intervals) from what needs the environment | Misses use/use pairs later added by [Wei & Pu][wei-pu]                   |
| Classify call pairs by naming mode (path vs descriptor) | Descriptors cannot be rebound by another process                                  | Says nothing about races _inside_ one path lookup                        |
| Trust = OR over every path component (Lemma 1)          | Rebinding any ancestor rebinds the leaf                                           | Requires per-host ownership data; not decidable statically               |
| Skip the trailing component when the target is written  | Its contents are about to be replaced anyway                                      | Wrong under sticky-bit directories; needs the footnote's ownership check |
| Ship a lexical, intra-procedural prototype              | Proof of concept on the systems available                                         | 19/24 false positives on sendmail; aliasing defeats it                   |
| Fix sendmail with `fchmod` rather than a check          | Moves the second operation onto the immutable binding                             | Only on systems that have `fchmod(2)`                                    |

## Sources

- [Bishop & Dilger, "Checking for Race Conditions in File Accesses", _Computing Systems_ 9(2), 1996][pdf] — §1 the binding-flaw definition; §2 the `xterm`, `passwd` and `binmail` attacks; §3.1 the path/descriptor taxonomy; §3.2 `w(I, o)` and Lemmas 1–2; §4 the Perl prototype and sendmail 8.6.10 results; §5 Rice's theorem and analyzer classes; §6 dynamic analysis; Appendix 2 the five real intervals; Appendix 3 the `fchmod` fix
- [Wei & Pu 2005][wei-pu] — extends the model to use/use pairs and enumerates 224 of them
- [Dean & Hu 2004 / Borisov et al. 2005][dean-hu] — the probabilistic `access`/`open` defense and its defeat
- [Tsafrir et al. 2008][tsafrir] — credits Bishop with the `faccess` proposal

<!-- References -->

[pdf]: https://nob.cs.ucdavis.edu/bishop/papers/1996-compsys/racecond.pdf
[wei-pu]: ./wei-pu-2005.md
[dean-hu]: ./dean-hu-2004-borisov-2005.md
[tsafrir]: ./tsafrir-2008.md
