# SELF / selfdb (Linux executable format · SQLite database)

An executable format in which the program **is** a SQLite database: the loadable image lives in a `segments` table, `strip(1)` is `DELETE` + `VACUUM`, `ldd(1)` is a view, and `binfmt_misc` dispatches on a four-byte `application_id` at file offset 68.

| Field           | Value                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Executable file format + `binfmt_misc` interpreter + converter/CLI + NixOS integration                                                    |
| Language        | Python (converter, on [LIEF][lief]), C (loaders, on `libsqlite3`), Nix (packaging, NixOS module, VM)                                      |
| License         | None declared — no `LICENSE` file at the surveyed commit                                                                                  |
| Repository      | [fzakaria/selfdb][repo]                                                                                                                   |
| Documentation   | [`DESIGN.md`][design] (the format spec) · [`schema/self.sql`][schema-sql] (the DDL) · the two announcement posts ([1][post1], [2][post2]) |
| First release   | First commit 2026-07-09; repository made public 2026-08-23                                                                                |
| Axis profile    | Multiplicity **1** / Reflexivity **3** / Closure **2** / Mutability **3**                                                                 |
| Index anchoring | **header** — SQLite's 100-byte header at offset 0, page 1 as the root of `sqlite_schema`                                                  |
| Dispatch owner  | **kernel** — `binfmt_misc` magic + mask, `CONFIG_BINFMT_MISC`                                                                             |

> **Latest revision surveyed:** [`e63f7c47`][repo] (2026-08-24, "Change to requests recorded"), 13 commits. **Platform:** Linux, x86-64 only; the `native` and `selfld` loaders are explicitly `EM_X86_64`-gated. **Status:** research prototype — milestones M0–M3b implemented, M4 (kernel loader, `mmap`) not started.

---

## Overview

### What it solves

ELF encodes a set of relations — segments, symbols, relocations, dependency edges — as offset-addressed byte structures, and then re-implements the database primitives those relations need by hand: `.dynstr` is string interning, `.gnu.hash` is an index (specifically a Bloom filter plus bucket chains), `st_name` is a foreign key expressed as an array offset, and the section header table is a table of tables. The consequence is that every consumer — the kernel, `ld.so`, binutils, [LIEF][lief], `goblin`, `pyelftools` — writes the same parser again, every producer writes the same serializer again, and any _mutation_ is offset surgery. That is the whole reason [`patchelf`][patchelf] exists: growing a string table means rewriting the file.

SELF takes the inversion seriously. Rather than putting a query layer _over_ ELF — which is what the author's earlier [sqlelf][sqlelf] did with virtual tables, and what the [binary inspection libraries][bin-inspect] do with object models — it makes the relations the format. A `.self` file is an ordinary SQLite database whose `application_id` is `0x53454C46`. The kernel is taught that magic; an interpreter reads the rows and runs the program.

What falls out is not one feature but a class of them, and they are the argument:

| Classic operation         | In SELF                                                       |
| ------------------------- | ------------------------------------------------------------- |
| `readelf -l`              | `SELECT type, vaddr, memsz, r, w, x FROM segments`            |
| `nm -D --undefined`       | `SELECT name, version FROM imports`                           |
| `ldd`                     | `SELECT soname FROM ldd` (a view over `needed`)               |
| `strip`                   | `DELETE FROM sections; DELETE FROM notes; VACUUM`             |
| `patchelf --set-rpath`    | `UPDATE dynamic_entries SET value = ? WHERE tag = 'RUNPATH'`  |
| `ldconfig` cache          | `CREATE INDEX idx_objects_soname ON objects(soname, machine)` |
| `LD_PRELOAD`              | a row in a `preload` table                                    |
| `.gnu.hash`               | `CREATE INDEX idx_symbols_name ON symbols(name, version)`     |
| diffing two builds        | [`sqldiff`][sqldiff]                                          |
| "what is taking up space" | `sqlite3_analyzer`                                            |

The last four rows are the ones that do not have an ELF analogue at all. A Bloom filter cannot be asked a question it was not shaped for; a b-tree index can.

### Design philosophy

The thesis is stated in the first sentence of `DESIGN.md` §1, and it is a claim about ELF rather than about SQLite ([`DESIGN.md`][design]):

> _"ELF is a hand-rolled, offset-addressed database from 1989 … Every ELF consumer (kernel, ld.so, binutils, LIEF, goblin, ...) re-implements the same parser over and over again, and every producer re-implements the same serializer, because the format's *data structures* are welded to its *encoding*."_

And the schema file states the consequence in one comment, next to the one index the format ships ([`schema/self.sql`][schema-sql]):

```sql
CREATE INDEX idx_symbols_name ON symbols(name, version);
-- ^ this index IS .gnu.hash.
```

The announcement post ([2026-08-23][post1]) frames the same point as a format-longevity argument rather than an ergonomics one:

> _"SQLite is the counter-example. They are a self-describing format that is extremely stable. It is designed to be extended to support new features without breaking existing consumers and supporting a wide range of queries performantly."_

That sentence is thesis 2 of this catalog — [self-description is what makes a format survivable][concepts] — asserted as the project's motivation. It is worth noticing what the design does _not_ claim: `DESIGN.md`'s non-goals are explicit that performance parity with ELF is out of scope ("we measure the gap honestly instead"), that kernel upstreaming is a stretch, and that the compiler and linker are untouched — SELF converts _post-link_ output, which is exactly why it can be demonstrated on unmodified nixpkgs.

Both posts are also unusually explicit about _why now_, which the catalog's [prior-art cluster][open-questions] asks about directly. The first post opens with it —

> _"I never let the idea go and with the recent improvements with LLMs, I find it compelling to revisit these ideas to explore further."_

— and the second closes with it:

> _"The code is at fzakaria/selfdb if you are curious. It is probably a bit half-baked, and definitely AI assisted, but that's OK with me."_

