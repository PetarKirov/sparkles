# Method and measurement (protocol)

The catalog repeats a handful of performance numbers it did not take: a fixed startup cost of order milliseconds, a lost-page-sharing claim, a 611.9 MiB against 5.53 GiB size comparison. This page specifies the experiments that would turn each of those from a quoted figure into a measured one, and is scrupulous about which is which.

| Field           | Value                                                                                                                                                                                   |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Methodology / measurement protocol — no subject of its own                                                                                                                              |
| Language        | Shell drivers, D probes (repo convention), `perf`/`bpftrace` scripts                                                                                                                    |
| License         | n/a — the instruments are surveyed, not vendored                                                                                                                                        |
| Repository      | Instruments: [`torvalds/linux`][linux-repo] (`binfmt_misc`, `smaps_rollup`, `perf`) · [`iovisor/bcc`][bcc-repo] · [`bpftrace/bpftrace`][bpftrace-repo] · [`sharkdp/hyperfine`][hf-repo] |
| Documentation   | [`proc(5)` / kernel `filesystems/proc`][kdoc-proc] · [cgroup v2][kdoc-cgroup] · [`perf_event_open(2)`][man-peo] · [`ld.so(8)`][man-ldso]                                                |
| First release   | n/a — the subject is a protocol. Instrument vintages are recorded per experiment.                                                                                                       |
| Axis profile    | Multiplicity **0** / Reflexivity **1** / Closure **0** / Mutability **1** — scored for the _apparatus_, not an artifact                                                                 |
| Index anchoring | **out-of-band** — every measurement index (`/proc/PID/smaps_rollup`, the `perf` ring buffer, `tracefs`) lives outside the artifact                                                      |
| Dispatch owner  | **consumer** — the experimenter picks the instrument, and that choice is itself a confound                                                                                              |

> **Revisions surveyed:** Linux `e43ffb69` (v7.1-rc6), glibc `04e750e7` (post-2.43), SQLite `8a988271`, `hyperfine` `f12f3d9f`, bcc `6d0a964c`, bpftrace `d052fff4`, `fzakaria/selfdb` `e63f7c47`. **Platform:** Linux, x86-64; NixOS observations where the distribution matters.

> [!IMPORTANT]
> **This page prescribes experiments. It reports no results.** No number below was measured for this catalog. Every figure that appears is either (a) a **source claim**, labelled as such with its citation, or (b) a **derivation** from source code, labelled as such. Where a prediction is stated, it is stated as a prediction and paired with the observation that would falsify it.

---

## Overview

### What it solves

Three numbers circulate through this tree, and all three are quoted rather than reproduced:

| Figure                                                                   | Status                                                                                       | Where it enters                       |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ------------------------------------- |
| _"a fixed ~5 ms to open SQLite and start the interpreter"_               | **source claim** ([post 1][post1])                                                           | [SELF][self], [`binfmt_misc`][binfmt] |
| Two processes running one SELF binary do not share text                  | **source claim** ([post 1][post1]), plus a code-level derivation from [`native.c`][native-c] | [SELF][self], [concepts][concepts]    |
| 611.9 MiB for a 723-executable userland against 5.53 GiB private-closure | **source claim** ([post 1][post1])                                                           | [SELF][self], [Nix closures][nix]     |

None of the three is dishonest. Two of them are the author's own, published alongside a harness that produces them, and the project's design document is explicit that measuring the gap is the plan rather than an afterthought. But a quoted figure cannot be argued with, and the catalog's central comparison — [thesis 4, `mmap` is the load-bearing constraint][concepts] — turns on the second one. This page exists so that a reader who wants to settle the question can, in an afternoon, with commodity tooling, and know exactly what the answer does and does not cover.

The protocol has four obligations:

1. **Decompose the constant.** "~5 ms" is one number covering at least eight distinct stages, at least two of which are not about SELF at all. Each stage gets an experiment, a baseline, and a named confound.
2. **Answer the page-sharing question decisively.** It is the cheapest experiment in the catalog and the most consequential. The formula, the arms, and the interpretation are specified below in full.
3. **Neutralise the loader confounder.** Loader work is proportional to **object count**, not bytes ([dynamic linking][ld]). Any ELF-against-anything startup comparison that does not control for it is measuring a packaging decision.
4. **Separate what was measured from what was inferred.** Including in this page.

### Design philosophy

The stance is borrowed, verbatim, from the seed project's own evaluation plan ([`DESIGN.md`][design] §9):

> _"Claims we make must survive measurement; the paper/talk needs both columns."_

That document then lists four metrics, a method for each, and — crucially — an **expectation** for each, including the one this page treats as the decisive question:

> _"memory sharing | `pss` across N concurrent instances | ELF wins (shared text) until the §8 aligned-blob trick"_

Read carefully, that row is a hypothesis with a stated prior, not a result: the method is named, the expectation is named, and nothing in the repository at [`e63f7c47`][repo] executes it. The same document's repository layout even reserves the slot — `bench/` is annotated _"hyperfine + size + pss harnesses"_ — and at the surveyed commit `bench/` contains `run.sh`, `big.sh` and their two result files, all exec-latency and file-size. The word `pss` occurs exactly twice in the tree, both times in `DESIGN.md`. So the sharpest claim in the catalog is, at the time of writing, a well-motivated prediction supported by a reading of the loader source rather than by a measurement — which is exactly the situation this page is for.

The second commitment is a discipline about instruments, and it is best stated by an instrument admitting its own limits. glibc's own high-precision timer, the one behind `LD_DEBUG=statistics`, carries this comment ([`sysdeps/x86/hp-timing.h`][hp-timing]):

> _"That's quite simple. Use the `rdtsc` instruction. Note that the value might not be 100% accurate since there might be some more instructions running in this moment. This could be changed by using a barrier like 'cpuid' right before the `rdtsc` instruction. But we are not interested in accurate clock cycles here so we don't do this."_

Every instrument in the table further down has a sentence like that somewhere in its source or its manual. Finding it before quoting the tool's output is the whole method.

---

## How it works

### The subject: what a single startup actually contains

Before decomposing a cost you have to enumerate the stages. Reading the kernel, glibc and SQLite sources gives the following map for one `execve` of a registered `.self` file. Each row names the boundary that is **observable**, which is what makes the row an experiment rather than a category.

