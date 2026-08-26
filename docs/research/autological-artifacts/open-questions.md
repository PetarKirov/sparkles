# Autological Artifacts — Open Questions

The research agenda, with the current state of each question and what would
actually settle it. The [source outline][concepts] posed ten; this survey closed
three, materially advanced four, left three open, and raised five new ones that
did not exist before the evidence came in.

**Last reviewed:** August 26, 2026

> [!NOTE]
> "Closed" here means _the evidence answers it_, not _somebody built it_. Where
> a question is closed by a system that already shipped, the entry says which
> system and where the deep-dive documents it.

---

## Status at a glance

| #   | Question                                                     | Status     | Owner                              |
| --- | ------------------------------------------------------------ | ---------- | ---------------------------------- |
| Q1  | Is there a taxonomy of which formats compose?                | **Closed** | [zip][zip], [boot][boot]           |
| Q2  | SQL or Datalog for the transitive queries?                   | **Closed** | [codedb][codedb]                   |
| Q3  | What does a concurrent GC over a live store look like?       | **Closed** | [images][images], [nix][nix]       |
| Q4  | Can you `SELECT` from a SELF binary over HTTP?               | Advanced   | [range][range]                     |
| Q5  | Can symbol binding be compiled and cached in the artifact?   | Advanced   | [ld][ld]                           |
| Q6  | Does SELF actually lose page sharing, and by how much?       | Advanced   | [aff][aff], [measure][measure]     |
| Q7  | Why did the single-level-store systems lose?                 | Advanced   | [sls][sls], [plan9][plan9]         |
| Q8  | How do you sign a mutable executable?                        | **Open**   | [provenance][provenance]           |
| Q9  | What is the least-privilege decomposition of a self-server?  | **Open**   | [threat][threat]                   |
| Q10 | What is the smallest browser-side `self-exec`?               | **Open**   | [vfs][vfs]                         |
| N1  | Why are multiplicity and reflexivity anticorrelated?         | New — open | [comparison][shape]                |
| N2  | Can a b-tree descent be made to parallelize remotely?        | New — open | [range][range]                     |
| N3  | Is mutability compatible with remote consumption at all?     | New — open | [range][range]                     |
| N4  | Can an artifact describe its own dispatch?                   | New — open | [threat][threat], [binfmt][binfmt] |
| N5  | Where should an index live, given it is a deployment choice? | New — open | [dwarf][dwarf]                     |

---

## Closed

### Q1 — Is there a taxonomy of which formats compose?

**Yes, and it predicts rather than catalogues.** A composition is possible when
one participant is [prefix-tolerant][tolerance] and the other suffix-tolerant, or
when one is hole-tolerant and the other fits the hole. That single rule generates
the entire ZIP-suffixed ecosystem — JAR, APK, `.docx`, EPUB, `.whl`,
self-extracting archives — from one structural fact about where ZIP anchors its
index. [ZIP parasitism][zip] develops it and tests it against a table of formats.