The claim being made is not that the idea is new (the author's PhD work and [sqlelf][sqlelf] predate it, and [IBM i and the single-level store][single-level-store] shipped the general idea commercially decades ago) but that _rewriting the toolchain_ — a converter, three loaders, an audit library, a NixOS module — went from prohibitive to a few weeks of evenings. That is a testable historical claim, and it is the most interesting thing in the posts that is not about bytes.

---

## How it works

### Conversion: `elf2self`

[`converter/selfconv/elf2self.py`][elf2self-py] parses a linked ELF with [LIEF][lief] and inserts it. The sequence is unremarkable and that is the point: `PRAGMA page_size = 4096`, the DDL from [`schema.py`][schema-py], `PRAGMA application_id = 0x53454C46`, `PRAGMA user_version = 1`, then one `INSERT` per program header, per `DT_NEEDED` entry, per dynamic tag, per symbol, per relocation, per section, per note — then `VACUUM`, then `chmod +x` if the source was executable.

Two details in the schema are load-bearing and are deviations from the original design sketch ([`DESIGN.md`][design] §13):

- `segments` keeps each program header's **original file `offset`**, not just its `vaddr`. The loaders reconstruct a byte-exact image so that offset↔vaddr congruence survives and the phdr table — which lives _inside_ the first load segment — lands where `AT_PHDR` says it does.
- `symbols` carries `source` (`'dynsym'` vs `'symtab'`) and `shndx`, so the `exports`/`imports` views can filter correctly, and `relocations` stores both a readable `type` and the raw `rtype` number, because [`selfld`][selfld-c] switches on the number and humans read the name.

The correctness anchor is a round-trip: `self2elf(elf2self(x))` must be a functionally equivalent ELF. [`converter/selfconv/self2elf.py`][self2elf-py] is a deliberate Python twin of the C serializer in [`loader/image.c`][image-c] so the two can be differentially tested.

### Identification: `application_id` at byte 68

SQLite reserves a four-byte big-endian integer at file offset 68 for exactly this purpose. The [file format documentation][sqlite-fileformat] is unambiguous about the intent:

> _"The 4-byte big-endian integer at offset 68 is an 'Application ID' that can be set by the `PRAGMA application_id` command in order to identify the database as belonging to or associated with a particular application. … The application ID can be used by utilities such as `file(1)` to determine the specific file type rather than just reporting 'SQLite3 Database'."_

SELF stamps it `'SELF'` = `0x53454C46`, so `file(1)` already reports the format without being taught anything, and `PRAGMA user_version = 1` carries the format version. [`examples/sqlite-header-probe.d`](./examples/sqlite-header-probe.d) walks the first 100 bytes of a SQLite header and reads both fields out, which is the whole of the identification story in about forty lines of D.

The shipped NixOS registration ([`nix/module.nix`][module-nix]) does not match the four bytes alone. It matches a **72-byte window from offset 0** with a mask that keeps bytes 0–15 (`SQLite format 3\0`) and bytes 68–71 (the `application_id`) and zeroes the 52 bytes in between:

```text
magic:  \x53\x51\x4c\x69\x74\x65\x20\x66\x6f\x72\x6d\x61\x74\x20\x33\x00  (16 bytes)
        \x00 × 52                                                          (don't-care)
        \x53\x45\x4c\x46                                                   ('SELF')
mask:   \xff × 16   \x00 × 52   \xff\xff\xff\xff
```

That fits comfortably: the kernel's matcher compares `bprm->buf + e->offset` against the magic under the mask, and `bprm->buf` is `BINPRM_BUF_SIZE = 256` bytes ([`include/uapi/linux/binfmts.h`][binprm-h], [`fs/binfmt_misc.c`][binfmt-src]). A 72-byte window at offset 0 uses under a third of the budget. [`examples/binfmt-magic-match.d`](./examples/binfmt-magic-match.d) implements the same masked comparison the kernel does, and running it against a real SQLite header is the cheapest possible check that a registration is correct before handing it to the kernel. See [`binfmt_misc`][binfmt-misc] for the dispatch mechanism in general.

> [!NOTE]
> A masked match is strictly stronger than the bare `SELF@68` the design sketch proposed: the mask makes an _ordinary_ SQLite database — `application_id` 0 — unmatchable, while still ignoring the page size, change counter and everything else that legitimately varies. The execute bit still gates everything, as it does for any `binfmt_misc` entry.

### Execution: three loaders behind one interpreter

`self-exec` is the registered interpreter ([`loader/self-exec.c`][self-exec-c]). It must itself remain an ELF file — an interpreter that also matched the registration would recurse straight to `-ELOOP`. It opens `argv[1]` read-only, verifies `application_id`, and dispatches on `$SELF_MODE`:

| Mode     | What it does                                                                                                                    | Source                 |
| -------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| `memfd`  | Re-serializes the ELF image **from the rows** into a `memfd_create` fd, then `execveat(fd, "", …, AT_EMPTY_PATH)`. The default. | [`image.c`][image-c]   |
| `native` | Maps the `segments` rows itself, maps `ld.so` itself, synthesizes the initial stack and auxv, jumps to `ld.so`'s entry.         | [`native.c`][native-c] |
| `selfld` | _Is_ the dynamic linker: maps a closure of `.self` objects, publishes their exports, binds eagerly by walking `relocations`.    | [`selfld.c`][selfld-c] |

`memfd` mode is the honest worst case and is deliberately not a smuggled blob: the ELF is rebuilt from `self_meta` + `segments` at every exec by the same code path `self2elf` uses. `native` mode is the interesting one, because it is the loader contract reproduced in userspace — reserve a hole with `PROT_NONE` for the PIE, map each load segment `MAP_PRIVATE|MAP_ANONYMOUS`, `memcpy` the blob in, `mprotect` to the final permissions, build the initial stack (`argc`, `argv`, `envp`, `auxv`) with `AT_PHDR`/`AT_BASE`/`AT_ENTRY`/`AT_RANDOM`/`AT_SYSINFO_EHDR`, then `mov %rsp` and `jmp`. `ld.so` never learns the program came from a database.

### Dynamic linking: two answers

**M3a — SQL resolution, glibc relocation.** `libself-audit.so` ([`loader/audit.c`][audit-c]) is an [`rtld-audit`][rtld-audit] library. glibc calls `la_objsearch()` for every soname before it touches the filesystem, `dlopen` included, so the audit library answers the search from a resolver database instead of walking `RUNPATH`:

```c
/* loader/audit.c — resolve() */
"SELECT path, kind FROM objects WHERE soname = ? LIMIT 1"
```

If the hit is a `.self` library it is materialized into a `memfd` by the _same_ row→ELF serializer, and `/proc/self/fd/N` is handed back to `ld.so`, which maps and relocates it normally. That is the pragmatic half: unmodified glibc, unmodified packages, lazy PLT, IFUNCs, TLS and symbol versioning all still work while library _storage_ is rows and library _lookup_ is SQL. [`tests/audit.sh`][test-audit] deletes the ELF `libgreet.so.1` from disk entirely and still runs the program.

**M3b — SQL binding.** [`selfld.c`][selfld-c] drops `ld.so` and does the binding itself:

```c
/* loader/selfld.c — relocate() */
"SELECT r.offset, r.rtype, r.addend, s.name"
" FROM relocations r LEFT JOIN symbols s ON r.symbol = s.id"
```

It handles `R_X86_64_RELATIVE`, `GLOB_DAT`, `JUMP_SLOT` and `64`, and dies on anything else. Its scope is a **freestanding, no-libc closure**: TLS, `IFUNC`/`R_X86_64_IRELATIVE`, symbol versioning in lookup order, and glibc's libc↔rtld handshake (`__libc_early_init`, `_rtld_global`) are all out of scope, exactly as `DESIGN.md` §5 anticipated they would have to be. This matters when reading the posts, because the most quotable demo in them runs _only_ here: `LD_PRELOAD`-as-a-table is a `preload` table read by `selfld`, and [`tests/preload.sh`][test-preload] builds its subjects with `cc -nostdlib`. The demo is real and the transaction is real; the closure it operates on is three freestanding objects, not a userland. See [dynamic linking][dyn-linking] for what the full contract contains, and [`examples/relocation-join.d`](./examples/relocation-join.d) for the same resolution expressed as a relational query — breadth-first scope order, first-wins interposition, an `LD_PRELOAD` object spliced in as one inserted tuple, and the SQL and Datalog spellings side by side.

---

## Format identity and multiplicity

**One byte stream, one parse.** This is the finding, and it is the opposite of [redbean/APE][ape].

A `.self` file admits exactly one grammar: SQLite's. There is no second parser, no suffix-parasitism, no header/footer negotiation. `file(1)` reports "SQLite 3.x database, application id 0x53454c46, user version 1" and it is right; `sqlite3` opens it and it is right; the kernel executes it and _that is not a second parse_ — `binfmt_misc` performs a masked memcmp over 72 bytes and then execs a different program entirely. Nothing ever parses the file as an executable, because the file is not one. Hence **Multiplicity = 1**: the executability is incidental to the format and entirely a property of a dispatch rule installed elsewhere.

That is the catalog's thesis 3 — [the container is a tax][concepts] — in its cleanest form, and the project says so in the `examples/server` README ([source][server-readme]):

> _"[redbean] reaches the same single-file place by stapling a ZIP onto an Actually Portable Executable and reading it back through a bespoke `zipos` layer. In SELF the container is already a database, so there is nothing to staple and nothing to parse: `SELECT body FROM routes WHERE path = ?` is the whole asset pipeline."_

The trade is stated in the next paragraph and is worth quoting because it is the honest half: redbean runs on six operating systems and two architectures; this runs on Linux, x86-64, and only where `binfmt_misc` has been taught the magic. Multiplicity buys reach at the format level; SELF declines to buy it and gets reach — if it gets any — from [the substrate instead][sqlite-vfs].

**Prefix and suffix tolerance.** SELF is neither prefix- nor suffix-tolerant in the [ZIP sense][zip-parasitism], and cannot be made so without leaving the format: a SQLite database begins at byte 0 and its size is `page_size × N` where `N` is the in-header page count at offset 28. Trailing bytes are a genuinely interesting edge case that the [page-sharing discussion](#the-lost-page-sharing) returns to, because it is where the only viable `mmap` fix lives.

**Where the identity is actually weak.** The `application_id`/`user_version` pair is supposed to be the discriminator — `DESIGN.md` §8 imagines a BPF matcher that "checks the SQLite magic _and_ `application_id` _and_ dispatches on `user_version` to versioned interpreters." At the surveyed commit it does not discriminate: [`closure.py`][closure-py] stamps the _same_ `application_id = 0x53454C46` and the _same_ `user_version = 1` onto a database with a **completely different schema** (`objects`/`needs`/namespaced `segments`, and no `self_meta` at all). A closure database therefore satisfies the kernel's magic test. It is saved in practice only by the execute bit, which `build_closure` never sets — and by `self_get_int`, which would fail to find `self_meta`, having ignored the return value of `sqlite3_prepare_v2` on the way ([`image.c`][image-c]). Two incompatible schemas sharing one format version is the kind of defect a schema is supposed to prevent, and it is fixable in one line; noting it is not a criticism of the prototype so much as evidence that _having_ a version field does not itself buy schema evolution.

---

## Index anchoring and random access

**Header-anchored, and then b-tree.** SQLite's [file format][sqlite-fileformat] puts a 100-byte header at offset 0 and makes page 1 the root of `sqlite_schema`, the table of tables. Everything else — every table, every index — is reached by descending a b-tree from a root page named in `sqlite_schema`. So the anchoring answer for this catalog's recurring sub-question is _header_, with the important qualification that the header names a **tree**, not a directory of extents. Compare [footer-indexed formats][footer-indexed], where the index is a contiguous region you seek to the end for; here you make `O(log n)` page reads instead of one seek plus one large read.

The practical consequences:

- **Partial reads are cheap and are the normal case.** `SELECT soname FROM ldd` touches the header page, a schema page, and the one or two pages holding `needed` — a few 4 KiB reads out of a 50 KiB or 96 MiB file alike. `sqlite3_analyzer`, `sqldiff`, and `.schema` all work the same way. This is what makes the format's tooling story real rather than aspirational: none of it needs to read the segment blobs.
- **The blobs are the expensive part and they are addressable.** `sqlite3_blob_open`/[`sqlite3_blob_read`][blob-open] can read a byte range out of a single BLOB without materializing the row, which is exactly what a loader wants. `DESIGN.md` §5 planned to use it ("the incremental-blob API — no full-row allocation"). The shipped `native.c` does **not**: it calls `sqlite3_column_blob`, `malloc`s the length, and `memcpy`s, then `memcpy`s again into the mapping. Every load segment is therefore materialized twice in full before the program starts. That is an implementation gap, not a format one, and closing it removes one whole copy.
- **Ranged remote access is nearly free by construction.** Because SQLite is page-oriented and its access layer is [a swappable VFS][sqlite-vfs], a `.self` file is queryable over HTTP range requests with no format work at all — the [`sql.js-httpvfs` pattern][range-request]. "`SELECT` a remote executable's symbol table without downloading the executable" is a small experiment, not a research programme, and it is the sharpest available demonstration of this catalog's thesis 5. It is untested here; nothing in the repository attempts it.

### The `~5 ms` constant, and what it is made of

The first post states the latency model in one sentence:

> _"There is a fixed ~5 ms to open SQLite and start the interpreter, plus a copy proportional to the image."_

The repository carries two harnesses, and they do not agree on the constant. [`bench/results.md`][bench-results] (host `Linux 7.0.10`, `hyperfine -N --warmup 30 --min-runs 300`) and [`bench/big.md`][bench-big] (host `Linux 7.1.2`, `--warmup 10 --min-runs 60`) give:

| Subject | libs | ELF size | SELF size |       ELF | `memfd` (M1) | `native` (M2) | Δ `memfd` | Harness            |
| ------- | ---: | -------: | --------: | --------: | -----------: | ------------: | --------: | ------------------ |
| `hello` |    2 |   15 KiB |    56 KiB |  0.422 ms |     2.116 ms |      2.168 ms |  +1.69 ms | `bench/results.md` |
| `noop`  |    2 |        — |         — |  0.398 ms |     2.116 ms |      2.157 ms |  +1.72 ms | `bench/results.md` |
| `hello` |    2 |   15 KiB |    56 KiB |  1.401 ms |     6.836 ms |      6.915 ms |  +5.44 ms | `bench/big.md`     |
| `curl`  |   27 |  274 KiB |   684 KiB | 11.069 ms |    18.751 ms |     15.170 ms |  +7.68 ms | `bench/big.md`     |
| `git`   |    5 | 4642 KiB | 10028 KiB |  3.000 ms |    32.714 ms |     20.821 ms | +29.71 ms | `bench/big.md`     |
| `gdb`   |   47 |   41 MiB |    94 MiB | 86.109 ms |   196.525 ms |    156.414 ms | +110.4 ms | `bench/big.md`     |

So "~5 ms" is the `hello` delta on one of the two hosts; on the other it is 1.7 ms. The constant is a property of the machine, not of the format, and the honest statement of the model is "a fixed cost of order milliseconds, plus a copy that dominates above roughly a megabyte of image."

The sources do **not** decompose the constant. Reading the code, it must contain at least:

1. `binfmt_misc` dispatch and a second `execve` of the interpreter (`fs/binfmt_misc.c`);
2. `self-exec`'s own dynamic link — it is an ordinary ELF against `libsqlite3`, so a whole `ld.so` run happens before any SELF work starts;
3. `sqlite3_open_v2` plus `PRAGMA application_id` plus schema parse;
4. the `segments` scan, the `malloc`/`memcpy` per blob, and the second `memcpy` into the mapping;
5. in `memfd` mode only: `memfd_create`, a `write` of the whole image, and a **third** `execve`.

Item 2 is invisible in the sources and is likely a large fraction of the constant: the post's own footnote observes that `curl` (274 KiB, 27 libraries) starts slower than `git` (4.6 MiB, 5 libraries) because `ld.so` does work proportional to the _number of objects_, and `self-exec` adds one more object graph to link before it starts.

> [!WARNING]
> **Both harnesses contain a measurement confound that inflates the SELF side.** In [`bench/run.sh`][bench-run] and [`bench/big.sh`][bench-big-sh] the ELF baseline is timed as `hyperfine -N "$work/$subj"`, while every SELF row is timed as `hyperfine -N "env SELF_MODE=memfd $SELF_EXEC …"`. Under `-N` there is no shell, so `env` is a real `execve` that the ELF row does not pay — on the order of the `noop` ELF baseline itself (0.398 ms / 1.4 ms on the two hosts), i.e. roughly a quarter of the reported `hello` delta. Separately, the SELF rows invoke `self-exec` **directly**, so the numbers do not include `binfmt_misc` dispatch at all: they measure the interpreter, not the registered path.

Confirming the model therefore needs a different experiment, not a rerun: `perf` or a uprobe on `load_misc_binary`, `sqlite3_open_v2` and `self_build_elf`; an `env`-prefixed ELF baseline so both arms pay the same launcher; a statically linked `self-exec` to isolate item 2; and PSS/USS sampling across `N` concurrent processes to quantify the sharing loss directly. The methodology belongs to [the measurement page][measurement], which owns it; this page's contribution is the confound above and the observation that the two in-repo harnesses disagree by 3×.

---

## Reflexivity and query surface

This is the axis SELF maxes out, and it is why it anchors the catalog alongside APE. **Reflexivity = 3.**

**Anyone can ask, in SQL, with no special tool.** `sqlite3 hello '.schema'`, `sqlite3 hello 'SELECT name FROM exports'`, Datasette, any language binding, `sqldiff`, `.recover`. The `docs` table shipped inside every converted binary makes the file literally self-explaining — [`elf2self.py`][elf2self-py] inserts a row telling the reader to run `.tables` and `.schema` and pointing at the repository. Views (`exports`, `imports`, `ldd`) travel in the file too, so the vocabulary is part of the artifact rather than part of a tool that must be installed alongside it. That is thesis 2 made operational: the schema is the spec.

**Transitive questions are where SQL starts to hurt.** The queries that matter most for a linker are reachability queries — dependency closure, symbol resolution order, "which library will actually satisfy this symbol given scope order". SQLite has recursive CTEs and they work, but they are ergonomically hostile compared to a language where transitive closure is the default mode of expression. The project sidesteps this rather than solving it: `self closure` **pre-resolves** every edge at pack time and stores `needs.resolved_path` as a foreign key, so the query at run time is a join and not a fixpoint. That is a good engineering answer and it is also an admission — see [code as a database][code-as-db] for the Datalog-shaped alternative (CodeQL, Glean, `ddisasm`) that expresses these natively.

**Self-inspection while running is the second post's whole subject.** `self-httpd` opens `argv[0]` and serves out of its own tables, including tables the loader also reads:

> _"The page at https://selfdb.exe.xyz shows a lot of fun additional information besides the visitor log and button presses. I included `segments`, `symbols` and `relocations`. Those are not baked in at built time, they are queried from itself while running."_

The `/api/tables` endpoint is described in the example README as `sqlite_schema` with live row counts — "`readelf -S`", except the program is answering about itself, at runtime, over HTTP. That closes the loop the catalog is about: the artifact is not merely queryable by external tools, it interrogates itself while executing. See [relational system surfaces][relational-surfaces] for the same move applied to an operating system rather than a file.

### The `argv[0]` problem

A running program can only query itself if it can find its own file, and under `binfmt_misc` that is genuinely hard. When a `binfmt_misc` entry matches, the kernel does not `execve` the matched file at all — it execs the _interpreter_ and demotes the file to an argument. In [`fs/binfmt_misc.c`][binfmt-src], `load_misc_binary` calls `remove_arg_zero()` (unless the `P` flag is set), then pushes the binary path as `argv[1]` and the interpreter path as `argv[0]`:

```c
/* fs/binfmt_misc.c — load_misc_binary() */
if (fmt->flags & MISC_FMT_PRESERVE_ARGV0) {
        bprm->interp_flags |= BINPRM_FLAGS_PRESERVE_ARGV0;
} else {
        retval = remove_arg_zero(bprm);
        ...
}
/* make argv[1] be the path to the binary */
retval = copy_string_kernel(bprm->interp, bprm);
```

`self-exec` then passes `argv + 1` through, so the target program's `argv[0]` is the `.self` path — and `sqlite3_open(argv[0])` works. `/proc/self/exe` does not: it names `self-exec` in `native` mode and an anonymous `memfd` in `memfd` mode. The example's own header comment states this precisely ([`server.c`][server-c]), and the second post makes it the section title: _"All you need is `argv[0]`"_.

Two further details make the trick work and are easy to miss:

- **`self-exec` closes its SQLite connection before jumping**, so nothing holds the file open when `main()` runs — no `ETXTBSY`, no lock contention. In `memfd` mode the kernel never `execve`d the database at all, so the executed image and the queried file are different objects.
- **The `P` flag is deliberately not used.** `DESIGN.md` proposed `O`+`F`+`P`; the shipped module sets none of them, because `P` (preserve-`argv[0]`) makes the kernel inject the original `argv[0]` as an extra leading operand that strict programs — GNU `hello` is the cited casualty — reject. Without it, `basename(argv[0])` still satisfies multi-call binaries like coreutils.

> [!NOTE]
> This is the fragile part of the design and it is known to be. `argv[0]` is advisory: anything that `exec`s the program with a different `argv[0]` breaks self-access, and the format has no fallback. The kernel-side fix is in flight rather than shipped — Christian Brauner's transparent-`binfmt_misc` work adds dispatch modes that keep `/proc/self/exe` pointing at the original file, including a loader-substitution mode where `binfmt_misc` becomes a plain `PT_INTERP` override ([fzakaria's write-up][post3]). At the revision of Linux surveyed here — `torvalds/linux` [`e43ffb69`][binfmt-src], v7.1-rc6 — `fs/binfmt_misc.c` still carries only the four historical flags (`MISC_FMT_PRESERVE_ARGV0`, `OPEN_BINARY`, `CREDENTIALS`, `OPEN_FILE`) and no BPF matcher, so none of that is available yet.

