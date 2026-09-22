# Comparison and Recommendations

The capstone: what the twenty-six subjects agree on, where they split, and what
that implies for `sparkles.base.dir_handle` — the directory-handle module that
`sparkles:test-utils`' `TmpFS` and the fileset walker
([`FSD5`–`FSD7`][spec]) will stand on.

**Last reviewed:** September 22, 2026

## The consensus, in one paragraph

Every surviving design descends from one 1996 sentence — "path names are
indirect pointers … file descriptors are direct pointers"
([Bishop & Dilger][bishop]) — and one 2009 verdict: any defense that _re-resolves
a name_ and hopes to be faster than the attacker is dead, because the attacker
can make any lookup, even of a non-existent name, take milliseconds
([Cai et al.][cai], after [Borisov et al.][dean-hu] broke the [k-race][dean-hu]).
What is left is **walking once, from a handle**: in the kernel where a scoped
lookup exists ([`openat2`][openat2], [`O_RESOLVE_BENEATH`][bsd]), and
otherwise one component at a time with `O_NOFOLLOW` on every step
([Chari 2010][chari] is the template; [Go][go], [Rust][rust], [cap-std][capstd],
[libpathrs][libpathrs] and [gnulib][fts] are the implementations). Deletion
follows the same rule: open each directory relative to its parent, list it from
the handle, unlink relative to it, never descend a link ([Rust's CVE-2022-21658
fix][rust], [CPython][cpython], [gnulib `fts`][fts]).

## Master table

| Subject                       | Kind    | Primitive                                                        | `..`                                  | Symlinks                              | Mounts                      | Fallback                                  | Deletion                      |
| ----------------------------- | ------- | ---------------------------------------------------------------- | ------------------------------------- | ------------------------------------- | --------------------------- | ----------------------------------------- | ----------------------------- |
| [Linux `openat2`][openat2]    | kernel  | whole-path `resolve` mask, 5.6+                                  | beneath allowed; `EAGAIN` on race     | per flag                              | `RESOLVE_NO_XDEV`           | `ENOSYS`/`EPERM` → caller's walk          | —                             |
| [procfs magic links][procfs]  | kernel  | `RESOLVE_NO_MAGICLINKS`; `fsopen`+`open_tree` private procfs     | —                                     | magic links = jumps                   | `STATX_MNT_ID`              | `f_type` list, `":[]"` heuristic          | —                             |
| [FreeBSD / OpenBSD][bsd]      | kernel  | `O_RESOLVE_BENEATH` (13+), Capsicum, `O_EMPTY_PATH` (14)         | **temporal escape refused**           | absolute refused                      | —                           | probe by behaviour (13 ≠ 14)              | —                             |
| [Darwin][darwin]              | kernel  | `O_NOFOLLOW_ANY`, `AT_SYMLINK_NOFOLLOW_ANY`, `*_RESOLVE_BENEATH` | lexical                               | none, whole path                      | —                           | **no surveyed consumer uses them**        | —                             |
| [Windows NT][windows]         | kernel  | `NtCreateFile` + `RootDirectory`, `OBJ_DONT_REPARSE`             | **lexical only** (parser, not lookup) | reparse zoo refused whole-path        | volume id in `FILE_ID_INFO` | probe `OBJ_DONT_REPARSE`, downgrade once  | handle-based POSIX            |
| [libpathrs][libpathrs]        | library | `openat2` → `O_PATH` walk                                        | re-check via `/proc/thread-self/fd`   | beneath (kernel) / re-fed (walk)      | **not** `NO_XDEV` (TODO)    | one-way failure cache; never downgrade    | fd-relative, unbounded        |
| [filepath-securejoin][sj]     | library | `openat2` → `O_PATH` walk (Go)                                   | as libpathrs                          | as libpathrs                          | none                        | never downgrade per-lookup                | none                          |
| [Go `os.Root`][go]            | runtime | per-component `O_NOFOLLOW` walk (**no `openat2`**)               | drop + restart from root; 255/8 bound | spliced, max 8                        | out of scope, documented    | js / Plan 9 name-based tier               | `removeAllFrom`               |
| [Rust std][rust]              | runtime | `remove_dir_all` walk; `fs::Dir` (unstable)                      | n/a                                   | `ELOOP` or `ENOTDIR` → unlink         | none                        | compile-time CVE algorithm on 7 targets   | fd-relative, 50 retries (Win) |
| [rustix][rustix]              | binding | every `*at`, `openat2` raw 437, `Dir::read_from` re-open         | policy-free                           | policy-free                           | policy-free                 | none                                      | none                          |
| [cap-std][capstd]             | library | `openat2 BENEATH\|NO_MAGICLINKS` → manual stack walk             | pop ancestor stack                    | spliced, max 40/63; absolute refused  | **none**                    | 4 `EAGAIN` retries then **silent** walk   | 2020 std algo                 |
| [openat / openat-ext][crates] | binding | thin `*at` wrapper                                               | kernel                                | `O_NOFOLLOW` on some calls            | none                        | none                                      | `d_type`-trusting             |
| [gnulib `fts`][fts]           | walker  | `FTS_CWDFD`: `openat` per dir, fd ring for ascent                | pop ring; else re-open + dev/ino      | `O_NOFOLLOW` iff `FTS_PHYSICAL`       | `FTS_XDEV` opt-in           | `/proc/self/fd/N/name` → `fchdir` → paths | `unlinkat` (coreutils `rm`)   |
| [CPython `shutil`][cpython]   | walker  | `lstat → open(dir_fd) → fstat + samestat`                        | n/a                                   | **identity compare, no `O_NOFOLLOW`** | none                        | `_rmtree_unsafe` (always on Windows)      | explicit stack (3.14)         |

