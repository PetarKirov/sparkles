# Defense and Attack Techniques Against File-Based TOCTOU Vulnerabilities: A Systematic Review

The map of the whole literature — 41 papers, 37 defenses and 4 attacks, sorted by
where they run and when they act — and its verdict that no universal solution
exists, with a shortlist of what one would need.

|                 |                                                                                                            |
| --------------- | ---------------------------------------------------------------------------------------------------------- |
| **Kind**        | Paper (systematic literature review)                                                                       |
| **Year**        | 2022                                                                                                       |
| **Authors**     | Razvan Raducu, Ricardo J. Rodríguez, Pedro Álvarez (University of Zaragoza)                                |
| **Venue**       | IEEE Access, vol. 10 (2022)                                                                                |
| **Corpus**      | 563 database hits + 13 manual → 41 articles (PRISMA), 1994–2021                                            |
| **Primitive**   | Taxonomy: memory region (kernel / user) × time of detection (static / dynamic) × attack vector             |
| **Dimension 2** | Meta: classifies every surveyed mechanism; makes no atomicity claim of its own                             |
| **Source read** | `raducu22-systematic-review.pdf` (19pp., "Submitted to IEEE Access" preprint); canonical [DOI][raducu-doi] |

## Overview

### What it solves

Orientation. Thirty-five years of TOCTOU work had never been surveyed
systematically, and the vulnerability is still live — the paper counts 786 NVD
and 120 MITRE hits at the time of writing, and eight CWE entries (CWE-59, -61,
-62, -362, -363, -367, -386, -706; Table 1, p.2). Its abstract (p.1):

> A wide variety of techniques have been proposed to detect, mitigate, avoid,
> and exploit these vulnerabilities over the past 35 years. However, despite
> these research efforts, TOCTOU vulnerabilities remain unsolved due to their
> non-deterministic nature and the particularities of the different filesystems
> involved in running vulnerable programs.

The root-cause statement is the same as [`payer-2012`][payer]'s and worth
quoting because the whole catalog turns on it (p.2):

> Although the mapping of the inode and device number to a file descriptor is
> race-free, the mapping of the filename to the inode and the device number is
> volatile since filenames and the underlying inode and device number may change
> on each system call invocation.

### Design philosophy

A reproducible protocol: Kitchenham-style research questions (RQ1 how do they
work; RQ2 which memory region; RQ3 when detected/exploited; RQ4 which OS; RQ5
is a tool available), a fixed search string over IEEE Xplore, ScienceDirect,
Scopus and ACM, title screening of 470 Tier-1/Tier-2 security conferences, StArt
keyword scoring with a threshold of 15, then inclusion/exclusion criteria (§III,
p.3-5). The PRISMA funnel (Fig. 2, p.5): 563 → 504 after de-duplication → 133
above threshold → 37 after criteria → 30 after full-text → 41 with 11 added by
snowballing.

## How it works

The taxonomy (Fig. 3, p.6) has two top-level axes and one attack-only axis:

| Axis                             | Values                                                                                                                | Share of defenses (n=35 distinct) |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| **Memory region**                | kernel-space level / user-space level                                                                                 | 60% (21) / 40% (14)               |
| **Time of detection**            | static (source-code detection, post-mortem detection) / dynamic                                                       | 28.6% (10) / 71.4% (25)           |
| **Dynamic sub-category**         | system call interposition / intra-inter-process memory consistency / transactional system calls / sandbox filesystems | —                                 |
| **Attack vector** (attacks only) | external devices / kernel I/O caching                                                                                 | 2 / 2 of 4 attacks                |

Every attack is user-space and dynamic — "if the attacker is able to execute
the attack from the kernel-space level, there is no real gain in exploiting the
vulnerability" (p.5).

The **timeline** (Fig. 5, p.10, for defenses; Fig. 6, p.12, for attacks):