---

## Closure, dedup, and size model

**Closure = 2.** A single `.self` executable does _not_ carry its dependencies — libraries stay separate objects, resolved at run time through `system.db` or through `ld.so`. But `self closure` ([`converter/selfconv/closure.py`][closure-py]) is a first-class command that packs a root and its transitive closure into one database, so closure is designed-in and opt-in rather than defining.

The interesting design decision is _what the edge stores_. `ldd` output names sonames, which on NixOS are ambiguous — many store paths provide `libc.so.6`. `closure.py` runs `ldd` **per object**, so each edge keeps the resolution that object's own `RUNPATH` produced:

```sql
CREATE TABLE needs (
  object_id     INTEGER NOT NULL REFERENCES objects(id),
  ord           INTEGER NOT NULL,
  soname        TEXT NOT NULL,
  resolved_path TEXT REFERENCES objects(path)   -- the FK that kills ambiguity
);
```

The module's docstring is explicit that a shared soname→path map was the bug this table exists to remove: two roots in one database can each need `libc.so.6` and mean different store paths. Dedup then falls out of `objects.path UNIQUE` — a library needed by fifty roots is one row — which is the same identity model [Nix store closures][nix-closures] use, and has the same granularity: **dedup is by store path, not by content**. The post's own query shows 345 distinct sonames across 399 library rows, with `libc.so.6`, `libsystemd.so.0`, `libpthread.so.0` and `libgcc_s.so.1` each appearing three times. Content-level dedup — [chunking or content addressing][chunking] — would go further and is not attempted.

