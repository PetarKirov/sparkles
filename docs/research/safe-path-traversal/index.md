# Safe Path Traversal

A primary-source survey of how serious systems open, walk and delete
filesystem paths without being redirected by whoever else can write to the
tree — thirty years of it, from the paper that named [TOCTTOU][bishop] in
1996 to Linux's [`openat2`][openat2], Go's [`os.Root`][go], Rust's
[CVE-2022-21658 rewrite][rust] and [libpathrs][libpathrs]. Nine papers, five
kernels, nine libraries and runtimes, three bodies of talks and reporting, and
three [runnable examples][examples] that pin the facts a CI run can check.

The evidence base for `sparkles.base.dir_handle` — the directory-handle module
that [`sparkles:test-utils`' `TmpFS`][tmpfs] and the fileset walker
([`FSD5`–`FSD7`][spec]) will be built on — and the reason that module's design
was sent back for this survey first.

This survey answers eight questions:

1. **Is TOCTTOU a bug in programs or in the API?** In the API. [Bishop &
   Dilger][bishop] proved it undecidable to find statically; [Wei & Pu][wei]
   counted 224 dangerous syscall pairs; [Watson][watson] showed even an
   in-kernel wrapper cannot make a path-string check atomic. See
   [concepts § the race][concepts].
2. **Can user space win the race by being fast?** No. The [k-race][dean-hu]
   was broken by [filesystem mazes][dean-hu]; [hardness amplification][tsafrir]
   was broken by a [name-cache complexity attack][cai]. Every probabilistic
   defense "pulls the performance characteristics of the OS into the trusted
   computing base". See [comparison § consensus][comparison].
3. **What survived?** Walking once from a handle: [`safe_open`][chari] in
   2010, [`openat2`][openat2] in 2020, and the component walk every library
   keeps as a fallback. See [axis 1][axis1].
4. **Do the kernels agree on `..`?** No — Linux allows a `..` that stays
   beneath, FreeBSD refuses even a temporary escape, Windows resolves it in the
   parser. See [axis 2][axis2] and the [flag matrix][ex-flags].
5. **Beneath or no-symlinks?** Two different guarantees; the portable floor is
   the stricter one. See [axis 3][axis3].
6. **How do the libraries fall back, and what do they get wrong?** Cache
   failure, never success; never downgrade per lookup — and [cap-std][capstd]
   does. See [axis 4][axis4].
7. **What does everyone do about deletion?** The same thing, since 2022:
   fd-relative, never descend a link, list from the handle. See [axis 6][axis6]
   and [`fd-remove-tree.d`][ex-rm].
8. **What should `sparkles.base.dir_handle` do?** See the [delta table][delta].

## Master catalog

| Subject                      | Category   | Year      | Primitive / contribution                                                       | Link           |
| ---------------------------- | ---------- | --------- | ------------------------------------------------------------------------------ | -------------- |
| Bishop & Dilger              | paper      | 1996      | Names the race; paths are indirect pointers, descriptors direct                | [→][bishop]    |
| Dean & Hu / Borisov et al.   | paper      | 2004/2005 | The k-race defense and the filesystem maze that broke it                       | [→][dean-hu]   |
| Wei & Pu                     | paper      | 2005      | 224 check/use pairs; live attacks on `rpm`, `vi`, `emacs`                      | [→][wei]       |
| Watson                       | paper      | 2007      | Syscall-wrapper races; check and use must share a handle                       | [→][watson]    |
| Tsafrir et al.               | paper      | 2008      | Component-at-a-time hardness amplification; "`openat` would solve this"        | [→][tsafrir]   |
| Cai, Gui & Johnson           | paper      | 2009      | Name-cache complexity attack; probabilistic defenses declared dead             | [→][cai]       |
| Chari, Halevi & Venema       | paper      | 2010      | `safe_open`: per-component `openat` walk with an explicit trust model          | [→][chari]     |
| Payer & Gross                | paper      | 2012      | DynaRace: user-space identity cache, termination on mismatch                   | [→][payer]     |
| Raducu, Rodríguez & Álvarez  | paper      | 2022      | Systematic review of 41 defenses; inode-reuse table                            | [→][raducu]    |
| Linux `openat2`              | kernel     | 2020      | `RESOLVE_BENEATH` / `IN_ROOT` / `NO_SYMLINKS` / `NO_MAGICLINKS` / `NO_XDEV`    | [→][openat2]   |
| Linux procfs and magic links | kernel     | 2019–2026 | Why `/proc` is the escape hatch; private procfs via `fsopen`                   | [→][procfs]    |
| FreeBSD and OpenBSD          | kernel     | 2021+     | `O_RESOLVE_BENEATH`, Capsicum, `O_EMPTY_PATH`; `unveil`                        | [→][bsd]       |
| Darwin                       | kernel     | 2020+     | `O_NOFOLLOW_ANY` family — present, and unused by every consumer surveyed       | [→][darwin]    |
| Windows NT                   | kernel     | —         | `NtCreateFile` + `RootDirectory`, `OBJ_DONT_REPARSE`, handle-based delete      | [→][windows]   |
| libpathrs                    | library    | 2019–2026 | `openat2` resolver + `O_PATH` fallback; the CVE catalogue                      | [→][libpathrs] |
| filepath-securejoin          | library    | 2017–2026 | Lexical `SecureJoin` → `OpenInRoot`; the runc lineage                          | [→][sj]        |
| Go `os.Root`                 | runtime    | 2025      | Per-component walk with restart-from-root on `..`; three platform tiers        | [→][go]        |
| Rust std                     | runtime    | 2022      | `remove_dir_all` rewrite on Unix and NT; `fs::Dir` tracking issue              | [→][rust]      |
| rustix                       | binding    | 2021–2026 | Every `*at`, raw `openat2`, `Dir::read_from` re-open; I/O safety               | [→][rustix]    |
| cap-std                      | library    | 2020–2026 | Capability `Dir`; ancestor-stack `..`; behaviour-probed `O_RESOLVE_BENEATH`    | [→][capstd]    |
| openat / openat-ext          | binding    | 2016–2023 | The minimal dirfd wrapper and its deprecation                                  | [→][crates]    |
| gnulib `fts`                 | walker     | 2005+     | `FTS_CWDFD`, the fd ring, the `openat` emulation ladder; coreutils `rm`        | [→][fts]       |
| CPython `shutil`             | walker     | 2012+     | `rmtree.avoids_symlink_attacks`; `lstat`/`fstat` identity without `O_NOFOLLOW` | [→][cpython]   |
| Aleksa Sarai's talks         | talks      | 2019–2025 | Path resolution in container runtimes, LPC → LCA → ASG → "in the trenches"     | [→][talks]     |
| LWN `openat2` coverage       | articles   | 2014–2026 | `O_BENEATH` to `openat2` to "the difficulty of safe path traversal"            | [→][lwn]       |
| Forshaw's Windows symlinks   | talk+tools | 2015–2021 | What an attacker plants between check and use on NT                            | [→][forshaw]   |

## Taxonomy

### By where the walk happens

| Where                     | Subjects                                                                                                                                 |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Kernel, whole path        | [`openat2`][openat2], [FreeBSD][bsd], [Windows `OBJ_DONT_REPARSE`][windows], [Darwin][darwin] (unused)                                   |
| User space, per component | [Chari][chari], [Tsafrir][tsafrir], [Go][go], [Rust][rust], [cap-std][capstd], [libpathrs][libpathrs], [gnulib][fts], [CPython][cpython] |
| User space, by name       | classic `SecureJoin` ([securejoin][sj]), Go on js/Plan 9, CPython on Windows                                                             |

### By `..` policy

| Policy                           | Subjects                                                                      |
| -------------------------------- | ----------------------------------------------------------------------------- |
| Rejected lexically               | [Go][go] (escape count), [Windows][windows] (parser), the [examples][ex-walk] |
| Popped from an ancestor stack    | [cap-std][capstd], [gnulib fd ring][fts]                                      |
| Restart from root                | [Go][go]                                                                      |
| Re-verified through procfs       | [libpathrs][libpathrs], [securejoin][sj]                                      |
| Kernel-checked, `EAGAIN` on race | [`openat2`][openat2]; [FreeBSD][bsd] refuses outright                         |

### By fallback honesty

| Behaviour                             | Subjects                                            |
| ------------------------------------- | --------------------------------------------------- |
| Publishes which resolver is live      | [CPython][cpython]                                  |
| Caches failure only, never downgrades | [libpathrs][libpathrs], [securejoin][sj]            |
| Downgrades silently                   | [cap-std][capstd] (after 4 `EAGAIN`), [gnulib][fts] |
| Decided at compile time               | [Rust std][rust]                                    |

## Milestones

| When    | What                                                                                                                   |
| ------- | ---------------------------------------------------------------------------------------------------------------------- |
| 1996    | [Bishop & Dilger][bishop] name TOCTTOU binding flaws                                                                   |
| 2004    | [Dean & Hu][dean-hu] propose the k-race                                                                                |
| 2005    | [Borisov et al.][dean-hu] break it with filesystem mazes; [Wei & Pu][wei] enumerate 224 pairs                          |
| 2006    | coreutils 6.0 moves `du`, `chmod`, `chown` onto an `openat`-based `fts` ([fts][fts])                                   |
| 2007    | [Watson][watson]: syscall-wrapper races                                                                                |
| 2008    | [Tsafrir et al.][tsafrir]: hardness amplification; POSIX.1-2008 standardizes `openat`                                  |
| 2009    | [Cai et al.][cai] break it again                                                                                       |
| 2010    | [Chari et al.][chari] publish `safe_open`                                                                              |
| 2012    | CPython 3.3 `rmtree` goes fd-based ([cpython][cpython]); [DynaRace][payer]                                             |
| 2014    | Drysdale's `O_BENEATH` for Capsicum-on-Linux ([LWN][lwn])                                                              |
| 2016    | tailhook `openat` crate ([crates][crates])                                                                             |
| 2019    | runc CVE-2019-5736 via `/proc/self/exe` ([procfs][procfs]); Sarai's LPC talk ([talks][talks])                          |
| 2020-03 | Linux 5.6 ships [`openat2`][openat2]; cap-std begins ([capstd][capstd])                                                |
| 2021    | FreeBSD 13 `O_RESOLVE_BENEATH` ([bsd][bsd])                                                                            |
| 2022-01 | Rust CVE-2022-21658 `remove_dir_all` rewrite ([rust][rust]); [Raducu][raducu] survey                                   |
| 2024    | runc CVE-2024-21626 (leaked `/proc` fd); securejoin `OpenInRoot` ([securejoin][sj]); libpathrs at ASG ([talks][talks]) |
| 2025-02 | Go 1.24 `os.Root` ([go][go])                                                                                           |
| 2026-01 | LWN: "The difficulty of safe path traversal" ([lwn][lwn])                                                              |

## Reading paths

- **I am designing `sparkles.base.dir_handle`:** [comparison][comparison] →
  [`openat2`][openat2] → [Go][go] → [libpathrs][libpathrs] → [Windows][windows]
  → [Darwin][darwin] → [Rust std][rust] (deletion) → the [examples][examples].
- **I want the theory:** [concepts][concepts] → [Bishop][bishop] → [Dean & Hu /
  Borisov][dean-hu] → [Cai][cai] → [Chari][chari] → [Raducu][raducu].
- **I want to know what an attacker does:** [Forshaw][forshaw] →
  [procfs][procfs] → [Sarai's talks][talks] → [Wei & Pu][wei].

## Sources

Every deep-dive carries its own `Sources` block. Repositories were read from
local clones at the commits pinned in each citation; papers from the publisher
PDFs; LWN and vendor documentation by URL. Nothing here is written from
memory.

<!-- References -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md
[axis1]: ./comparison.md#axis-1-where-the-walk-happens
[axis2]: ./comparison.md#axis-2-what-means
[axis3]: ./comparison.md#axis-3-beneath-versus-no-symlinks
[axis4]: ./comparison.md#axis-4-the-fallback-ladder-and-how-it-is-detected
[axis6]: ./comparison.md#axis-6-deletion
[delta]: ./comparison.md#delta-dir-handle-against-the-field
[examples]: ./examples/
[ex-flags]: ./examples/openat2-resolve-flags.d
[ex-walk]: ./examples/component-walk.d
[ex-rm]: ./examples/fd-remove-tree.d
[spec]: ../../specs/build-primitives/filesets/SPEC.md
[tmpfs]: ../../../libs/test-utils/src/sparkles/test_utils/tmpfs.d
[bishop]: ./bishop-dilger-1996.md
[dean-hu]: ./dean-hu-2004-borisov-2005.md
[wei]: ./wei-pu-2005.md
[watson]: ./watson-2007.md
[tsafrir]: ./tsafrir-2008.md
[cai]: ./cai-2009.md
[chari]: ./chari-2010.md
[payer]: ./payer-2012.md
[raducu]: ./raducu-2022.md
[openat2]: ./linux-openat2.md
[procfs]: ./linux-procfs-magic-links.md
[bsd]: ./freebsd-openbsd.md
[darwin]: ./darwin.md
[windows]: ./windows-nt.md
[libpathrs]: ./libpathrs.md
[sj]: ./filepath-securejoin.md
[go]: ./go-os-root.md
[rust]: ./rust-std.md
[rustix]: ./rustix.md
[capstd]: ./cap-std.md
[crates]: ./openat-crates.md
[fts]: ./gnulib-fts.md
[cpython]: ./cpython-shutil.md
[talks]: ./sarai-talks.md
[lwn]: ./lwn-openat2-series.md
[forshaw]: ./forshaw-windows-symlinks.md
