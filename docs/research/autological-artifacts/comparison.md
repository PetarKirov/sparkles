# Autological Artifacts — Comparison and Synthesis

The capstone. Twenty-six deep-dives, re-cut by dimension, followed by the
verdicts on the five [cross-cutting theses][concepts-theses] and — because the
evidence went that way — a section of **corrections to the premises this survey
started from**.

**Last reviewed:** August 26, 2026

> [!IMPORTANT]
> The axis scores below are **ordinal judgements assigned by this survey**, not
> measurements of nature. Each is argued in the corresponding deep-dive's spine
> sections, and the aggregate patterns in [the shape of the space](#the-shape-of-the-space)
> are only as good as that coding. The _measured_ numbers quoted in this
> document are attributed to the page that measured them, and figures taken from
> a source rather than reproduced are labelled as that source's claim.

---

## Master comparison

Scores are **Multiplicity / Reflexivity / Closure / Mutability**, each 0–3
(0 = absent, 1 = incidental, 2 = designed-in, 3 = defining). See
[concepts][concepts-axes] for the definitions.

| Subject                                       | M   | R   | C   | Mu  | Index anchoring            | Dispatch owner     | Deep-dive                  |
| --------------------------------------------- | --- | --- | --- | --- | -------------------------- | ------------------ | -------------------------- |
| **Cosmopolitan / APE / redbean**              | 3   | 2   | 3   | 2   | footer (ZIP `EOCD`)        | shell → kernel     | [deep-dive][ape]           |
| **ZIP suffix parasitism**                     | 3   | 1   | 2   | 1   | footer                     | consumer           | [deep-dive][zip]           |
| **Polyglot craft (Corkami, PoC‖GTFO)**        | 3   | 1   | 1   | 0   | mixed by construction      | consumer           | [deep-dive][polyglot]      |
| **Boot hybrids (isohybrid, UKI, El Torito)**  | 3   | 1   | 2   | 0   | header + standardized hole | firmware           | [deep-dive][boot]          |
| **Parser differentials / LangSec**            | 3   | 0   | 0   | 1   | footer + stream-scanned    | consumer + shell   | [deep-dive][differentials] |
| **SELF / selfdb / self-httpd**                | 1   | 3   | 2   | 3   | header (b-tree)            | kernel             | [deep-dive][self]          |
| **sqlelf**                                    | 0   | 2   | 1   | 0   | out-of-band                | kernel (unchanged) | [deep-dive][sqlelf]        |
| **Format→query layers (LIEF, Kaitai, DFDL)**  | 1   | 3   | 0   | 2   | out-of-band                | consumer           | [deep-dive][inspection]    |
| **Relational system surfaces (osquery, …)**   | 1   | 3   | 1   | 1   | out-of-band (degenerate)   | consumer           | [deep-dive][relational]    |
| **Code as a database (CodeQL, Glean, …)**     | 1   | 3   | 2   | 1   | out-of-band                | consumer           | [deep-dive][codedb]        |
| **`binfmt_misc`**                             | 1   | 2   | 1   | 0   | header (256-byte window)   | kernel             | [deep-dive][binfmt]        |
| **The dynamic loader (`ld.so`)**              | 1   | 2   | 1   | 1   | header + out-of-band cache | loader             | [deep-dive][ld]            |
| **Wasm component model / WIT**                | 1   | 3   | 2   | 0   | stream-scanned             | loader             | [deep-dive][wasm]          |
| **Footer-indexed formats (Parquet, ORC, …)**  | 2   | 2   | 0   | 1   | footer                     | consumer           | [deep-dive][footer]        |
| **Range-request consumption**                 | 0   | 2   | 1   | 0   | footer / header+b-tree     | consumer           | [deep-dive][range]         |
| **The Nix store and closures**                | 0   | 2   | 3   | 1   | out-of-band                | consumer           | [deep-dive][nix]           |
| **Content addressing and chunking**           | 0   | 1   | 3   | 1   | out-of-band (+ footer TOC) | consumer           | [deep-dive][chunking]      |
| **Image-based systems (Squeak, pdumper, …)**  | 1   | 2   | 2   | 3   | header                     | loader             | [deep-dive][images]        |
| **SQLite as an application file format**      | 1   | 3   | 2   | 3   | header                     | consumer           | [deep-dive][aff]           |
| **The SQLite VFS as substrate**               | 1   | 2   | 0   | 2   | out-of-band (negotiable)   | consumer           | [deep-dive][vfs]           |
| **Embedded provenance (build-id, buildinfo)** | 0   | 2   | 1   | 0   | mixed by design            | consumer           | [deep-dive][provenance]    |
| **Debug info and out-of-band indexes**        | 1   | 2   | 1   | 1   | stream-scanned + bolt-ons  | consumer           | [deep-dive][dwarf]         |
| **Threat model**                              | 0   | 1   | 0   | 3   | out-of-band                | kernel             | [deep-dive][threat]        |
| **Single-level store (IBM i, Multics)**       | 0   | 3   | 1   | 2   | out-of-band                | kernel             | [deep-dive][sls]           |
| **Plan 9 and 9P**                             | 1   | 2   | 0   | 1   | out-of-band (no artifact)  | kernel             | [deep-dive][plan9]         |
| **Method and measurement**                    | 0   | 1   | 0   | 1   | out-of-band                | consumer           | [deep-dive][measure]       |

---

## The shape of the space

Three aggregate patterns fall out of the coding above. The first is the one the
source outline did not anticipate.

### Multiplicity and reflexivity are near-mutually-exclusive

**No subject scoring 3 on reflexivity scores above 1 on multiplicity** — zero of
seven. Across all 26 subjects the Pearson correlation is only `r = −0.36`, which
on its own would be weak; the categorical statement is far sharper than the
coefficient, and it is the honest way to report it.

Only one artifact in the survey reaches a combined multiplicity + reflexivity of
5: [APE][ape], at 3 + 2. Everything else is at 4 or below.

The mechanism is visible in the deep-dives and is not a coincidence of scoring.
**Multiplicity is bought with structural slack** — a footer index, a reserved
hole, a tolerated prefix, unknown-chunk tolerance. **Reflexivity is bought with
structural commitment** — a schema, a declared type graph, a b-tree with a fixed
root. Slack and commitment are the same dimension with opposite signs. A format
that promises a reader it may ignore what it does not recognize has, by that
promise, given up the ability to enumerate what is there.

This reframes the two seeds. [redbean][ape] and [SELF][self] are not two points
on one road; they are on opposite walls of the room, and the outline's
[thesis 5](#thesis-5--portability-has-migrated-from-the-format-to-the-access-layer)
is really a claim about which wall the field is moving toward.

### The most common place for an index is outside the artifact

Eleven of 26 subjects anchor their index **out-of-band** — more than footer (5),
header (6), and stream-scanned (4) individually. Every one of those eleven is a
[materialized view][concepts-terms] with the staleness properties that implies:
`/etc/ld.so.cache`, `/nix/var/nix/db/db.sqlite`, `.gdb_index` in a cache
directory, a `debuginfod` server, a `.caibx` chunk index, an OCI manifest, a
CodeQL database.

The pattern is strong enough to state as a finding: **when a format has no query
surface, the index leaves the artifact.** [DWARF][dwarf] is the clearest single
case — three in-artifact index generations (`.debug_pubnames`, `.gdb_index`,
`.debug_names`) plus two out-of-band ones — and its deep-dive documents that the
_same_ 785,047 bytes of `.gdb_index` for one object file can live inside the
artifact, beside it keyed by build-id, or nowhere at all. **Index anchoring
turns out to be a deployment setting more often than a property of the format.**

### Dispatch is overwhelmingly the consumer's job

Fifteen of 26 subjects are dispatched by the consumer; the kernel owns six, the
loader three, firmware one, the shell one. The interesting consequence is in
[the threat model][threat]: consumer dispatch means there is no privileged
arbiter, which is exactly the precondition for a
[parser differential][differentials].

---

## By dimension

### Where the index lives, and what it costs remotely

[Footer-indexed formats][footer] establishes the causal rule the catalog was
looking for, and it is a writer-side constraint rather than a reader-side one:
**the index cannot be written until the data is, and the front of a large file
cannot be rewritten** — so a streaming writer must append. That one sentence
predicts ZIP, Parquet, ORC, and seekable `zstd` alike, and it explains why
SQLite does _not_ need a footer: its index is a b-tree descended from a fixed
root pointer, not a contiguous block that must be placed.

[Range-request consumption][range] then adds a consequence the four-way
anchoring table in [concepts][concepts-index] does not capture, and it matters
enough to state here:

> A Parquet footer yields a **complete list of independent `(offset, length)`
> extents before any of them is fetched**, so a client can coalesce and issue
> them concurrently. A SQLite b-tree descent is a **data-dependent pointer
> chase**: the page needed at level _k+1_ is unknown until level _k_ is parsed.

Both are "random access". Over a local file the difference is negligible; over a
network it is the difference between one bandwidth-delay-product round trip and
a serial chain of them. **Footer-anchored indexes parallelize; b-tree descents
serialize.** That is a real cost of SELF's design that the outline did not name.

### Tolerance, and whether the taxonomy holds

The [tolerance partial order][concepts-tolerance] — prefix-tolerant,
suffix-tolerant, hole-tolerant, neither — survives contact with the evidence,
with one instructive amendment from [boot hybrids][boot]:

ISO 9660 is **header-anchored yet prefix-parasitic**, because ECMA-119 reserves
Logical Sectors 0–15 (_"Its content is not specified by this Standard"_) _and_
obliges producers to expose them. So hole-tolerance is not a weaker form of
prefix-tolerance; it is a distinct, deliberately specified third thing, and it
is the only one of the four that a standards body ever wrote down on purpose.
The rest were discovered by people appending ZIPs to executables.

### Query language: the field already answered

[Code as a database][codedb] settles the outline's SQL-or-Datalog question
empirically rather than by argument: **the systems that must express transitive
reachability overwhelmingly chose Datalog or a Datalog descendant** — CodeQL,
Glean's Angle, `ddisasm` over Souffle — while the ones that chose SQL
(`sqlelf`, `osquery`) either avoid transitive queries or make them awkward.

[Nix][nix] supplies the sharpest single data point, and it cuts against the
implementations rather than the languages: store closure _is_ literally a
recursive query, and a **four-line `WITH RECURSIVE` over the two-column `Refs`
table reproduced `nix path-info -S` byte-for-byte** — yet Nix reimplemented the
traversal in C++ anyway, on top of a real database it already had.

---

## The five theses

### Thesis 1 — every binary format eventually reimplements a database, badly

**Verdict: upheld on the "reimplements", split on the "badly".**

The reimplementation is near-universal and reaches beyond ELF, which is what the
outline asked to test:

- [DWARF][dwarf] is the strongest case. Abbreviation tables are schema interning,
  DIE references are foreign keys, and the community bolted on _five_ index
  generations because the format shipped with no query surface.
- [Content-addressed chunking][chunking] found the pattern reappearing in
  brand-new code: `containers/storage`'s `chunked-manifest-cache` is a Bloom
  pre-filter (10 bits/entry, 3 hashes) over a sorted fixed-width tag table,
  `mmap`-able and version-tagged. **Feature for feature, that is ELF's
  `.gnu.hash`, rebuilt in 2023.**
- [Wasm][wasm] reimplements one _deliberately and normalized_:
  `wasm-tools component wit --json` emits exactly four arrays — `worlds`,
  `interfaces`, `types`, `packages` — joined by integer foreign keys.

But "badly" does not survive [footer-indexed formats][footer]. Parquet
reimplemented a catalog, a zone map (`ColumnIndex` per-page min/max, with a
_specified_ licence to truncate bounds outward), and a Bloom filter — and did it
**well**: these are the structures a column store would choose, and they are
normative rather than conventional. The thesis should be restated as: _formats
that grow an index by accretion do it badly; formats that specify one up front do
it about as well as a database would._

### Thesis 2 — self-description is what makes a format survivable

**Verdict: refuted as stated.** This is the survey's cleanest kill.

[Nix][nix] store objects carry **no self-description whatsoever** — no schema,
no manifest, no declared dependencies, not even a marker byte — and the model has
survived unchanged since 2003-03-13. What made it survivable is the _opposite_
property: because the reference scanner knows only ASCII and Nix32 and nothing
about file formats, it found dependencies in formats that did not exist when it
was written.

Three further complications:

- [DWARF][dwarf] _is_ genuinely self-describing at the encoding level —
  `.debug_abbrev` lets a reader skip constructs it has never heard of, which ELF
  proper cannot do — and it still needed three failed index generations, because
  **indexes require agreement about semantics, which encoding-level
  self-description does not provide.**
- [Plan 9][plan9] deliberately declined it: 9P's `stat` record carries name,
  permissions, times, and owner, and nothing about content. Nothing in the
  protocol says `/net/tcp/0/ctl` accepts `connect addr!port`. Per the design
  paper, _"it is the conventions that make the system"_.
- [The threat model][threat] finds the limit even where self-description is
  total: a `.self` file carries its schema, segments, symbols and closure, and
  **does not carry the one fact that decides what happens when it is executed**.
  `binfmt_misc` sets `FS_USERNS_MOUNT`, so anyone who can `unshare -Ur`
  redefines what the artifact _is_. Self-description stops exactly at
  self-dispatch.

The defensible replacement: _a format survives when something outside it can
recover meaning without the format's cooperation._ Nix's byte scanner, DWARF's
abbreviation skipping, and Plan 9's conventions are all instances.

### Thesis 3 — the container is a tax

**Verdict: refuted for the seed case; the tax is real but it is on the closure.**

[APE][ape] refutes it directly. Because deflate's stream is byte-identical to
gzip's, redbean's `ServeAssetPrecompressed` synthesizes a gzip header and footer
and writes the archive's stored bytes **straight to the socket with no inflate
and no recompression**. The ZIP container is not overhead; it is the reason the
server is fast. A [chimera][polyglot] makes the point again from the other
direction — when host and guest agree on a payload encoding, one copy of the
image data is reused by every parse and the container costs _zero bytes_.

[Nix][nix] pays no container tax by the opposite route to SELF's: there is no
Nix artifact format at all, and the entire out-of-band index costs **371,535,872
bytes against 344,988,556,624 bytes of store content — 0.108%**.

And [chunking][chunking] relocates the tax where it actually lives. Two NixOS
store paths of the same `libLLVM.so.21.1` build (187,668,968 bytes each) share
**0.00% at Nix's path grain and 99.88% at a 64 KiB content-defined chunk
grain**. The tax is on the _closure_, not the container, and name-based sharing
is what forfeits it.

Two dual taxes the outline missed, both from the deep-dives:

- **The dispatcher is a tax.** [SELF][self] pays none in bytes but pays one per
  start; [binfmt_misc][binfmt] documents the mechanics precisely (and corrects
  the folklore — see [below](#corrections-to-the-outline)).
- **The absence of a container is a per-start tax.** [Dynamic linking][ld]
  measured `weston` (30 objects) issuing **140 `openat` calls of which 111 were
  `ENOENT`** with `RUNPATH` alone, and 326/297 with a six-entry
  `LD_LIBRARY_PATH` prepended — identical answer, 2.3× the probes.

### Thesis 4 — `mmap` is the load-bearing constraint

**Verdict: upheld as a design constraint, but the specific claim about SELF is
wrong, and nobody had checked.**

[Image-based systems][images] is the strongest support: five independent systems
— Squeak, SBCL, Emacs `unexec` → `pdumper`, CRIU, Erlang — each collided with
demand paging and cross-process sharing, and **converged on the same fix**:
partition off a never-relocated region and map only that off the file. Emacs's
`unexec` broke precisely under ASLR, PIE, and modern `malloc`.

But the catalog's headline claim — _"SELF loses page sharing"_ — does not
survive [the SQLite deep-dive][aff]:

> Since 3.7.17 (2013-05-20) the VFS has `xFetch`/`xUnfetch`, so with
> `PRAGMA mmap_size` set, SQLite returns a pointer into a mapped page **"without
> having to copy anything"**, and two processes share physical pages.

So the claim is **false at the page level and true at the object level**, and the
distinction is the whole of the engineering problem. Meanwhile
[measurement][measure] establishes the more uncomfortable fact: the claim **has
never been measured by anyone**. SELF's own `DESIGN.md` §9 names the method and
the expected outcome (`pss` across N concurrent instances, "ELF wins (shared
text)"), and §11 reserves the `bench/` slot — empty.

Two boundary cases keep the thesis honest rather than universal. [Wasm][wasm]
**refutes** it by declining to describe memory layout at all: the component
binary grammar specifies no addresses, no `st_value`, no `PT_LOAD`, no
alignment, so paging is decided entirely below the format. And
[single-level store][sls] gets _stronger_ sharing than `mmap` by abolishing
files: IBM's own comparison table states single-level storage does not support
memory mapping and is not addressed by 8-byte pointers, yet is
_"Global: accessible to any job that has a pointer to it"_.

### Thesis 5 — portability has migrated from the format to the access layer

**Verdict: upheld, but it is a three-way choice, not a two-way one.**

[The VFS deep-dive][vfs] documents the seam in the detail the thesis needs — a
17-slot `sqlite3_vfs` and 18-slot `sqlite3_io_methods` delivering the same
b-tree pages from `pread(2)`, an OPFS `FileSystemSyncAccessHandle`, an HTTP 206
response, or a byte range appended to an executable.

Three findings complicate it:

1. **The substrate reaches up into the format.** Both OPFS import paths write
   `new Uint8Array([1,1])` at **file offset 18** to force the database out of
   WAL mode, because the WASM build has no shared-memory API. The access layer
   is not transparent; it edits the header.
2. **There is a third strategy.** [Plan 9][plan9] achieves reach by holding one
   _interface_ fixed — path plus open/read/write, 13 messages — rather than by
   satisfying every parser (APE) or swapping the substrate (SQLite).
   [binfmt_misc][binfmt] is a fourth: the artifact supplies the _claim_, the host
   owns the _decision_, and the decision does not travel with the file.
3. **The one-file property has a footnote.** SQLite's own documentation concedes
   that WAL mode means _"there is an additional quasi-persistent `-wal` file"_ —
   the artifact is transiently not one file, which is exactly the property the
   whole catalog is about.

---

## Corrections to the outline

The source outline is the survey's starting hypothesis, and five of its specific
claims did not survive. They are collected here because a research catalog that
only confirms its brief has not been read carefully enough.

| Outline claim                                                               | What the evidence says                                                                                                                                                                                                      | Owner                     |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| The three page-sharing fixes "are all VFS-shaped — which is the good news." | Only one is viable and it is **not** VFS-shaped. Overflow pages carry a 4-byte big-endian next-page link at their head, so BLOB payload arrives in discontiguous runs; page-aligned BLOBs are impossible.                   | [SELF][self]              |
| "Storage got cheap enough that a 2× b-tree overhead is negotiable."         | **There is no 2× overhead.** SELF's own figures are 611.9 MiB of database against **644.4 MiB of equivalent ELF** — the database is _smaller_, because schema-level dedup beats per-file duplication.                       | [Single-level store][sls] |
| The 5.53 GiB figure quantifies the b-tree cost.                             | It is a comparison against the **AppImage model**, not against ELF. The like-for-like comparison is 611.9 vs 644.4 MiB, and the two comparisons answer different questions.                                                 | [Single-level store][sls] |
| "Both fzakaria posts are explicit that LLM assistance is why now."          | Neither claims that. Post 1 says LLM improvements make it _"compelling to revisit these ideas"_ — motivation, not feasibility; post 2's _"definitely AI assisted"_ is an admission about a prototype.                       | [Single-level store][sls] |
| `binfmt_misc` dispatch costs a "double exec".                               | Not a second `execve`. `exec_binprm()` swaps `bprm->file` and re-runs `search_binary_handler` in an **in-kernel loop** bounded by a depth counter; the only genuine extra exec-family syscall is `memfd` mode's `execveat`. | [binfmt_misc][binfmt]     |

Two more, which are not corrections to the outline but to the field:

- **A likely defect in SELF itself.** `closure.py` stamps the same
  `application_id = 0x53454C46` _and_ the same `user_version = 1` onto
  `CLOSURE_SCHEMA`, a completely different schema. The discriminator that
  `binfmt_misc` dispatches on does not discriminate. ([SELF][self])
- **`ETXTBSY` never protects a `.self` file.** `do_open_execat` calls
  `exe_file_deny_write_access()` on `bprm->file`, which the dispatch loop has
  already swapped to the interpreter — so the write protection lands on
  `self-exec`, not on the artifact being executed. ([Threat model][threat])

---

## Architectural trade-offs

The recurring, non-negotiable ones, each owned by a deep-dive:

| Trade-off                                | The two horns                                                                                                         | Where it is argued                                |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| **Slack vs. enumerability**              | Tolerating unknown bytes buys multiplicity; committing to a schema buys reflexivity. You cannot have both maximally.  | [the shape of the space](#the-shape-of-the-space) |
| **Parallel fetch vs. pointer chase**     | A footer extent list coalesces into concurrent range requests; a b-tree descent serializes on data dependence.        | [range][range], [footer][footer]                  |
| **Name-based vs. content-based sharing** | 0.00% sharing at store-path grain vs. 99.88% at 64 KiB content-defined chunk grain, same two artifacts.               | [chunking][chunking]                              |
| **Mutability vs. remote consumption**    | DuckDB sends `If-Match` and raises on 412; a `self-httpd` that `INSERT`s per request would 412 on every remote query. | [range][range]                                    |
| **Self-description vs. self-dispatch**   | An artifact can describe everything about itself except what will be done with it — `FS_USERNS_MOUNT` decides that.   | [threat][threat]                                  |
| **Signature vs. legitimate mutation**    | Every attestation standard binds to an immutable digest; `VACUUM` rewrites bytes and rowids.                          | [provenance][provenance]                          |
| **In-artifact index vs. rebuild cost**   | The same 785,047-byte `.gdb_index` can live in the file, beside it, or nowhere — measurably different startups.       | [dwarf][dwarf]                                    |

---

## What actually got answered

Of the outline's ten open questions, the survey closed three, materially advanced
four, and left three genuinely open. [open-questions.md][open] carries the full
agenda with the current state of each; the short version:

- **Closed — SQL or Datalog?** The field chose Datalog for reachability, and the
  reason is fixpoint semantics rather than syntax. ([code-as-database][codedb])
- **Closed — a concurrent GC over a store somebody is executing from.** Erlang
  has shipped one for decades: MVCC over three code indices, explicitly so that
  readers need _"no locks or other expensive memory barriers"_, with a
  two-version retention bound. ([images][images], [nix][nix])
- **Closed — is there a taxonomy of which formats compose?** Yes: the
  [tolerance partial order][concepts-tolerance], amended with hole-tolerance as a
  distinct third case.
- **Advanced — can you `SELECT` from a SELF binary over HTTP?** Derived, not
  measured; the arithmetic and the serialization penalty are in [range][range].
- **Still open — how do you sign a mutable executable?** [Provenance][provenance]
  works the Merkle-over-canonical-rows design to the point where it breaks (row
  order is not canonical; rowids move under `VACUUM`; a subset signature does not
  bind the subset to the whole) and no existing standard covers it.

---

## What this means for Sparkles

This survey does not feed a planned Sparkles library; it was commissioned as
background. Recorded here so a future reader knows what was and was not
concluded.

| Capability the catalog surveys     | Where Sparkles stands today                                                                                                           |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Footer-anchored index parsing      | None. `sparkles:wired` is a wire format with a JSON surface; nothing in the repo reads a ZIP/Parquet-style footer.                    |
| Declarative binary-format grammars | Adjacent: `sparkles:wired` is compile-time-reflected D, which is the [Kaitai/DFDL][inspection] idea reached by a different route.     |
| Self-describing artifacts          | D binaries carry ELF notes only if the link asks — as [`elf-note-buildid.d`](./self-selfdb/examples/elf-note-buildid.d) demonstrates. |
| Query surface over build outputs   | None. `sparkles:build-primitives` walks repositories; there is no relational surface over what it finds.                              |
| Single-file distribution           | Out of scope here by design — [application-packaging][packaging] owns it.                                                             |

The one concrete, low-cost item the survey surfaced: **the repository's own
example programs are `.d` single-file `dub` recipes whose dependency closure is
computed and thrown away on every run**, which is [thesis 3's dual][ld] (the
absence of a container as a per-start tax) in miniature. Whether that is worth
anything is not something this survey established.

## Sources

Every claim above is owned by the deep-dive it is attributed to; those pages
carry the primary sources and the pinned citations. The tree-wide grounding
state at the last review: **590 GitHub blob citations, 495 verified to resolve at
their pinned commit** against local clones, 3 unverifiable for lack of a clone at
that revision, and 154 individually-recorded claims that could not be verified
and were dropped or explicitly marked.

<!-- References -->

[concepts-theses]: ./concepts.md#the-five-cross-cutting-theses
[concepts-axes]: ./concepts.md#the-four-axes
[concepts-index]: ./concepts.md#where-does-the-index-live
[concepts-tolerance]: ./concepts.md#tolerance-a-partial-order-on-composability
[concepts-terms]: ./concepts.md#terms-used-throughout
[ape]: ./cosmopolitan-ape/index.md
[zip]: ./zip-parasitism.md
[polyglot]: ./polyglot-craft.md
[boot]: ./boot-hybrids.md
[differentials]: ./parser-differentials.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[inspection]: ./binary-inspection-libraries.md
[relational]: ./relational-system-surfaces.md
[codedb]: ./code-as-database.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[wasm]: ./wasm-component-model.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[nix]: ./nix-store-closures.md
[chunking]: ./content-addressed-chunking.md
[images]: ./image-based-systems.md
[aff]: ./sqlite-application-file-format.md
[vfs]: ./sqlite-vfs-substrate.md
[provenance]: ./embedded-provenance.md
[dwarf]: ./debug-info-and-indexes.md
[threat]: ./threat-model.md
[sls]: ./single-level-store.md
[plan9]: ./plan9-namespaces.md
[measure]: ./measurement.md
[open]: ./open-questions.md
[packaging]: ../application-packaging/index.md