### The numbers

| Subject                                     |           ELF |   SELF (full) | SELF (stripped) | Ratio (stripped)      |
| ------------------------------------------- | ------------: | ------------: | --------------: | --------------------- |
| `hello`                                     |      15,856 B |      57,344 B |        49,152 B | 3.10×                 |
| `coreutils` (`ls`)                          |   1,768,632 B |   3,887,104 B |     1,794,048 B | **1.014×**            |
| `ls` + its 5 libraries (`self closure`)     |             — |       4.8 MiB |               — | one file, 6 objects   |
| 723 executables + 400 libraries (userland)  | **644.4 MiB** | **611.9 MiB** |               — | **0.95×**             |
| the same 723, AppImage-style private copies |             — |  **5.53 GiB** |               — | 9.0× the SELF closure |

The single-binary overhead is roughly 2–3.5×, and it is mostly recoverable because it is mostly the optional tables: `strip` — that is, `DELETE FROM sections; DELETE FROM notes; DELETE FROM symbols WHERE source='symtab'; VACUUM` — brings `coreutils` to within 1% of its ELF. The userland number is the headline: 1,123 objects, 346,386 symbols, 3,808 dependency edges in one file that is _smaller_ than the ELF files it came from, and about 6% over the raw program bytes.

> [!IMPORTANT]
> **The 611.9 vs 644.4 MiB comparison is not like-for-like, and the difference explains the sign.** `CLOSURE_SCHEMA` in [`closure.py`][closure-py] has exactly four tables — `objects`, `needs`, `segments`, `symbols` — and `symbols` is populated only from `b.dynamic_symbols`. There is no `sections` table, no `notes` table, and no `symtab` rows at all. A closure database is therefore _structurally stripped_, while the 644.4 MiB of ELF files on the other side of the comparison still carry their section headers, static symbol tables and any retained debug sections. The correct reading of the number is "b-tree overhead amortises to ~6% across 1,123 objects", which is the claim the post actually makes and which the per-object stripped ratios independently support. The "smaller than the files it came from" framing compares a stripped database against unstripped inputs and should not be quoted without that caveat.