| #   | Stage                                                         | Runs in     | Observable boundary                                                                  |
| --- | ------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------ |
| 1   | `execve` → `bprm_execve` → `search_binary_handler`            | kernel      | `sched:sched_process_exec` tracepoint; `syscalls:sys_enter_execve`                   |
| 2   | format walk: `binfmt_elf` declines, `binfmt_misc` matches     | kernel      | kprobe on `load_misc_binary` ([`fs/binfmt_misc.c`][binfmt-src])                      |
| 3   | interpreter substitution and re-dispatch                      | kernel      | the `exec_binprm` loop ([`fs/exec.c`][exec-src]) — **not** a second `execve` syscall |
| 4   | `self-exec`'s own dynamic link (it is an ordinary ELF)        | `ld.so`     | uprobe on `_dl_start`; `LD_DEBUG=statistics`                                         |
| 5   | `sqlite3_open_v2`: one `openat`, one 100-byte `pread`         | libsqlite3  | `strace`; uprobe on `sqlite3_open_v2`                                                |
| 6   | first `prepare`: page-1 read **and the schema re-parse**      | libsqlite3  | uprobe on `sqlite3_prepare_v2` / `sqlite3InitOne`                                    |
| 7   | segment scan: `sqlite3_column_blob` + `malloc` + two `memcpy` | `self-exec` | uprobe on the loader's own segment function                                          |
| 8   | `memfd` mode only: `memfd_create`, `write`, `execveat`        | kernel      | a genuine second `execve`-family syscall, visible to `strace`                        |

Three corrections to the naive model fall straight out of the sources, and each one changes an experiment's design.

**Stage 3 is not a second `execve` syscall.** `binfmt_misc` does not re-enter `execve`; `exec_binprm` swaps `bprm->file` for the interpreter and loops in place, bounded by a depth counter ([`fs/exec.c`][exec-src]):

```c
/* fs/exec.c — exec_binprm() */
/* This allows 4 levels of binfmt rewrites before failing hard. */
for (depth = 0;; depth++) {
        struct file *exec;
        if (depth > 5)
                return -ELOOP;
        ret = search_binary_handler(bprm);
        ...
        exec = bprm->file;
        bprm->file = bprm->interpreter;
```

So counting `execve` entries does **not** count dispatch rounds; a kprobe on `search_binary_handler` does. The extra work stage 3 contributes is one more `prepare_binprm`, one more `security_bprm_check` pass over the LSM stack, and one `open_exec` of the interpreter path.

**Stage 2's matcher is a byte loop, not a hash.** `search_binfmt_handler` walks the registered entries linearly and compares under the mask one byte at a time ([`fs/binfmt_misc.c`][binfmt-src]):

```c
/* fs/binfmt_misc.c — search_binfmt_handler() */
s = bprm->buf + e->offset;
if (e->mask) {
        for (j = 0; j < e->size; j++)
                if ((*s++ ^ e->magic[j]) & e->mask[j])
                        break;
}
```

The derived cost is therefore _(registered entries scanned) × (magic length)_ byte comparisons over a buffer the kernel already read, bounded by `BINPRM_BUF_SIZE`. SELF's registration is 72 bytes ([`nix/module.nix`][module-nix]). This predicts sub-microsecond dispatch. It is a **derivation, not a measurement**, and E1 below exists to check it — because the prediction ignores `open_exec`'s path walk and the LSM pass, which are the parts that could plausibly cost real time.

**Stage 6, not stage 5, is where the schema is parsed.** `sqlite3_open_v2` reaches `sqlite3BtreeOpen`, which reads exactly 100 bytes at offset 0 into a stack buffer to learn the page size ([`src/btree.c`][btree-c]):

```c
/* src/btree.c — sqlite3BtreeOpen() */
unsigned char zDbHeader[100];          /* Database header content */
...
rc = sqlite3PagerReadFileheader(pBt->pPager, sizeof(zDbHeader), zDbHeader);
pBt->pageSize = (zDbHeader[16]<<8) | (zDbHeader[17]<<16);
```