- 1994–1996: static user-space detection — Ko et al.'s execution monitoring
  (1994), Bishop's tortoise-and-hare report (1995) and
  [`bishop-dilger-1996`][bishop]'s lexical C scanner, which "demonstrated that
  privilege escalation attacks that exploit TOCTOU vulnerabilities only occur
  when filesystem objects are referenced by their names and not by file
  descriptors" (p.7).
- 2001–2005: dynamic kernel-space detection arrives — RaceGuard (2001),
  Tsyrklevich & Yee (2003, later broken by [`cai-2009`][cai]), RPS, Lhee &
  Chapin, Uppuluri, and [`wei-pu-2005`][weipu]'s CUU pair model (2005).
- 2004: [`dean-hu-2004-borisov-2005`][deanhu] — the first _probabilistic_ user-space
  defense (source modified to repeat the check `k` times); broken in 2005 by
  Borisov's maze attack, the first paper in the attack timeline.
- 2006: dynamic user-space detection begins (Aggarwal & Jalote); EDGI extends
  CUU in kernel space.
- 2008: [`tsafrir-2008`][tsafrir]'s hardness amplification (user space) and Kupsch &
  Miller's safefile library (kernel-space per the review's Table 3).
- 2009: [`cai-2009`][cai] breaks atomic k-race and TY-Race; TxOS transactional
  syscalls.
- 2010: [`chari-2010`][chari]'s safe calls (user space); Wei & Pu's Stateful
  TOCTOU Enumeration Model (224 Linux / 285 POSIX vulnerable pairs).
- 2011–2014: RacePro (static kernel), [`payer-2012`][payer]'s DynaRace (dynamic
  user), Vijayakumar/Jaeger's STING, Process Firewall, Jigsaw (kernel LSMs),
  Mbox (sandbox FS, 2013), SHIELD (memory consistency, 2014).
- 2015: Cai, Lale, Zhang, Johnson's library of secure calls (dynamic user) —
  the last user-space runtime defense in the corpus.
- 2017–2019: SIMEXPLORER (static, Simics), SandFS (eBPF sandbox FS, 2018),
  Capobianco's attack graphs (2019) — "the date of the last solution we found."
- Attacks: 2005 (Borisov, kernel I/O caching), 2009 (Cai, kernel I/O caching),
  2012 (Read It Twice, external devices), 2017 (Ghost Installer, Android,
  external devices).

Nineteen dynamic kernel-space solutions were published between 2001 and 2014 —
"averaging more than one publication per year" — against exactly one static
kernel-space one (p.6-7).

### Dimension 1 — Threat model

The review's scope is file-based TOCTOU on filesystems "with weak
synchronization mechanisms" (p.2), i.e. no way to pin an object between
consecutive operations. Its canonical adversary is a local user racing a setuid
program (the `access`/`fopen` example of Fig. 1); symlink following (CWE-61),
hard links (CWE-62) and link-following races (CWE-363) are the named vehicles.
Two attack-vector families are recognized: **external devices** (USB/SD media
swapped between verify and install — Samsung TVs, Android installers) and
**kernel I/O caching** (forcing I/O or cache-collision work to widen the
window — [`dean-hu-2004-borisov-2005`][deanhu], [`cai-2009`][cai]). The
review notes Windows is treated by the literature as outside the file-based
TOCTOU problem because it "manage[s] references to files through internal
structures similar to file descriptors (for instance, via handles)" (p.14) — a
claim the catalog's [`windows-nt`][windows] and
[`forshaw-windows-symlinks`][forshaw] entries examine rather than accept.

### Dimension 2 — Resolution primitive (the defense/attack mechanism and its atomicity claim)