The 5.53 GiB figure is the same trade-off Nix, Flatpak, static linking and [AppImage][app-packaging] each resolve differently, expressed in one table: if every root ships its own private closure you pay 9× for self-containment. SELF's schema gets the sharing for free because the store _is_ relational — but only within one database file. Across two `self closure` outputs there is no sharing at all, which is precisely the boundary [Nix's store][nix-closures] moves one level up.

> [!NOTE]
> A closure database is queryable but **not executable**: it has no `self_meta` and its `segments` are namespaced by `object_id`, so no shipped loader can run it. "One file, one userland" is a _store_, in the Nix sense, not a fat binary. `DESIGN.md` §7 considered making the store the unit and rejected it as fighting Nix's per-path immutability "for no demo value".

A store also needs a garbage collector, and this one does not have one. The roots are the `is_root = 1` rows; a mark-and-sweep over `needs` is a recursive CTE plus `DELETE` plus `VACUUM`. What a _concurrent_ GC looks like against a database somebody is executing out of is genuinely open — `VACUUM` rewrites the file, and the loader is reading blobs out of it. See [open questions][open-questions].

---

## Mutability, dispatch, and trust

**Mutability = 3**, and unusually it is mutability of _both_ kinds: the artifact is modified by tooling as a transaction, and it is written to by the program that is executing from it.

**Tooling mutation.** `strip` is `DELETE` + `VACUUM`; `patchelf` is `UPDATE`; adding a signature would be an `INSERT`. All of these are atomic and crash-safe, which is not a marginal improvement over the ELF equivalents — it is the removal of an entire failure mode. `patchelf`'s reason to exist (growing a string table means rewriting the file) is a non-problem when the string is a `TEXT` column.

**Self-mutation.** `self-httpd` ([`examples/server/server.c`][server-c]) opens `argv[0]` and `INSERT`s a `visits` row on every request, into the same file its own text was loaded from. The example README records the artifact growing from 155,648 to 200,704 bytes over a few thousand requests. Editing the live site is an `UPDATE`; rolling it back is a `ROLLBACK`; a deploy's diff is auditable with [`sqldiff --summary`][sqldiff]:

```text
routes:      1 changes, 0 inserts, 0 deletes, 2 unchanged
segments:    0 changes, 0 inserts, 0 deletes, 13 unchanged
symbols:     0 changes, 0 inserts, 0 deletes, 174 unchanged
relocations: 0 changes, 0 inserts, 0 deletes, 99 unchanged
```

That is a deploy audit log with no infrastructure behind it, and it says something the ELF world cannot say without a build system: _this deploy touched the website and not the program._ A redeploy is likewise two `INSERT ... SELECT` statements over an `ATTACH`ed old artifact ([`deploy.sh`][deploy-sh]) — the visitor log survives the new build because the program and its data are the same file. [Image-based systems][image-based] — Smalltalk, Lisp images, Emacs `pdumper` — are the tradition this belongs to; the novelty is that the image is also a _queryable_ store rather than a heap dump.

The measured cost is small and is entirely the durable write ([`examples/server/README.md`][server-readme], `bench.py`, 300 requests/path):

| What                                                   |    mean |     p50 |
| ------------------------------------------------------ | ------: | ------: |
| the same accept/respond loop with the body compiled in | 0.40 ms | 0.38 ms |
| `GET /` served from the b-tree, no visit logged        | 0.40 ms | 0.37 ms |
| `GET /` as deployed — `--journal wal`, one `INSERT`    | 0.54 ms | 0.49 ms |
| `GET /` with `--journal delete`, one `INSERT`          | 1.48 ms | 1.42 ms |

Reading out of the b-tree is free — sixteen queries do not clear the noise floor of the process model. The 8× spread between the journal modes is the price of the _single-file property while serving_: a rollback journal creates, syncs and unlinks `server-journal` per commit and leaves one file on disk; WAL is ~3× faster end to end but puts `server-wal` and `server-shm` next to the executable for as long as a connection is open. The example makes it a flag rather than picking, and asserts both halves in `tests/server.sh`. That is a nice, small illustration of the catalog's general point that the "one file" property is a property of the _access layer_, not the format.

### The lost page sharing

This is the sharpest open problem in the catalog and the one that decides whether SELF is a format or a demonstration. The post states it plainly:

> _"That copy is worse than it looks, because the b-tree pages are not mapped into memory. Two processes running the same SELF binary do not share text pages the way a normally-mmap'd ELF does, because the bytes are copied out of the b-tree rather than mapped."_

Reading [`native.c`][native-c] makes it worse than the post says. `map_segment` maps `MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED` and then `memcpy`s the blob in:

```c
/* loader/native.c — map_segment() */
void *p = mmap((void *)start, end - start, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
if (filesz && src)
        memcpy((void *)(load_bias + vaddr), src, filesz);
if (mprotect((void *)start, end - start, prot) != 0) ...
```

Three things follow, and only the first is in the sources:

1. **No cross-process sharing.** Anonymous private pages are per-process by construction. `N` copies of `gdb` cost `N × 41 MiB` of text instead of one.
2. **No demand paging.** The `memcpy` touches every byte of every load segment before `main()` runs, so the entire `filesz` is resident and dirty even if the program touches 2 MiB of it. A normally-mapped ELF faults in only what it executes. This is a strictly larger effect than (1) for large, sparsely-used binaries, and it is invisible in the wall-clock benchmarks because it shows up as RSS, not latency.
3. **The pages are dirty, so they are swap-backed, not file-backed.** Under memory pressure a normal executable's clean text is simply dropped and re-read; SELF's must be written to swap.

`memfd` mode differs in shape but not in outcome: each process creates its own `memfd`, writes the whole image into it, and `execveat`s it, so the kernel _does_ map the resulting image file-backed and demand-paged — but the file is private to the process. `DESIGN.md` §5 notes that the memfd cache could be keyed by `build_id`; nothing does it.

#### The three candidate fixes, against what SQLite actually guarantees

The catalog's framing is that all three candidates are VFS-shaped, and that this is good news because [the VFS is a well-exercised seam][sqlite-vfs]. Checked against the [file format][sqlite-fileformat], only one of them is, and it is not the one that sounds most natural.

**(a) Page-aligned BLOBs plus a custom VFS mapping blob extents.** This does not work, and the reason is structural rather than incidental. When a cell's payload exceeds the b-tree page's capacity the surplus spills onto a linked list of overflow pages, and the format specifies that _"the first four bytes of each overflow page are a big-endian integer which is the page number of the next page in the chain … The fifth byte through the last usable byte are used to hold overflow content."_ A multi-megabyte segment blob is therefore delivered as runs of `usable_size − 4` bytes at file offsets congruent to 4 modulo the page size — never contiguous, never page-aligned, at any page size (the 4-byte link is a fixed cost per page, so raising `page_size` to the 65,536-byte maximum leaves the payload misaligned by the same 4 bytes). Crucially, **the overflow chain is constructed above the VFS**: the pager hands `xWrite` a complete page image, link pointer included, so a custom VFS can relocate whole pages but cannot remove the four bytes at the front of each one. `DESIGN.md` §8 reaches the same conclusion from the other direction ("content is contiguous but _off by 4 per page_, killing direct mmap"). The seam the outline hopes for is one layer too low.

**(b) Segments in SQLite's reserved region.** This one is smaller than it sounds. The "reserved space" is _"the number of bytes of space at the end of each page to reserve for extensions"_, recorded in **a 1-byte integer at offset 20** — so at most 255 bytes, and it is a per-page _tail_, not a contiguous region. (The format additionally forbids usable size below 480 bytes.) It was designed to hold a nonce or checksum per page for the encryption extension. It cannot hold a text segment: 255 bytes every 4 KiB is 6% of the file, scattered, and still not page-aligned. This candidate should be struck.

**(c) A loader that maps the file and lets SQLite own only the metadata pages.** This is the only one the format permits, and the format documentation resolves the uncertainty `DESIGN.md` §8 left open. A modern SQLite database's size is the in-header page count at **offset 28**, and the documentation is explicit that it is authoritative when valid: _"The 4-byte big-endian integer at offset 28 into the header stores the size of the database file in pages. If this in-header datasize size is not valid … then the database size is computed by looking at the actual size of the database file,"_ with validity meaning the change counter at offset 24 matches the version-valid-for number at offset 92 — _"always valid when the database is only modified using recent versions of SQLite, versions 3.7.0 (2010-07-21) and later."_ So a `.self` file may be a database followed by a page-aligned trailer holding the segment bytes, with `segments` carrying a `content_offset` into it instead of a BLOB; SQLite reads the database, and the loader `mmap`s the trailer `MAP_PRIVATE|PROT_READ|PROT_EXEC` straight off the file. Demand paging and cross-process sharing both come back, and no VFS is needed at all.

The cost is precisely the property the format is selling. A trailer is invisible to SQLite, so:

- **`VACUUM` destroys it.** `VACUUM` rebuilds the database into a fresh file and copies it back; the trailer is not part of the database and does not survive. The format's headline demo — `strip` is `DELETE` + `VACUUM` — becomes the operation that unloads the program.
- The [backup API][sqlite-backup], `.recover`, `.dump`/reload, and any tool that round-trips the database page-by-page have the same problem.
- `sqldiff` would compare metadata only, so the deploy-audit property degrades from "the program did not change" to "the metadata about the program did not change".

The general shape of the answer, then, is that **`mmap` and `VACUUM` are in direct opposition**, and the format has to choose which of its two headline properties is load-bearing. A hybrid is conceivable — keep the blobs in the b-tree as the canonical representation and treat the trailer as a _cache_, rebuilt by a `self mmapify` step and invalidated by any write, in the manner of `prelink` — which is a materialized view, with all the invalidation problems that implies. Nobody has built it. This is the concrete content behind the catalog's thesis 4, [`mmap` is the load-bearing constraint][concepts], and it is a genuine counterweight to thesis 5: portability may have migrated to the access layer, but _this_ problem lives below the access layer, where swapping the VFS does not reach.

### W^X, signing, and the threat model

**W^X holds inside the loader.** `map_segment` maps `PROT_READ|PROT_WRITE`, copies, then `mprotect`s to the final permissions — there is no window in which a page is simultaneously writable and executable. That is better than it had to be, and `DESIGN.md` §5 claims it deliberately.

**W^X does not hold for the artifact.** The text of a `self-httpd` process lives in rows of a file the process holds open read-write, and `sqlite3_open(argv[0])` gives it full DDL and DML rights over `segments` — the second post says so cheerfully ("You can even do this for the program itself in reverse. The `segments` table is just like any other table 😈"). redbean makes the equivalent capability an explicit opt-in behind the `-*` flag for exactly this reason; SELF has no such gate, because the file has to be writable for the state story to work at all. The least-privilege decomposition the catalog asks for — a read-only handle to the loader tables and a writable handle to the state tables, enforced below the application — is not available: one SQLite connection is one connection, and the enforcement would have to come from `seccomp`, [Landlock][threat-model], or a schema-aware authorizer callback. `sqlite3_set_authorizer` is the obvious in-process lever and is unused here.

**Signing is unsolved and the format makes it harder, not easier.** Any byte-hash attestation is invalidated by a no-op `VACUUM`, and `self-httpd` commits on every request, so the artifact's bytes are never stable. `DESIGN.md` §12 lists the intended shape — minisign over a canonical serialization (`SELECT … ORDER BY`) — and calls "signing rows, not bytes" a genuinely novel-feeling win, which is another way of saying nobody has built it. The design that suggests itself is per-table Merkle roots over a canonical row encoding, with the signature covering only the immutable tables; that also fits `fs-verity`'s and IMA's requirement of an immutable measured file about as badly as possible, since the measured object would have to be a _subset_ of the file. See [embedded provenance][provenance] and [the threat model page][threat-model]. What SELF _does_ carry is the one identity ELF already had: `elf2self` copies `NT_GNU_BUILD_ID` into `self_meta.build_id` and into a `notes` row, and `DESIGN.md` §5 proposes keying the `memfd` cache on it — so the pre-existing provenance channel survives the format change unchanged ([`examples/elf-note-buildid.d`](./examples/elf-note-buildid.d) reads it out of a live process's own image).