The nine papers are not rows: they are the reasons the rows look like this. Their
one-line contributions are in the [umbrella's milestones][index].

## Axis 1: where the walk happens

| Where                     | Who                                                       | What it buys                                                      | What it costs                                                                      |
| ------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Kernel, whole path        | `openat2`, `O_RESOLVE_BENEATH`, `OBJ_DONT_REPARSE`        | one syscall; kernel locks; `..` checked _during_ the walk         | Linux ≥ 5.6 / FreeBSD ≥ 13 / Windows ≥ Vista-ish only; still `EAGAIN` under rename |
| User space, per component | Go, Chari, cap-std manual, libpathrs `opath`, gnulib      | works everywhere `openat` exists (macOS 10.10+, every BSD, Linux) | `O(depth)` syscalls; `..` must be handled by the caller; symlinks must be re-fed   |
| User space, by name       | Go on js/Plan 9, CPython on Windows, classic `SecureJoin` | nothing to install                                                | the TOCTTOU every paper describes                                                  |

The field's direction is unambiguous, and so is its lag: the kernel answer is
six years old, yet [Go][go] ships without it and [libpathrs][libpathrs] keeps a
full fallback resolver. **A portable module must be designed around the
component walk and treat the kernel path as an accelerator**, not the reverse.

## Axis 2: what `..` means

This is the axis on which the kernels disagree with each other, and the one a
portable API has to settle by fiat:

- Linux `RESOLVE_BENEATH` **allows** a `..` that stays beneath and fails closed
  with `EAGAIN` when it cannot prove it did ([flag matrix][ex-flags]).
- FreeBSD `O_RESOLVE_BENEATH` **refuses** "even the temporal escape" — and
  FreeBSD 13 and 14 behave differently at the root, which is why [cap-std][capstd]
  probes behaviour rather than presence.
- Windows never resolves `..` in a lookup at all; it is a **parser** feature,
  which is why [Go][go] cleans lexically first with a `\\?\?\` guard.
- Every user-space walker either **rejects `..` before the first syscall**
  ([Go's `errPathEscapes`][go] for more `..` than components, this catalog's
  [walk example][ex-walk]) or **pops an ancestor-handle stack** ([cap-std][capstd],
  [gnulib's fd ring][fts]) — never `openat(dir, "..")`, "because dir may have moved
  since we opened it".

For a module whose consumers are a test fixture and a build-tree walker, the
only behaviour that is identical on every platform is the strictest one:
**reject `..` lexically**. Anything looser means a fixture test that passes on
Linux and fails on macOS.

## Axis 3: beneath versus no-symlinks

| Guarantee         | Linux                 | FreeBSD             | Darwin           | Windows                                 | Component walk        |
| ----------------- | --------------------- | ------------------- | ---------------- | --------------------------------------- | --------------------- |
| No symlink at all | `RESOLVE_NO_SYMLINKS` | walk                | `O_NOFOLLOW_ANY` | `OBJ_DONT_REPARSE`                      | `O_NOFOLLOW` per step |
| Beneath, links ok | `RESOLVE_BENEATH`     | `O_RESOLVE_BENEATH` | walk + splice    | walk + `FILE_OPEN_REPARSE_POINT` + read | splice link text      |

"Beneath" is the richer semantics and what [cap-std][capstd] and
[libpathrs][libpathrs] chose. It costs a symlink re-feeding loop with a depth
bound (8 in Go, 40/63 in cap-std, `MAXSYMLINKS` in the kernel), and on Windows it
costs reading the reparse buffer by hand. "No symlinks" is one flag on three
kernels and one `O_NOFOLLOW` on the fourth, and it is what [Rust's
`remove_dir_all`][rust], [gnulib `rm`][fts] and every deletion path already do.
**Recommendation: no-symlinks as the floor; beneath as an opt-in the module can
grow later**, since the fileset spec's node model reads links as values and
never needs to follow one.

## Axis 4: the fallback ladder and how it is detected

| Library      | Detects with                                    | Caches          | On `EAGAIN` exhaustion    | Downgrades per-lookup?                              |
| ------------ | ----------------------------------------------- | --------------- | ------------------------- | --------------------------------------------------- |
| libpathrs    | first `ENOSYS`; `EPERM` counted                 | failure only    | surfaces `EAGAIN`, 128×   | **never** — "downgrade attack"                      |
| securejoin   | same                                            | failure only    | surfaces `EAGAIN`/`EXDEV` | **never** (`lookup_linux.go`)                       |
| cap-std      | `ENOSYS` static; `EPERM` per call; skip Android | success+failure | returns `ENOSYS`, 4×      | **yes, silently** — a rename storm changes resolver |
| Rust std     | compile-time target list                        | —               | —                         | n/a                                                 |
| Rust std Win | `OBJ_DONT_REPARSE` once, `INVALID_PARAMETER`    | atomic, one-way | —                         | downgrade-only, never re-probed                     |
| gnulib       | `openat_needs_fchdir()` at `fts_open`           | —               | —                         | silent to `FTS_NOCHDIR`                             |
| CPython      | `os.supports_dir_fd` at import                  | —               | —                         | publishes `avoids_symlink_attacks`                  |

Two rules fall out. **Cache failure, never success** — "a process can always
add seccomp-bpf filters to itself" ([libpathrs][libpathrs]). **Do not fall back
per lookup** — if `openat2` works and refuses _this_ path, the walk must not be
given a second chance ([securejoin][sj]). And one honesty rule from
[CPython][cpython]: publish which resolver is live (`avoids_symlink_attacks`), the
same posture as the spec's `FSD6`.

## Axis 5: identity

| Identity            | Who relies on it                                       | Why it is not enough                                                                                                                     |
| ------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `(st_dev, st_ino)`  | gnulib `fts_safe_changedir`, CPython `samestat`, Chari | inode numbers are reused on ext4/XFS/ReiserFS/NILFS2 ([Raducu Table 4][raducu]); hard-link swaps defeat symlink-only checks ([Cai][cai]) |
| `FILE_ID_INFO`      | Go, Rust on Windows                                    | 128-bit id + volume serial — durable, but not a lock                                                                                     |
| **The open handle** | every fd-relative design                               | the only identity that cannot be swapped: what you hold is what you opened                                                               |

Recommendation: never remember a tuple to compare later; **hold the handle**.

## Axis 6: deletion

All five deletion implementations converged on the same shape and disagree only
at the edges:

- **Classify without following**: `openat(O_DIRECTORY|O_NOFOLLOW)` and treat
  `ENOTDIR` _or_ `ELOOP` as "unlink it" ([Rust][rust]; this catalog's
  [example][ex-rm] shows Linux returns `ENOTDIR` for a symlinked intermediate).
  CPython instead compares `lstat` to `fstat` ([cpython][cpython]) — the only
  design with no `O_NOFOLLOW` at all.
- **List from the handle** — and do not `dup` it into `fdopendir`: the shared
  file description is undefined behaviour territory, so [rustix][rustix]
  re-opens with `openat(fd, ".")`.
- **Re-read until empty** ([libpathrs][libpathrs]) or close-and-reopen per
  1024-name batch ([Go][go]), because deleting while iterating skips entries.
- **Windows**: `FILE_DISPOSITION_INFORMATION_EX` with `POSIX_SEMANTICS |
IGNORE_READONLY_ATTRIBUTE`, fall back to the classic disposition on
  `INVALID_PARAMETER`, treat `DELETE_PENDING` as gone, retry `SHARING_VIOLATION`
  ([Rust][rust]); a directory symlink opened by handle **iterates as empty**.
- **Bounds**: nobody but gnulib (fd ring) and CPython (explicit stack) bounds
  depth or descriptors; libpathrs and cap-std recurse unbounded.

## What nobody does

Findings by absence, which the [research guideline][guide] asks for:

- **Nobody uses Darwin's `O_NOFOLLOW_ANY`.** Go, Rust and cap-std all walk.
- **Nobody checks mounts in a general resolver.** libpathrs has it as a TODO,
  cap-std and Go declare it out of scope; only libpathrs's _procfs_ handle and
  gnulib's opt-in `FTS_XDEV` care.
- **Nobody re-verifies after `openat2`**; the kernel's answer is trusted.
- **Nobody ships without a fallback** except rustix (which ships no policy).
- **The academic survey does not know this lineage exists**: [Raducu 2022][raducu]
  contains none of `openat2`, `O_RESOLVE_BENEATH`, libpathrs or `os.Root`.

## Delta: dir_handle against the field

| Capability                        | Field                                                   | Sparkles today                               | Proposed                                                                                                            |
| --------------------------------- | ------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Handle-relative open              | universal                                               | none — `TmpFS` builds paths with `buildPath` | `DirHandle` over `int`/`HANDLE`, move-only, closes on destruct                                                      |
| Lexical `..` / absolute rejection | Go (Unix), Go (Windows, cleaned), examples              | `enforceBeneath` string check (`517803e5e`)  | keep, as the portable layer, before any syscall                                                                     |
| Whole-path no-symlink lookup      | `RESOLVE_NO_SYMLINKS`, `OBJ_DONT_REPARSE`               | none                                         | Linux `openat2(BENEATH\|NO_SYMLINKS\|NO_MAGICLINKS)`; Windows `OBJ_DONT_REPARSE`                                    |
| Component-walk fallback           | Go, cap-std, libpathrs, gnulib                          | none                                         | `openat(O_NOFOLLOW\|O_DIRECTORY\|O_CLOEXEC)` per step; the one walker that runs on Darwin                           |
| Detection policy                  | failure-only cache; never downgrade per lookup          | —                                            | probe once, cache `ENOSYS`; `EPERM` per call; a refused `openat2` lookup is a refusal                               |
| Capability reporting              | `avoids_symlink_attacks`                                | `FSD6` (spec only)                           | `DirHandle.resolution()` → `kernelWholePath` / `componentWalk`                                                      |
| Fd-relative deletion              | Rust, CPython, gnulib, libpathrs, Go                    | `std.file.rmdirRecurse` by path              | `removeTree`: re-open `.` for listing, `ENOTDIR\|ELOOP` → unlink, bounded depth; Windows POSIX delete with fallback |
| Mount boundary                    | nobody (general); `FSD7` wants it                       | —                                            | `RESOLVE_NO_XDEV` on Linux; `st_dev`/volume-serial compare elsewhere, documented as racy                            |
| Retry budget on `EAGAIN`          | 128 (libpathrs) vs 4 (cap-std)                          | —                                            | explicit constant, surfaced as an error kind when exhausted — never a fallback                                      |
| Test oracle                       | `TestRootRaceRenameDir`, `avoids_symlink_attacks` tests | none                                         | plant links/junctions and a rename race; assert which resolver ran                                                  |

## Open questions the research does not settle

1. **Beneath or no-symlinks as the default** for the fileset walker's `FsoRef`
   once it needs to _read_ a link's target — `RESOLVE_NO_SYMLINKS` refuses to
   open the link itself; `O_PATH|O_NOFOLLOW` plus `readlinkat` is the
   libpathrs answer, and it needs a second call.
2. **Whether to expose an `O_PATH`-style "located but not opened" handle** at
   all, given that re-opening it on Linux goes through `/proc/self/fd` and
   FreeBSD 14 has `O_EMPTY_PATH` while Linux's `RESOLVE_EMPTY_PATH` never merged.
3. **How much of Windows to promise**: `OBJ_DONT_REPARSE` needs a version probe
   and a downgrade path; the per-component reparse-tag check is the honest
   floor, and CPython's choice — no fd-relative path on Windows at all — is the
   floor below that.

<!-- References -->

[index]: ./index.md
[spec]: ../../specs/build-primitives/filesets/SPEC.md
[guide]: ../../guidelines/research-docs.md
[bishop]: ./bishop-dilger-1996.md
[dean-hu]: ./dean-hu-2004-borisov-2005.md
[cai]: ./cai-2009.md
[chari]: ./chari-2010.md
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
[ex-flags]: ./examples/openat2-resolve-flags.d
[ex-walk]: ./examples/component-walk.d
[ex-rm]: ./examples/fd-remove-tree.d