None of its own — the review classifies rather than proposes. Its
classification of the primitives _this_ catalog covers is worth recording,
because it disagrees with the papers' own framing in places: [`chari-2010`][chari]
is "user-space / dynamic / POSIX / reproducible with remarks" (Table 3, `[44]`),
faulted for showing "only a subset of the proposed secure calls"; [`payer-2012`][payer]
is "user-space / dynamic / Unix-like / no longer available"; [`tsafrir-2008`][tsafrir]
is "user-space / dynamic / Solaris 8, AIX 5.3, Linux 2.4–2.6 / reproducible",
with noted drawbacks of "defending against circular symbolic links, or
multi-threaded applications"; Kupsch & Miller's safefile appears as
kernel-space (arguably a misclassification — it is a C library). The review's
synthesis of RQ2 (p.13) is the design argument: user-space techniques are
portable and debuggable but "cannot access kernel-level information or
mechanisms such as the system's cache, the scheduler, hardware, I/O, or the
inode generation algorithm"; kernel-space techniques see everything but "may
require modifying the kernel or adding modules," with backward-compatibility
and crash risk.

### Dimension 3 — Symlink and `..` policy

Not treated per se; the review records which _metadata_ each defense uses to
identify an object (Fig. 7, p.14): the inode in 20 of 35, then device ID, file
path and filename, with a long tail of PID, UID, generation number, logical
disk block, parent directory and so on. This is the review's substitute for a policy
discussion — and it leads directly to its most useful empirical contribution.

### Dimension 4 — Boundaries

The one boundary the review tests itself is **inode reuse** (Table 4, p.14):
the authors emptied inodes on each major filesystem and checked whether the
number is ever reissued.

| Reuses freed inode numbers              | Never reuses                                       |
| --------------------------------------- | -------------------------------------------------- |
| ext2, ext3, ext4, XFS, ReiserFS, NILFS2 | Btrfs, FAT16, FAT32, NTFS, HFS+, JFS, ramfs, tmpfs |

Their conclusion: "the uniqueness of an inode depends to a large extent on the
underlying filesystem and, therefore, inodes cannot be assumed to be an item for
single distinction" (p.14). For a dirfd module this is the argument for holding
an **open handle** as identity rather than a remembered `(st_dev, st_ino)` —
the tuple can name a different object after an unlink/create cycle on ext4 or
XFS. Mounts, procfs and magic links are otherwise absent.

### Dimension 5 — Portability and fallback

All 37 defenses target Unix-like systems; 3 of 4 attacks do (the fourth is
Android, on a Linux kernel). Reproducibility is the review's headline failure
(Fig. 4c, p.9): 62.9% (22) of defenses have no artifact, 8.6% (3) are "no
longer available," 11.4% (4) reproducible "with remarks," and only 17.1% (6)
fully reproducible — "almost all the software tools developed to defend or
exploit TOCTOU vulnerabilities are not available" (p.15). Both kernel-I/O-cache
attack papers' repositories are gone.

### Dimension 6 — Failure and partiality

Surveyed at the class level (RQ3, p.13): static techniques "only propose
solutions to known attacks" and post-mortem log analysis "is detected when it
has already occurred" and is "often unsound"; dynamic defenses "tend to incur
performance overheads" and several (Tsyrklevich & Yee, Uppuluri) are noted as
"not free of race conditions, as the interception of system calls implicitly
generates another race condition vulnerability window" (p.11) — the
[`watson-2007`][watson] result restated, though Watson's paper is not in the
corpus. Cai et al.'s 2015 library is faulted for leaving "the vulnerable
program in an unknown state after detecting an exploitation attempt" (p.9).

### Dimension 7 — Enumeration and deletion

Does not apply, because no surveyed work is a tree walker and the review
does not consider recursive operations. The nearest item is Mbox's layered
sandbox filesystem (commit-or-discard of a whole operation set), which is the
"transactional" answer to partial failure rather than a walker.

## Strengths

- **The counts and the timeline** — a citable, reproducible inventory of
  what has been tried, when, and at which layer.
- **The inode-reuse table**: original measurement, and directly actionable for
  identity design.