**`binfmt_misc` registration is itself a privilege surface.** Registering a format means naming an interpreter that the kernel will run for any matching file; the entry is written to `/proc/sys/fs/binfmt_misc/register` by root and the shipped deployment does exactly that via `/etc/binfmt.d/self.conf` ([`deploy.sh`][deploy-sh]). SELF also declares setuid `.self` binaries out of scope, because the `C` (credentials) flag's semantics are subtle — a correct call, and one that quietly removes a large class of programs from the format's reach. [`binfmt_misc`][binfmt-misc] covers the general surface.

---

## Strengths

- **The tooling story is not a promise, it is inherited.** `sqlite3`, `sqldiff`, `sqlite3_analyzer`, `.recover`, FTS5, Datasette, and every language binding work on day one because the file is a SQLite database. The second post's observation is exactly right: _"None of that is machinery I wrote. It is machinery SQLite already has, that a program inherits for free by being a database."_
- **Mutation becomes atomic and crash-safe.** `strip`, `patchelf`, adding a table — transactions, not offset surgery. This removes a real class of bugs, not just a class of inconvenience.
- **The size overhead amortises to near zero at userland scale.** ~2–3.5× on one small binary; ~6% over program bytes across 1,123 objects; 9× better than a private-closure-per-root model.
- **Resolution as a foreign key.** `needs.resolved_path` eliminates soname ambiguity by construction inside a closure — the same guarantee Nix provides, expressed as a schema constraint rather than as `RUNPATH` discipline.
- **Interposition and lookup become data.** `LD_PRELOAD` as a `preload` table and `ldconfig` as an index are the clearest demonstrations that "linker policy" was always a database question wearing environment-variable clothes.
- **Round-trip fidelity is the CI anchor.** `self2elf(elf2self(x))` must be functionally equivalent, with a Python twin of the C serializer to make the differential test cheap.
- **The prototype is complete enough to falsify itself.** Three loaders, an audit library that runs real glibc programs with no ELF library on disk, a NixOS module, a VM, a benchmark harness that reports numbers unflattering to the format, and a public deployment. Very few format proposals get this far.

## Weaknesses

- **No page sharing and no demand paging.** The decisive cost. Segment bytes are `memcpy`'d into anonymous private mappings, so `N` processes cost `N ×` the image in dirty, swap-backed pages. See [the analysis above](#the-lost-page-sharing); the one viable fix collides with `VACUUM`.
- **`argv[0]` is the self-access channel and it is advisory.** `/proc/self/exe` names the interpreter or a `memfd`. The kernel work that would fix this is not in mainline at v7.1-rc6.
- **Linux, x86-64, `binfmt_misc`-only.** `native.c` and `selfld.c` both hard-fail on `em != EM_X86_64`. Compared with [APE][ape]'s six operating systems this is not a portability story at all — it is a bet that the _substrate_ travels instead.
- **`self-ld` does not run real programs.** M3b is freestanding and no-libc: no TLS, no `IFUNC`, no versioning-aware lookup, no `dlopen`. The `LD_PRELOAD`-as-a-transaction demo runs only in that mode. The half that works on real glibc packages (M3a) keeps `ld.so` and therefore keeps ELF as the in-memory representation.
- **Two schemas share one `application_id` and one `user_version`.** A `self closure` database matches the kernel's magic and carries no `self_meta`; the version field that was supposed to discriminate does not.
- **The shipped loader ignores the incremental-blob API** that the design specified, materializing each segment twice.
- **The benchmark harness has a launcher asymmetry** that inflates the SELF arm and omits `binfmt_misc` dispatch entirely.
- **No signing, no GC, no `setuid`, no concurrency story for a database being executed from.** Each is named as an open question rather than answered.
- **No `LICENSE` file** at the surveyed commit, which is a real obstacle to anyone wanting to build on it.
- **Transitive queries are the ones you most want and the ones SQL serves worst.** Pre-resolving at pack time is a workaround, not an answer.

---

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                                              | Trade-off                                                                                                               |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| The database **is** the container (no ZIP, no archive layer)         | Removes the container tax entirely; one parse, one library, tooling for free                                           | Zero format multiplicity — reach depends wholly on `binfmt_misc` being registered on the target host                    |
| `application_id` at offset 68 + a masked 72-byte `binfmt_misc` magic | Uses a field SQLite reserved for exactly this; ordinary databases can never match; `file(1)` identifies it unaided     | Requires root to register; the kernel is now the dispatcher for a file it cannot itself load                            |
| Segment bytes as BLOBs in the b-tree                                 | One representation, `VACUUM`-able, `sqldiff`-able, round-trippable; strip becomes a transaction                        | **No `mmap`, no sharing, no demand paging** — the format's central cost, and structurally unfixable inside the b-tree   |
| `symbols` + one composite index instead of `.gnu.hash`               | A general index answers questions a Bloom filter cannot; symbol versioning becomes a column                            | A b-tree lookup is a different constant factor than a tuned Bloom filter + bucket chain; unmeasured here                |
| Convert post-link rather than teach the compiler                     | No toolchain rebuild; the whole of nixpkgs is available as input; a `postFixup` hook is the entire integration         | Nothing is _born_ as SELF; the ELF linker's decisions (layout, `.gnu.hash`, PLT) are still baked into the segment bytes |
| `memfd` as the default loader mode                                   | Simplest and most compatible: the kernel's own `binfmt_elf` does the mapping, so everything downstream works           | An extra `execve` and a full image copy per process; the honest worst case                                              |
| M3a via `rtld-audit` rather than replacing `ld.so`                   | Stock glibc keeps lazy PLT, IFUNCs, TLS, versioning; works on unmodified packages today                                | The in-memory representation is still ELF; only _storage_ and _lookup_ moved to SQL                                     |
| `needs.resolved_path` recorded per object at pack time               | Kills soname ambiguity; turns resolution into a join instead of a fixpoint                                             | Bakes one machine's `ldd` answers into the artifact; recursive queries are avoided rather than made ergonomic           |
| Journal mode as a runtime flag in `self-httpd`                       | The single-file property and 3× throughput are both defensible defaults; the artifact's purpose decides                | WAL leaves `-wal`/`-shm` sidecars while serving; a crashed server must be recovered before it is `scp`'d                |
| No `P`/`O`/`F` `binfmt_misc` flags                                   | `P` injects an extra leading operand that strict programs reject; `basename(argv[0])` suffices for multi-call binaries | `/proc/self/exe` is wrong, and self-access rests entirely on `argv[0]` being preserved by whoever `exec`s the program   |

---

## Sources