The schema itself is materialized later, on the first statement preparation, by `sqlite3InitOne` — which builds the in-memory schema by **re-running the SQL parser** over each `sqlite_schema.sql` text ([`src/prepare.c`][prepare-c]). The consequence for experiment design is sharp: **the schema-parse term scales with the DDL text, not with the image size**, so it must be varied independently of the segment blobs or the two terms are inseparable. The [SELF page's][self] item 3 folds them together; they are two experiments.

### E1: `binfmt_misc` dispatch, by difference

**Arms.** (a) `./hello.self`, the registered path. (b) `self-exec hello.self`, the interpreter invoked directly. Everything downstream of stage 3 is identical; the delta is stages 1–3.

**Why this arm pair.** It repairs the specific defect the [SELF deep-dive][self] identifies in the shipped harness: `bench/run.sh` and `bench/big.sh` time the SELF arms as `self-exec` invocations, so **the published numbers contain no dispatch cost at all**, and they prefix those arms with `env` while the ELF baseline runs bare, so the SELF arm pays one extra `execve` the ELF arm does not. Both defects are fixed by construction here: the launcher is identical in both arms, or absent in both.

**Confounds to hold and to record.**

- The number and order of registered `binfmt_misc` entries — the matcher is a list walk. Record `ls /proc/sys/fs/binfmt_misc` and the position of the SELF entry.
- The active LSM stack — `security_bprm_check` runs once per `search_binary_handler` call. Record `cat /sys/kernel/security/lsm`.
- The interpreter path's directory depth, since stage 3 does an `open_exec` on it. Use the same absolute path in both arms.
- The `F` (`MISC_FMT_OPEN_FILE`) flag changes stage 3 from `open_exec` to `file_clone_open` of a pre-opened file. SELF's shipped registration sets no flags, so this is a _variant_ worth running rather than a confound to eliminate.

### E2: the interpreter's own dynamic link

Stage 4 is the term the seed project's own post identifies as invisible, and it is not a property of the SELF format at all: `self-exec` is an ordinary dynamically linked ELF against `libsqlite3`, so a complete `ld.so` run happens before any SELF work begins.

**Arms.** The shipped dynamic `self-exec` against a statically linked build of the same source (SQLite ships as an amalgamation, so this is a build-flag change, not a port). The delta is stage 4, plus whatever static linking changes about stages 5–7 — which is why the arms must also be compared on a workload that skips the SELF path entirely (open the database, read `self_meta`, exit) to separate them.

**Cross-check, free.** `LD_DEBUG=statistics ./self-exec …` reports the loader's own accounting of stage 4 in cycles. Read [what that number excludes](#the-instruments-and-what-each-cannot-see) before quoting it.

### E3: open, schema parse, and image copy

**Three terms, three independent variables.**

| Term               | Vary by                                                        | Expected scaling                          |
| ------------------ | -------------------------------------------------------------- | ----------------------------------------- |
| open + header read | nothing — it is one `openat` and one 100-byte `pread`          | constant                                  |
| schema parse       | adding tables/indexes/views with no effect on the image        | with total DDL text length                |
| image copy         | converting programs of increasing `filesz` with a fixed schema | linear in bytes, with two `memcpy` passes |

**Instrument ladder, cheapest first.**

1. `strace -c -f -e trace=openat,pread64,read,mmap,mprotect,memfd_create,execve,execveat` — syscall **counts** are exact and free; the times reported next to them are not (see below). This alone distinguishes `memfd` mode from `native` mode unambiguously, because only `memfd` mode issues `memfd_create` and a second exec-family call.
2. `perf stat -e task-clock,page-faults,minor-faults,major-faults,context-switches --repeat 30 --table` — `--table` prints each run, which is what you want for a distribution rather than a mean ([`perf-stat.txt`][perf-stat-doc]).
3. Only then uprobes on `sqlite3_open_v2`, `sqlite3_prepare_v2` and the loader's segment function, for the per-stage split.

**The baseline that makes stage 5+6 interpretable** is a control program that opens the same `.self` file, prepares one trivial statement, and exits — i.e. everything except the segment copy. The difference between the control and the real loader is stage 7 alone.

**Confounds.** Page-cache state dominates the first read of a large image and must be declared, not averaged away (see the [checklist](#reproducibility-checklist)). Journal mode changes SQLite's open-time file operations; the seed project's own server example measures an 8× spread between WAL and rollback journal on a _write_ path ([`examples/server/README.md`][server-readme]) and the read path is not immune. Fix `PRAGMA journal_mode` explicitly in both arms.

### E4: controlling the loader confounder

This is the control that makes any ELF-against-SELF comparison mean anything, and the reason is quantitative. The cost model for symbol binding is stated by the same author in an earlier post ([_Speeding up ELF relocations for store-based systems_][fz-reloc]) as

> _"the cost of relocations is : O(R + nr log s), where R is the number of relative relocations, n is the number of shared libraries, r is the number of named relocations, and s is the number of symbols."_

The dominant free parameter there is `n`, and `n` is a **packaging decision**. Two builds of one program, from one source tree, with identical total bytes, can differ several-fold in loader time purely by how the distribution split libc, libm, libz and friends. So:

**Do not report a point. Report a slope.**

1. Construct a family of builds of the same program at object counts `n` ∈ {1, 2, 4, 8, 16, 32}, holding total code bytes and total defined/undefined symbol counts fixed — split the same translation units across a varying number of shared objects rather than adding code.
2. Measure both formats at every `n`.
3. Report `d(startup)/dn` for each arm, and the intercept. The intercept is the format's fixed cost; the slope is the loader's, and it is shared by both arms except where the SELF loader replaces `ld.so`.
4. State the `n` of any single-point comparison you publish, next to the number.

[`self-selfdb/examples/relocation-join.d`](./self-selfdb/examples/relocation-join.d) computes the quantity that actually scales — the **probe count**: how many objects in scope were examined before each symbol resolved, first-match-wins, with an `LD_PRELOAD` object spliced in as one extra tuple. Its own closing note is the methodological point in one line: the probe count grows with the object count _even when the image size is held fixed_. Run it against the `n`-family before running any timing, because it predicts the slope you are about to measure and a mismatch means the family is not controlled.

> [!WARNING]

### Closing the books: the residual is the result

The failure mode of a decomposition is that the parts do not add up and nobody says so. Bound it explicitly:

```text
T_total        = end-to-end wall clock of the registered path            (E1 arm a)
T_dispatch     = T_total − (direct-interpreter arm)                       (E1)
T_interp_link  = dynamic self-exec − static self-exec                     (E2)
T_open         = uprobe span over sqlite3_open_v2                         (E3)
T_schema       = uprobe span over the first prepare                       (E3)
T_copy         = uprobe span over the segment loop                        (E3)
residual       = T_total − (T_dispatch + T_interp_link + T_open
                            + T_schema + T_copy + T_program)
```

`T_program` is the subject's own `main()`, which is why the subject should be a `noop` that returns 0 — it makes `T_program` a constant you can measure once and subtract. **Publish the residual.** A residual of a few percent means the map in [the stage table](#the-subject-what-a-single-startup-actually-contains) is complete; a residual of forty percent means a stage is missing, and the interesting work is finding it rather than reporting the five terms you did account for.

Two known contributors to the residual, both real and both easy to forget: the kernel's `begin_new_exec` work (address-space teardown and setup, which scales with the _old_ process's mappings, so it depends on what forked the subject), and the `mprotect` pass at the end of each segment map. Neither is SELF-specific; both are charged to the arm that runs them.

> A self-contained artifact's apparent **win** over dynamically linked ELF may be entirely the collapse of `n` to 1 — which static linking also achieves, with none of the properties this catalog is about. A static-link control arm is therefore not optional; it is the arm that separates "this format is fast" from "this comparison had a fan-in of 27". See [dynamic linking][ld] for the full argument and [`cosmopolitan-ape`][ape] for the other artifact in this catalog that collapses `n` by construction.

---

## Format identity and multiplicity

**Multiplicity 0, and the absence is a finding.** There is no artifact here whose bytes admit several parses. What this section can usefully say instead is that measurement introduces a _second_ set of formats — `perf.data`, `tracefs` text, `/proc` text, `hyperfine`'s JSON export — and that the recurring failure mode of the catalog reappears in miniature: **two consumers disagreeing about one byte stream.**

The concrete instance is `/proc/PID/smaps_rollup`. It is a text format with no schema and no version field. `Pss_Anon`, `Pss_File` and `Pss_Shmem` exist only in the rollup and not in `smaps`; `KSM`, `LazyFree`, `FilePmdMapped` and `THPeligible` sit alongside the fields a naive parser expects ([kernel `filesystems/proc`][kdoc-proc]); and a parser written against one kernel silently mis-reads another by matching the wrong prefix. It is exactly the accreted-conventions failure that [thesis 2][concepts] predicts for a format without a schema, and the mitigation is the same one a self-describing format would make unnecessary: parse by exact field name, assert on unknown fields, and record `uname -r` beside every number.

The one place multiplicity genuinely bears on method is the **identity of the subject under test**. A `.self` file is simultaneously a thing `sqlite3` opens and a thing the kernel dispatches on, and the two paths touch different byte ranges: `sqlite3` reads the header and descends the b-tree, while `binfmt_misc` compares 72 bytes at offset 0 and then never looks at the file again. An experiment that measures "opening the artifact" must say which of those it means. See [`self-selfdb/examples/sqlite-header-probe.d`](./self-selfdb/examples/sqlite-header-probe.d) and [`binfmt-magic-match.d`](./self-selfdb/examples/binfmt-magic-match.d) for the two reads made explicit and runnable, which is the cheapest way to confirm a registration or a header assumption before spending an afternoon on a harness built over a wrong one.

## Index anchoring and random access

**Out-of-band, in every case, and that is the methodological hazard.** None of the artifacts in this catalog carries its own performance index; every measurement index lives elsewhere and is a [materialized view][concepts] of something happening inside the process.

| Index                     | Anchoring                         | Cost of reading it                                          | Staleness mode                          |
| ------------------------- | --------------------------------- | ----------------------------------------------------------- | --------------------------------------- |
| `/proc/PID/smaps_rollup`  | out-of-band, materialized on read | **O(mapped pages)** — a full page-table walk per read       | a snapshot; the process moves under you |
| `perf` ring buffer        | out-of-band, streamed             | O(samples); lost records are reported, not silently dropped | overflow under a too-high frequency     |
| `tracefs` / uprobe events | out-of-band, streamed             | one trap per hit                                            | none, but see the COW warning below     |
| `LD_DEBUG=statistics`     | in-process, printed at handoff    | one `write` to stderr                                       | covers one process's loader phase only  |

The `smaps_rollup` row is the one that catches people. The kernel's own documentation is explicit that the rollup is derived rather than stored: _"all information in smaps_rollup can be derived from smaps, but at a significantly higher cost"_ ([`filesystems/proc`][kdoc-proc]) — the rollup exists precisely so that a reader gets the sums in one page-table walk instead of `N`. It is still a walk. Sampling `smaps_rollup` in a tight loop across 64 concurrent processes is not free, and the cost lands on the same CPUs running the subject.

The practical rule that follows: **sample once, at a defined phase.** Have each subject process reach a barrier (a blocking read on a FIFO, or `raise(SIGSTOP)` with the harness resuming them after the sweep), take exactly one `smaps_rollup` read per process, then release. A sweep taken while processes are at different points in their startup is not a measurement of anything.

Random access into the measurement itself matters in one further place: an artifact can be interrogated _without being run_. `sqlite3_analyzer` reports where a `.self` file's bytes went, page by page and table by table, over a handful of b-tree descents rather than a full read — and over HTTP range requests it would not even need the file locally ([range-request access][range]). That is the size-model instrument, and it is the reason the size half of this protocol is cheap while the latency half is not.

## Reflexivity and query surface

The instruments differ in one respect that matters more than their resolution: **whether the subject reports on itself, or something outside reports on it.** The two answer different questions and fail differently.

| Surface                       | Who observes            | Question it answers                              | Blind to                                           |
| ----------------------------- | ----------------------- | ------------------------------------------------ | -------------------------------------------------- |
| `LD_DEBUG=statistics`         | the subject, in-process | how much of _this_ start was link work           | everything before `_dl_start` and all lazy binding |
| `dl_iterate_phdr` / `dladdr`  | the subject             | what is mapped, right now                        | timing entirely                                    |
| `sqlite3_analyzer`, `sqldiff` | an external tool        | where the bytes are; what changed between builds | anything about execution                           |
| `perf`, uprobes, `strace`     | outside                 | when things happened, in whose stack             | intent; and they perturb, see below                |
| `SELECT` against the artifact | anyone                  | the artifact's own model of itself               | its runtime behaviour                              |

The self-reporting row is where these artifacts are genuinely different from ordinary programs, and it is under-exploited by the harnesses in the field. A running `self-httpd` can answer `SELECT count(*) FROM segments` about the file it is executing from ([SELF][self]) — which means an instrumented build can emit its **own** stage timings into a table in its own image, timestamped, per process, with no external tracer attached and therefore with none of the perturbation the next section describes. That is a measurement channel [thesis 4's][concepts] critics should want, because it is the one channel that does not disturb the page sharing being measured. Nobody has built it; it is a small piece of work and it belongs in [open questions][open].

`LD_DEBUG=statistics` deserves its label as the loader's `EXPLAIN ANALYZE`, and equally deserves its caveats. It is generated by `print_statistics` in [`elf/rtld.c`][rtld-c], reports `rdtsc` cycles rather than nanoseconds, and exists at all only where `HP_TIMING_INLINE` is defined — which on x86 is gated on `MINIMUM_ISA` being 686 or 8664 ([`sysdeps/x86/hp-timing.h`][hp-timing]). On an architecture without it, the cycle lines silently vanish and only the relocation **counts** are printed. Those counts are still useful, and they are exact: they come from `GL(dl_num_relocations)` and the `DT_RELCOUNT`/`DT_RELACOUNT` sums walked at print time.

## Closure, dedup, and size model

This is the half of the protocol that is cheap, offline, and reproducible on any machine — no counters, no root, no scheduler noise. It is also where the catalog's most-quoted figure lives.

**The source claim.** 723 executables plus 400 libraries occupy **611.9 MiB** as one relational store, against **5.53 GiB** if every root ships a private closure ([post 1][post1]). The [SELF deep-dive][self] already establishes the necessary caveat — a closure database is _structurally stripped_ (its schema has no `sections`, no `notes`, and no `symtab` rows), so the comparison against unstripped ELF inputs is not like-for-like, and the defensible reading is "b-tree overhead amortises to roughly 6% across 1,123 objects." What follows is the experiment that would establish the curve rather than the point.

**E5 — the amortization curve.** Fix a corpus. Vary the number of roots `R` and the shared-library fan-in `F`. Build the _same_ corpus under three storage models, at the **same strip level** in all three:

| Model                        | Predicted shape of bytes(R)                                                | Where the catalog covers it       |
| ---------------------------- | -------------------------------------------------------------------------- | --------------------------------- |
| (a) private closure per root | linear in `R`, slope ≈ mean closure size — self-containment paid `R` times | [application packaging][apppkg]   |
| (b) one relational store     | sublinear, saturating as the distinct-object set saturates                 | [SELF][self]                      |
| (c) content-addressed chunks | (b) minus intra-object similarity, plus a chunk-index term                 | [content-addressed chunking][cas] |

The interesting output is not three totals but **two crossovers**:

- Where (b) overtakes (a). Predicted early and steeply, because (a)'s slope is the whole closure while (b)'s is only the _new_ objects. This is the 9× the source claim reports at one point on the curve.
- Where (c) overtakes (b). This one is genuinely uncertain and is the reason to run it: (b) dedups by **object identity** — `objects.path UNIQUE`, the same granularity [Nix][nix] uses — while (c) dedups by **content**, below the object. The crossover is where per-object b-tree overhead exceeds the sub-object redundancy that chunking finds. Nobody has measured it for a binary corpus, and the answer decides whether a relational store is a store or an intermediate step toward one.

**Controls that make the curve honest.** Strip level identical in all three arms — this is the caveat the source figure trips over, and it dominates. Compression identical or absent in all three; a chunk store that compresses and a b-tree that does not are not comparable. `page_size` recorded, because b-tree overhead is a per-page tail and the round-up cost of a small object is a page. And report bytes _and_ object counts, so a reader can recompute the per-object overhead you are claiming amortises.

## Mutability, dispatch, and trust

### E6: the page-sharing experiment

**The cheapest decisive experiment in the catalog.** It needs no counters, no root beyond reading `/proc`, and one afternoon.

**Setup.** Launch `N` concurrent processes of the same program, in each arm, and hold all of them at a barrier after startup completes. Sweep `/proc/PID/smaps_rollup` once per process. Repeat for `N` ∈ {1, 2, 4, 8, 16, 32}.

**The barrier, concretely.** The sweep is only meaningful if every subject is at the same point in its life when it is read:

```text
1. harness creates a FIFO and an empty results file
2. launch N subjects; each subject, immediately after startup completes,
   blocks on a read of the FIFO   (no uprobes anywhere on the subject)
3. harness waits until all N are in state S (sleeping) per /proc/PID/stat
4. harness reads /proc/PID/smaps_rollup exactly once per PID, in one pass
5. harness writes N bytes to the FIFO; every subject exits
6. repeat for the next N
```

> [!NOTE]
> The harness is not a shell script. Everything above steps 3 and 4 is parsing `/proc` text, matching exact field names, and asserting on unknown ones — which is real logic, and this repository's convention is that real logic is written in D and lives where it can be promoted into a test or an example ([benchmarking & profiling][bench-guide]). The three runnable companions in this tree are the precedent: each is a single-file `dub` program that reads a real artifact and prints what it found.

Step 3 matters more than it looks: a sweep begun while one subject is still faulting in text measures a mixture of the transient and steady states, and the transient is exactly where the two arms differ most.

**Arms.** (a) the program as an ordinary dynamically linked ELF; (b) the same program as `.self` under `native` mode; (c) the same under `memfd` mode; (d) a statically linked control, which fixes the [E4](#e4-controlling-the-loader-confounder) confound for the memory question too.

**The quantities**, straight from the kernel's field definitions ([`fs/proc/task_mmu.c`][task-mmu], [`filesystems/proc`][kdoc-proc]):

```text
PSS  = the "Pss:" line                          (proportional set size)
USS  = "Private_Clean:" + "Private_Dirty:"      (unique set size — not a kernel field)
RSS  = the "Rss:" line
```

PSS is defined by division: _"the count of pages it has in memory, where each page is divided by the number of processes sharing it. So if a process has 1000 pages all to itself, and 1000 shared with one other process, its PSS will be 1500."_ The implementation is literally that ([`fs/proc/task_mmu.c`][task-mmu]):

```c
/* fs/proc/task_mmu.c — smaps_account() */
if (mapcount >= 2)
        pss /= mapcount;
smaps_page_accumulate(mss, folio, PAGE_SIZE, pss, dirty, locked, exclusive);
```

**The model to fit.** For a shared, file-backed, demand-paged image, let `U` be the genuinely private resident bytes per process and `S` the shared resident bytes. Then

```text
PSS(N) ≈ U + S/N
```

so PSS falls hyperbolically toward `U` as `N` grows, while the machine-wide total `Σ PSS ≈ N·U + S` grows with slope `U`, not with slope `U + S`.

**The discriminator.** Fit `PSS(N) = a + b/N` by least squares over the `N` series and report `b/a`.

| Observation                                           | Interpretation                                         |
| ----------------------------------------------------- | ------------------------------------------------------ |
| `b` large, `PSS` falls toward `USS` as `N` grows      | text is shared — the ordinary ELF case                 |
| `b ≈ 0`, `PSS ≈ RSS ≈ USS` at every `N`               | **segments are copied per process — no sharing**       |
| `Shared_Clean ≈ 0` while `Private_Dirty ≈ image size` | anonymous private copies; also **swap-backed**         |
| `Pss_File` high but `Shared_Clean ≈ 0`                | file-backed but _privately_ so — the `memfd` signature |

That last row is why arm (c) is worth running separately. `memfd` mode does get the kernel to map the image file-backed and demand-paged — but into a `memfd` private to the process, so the pages are file-backed and unshared at once. `Pss_File` alone would read as a success; `Shared_Clean` is what exposes it. The `smaps_rollup` split into `Pss_Anon` / `Pss_File` / `Pss_Shmem` gives this for free and is the reason to use the rollup rather than parsing `smaps`.

**The prediction, and it is a prediction.** Reading [`native.c`][native-c], `map_segment` maps `MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED` and `memcpy`s the blob in, which by construction cannot share and by construction dirties every byte of every load segment before `main()` runs. So arm (b) should show `b ≈ 0`, `Private_Dirty ≈ Σ filesz`, and `Shared_Clean ≈ 0`. If it does not, the reading is wrong and that is a more interesting result than confirmation. **Nothing in this catalog has run it.**

### The instrument that destroys the thing it measures

> [!WARNING]
> **Never run E6 with uprobes attached to the subject.** Installing a uprobe rewrites a byte of the probed text, and to do that the kernel must break the page's sharing ([`kernel/events/uprobes.c`][uprobes-c]):
>
> ```c
> /* kernel/events/uprobes.c — uprobe_write_opcode() */
> /*
>  * When registering, we have to break COW to get an exclusive anonymous
>  * page that we can safely modify. Use FOLL_WRITE to trigger a write
>  * fault if required. ...
>  */
> if (is_register)
>         gup_flags |= FOLL_WRITE | FOLL_SPLIT_PMD;
> ```
>
> The breakpoint is installed **per `mm`**, so `N` probed processes acquire `N` private copies of the probed page. A uprobe in `ld.so` — the placement recommended everywhere else on this page — converts a shared page into an unshared one in exactly the arm whose sharing you are trying to demonstrate. It is a small absolute effect (one page per probe site per process) and a fatal one for a ratio, because arm (a)'s advantage is precisely that its pages are shared.

This generalises past uprobes. The apparatus in this catalog is unusually intrusive because the subjects are unusually small: a 2 ms process instrumented by a tool with a per-event trap cost is not the process you meant to measure. State the perturbation for every arm, and prefer the ladder — counts before timings, external before invasive, one instrument at a time.

### Dispatch: who decides what you measured

The [dispatch question][concepts] has a measurement twin. When the same file can be started three ways — registered through `binfmt_misc`, invoked through the interpreter directly, or `execveat`'d out of a `memfd` — "startup time for this artifact" is under-specified until you name the dispatcher. The in-repo harness names the second, publishes it, and it is read as the first ([SELF][self]). The fix is a naming convention, not a technique: **every number carries its dispatch path.** See [`binfmt_misc`][binfmt] for what the registered path actually costs and why the unmerged transparent-dispatch work would change it.

### Trust

Two properties of these measurements need stating because they are what make a published number reusable by someone else:

1. **A number without its environment is not evidence.** The two harnesses in the seed repository report a `hello` delta of +1.69 ms and +5.44 ms — a 3× spread, on two hosts, for the same subject ([SELF][self]). Neither is wrong. The constant is a property of the machine, and any statement of the form "SELF costs ~5 ms" that omits the host is unfalsifiable rather than false.
2. **You cannot verify a measurement you cannot re-run.** This is the same problem [embedded provenance][prov] has for artifacts, one level up: a benchmark result is an attestation about a computation, and it is only as good as the reproducibility of the inputs. The checklist below is that reproducibility contract, and it is short on purpose.

---

## The instruments and what each cannot see

For counter mechanics — groups, multiplexing and the scaling formula, `perf_event_paranoid`, precise sampling engines — this repository already has a full survey, and it should be read rather than restated: [`docs/research/cpu-pmu/`][cpu-pmu], particularly [the `perf_event_open` page][cpu-pmu-linux]. The repository's own practical loop — measure, profile, fix, re-measure — is [`docs/guidelines/benchmarking-and-profiling.md`][bench-guide], and its two standing rules apply verbatim here: compare deltas on one machine, and record the environment next to any absolute number.

| Instrument               | Sees                                                                  | **Cannot see**                                                                                                      |
| ------------------------ | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `hyperfine`              | wall clock per invocation, with warmup and per-run export             | anything _inside_ the process; with `-N` there is no shell and therefore no shell-time correction to apply          |
| `perf stat`              | counters aggregated over the whole command, `--repeat` with `--table` | phase attribution without markers; counters may be multiplexed and scaled ([cpu-pmu][cpu-pmu])                      |
| `perf record`            | where time goes, by stack                                             | a 2 ms process at 999 Hz yields ~2 samples — raise `-F` or aggregate many runs; skid; kernel stacks without symbols |
| `perf probe -x`          | a named user-space function boundary in any binary or library         | symbols that were stripped; and it perturbs (see the COW warning)                                                   |
| `LD_DEBUG=statistics`    | loader cycles and exact relocation counts                             | everything before `_dl_start`, all lazy binding after handoff, and — off x86 — the cycle lines entirely             |
| `strace -c`              | exact syscall counts and error tallies                                | work with no syscall (schema parse, `memcpy`, relocation); and its _times_ are inflated by a ptrace stop per call   |
| bcc / `bpftrace` uprobes | per-call latency histograms, arguments, stacks                        | it breaks COW at the probe site; it costs a trap per hit; bare library names resolve via `/etc/ld.so.cache`         |
| `/proc/PID/smaps_rollup` | PSS/USS/RSS and the anon/file/shmem split, in one page-table walk     | history — it is a snapshot; and it costs O(mapped pages) to read                                                    |
| cgroup v2                | isolation and a peak-memory watermark                                 | it isolates scheduling and accounting, not shared caches, TLBs, or SMT siblings                                     |

Six of those rows need their sharp edge spelled out.

**`hyperfine` corrects for the shell, and `-N` removes both.** The README is explicit: _"hyperfine always corrects for the shell spawning time. To do this, it performs a calibration procedure where it runs the shell with an empty command (multiple times), to measure the startup time of the shell"_, and `-N` exists because for _"very fast commands (< 5 ms) … the shell startup overhead correction would produce a significant amount of noise"_ ([README][hf-readme]). Every subject in this catalog is in that regime, so `-N` is right — and it means **any launcher you put in one arm's command line is measured, uncorrected**. That is the `env` asymmetry, exactly. Use `--export-json` to get per-run times; the other export formats carry summary statistics only ([`hyperfine.1`][hf-man]). Its outlier detection is a modified z-score against the median with a threshold of `1.4826 * 10.0` ([`outlier_detection.rs`][hf-outlier]) — it _warns_, it does not filter, and you should not filter either.

**`strace -c` counts are gold; its times are not.** Every traced syscall stops the tracee twice. Use it to establish _what happens_ — does this arm issue a `memfd_create`, how many `openat` calls does the loader make, how many are `ENOENT` — and never to establish _how long_.

**`perf record` on a millisecond-scale process is a sampling problem.** Either raise the frequency far above the default and accept the overhead, or aggregate hundreds of runs into one `perf.data` and read the aggregate. A profile of a single 2 ms start is noise wearing a flame graph's clothes.

**uprobe symbol availability is distribution-dependent.** `_dl_start` and `_dl_relocate_object` are the two useful placements on the loader path, and on the glibc 2.42 build on this machine both are present as **local** symbols in the static symbol table (`nm` shows them as `t`) and absent from the dynamic symbol table, which lists 38 entries. So `perf probe -x /path/to/ld-linux-x86-64.so.2 _dl_start` works — but only because the build was not stripped. Verify with `nm` before designing an experiment around a probe site, and fall back to `uprobe:binary:offset` ([bpftrace][bpftrace-lang]) when the symbol is gone.

**`bpftrace`'s bare-library resolution assumes a cache this repository's machines do not have.** The manual states that for libraries _"it is sufficient to specify the library name instead of a full path. The path will be then automatically resolved using `/etc/ld.so.cache`"_ ([`docs/language.md`][bpftrace-lang]). On NixOS there is no `/etc/ld.so.cache` — `RUNPATH` does all the work ([dynamic linking][ld]) — so `uprobe:libc:malloc` will not resolve and the full store path is mandatory. This is a five-minute trap that costs an hour.

**cgroup v2 gives isolation, not measurement.** The two levers worth using are `cpuset.cpus.partition` set to `isolated`, which puts the partition's CPUs _"in an isolated state without any load balancing from the scheduler and excluded from the unbound workqueues"_, and `memory.peak`, _"the max memory usage recorded for the cgroup and its descendants since either the creation of the cgroup or the most recent reset for that FD"_ ([cgroup v2][kdoc-cgroup]). `memory.peak` is a genuinely useful cross-check on E6: it is a kernel-side high-water mark that does not require sampling at the right moment. It is charged per cgroup and does not decompose per process, so it complements PSS rather than replacing it.

---

## Reproducibility checklist

Six items. Each one has changed a published result somewhere.

- [ ] **Pinned kernel, and the config bits that change the answer.** Record `uname -r`. For E6 specifically, record whether `CONFIG_PAGE_MAPCOUNT` or `CONFIG_NO_PAGE_MAPCOUNT` is set: under the latter the kernel uses `folio_average_page_mapcount()` and PSS becomes an **estimate** rather than an exact division ([`fs/proc/task_mmu.c`][task-mmu]). The same code notes that even the exact path takes _"a snapshot of the mapcount"_ that _"can be slightly wrong as we cannot always read the mapcount atomically."_ Also record `CONFIG_BINFMT_MISC` and the registered entry list for E1.
- [ ] **CPU governor pinned to `performance`, turbo declared.** The `performance` governor _"causes the highest frequency, within the `scaling_max_freq` policy limit, to be requested"_ ([cpufreq][kdoc-cpufreq]). Turbo is the second variable: on `intel_pstate`, `no_turbo` set to 1 means _"the driver is not allowed to set any turbo P-states"_ ([intel_pstate][kdoc-pstate]). Turbo on gives higher numbers and higher variance and is thermally history-dependent; turbo off gives lower, flatter, reproducible numbers. Either is defensible. Not saying which is not.
- [ ] **ASLR declared, with a reason.** `kernel.randomize_va_space` selects the mode: 0 off, 1 randomises _"mmap base, stack and VDSO"_ and — for PIE binaries — _"the location of code start"_, 2 adds heap randomisation ([sysctl/kernel][kdoc-sysctl]). It matters here twice over: it changes cache and TLB aliasing between runs (raising variance), and it changes where `ld.so` maps objects, which is exactly the layout `prelink` used to fix ([dynamic linking][ld]). Disabling it per-process with `setarch -R` reduces variance and makes address-keyed probes stable; leaving it on measures what production does. Run both if the effect is near the size of the difference you are claiming.
- [ ] **Page-cache state declared per arm.** Warm is the normal case and is what `hyperfine --warmup` produces; cold is the honest case for a first launch and needs `--prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches'` ([README][hf-readme]). The two answers can differ by more than the effect under test for a 41 MiB image. Never mix them across arms.
- [ ] **Environment pinned.** `execve` copies `argv` and `envp` into the new address space, so environment size is a real term in a sub-millisecond exec measurement. Use `env -i` plus an explicit minimal set, identically in every arm — and remember that the launcher used to do that is itself an exec unless it is present in both arms.
- [ ] **Report distributions, not means.** Publish min / p50 / p95 / max and `N`, and keep the raw sample (`hyperfine --export-json`, `perf stat --repeat --table`). A mean over a bimodal sample — which is what a page-cache miss on 1 run in 30 produces — describes nothing that happened. State the outlier count; do not delete the outliers.

> [!NOTE]
> Two further items apply only to the memory arm: no uprobes anywhere on the subject (see [the COW warning](#the-instrument-that-destroys-the-thing-it-measures)), and one `smaps_rollup` read per process at a barrier, never a polling loop.

---

## Strengths

- **The decisive experiment is cheap.** E6 needs `/proc`, arithmetic, and no privileges beyond reading your own processes. The catalog's sharpest open question can be closed in an afternoon, and the fact that it has not been is a statement about attention rather than difficulty.
- **The decomposition is entirely observable.** Every one of the eight startup stages has a named boundary in a kernel, glibc or SQLite source file, and every boundary has at least one instrument that can stand on it. Nothing here requires a custom kernel or a research tool.
- **Two of the confounds are removable by construction, not by correction.** The `env` asymmetry and the missing dispatch cost are both fixed by choosing arms that differ in exactly one thing, which is cheaper and more trustworthy than modelling the difference.
- **The size half is fully offline.** The amortization curve needs no timing, no isolation and no governor discipline, so it is reproducible on any machine and by anyone, including in CI.
- **The instruments document their own limits.** glibc's timer, `hyperfine`'s shell correction, the kernel's mapcount snapshot, `bpftrace`'s cache assumption — each caveat above is a quotation, not an inference, which means a reader can check the caveat as easily as the claim.

## Weaknesses

- **It prescribes and does not report.** Every experiment here is unexecuted. A protocol that has never been run has undiscovered defects, and the honest expectation is that the first execution finds two or three.
- **The subject is a moving target.** SELF at `e63f7c47` is a prototype with milestones outstanding; the shipped loader does not use the incremental-blob API its own design specifies, so E3's stage-7 term measures an implementation gap as much as a format property.
- **Sub-millisecond wall-clock measurement is genuinely hard**, and several instruments here perturb at the same order as the effect. The ladder mitigates this; it does not eliminate it.
- **`n`-family construction is fiddly.** Holding total bytes and symbol counts fixed while varying object count requires a synthetic corpus, and a synthetic corpus is not a userland — the slope it yields may not be the slope real packages exhibit.
- **The page-sharing arms are not fully parallel.** Arm (a) is demand-paged from a shared inode; arm (b) is fully resident before `main()`. They differ in _residency_ as well as in _sharing_, so PSS alone conflates two effects; the `Private_Dirty` and `Referenced` fields must be reported alongside, or the result overstates the sharing loss by attributing eager residency to it.
- **Nothing here addresses tail latency under memory pressure**, which is where the dirty-and-swap-backed property of copied segments should hurt most and where no instrument in the table looks.

---

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                    | Trade-off                                                                           |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Prescribe experiments; report no numbers                           | A catalog that invents figures is worse than one that quotes them; the line must be visible  | The page cannot settle any question by itself — it can only make settling one cheap |
| Arms that differ in exactly one thing, over statistical correction | Removes the `env` and dispatch confounds by construction rather than by modelling            | More arms to build and more builds to keep in sync                                  |
| PSS/USS from `smaps_rollup`, not `smaps`                           | One page-table walk instead of many; and the anon/file/shmem split exists only in the rollup | The rollup's field set is kernel-version dependent and has no schema                |
| Fit `PSS(N) = a + b/N` rather than compare two points              | The sharing signal is a _shape_; two points cannot distinguish it from a constant offset     | Needs six `N` values and a barrier protocol instead of one measurement              |
| Report a slope over object count, never a point                    | Loader cost is dominated by `n`, a packaging decision, not by the format under test          | A synthetic `n`-family may not match real distributions' fan-in                     |
| Counts before timings; external before invasive                    | `strace -c` and `LD_DEBUG` counts are exact and nearly free; uprobes are neither             | The cheap instruments answer "what" and never "how long"                            |
| No uprobes in the memory arm, at all                               | A uprobe breaks COW at its site, destroying exactly the sharing under test                   | The memory arm and the latency arm cannot share one instrumented build              |
| Same strip level across all size arms                              | The one caveat the headline size figure trips over                                           | Rules out the most flattering comparison, which is the point                        |

---

## Sources

- [`fzakaria/selfdb` `DESIGN.md` §9, "Honest evaluation plan"][design] — the four metrics, their methods, and the stated expectations, read at [`e63f7c47`][repo]
- [`bench/run.sh`][bench-run] and [`bench/big.sh`][bench-big-sh] — the harnesses whose launcher asymmetry and missing dispatch step E1 repairs
- [`loader/native.c`][native-c] — `map_segment`'s `MAP_PRIVATE | MAP_ANONYMOUS` plus `memcpy`, the code-level basis for E6's prediction
- [`nix/module.nix`][module-nix] — the 72-byte masked registration whose match cost E1 bounds
- [Farid Zakaria, "Your executable is a SQLite database" (2026-08-23)][post1] — the "~5 ms", the lost-sharing statement, and the 611.9 MiB / 5.53 GiB figures, all quoted here as **source claims**
- [Farid Zakaria, "Speeding up ELF relocations for store-based systems" (2024-05-03)][fz-reloc] — the `O(R + nr log s)` cost model that makes object count the controlling variable
- Linux `e43ffb69` (v7.1-rc6): [`fs/binfmt_misc.c`][binfmt-src] (the masked byte-loop matcher, `load_misc_binary`), [`fs/exec.c`][exec-src] (`exec_binprm`'s depth-bounded in-kernel rewrite loop), [`fs/proc/task_mmu.c`][task-mmu] (`smaps_account`, `pss /= mapcount`, the rollup field set), [`kernel/events/uprobes.c`][uprobes-c] (breakpoint installation breaks COW)
- [Kernel documentation — `filesystems/proc`][kdoc-proc] (the PSS definition, `smaps_rollup`'s extra fields and its cost) · [cgroup v2][kdoc-cgroup] (`cpuset.cpus.partition = isolated`, `memory.peak`) · [`cpufreq`][kdoc-cpufreq] · [`intel_pstate`][kdoc-pstate] (`no_turbo`) · [`sysctl/kernel`][kdoc-sysctl] (`randomize_va_space`)
- [`perf-stat(1)`][man-perf-stat] and [`tools/perf/Documentation/perf-stat.txt`][perf-stat-doc] (`--repeat`, `--table`, `--pre`) · [`tools/perf/Documentation/perf-probe.txt`][perf-probe-doc] (`-x/--exec` for user-space probes) · [`perf_event_open(2)`][man-peo] · [the perf wiki][perf-wiki]
- [`proc(5)`][man-proc] and [`proc_pid_smaps(5)`][man-smaps] · [`strace(1)`][man-strace] · [`ld.so(8)`][man-ldso] (`LD_DEBUG`)
- glibc `04e750e7`: [`elf/rtld.c`][rtld-c] (`print_statistics`, the relocation counters) and [`sysdeps/x86/hp-timing.h`][hp-timing] (the `rdtsc` accuracy disclaimer, `HP_TIMING_INLINE` gating)
- SQLite `8a988271`: [`src/btree.c`][btree-c] (`zDbHeader[100]`, the header read at open) and [`src/prepare.c`][prepare-c] (`sqlite3InitOne` re-parsing the schema DDL on first prepare)
- [`sharkdp/hyperfine`][hf-repo] `f12f3d9f`: [README][hf-readme] (shell-time calibration, `-N`, warmup and `--prepare`), [`doc/hyperfine.1`][hf-man] (`--export-json` carries per-run times), [`src/outlier_detection.rs`][hf-outlier] (modified z-score, threshold `1.4826 * 10.0`)
- [`iovisor/bcc`][bcc-repo] `6d0a964c`: [`docs/reference_guide.md`][bcc-ref] (`attach_uprobe`, PID scoping), [`tools/funclatency.py`][bcc-funclat] (per-function latency histograms over uprobes)
- [`bpftrace/bpftrace`][bpftrace-repo] `d052fff4`: [`docs/language.md`][bpftrace-lang] (uprobe variants including `binary:offset`, and the `/etc/ld.so.cache` resolution assumption)
- SQLite reference: [file format][sqlite-fileformat] · [`sqlite3_open_v2`][sqlite-open]
- In this repository: [benchmarking & profiling guidelines][bench-guide] · [the CPU-PMU survey][cpu-pmu] and [its `perf_event_open` page][cpu-pmu-linux]
- Runnable companions: [`self-selfdb/examples/relocation-join.d`](./self-selfdb/examples/relocation-join.d) (the probe count that scales with object count), [`sqlite-header-probe.d`](./self-selfdb/examples/sqlite-header-probe.d) (the 100-byte header the open path reads), [`binfmt-magic-match.d`](./self-selfdb/examples/binfmt-magic-match.d) (the kernel's masked registration predicate)
- Related in this tree: [SELF / selfdb][self] · [`binfmt_misc`][binfmt] · [dynamic linking][ld] · [content-addressed chunking][cas] · [Nix store closures][nix] · [image-based systems][image] · [range-request access][range] · [Cosmopolitan / APE][ape] · [code as a database][codedb] · [embedded provenance][prov] · [concepts][concepts] · [open questions][open] · [comparison][comparison]

<!-- References -->

[repo]: https://github.com/fzakaria/selfdb/tree/e63f7c470302f089a677ec87679a7df60b628547
[design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[bench-run]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/run.sh
[bench-big-sh]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/big.sh
[native-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/native.c
[module-nix]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/nix/module.nix
[server-readme]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/README.md
[post1]: https://fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database
[fz-reloc]: https://fzakaria.com/2024/05/03/speeding-up-elf-relocations-for-store-based-systems
[linux-repo]: https://github.com/torvalds/linux/tree/e43ffb69e0438cddd72aaa30898b4dc446f664f8
[binfmt-src]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/fs/binfmt_misc.c
[exec-src]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/fs/exec.c
[task-mmu]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/fs/proc/task_mmu.c
[uprobes-c]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/uprobes.c
[perf-stat-doc]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/Documentation/perf-stat.txt
[perf-probe-doc]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/Documentation/perf-probe.txt
[kdoc-proc]: https://docs.kernel.org/filesystems/proc.html
[kdoc-cgroup]: https://docs.kernel.org/admin-guide/cgroup-v2.html
[kdoc-cpufreq]: https://docs.kernel.org/admin-guide/pm/cpufreq.html
[kdoc-pstate]: https://docs.kernel.org/admin-guide/pm/intel_pstate.html
[kdoc-sysctl]: https://docs.kernel.org/admin-guide/sysctl/kernel.html
[man-peo]: https://man7.org/linux/man-pages/man2/perf_event_open.2.html
[man-proc]: https://man7.org/linux/man-pages/man5/proc.5.html
[man-smaps]: https://man7.org/linux/man-pages/man5/proc_pid_smaps.5.html
[man-strace]: https://man7.org/linux/man-pages/man1/strace.1.html
[man-ldso]: https://man7.org/linux/man-pages/man8/ld.so.8.html
[man-perf-stat]: https://man7.org/linux/man-pages/man1/perf-stat.1.html
[perf-wiki]: https://perf.wiki.kernel.org/index.php/Main_Page
[rtld-c]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/elf/rtld.c
[hp-timing]: https://github.com/bminor/glibc/blob/04e750e75b73957cf1c791535a3f4319534a52fc/sysdeps/x86/hp-timing.h
[btree-c]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/btree.c
[prepare-c]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/prepare.c
[sqlite-fileformat]: https://sqlite.org/fileformat2.html
[sqlite-open]: https://sqlite.org/c3ref/open.html
[hf-repo]: https://github.com/sharkdp/hyperfine/tree/f12f3d9f86f3643b3b7deace5e160b1f0f44d2b7
[hf-readme]: https://github.com/sharkdp/hyperfine/blob/f12f3d9f86f3643b3b7deace5e160b1f0f44d2b7/README.md
[hf-man]: https://github.com/sharkdp/hyperfine/blob/f12f3d9f86f3643b3b7deace5e160b1f0f44d2b7/doc/hyperfine.1
[hf-outlier]: https://github.com/sharkdp/hyperfine/blob/f12f3d9f86f3643b3b7deace5e160b1f0f44d2b7/src/outlier_detection.rs
[bcc-repo]: https://github.com/iovisor/bcc/tree/6d0a964c2cda4f8c61106a11c53d8eadd5a16097
[bcc-ref]: https://github.com/iovisor/bcc/blob/6d0a964c2cda4f8c61106a11c53d8eadd5a16097/docs/reference_guide.md
[bcc-funclat]: https://github.com/iovisor/bcc/blob/6d0a964c2cda4f8c61106a11c53d8eadd5a16097/tools/funclatency.py
[bpftrace-repo]: https://github.com/bpftrace/bpftrace/tree/d052fff44649305ddcb9c5e6d19f74c2e41e542f
[bpftrace-lang]: https://github.com/bpftrace/bpftrace/blob/d052fff44649305ddcb9c5e6d19f74c2e41e542f/docs/language.md
[bench-guide]: ../../guidelines/benchmarking-and-profiling.md
[cpu-pmu]: ../cpu-pmu/index.md
[cpu-pmu-linux]: ../cpu-pmu/linux-perf-events.md
[apppkg]: ../application-packaging/index.md
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[cas]: ./content-addressed-chunking.md
[nix]: ./nix-store-closures.md
[image]: ./image-based-systems.md
[range]: ./range-request-access.md
[codedb]: ./code-as-database.md
[prov]: ./embedded-provenance.md
[concepts]: ./concepts.md
[open]: ./open-questions.md
[comparison]: ./comparison.md