- **Honest about artifacts**: three-quarters of the field cannot be re-run.

## Weaknesses

- **English-only, peer-reviewed-only**, so the practitioner lineage this catalog
  cares about — `openat2` ([`linux-openat2`][openat2]), `O_RESOLVE_BENEATH`
  ([`freebsd-openbsd`][freebsd]), [`libpathrs`][libpathrs], Go's `os.Root`
  ([`go-os-root`][goroot]) — is invisible to it; the authors concede that "gray
  literature is an important source of knowledge" (p.15).
- **Windows dismissed by assertion**, not evidence.
- **Ends in 2021** with the last defense dated 2019; the kernel-side
  developments of 2019–2024 are exactly the ones it misses.
- Occasional layer misclassification (safefile as kernel-space).

## Key design decisions and trade-offs

| Decision                                             | Rationale                                             | Trade-off                                                                   |
| ---------------------------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------- |
| Two-axis taxonomy (region × time) plus attack vector | Answers RQ2/RQ3 uniformly for 41 heterogeneous papers | Flattens design differences (probabilistic vs deterministic) into "dynamic" |
| Peer-reviewed corpus via fixed search string         | Reproducible, bias-free selection                     | Excludes the kernel and library work that actually shipped                  |
| Measure inode reuse per filesystem                   | Tests the identity assumption 20/35 defenses rely on  | Small experiment; no generation-number or handle-based comparison           |

### The open problems, in the authors' words

The review's forward look (§V-B, p.14-15) states that "no defense solution is
universal, as reflected in the fact that, until now, no solution has been
officially adopted," judges a universal solution "unlikely," and proposes a
mixture of three directions:

- **A new race-free, security-focused API** — "an API based on file
  descriptors rather than filenames. However, legacy software would still be
  vulnerable. In addition, the burden falls on software developers."
- **Modification of the kernel to always work with file descriptors** —
  "likely to cause serious backwards compatibility issues."
- **Transactional filesystems** — atomic create/modify/rename/delete so that
  "file objects do not change between pairs of TOCTOU vulnerable system calls."

The first of these is what the rest of this catalog is about: `openat2` with
`RESOLVE_*` flags and the directory-handle libraries built on it are the
"fd-based API" the review asks for, published one to three years before the
review and outside its corpus.

## Sources

- [`raducu22-systematic-review.pdf`][raducu-doi] — introduction and CWE table
  (§I, p.1-2); methodology and PRISMA (§III, Fig. 2, p.3-5); taxonomy (§IV-A,
  Fig. 3, p.5-6); defense descriptions and Table 3 (§IV-B, p.6-12); defense
  timeline (Fig. 5, p.10); attacks and their timeline (§IV-C, Fig. 6, p.12-13);
  synthesis of RQ2-RQ5, metadata prevalence (Fig. 7) and inode reuse (Table 4)
  (§V-A, p.13-14); future directions (§V-B, p.14-15); limitations (§V-C, p.15).

> [!NOTE]
> **Unverified.** Page numbers cite the author preprint ("Submitted to IEEE
> Access", 19pp.) that was read; the published IEEE Access pagination differs.
> The DOI landing page was not fetched.

<!-- References -->

[raducu-doi]: https://doi.org/10.1109/ACCESS.2022.3153064
[bishop]: ./bishop-dilger-1996.md
[weipu]: ./wei-pu-2005.md
[deanhu]: ./dean-hu-2004-borisov-2005.md
[watson]: ./watson-2007.md
[tsafrir]: ./tsafrir-2008.md
[cai]: ./cai-2009.md
[chari]: ./chari-2010.md
[payer]: ./payer-2012.md
[openat2]: ./linux-openat2.md
[freebsd]: ./freebsd-openbsd.md
[windows]: ./windows-nt.md
[forshaw]: ./forshaw-windows-symlinks.md
[libpathrs]: ./libpathrs.md
[goroot]: ./go-os-root.md