- [fzakaria/selfdb — repository][repo], read at [`e63f7c47`][repo] (2026-08-24)
- [`DESIGN.md` — the format design, milestones M0–M4, the honest evaluation plan, and §13's deviations][design]
- [`schema/self.sql` — the v1 DDL, generated from `converter/selfconv/schema.py`][schema-sql]
- [`converter/selfconv/schema.py` — the authoritative schema and `APPLICATION_ID`][schema-py]
- [`converter/selfconv/elf2self.py` — ELF → rows, including the in-binary `docs` table][elf2self-py]
- [`converter/selfconv/self2elf.py` — the Python twin of the C row → image serializer][self2elf-py]
- [`converter/selfconv/closure.py` — `self closure`, `CLOSURE_SCHEMA`, per-object `ldd` resolution][closure-py]
- [`converter/selfconv/cli.py` — `self info` / `self q` / `self scan`, and the resolver schema][cli-py]
- [`loader/self-exec.c` — the `binfmt_misc` interpreter and mode dispatch][self-exec-c]
- [`loader/image.c` — the exit-free row → ELF serializer and `self_materialize_memfd`][image-c]
- [`loader/native.c` — the M2 loader: segment mapping, auxv synthesis, the `memcpy` that costs the sharing][native-c]
- [`loader/audit.c` — `libself-audit.so`, `la_objsearch` resolution through SQL][audit-c]
- [`loader/selfld.c` — the M3b eager SQL binder and the `preload` table][selfld-c]
- [`nix/module.nix` — the shipped masked `binfmt_misc` registration and the `P`-flag rationale][module-nix]
- [`examples/server/server.c` + `README.md` — self-httpd, `argv[0]`, the journal-mode trade, the measured latencies][server-c]
- [`examples/server/deploy.sh` — deployment as `scp`, and redeploy as `INSERT ... SELECT`][deploy-sh]
- [`bench/results.md`][bench-results] and [`bench/big.md`][bench-big] — the two exec-latency and size harnesses
- [Farid Zakaria, "Your executable is a SQLite database" (2026-08-23)][post1]
- [Farid Zakaria, "Actually Queryable Executables" (2026-08-24)][post2]
- [Farid Zakaria, "Linux kernel will support $ORIGIN, sort of" (2026-07-20)][post3] — transparent `binfmt_misc`, the BPF matcher, and the `L` loader-substitution mode
- [sqlelf, arXiv:2405.03883 — the SQL-view-over-ELF precursor][arxiv]
- [SQLite — Database File Format][sqlite-fileformat] (header layout, `application_id` at offset 68, in-header size at offset 28, reserved bytes at offset 20, overflow-page chains)
- [SQLite — an Application File Format][sqlite-appfileformat] · [Memory-Mapped I/O][sqlite-mmap] · [`sqlite3_blob_read`][blob-open] · [`VACUUM`][vacuum] · [Backup API][sqlite-backup] · [`sqldiff`][sqldiff] · [FTS5][fts5]
- [`fs/binfmt_misc.c`][binfmt-src] and [`include/uapi/linux/binfmts.h`][binprm-h], `torvalds/linux` at `e43ffb69` (v7.1-rc6) — masked matching, `remove_arg_zero`, `BINPRM_BUF_SIZE`, the four flags
- [Linux admin guide — `binfmt_misc`][binfmt-doc] · [`rtld-audit(7)`][rtld-audit]
- Runnable companions: [`examples/sqlite-header-probe.d`](./examples/sqlite-header-probe.d) (the 100-byte header, `application_id`, `page_size`, reserved bytes), [`examples/binfmt-magic-match.d`](./examples/binfmt-magic-match.d) (the kernel's masked registration predicate), [`examples/relocation-join.d`](./examples/relocation-join.d) (symbol resolution as a join, in SQL and Datalog), [`examples/elf-note-buildid.d`](./examples/elf-note-buildid.d) (a program reading its own build-id)
- Related in this tree: [redbean / Cosmopolitan / APE][ape] · [sqlelf][sqlelf] · [`binfmt_misc`][binfmt-misc] · [SQLite as an application file format][sqlite-app] · [the VFS as substrate][sqlite-vfs] · [dynamic linking][dyn-linking] · [Nix store closures][nix-closures] · [code as a database][code-as-db] · [image-based systems][image-based] · [measurement][measurement] · [threat model][threat-model] · [comparison][comparison] · [umbrella][umbrella]

<!-- References -->

[repo]: https://github.com/fzakaria/selfdb/tree/e63f7c470302f089a677ec87679a7df60b628547
[design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[schema-sql]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/schema/self.sql
[schema-py]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/converter/selfconv/schema.py
[elf2self-py]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/converter/selfconv/elf2self.py
[self2elf-py]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/converter/selfconv/self2elf.py
[closure-py]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/converter/selfconv/closure.py
[cli-py]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/converter/selfconv/cli.py
[self-exec-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/self-exec.c
[image-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/image.c
[native-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/native.c
[audit-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/audit.c
[selfld-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/loader/selfld.c
[module-nix]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/nix/module.nix
[server-c]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/server.c
[server-readme]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/README.md
[deploy-sh]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/deploy.sh
[bench-results]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/results.md
[bench-big]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/big.md
[bench-big-sh]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/big.sh
[bench-run]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/bench/run.sh
[test-preload]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/tests/preload.sh
[test-audit]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/tests/audit.sh
[post1]: https://fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database
[post2]: https://fzakaria.com/2026/08/24/actually-queryable-executables
[post3]: https://fzakaria.com/2026/07/20/linux-kernel-will-support-origin-sort-of
[arxiv]: https://arxiv.org/abs/2405.03883
[sqlite-fileformat]: https://sqlite.org/fileformat2.html
[sqlite-appfileformat]: https://sqlite.org/appfileformat.html
[sqlite-mmap]: https://sqlite.org/mmap.html
[blob-open]: https://sqlite.org/c3ref/blob_open.html
[vacuum]: https://sqlite.org/lang_vacuum.html
[sqlite-backup]: https://sqlite.org/backup.html
[sqldiff]: https://sqlite.org/sqldiff.html
[fts5]: https://sqlite.org/fts5.html
[binfmt-src]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/fs/binfmt_misc.c
[binprm-h]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/binfmts.h
[binfmt-doc]: https://docs.kernel.org/admin-guide/binfmt-misc.html
[rtld-audit]: https://man7.org/linux/man-pages/man7/rtld-audit.7.html
[lief]: https://lief.re/
[patchelf]: https://github.com/NixOS/patchelf/tree/7688b17c18d16f67fa8d5a82a2404c2e3a18648d
[ape]: ../cosmopolitan-ape/index.md
[sqlelf]: ../sqlelf.md
[bin-inspect]: ../binary-inspection-libraries.md
[binfmt-misc]: ../binfmt-misc.md
[sqlite-app]: ../sqlite-application-file-format.md
[sqlite-vfs]: ../sqlite-vfs-substrate.md
[dyn-linking]: ../dynamic-linking.md
[nix-closures]: ../nix-store-closures.md
[chunking]: ../content-addressed-chunking.md
[code-as-db]: ../code-as-database.md
[image-based]: ../image-based-systems.md
[relational-surfaces]: ../relational-system-surfaces.md
[single-level-store]: ../single-level-store.md
[footer-indexed]: ../footer-indexed-formats.md
[range-request]: ../range-request-access.md
[zip-parasitism]: ../zip-parasitism.md
[provenance]: ../embedded-provenance.md
[threat-model]: ../threat-model.md
[measurement]: ../measurement.md
[open-questions]: ../open-questions.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md
[umbrella]: ../index.md
[app-packaging]: ../../application-packaging/index.md