The amendment came from [boot hybrids][boot], and it is the part that was not
obvious: **hole-tolerance is a distinct third case, not a weak form of
prefix-tolerance.** ISO 9660 is header-anchored yet prefix-parasitic, because
ECMA-119 reserves Logical Sectors 0–15 (_"Its content is not specified by this
Standard"_) _and_ obliges producers to expose them. It is also the only one of
the four tolerances a standards body wrote down deliberately; the others were
discovered by people appending archives to executables.

### Q2 — SQL or Datalog?

**Datalog, and the field decided years ago.** [Code as a database][codedb] finds
that the systems which must express transitive reachability — CodeQL, Glean's
Angle, `ddisasm` over Souffle — chose Datalog or a descendant, while those that
chose SQL either avoid transitive queries or make them awkward. The reason is
semantic rather than syntactic: fixpoint semantics, guaranteed termination under
semi-naive evaluation, and stratified negation.

[Nix][nix] supplies the sharpest data point, and it indicts the implementations
rather than the languages: store closure _is_ a recursive query, and a **four-line
`WITH RECURSIVE` over the two-column `Refs` table reproduced `nix path-info -S`
byte-for-byte** — yet Nix reimplemented the traversal in C++ on top of the SQLite
database it already had.

**What remains worth building:** a Datalog front-end over SELF's tables is still
the small, high-signal experiment the outline called for. Q2 being closed makes
it more attractive, not less — the design question is settled, so only the work
is left.

### Q3 — What does a concurrent GC over a store somebody is executing from look like?

**Erlang shipped one, and has run it in production since the 1990s.**
[Image-based systems][images] documents it: code replacement is MVCC over three
code indices — "active", "staging", and a third quarantined until every scheduler
has passed it — explicitly so that readers need _"no locks or other expensive
memory barriers"_. The two-version rule bounds retention, and a third load purges.

[Nix][nix] supplies the complementary half for the _store_ case: the GC lock, plus
a `/proc` scan to find store paths mapped by running processes — which in the
measured instance supplied **20.6% of the roots**. That scan is exactly the
mechanism SELF lacks: once segments are rows, there is no "this file is still
open, do not delete it" for the kernel to report.

So the answer is known, and the port is the work: **Erlang's version discipline
for the code, Nix's root discovery for the store, and a replacement for the
`/proc` scan that SELF currently has no analogue for.**

---

## Advanced

### Q4 — Can you `SELECT` from a SELF binary over HTTP without downloading it?

**Probably yes, and [range-request consumption][range] does the arithmetic** —
but the answer is _derived, not measured_, and the page says so explicitly.

The new finding is that the cost model is worse than the outline assumed, for a
structural reason:

> A Parquet footer yields a complete list of independent `(offset, length)`
> extents **before any of them is fetched**, so a client coalesces them and
> issues them concurrently. A SQLite b-tree descent is a **data-dependent pointer
> chase**: the page needed at level _k+1_ is unknown until level _k_ is parsed.

Footer-anchored indexes parallelize; b-tree descents serialize. "Query a remote
executable's symbol table for 40 KiB" is still plausible on bytes and much less
plausible on latency, because the round trips are sequentially dependent.

**To settle it:** stand up a SELF binary behind a range-serving origin, run a
symbol-table query through `sql.js-httpvfs`-style plumbing, and report round
trips and wall time against page size. Page size is the dominant tunable and the
one `sql.js-httpvfs`'s own guidance is loudest about.

### Q5 — Can symbol binding be compiled and cached in the artifact?

**The question survives; `prelink` is the cautionary tale and `shrinkwrap` the
partial answer.** [Dynamic linking][ld] establishes that the recurring cost is
real and measurable — `weston` (30 objects) issues **140 `openat` calls of which
111 are `ENOENT`** with `RUNPATH` alone, and 326/297 with a six-entry
`LD_LIBRARY_PATH` prepended: identical answer, 2.3× the probes.

What a stored materialized view of resolved addresses must survive is now
enumerable: ASLR, any change to any object in the closure, `LD_PRELOAD`,
interposition order, and `dlopen`. `prelink` failed on the second and third of
those. A schema does not by itself make the view safe — it makes the
_invalidation condition_ expressible, which is a smaller claim than the outline
made and the honest version of it.

### Q6 — Does SELF actually lose page sharing?

**The headline claim is wrong as stated, and nobody has measured the corrected
version.** Two findings, both from this survey:

1. **False at the page level.** [SQLite as an application file format][aff]
   establishes that since 3.7.17 (2013-05-20) the VFS has `xFetch`/`xUnfetch`, so
   with `PRAGMA mmap_size` set SQLite returns a pointer into a mapped page
   _"without having to copy anything"_, and two processes do share physical
   pages. The loss is at the **object** level, not the page level.
2. **Never measured.** [Measurement][measure] found that SELF's own `DESIGN.md`
   §9 names the method and the expected outcome (`pss` across N concurrent
   instances, "ELF wins (shared text)") and §11 reserves the `bench/` slot — and
   it is empty.

The outline's proposed fixes fare worse than it hoped. **Page-aligned BLOBs are
impossible**: overflow pages carry a 4-byte big-endian next-page link at their
head, so BLOB payload arrives in discontiguous runs. Of the three candidates only
one survives, and it is not VFS-shaped — which inverts the outline's
"the good news is that seam is already load-bearing".

**To settle it:** the PSS/USS sweep in [measurement][measure] §2. It is cheap and
decisive. Note the instrument trap that page also found: **installing a `uprobe`
breaks COW at the probe site** (`uprobe_write_opcode()` sets
`FOLL_WRITE | FOLL_SPLIT_PMD`), so the standard tool for watching the loader
destroys the very sharing being measured. Use `smaps_rollup`, not uprobes.

### Q7 — Why did the single-level-store systems lose?

**Advanced, and two of the outline's three candidate answers are wrong.**
[Single-level store][sls] tested them:

- _"Storage got cheap enough that a 2× b-tree overhead is negotiable"_ —
  **there is no 2× overhead.** SELF's own figures are 611.9 MiB of database
  against **644.4 MiB of equivalent ELF**. The database is _smaller_, because
  schema-level dedup of shared libraries and symbols beats per-file duplication.
  The 5.53 GiB figure is a comparison against the _AppImage_ model and answers a
  different question.
- _"Both fzakaria posts are explicit that LLM assistance is why now"_ — neither
  claims that. Post 1 says LLM improvements make it _"compelling to revisit these
  ideas"_ (motivation, not feasibility); post 2's _"definitely AI assisted"_ is an
  admission about a prototype.
- _"SQLite's ubiquity removed the format-adoption cost"_ — **this one holds**, and
  it is the strongest of the three.

The answer the evidence actually supports, and which the outline did not list:
**the Unix byte-stream file won because it composed with pipes and portable
tooling, and every schema-enforcing system paid for its schema with a closed
toolchain.** [Plan 9][plan9] sharpens it — osquery and Datasette had to _rebuild_
tooling for their interface, whereas Plan 9's interface was already the one every
tool spoke. On that reading the current wave is viable precisely because it puts
the database **inside** the Unix file instead of replacing it.

---

## Open

### Q8 — How do you sign a mutable executable?

**Genuinely unsolved.** [Embedded provenance][provenance] works the obvious
design — per-table Merkle roots over a canonical row encoding, the signature
covering only immutable tables — to the point where it breaks, and it breaks in
three independent places:

1. **Row order is not canonical in SQL.** A canonical serialization has to impose
   one, and then defend it against every future SQLite version.
2. **Rowids move under `VACUUM`**, which is exactly the operation `strip` becomes.
3. **A signature over a subset does not bind the subset to the whole.** An
   attacker who can rewrite the mutable tables can present a validly-signed
   immutable half attached to anything.

Every existing standard dodges rather than solves it: in-toto binds attestations
to subjects that _"are assumed to be immutable … SHOULD NOT change"_, matched
_"purely by digest"_; SLSA defines an artifact as an _"immutable blob of data"_;
Authenticode excludes its own signature region; APK v2 signs everything before
the central directory; dm-verity signs a Merkle tree over blocks, not semantics.

**The shape of an answer**, if one exists: signing must move from _bytes_ to
_derivations_ — sign the immutable inputs and the transformation, not the mutable
output. That is Nix's model, and pointing at it is not the same as having built it.

### Q9 — What is the least-privilege decomposition of a self-querying server?

**Open, and [the threat model][threat] explains why it is harder than it looks.**
The finding that reframes the question:

> Every OS enforcement primitive that would protect an autological artifact
> identifies its subject by **inode, path, device, or policy — never by content**
> — because content is exactly what the artifact mutates.

So "read-only on these bytes of this file, read-write on those" is not expressible
by `pledge`, `unveil`, Landlock, or seccomp-BPF. The candidate answers and their
verdicts: two file descriptors with different open modes (does not survive
SQLite's own reopening); the SQLite authorizer callback (application-level, so it
is not enforcement); two database files (forfeits the one-file property that is
the entire point); a helper process (works, and concedes the architecture).

Two further findings make the ground worse: **`ETXTBSY` never protects a `.self`
file**, because `do_open_execat` calls `exe_file_deny_write_access()` on
`bprm->file`, which the dispatch loop has already swapped to the interpreter; and
`binfmt_misc` sets `FS_USERNS_MOUNT`, so anyone who can `unshare -Ur` redefines
what the artifact _is_.

**What a kernel would have to offer:** a byte-range-scoped file capability, or an
`fs-verity`-like read-time integrity check that admits a mutable region. Neither
exists.

### Q10 — What is the smallest browser-side `self-exec`?

**Open, and [the VFS deep-dive][vfs] sketches it while naming what does not
work.** The shape: a Worker that reads the `segments` table out of a SQLite
database held in OPFS and hands the bytes to `WebAssembly.instantiate`. At that
point the module lives _in_ the database, the module loader plays the role of
[`binfmt_misc`][binfmt], and there is a browser-native autological artifact with
no kernel involvement at all.

What blocks it today: no relocations, no `dlopen`, and the Wasm memory model.
And the substrate is not transparent — both OPFS import paths **write
`new Uint8Array([1,1])` at file offset 18** to force the database out of WAL
mode, because the WASM build has no shared-memory API. The access layer reaches
up and edits the format's header, which is a real qualification on
[thesis 5][thesis5].

---

## New questions this survey raised

### N1 — Why are multiplicity and reflexivity anticorrelated?

[Comparison][shape] establishes the pattern: **no subject scoring 3 on
reflexivity scores above 1 on multiplicity**, zero of seven, with APE the sole
artifact reaching a combined 5. The proposed mechanism is that multiplicity is
bought with structural _slack_ and reflexivity with structural _commitment_, and
that these are one dimension with opposite signs.

That is an argument, not a proof. **Is there an artifact that defeats it** — high
multiplicity _and_ a real query surface? A UKI with a `.self` section would be a
candidate to construct; so would a SELF database whose reserved-per-page region
carried a valid ZIP footer. Building one and scoring it honestly is the test.

### N2 — Can a b-tree descent be made to parallelize remotely?

Q4's blocker is that b-tree levels are sequentially dependent while a footer
extent list is not. **Can a SQLite database ship a precomputed extent map** — a
footer, in effect — that lets a remote client fetch the pages a common query
needs in one round trip? That is a materialized view of a page-access pattern,
which puts it in the same family as `prelink` (Q5) and `.gdb_index` (N5), with
the same invalidation problem.

### N3 — Is mutability compatible with remote consumption at all?

[Range-request consumption][range] found the collision: DuckDB attaches
`If-Match` with a strong ETag to every range request and raises on 412
(_"ETag on reading file … changed after it was opened"_). A `self-httpd` that
`INSERT`s a `visits` row per request changes its strong ETag constantly, so a
**correct** client would 412 on every remote query. Axes 4 and remote ranged
access appear mutually exclusive without a snapshot mechanism. Does one exist
that does not amount to serving a different file?

### N4 — Can an artifact describe its own dispatch?

Self-description stops exactly at self-dispatch ([Q9](#q9--what-is-the-least-privilege-decomposition-of-a-self-querying-server)).
A `.self` file carries its schema, segments, symbols and closure, and carries
nothing about what will happen when it is executed — that lives in a volatile,
per-user-namespace registry that does not travel with the file. **Is there a
design in which the artifact's own bytes constrain their own dispatch**, without
handing an attacker a way to demand a particular interpreter?

### N5 — Where should an index live, given that it is a deployment choice?

[Debug info][dwarf] showed that the identical 785,047 bytes of `.gdb_index` can
live inside the artifact, beside it keyed by build-id, or nowhere at all — with
measurably different startup costs. **Index anchoring is a deployment setting far
more often than the four-way taxonomy in [concepts][anchoring] implies.** What is
the decision procedure? The inputs look like: read frequency, write frequency,
whether the artifact is shared, and whether the consumer is remote — which is
exactly the calculation a database administrator makes about an index, and
nobody appears to have written it down for artifacts.

## Sources

Every claim on this page is owned by the deep-dive it is attributed to; those
pages carry the primary sources and pinned citations.

<!-- References -->

[concepts]: ./concepts.md
[tolerance]: ./concepts.md#tolerance-a-partial-order-on-composability
[anchoring]: ./concepts.md#where-does-the-index-live
[shape]: ./comparison.md#the-shape-of-the-space
[thesis5]: ./comparison.md#thesis-5--portability-has-migrated-from-the-format-to-the-access-layer
[zip]: ./zip-parasitism.md
[boot]: ./boot-hybrids.md
[codedb]: ./code-as-database.md
[nix]: ./nix-store-closures.md
[images]: ./image-based-systems.md
[range]: ./range-request-access.md
[ld]: ./dynamic-linking.md
[aff]: ./sqlite-application-file-format.md
[measure]: ./measurement.md
[sls]: ./single-level-store.md
[plan9]: ./plan9-namespaces.md
[provenance]: ./embedded-provenance.md
[threat]: ./threat-model.md
[vfs]: ./sqlite-vfs-substrate.md
[binfmt]: ./binfmt-misc.md
[dwarf]: ./debug-info-and-indexes.md
