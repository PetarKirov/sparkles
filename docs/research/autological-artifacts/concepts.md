# Autological Artifacts — Concepts

The shared vocabulary for the survey. Discussions of self-containing files go
wrong quickly because "self-contained", "portable", "single-binary", and
"self-describing" get used as synonyms for one another, and because "polyglot"
gets applied both to a file that _two_ parsers accept and to a file that _one_
parser accepts _in two ways_. This page assigns each term a narrow meaning, ties
it to a concrete artifact, and defines the four axes and two structural
questions every deep-dive in the tree answers.

**Last reviewed:** August 26, 2026

---

## The name

**Autological** describes a term that is an instance of what it denotes:
_"short"_ is short, _"polysyllabic"_ is polysyllabic, _"English"_ is English. Its
opposite is _heterological_ — _"long"_ is not long — and the pair is the setup
for [Grelling's paradox][grelling], which asks whether _"heterological"_ is
itself heterological.

The word is doing real work here rather than decorating the catalog. The two
seed artifacts differ in almost every respect except this one:

- [redbean][ape] is a file whose own bytes are its archive. The web server
  serves assets by reading the ZIP central directory of the executable that is
  running.
- [SELF][self] is a file whose own bytes are its schema. The executable is a
  SQLite database, and the loader's questions are answered by querying the file
  it is loading.

Neither is merely "self-contained" (a statically linked binary is that, and is
not interesting here). What they share is that the artifact is an instance of
the thing it describes — the archive is the program, the database is the
executable — and that is precisely autology.

> [!NOTE]
> The catalog is deliberately narrower than "interesting file formats". A format
> earns an entry by being **queryable, polyglot, closed over its dependencies,
> or self-mutating** — see [what is out of scope](#what-is-out-of-scope).

---

## The four axes

Every subject in this tree is a point in a four-dimensional space, scored 0–3 on
each axis in that subject's metadata table. The scores are collected in the
[master catalog](./index.md#master-catalog). They are ordinal, not measured:
**0** = absent, **1** = incidental, **2** = designed-in, **3** = defining.

### Multiplicity

**How many formats does one byte stream simultaneously satisfy?**

Multiplicity is a property of the _bytes_, not of the tooling. A file has
multiplicity 3 on this scale when being several formats at once is the reason it
exists — [APE][ape] is PE and ELF and Mach-O and a shell script and, with the
right prologue, an MBR boot sector. A `.docx` scores lower: it is a ZIP, and the
OOXML layer is a convention _inside_ the ZIP rather than a second parse of the
same bytes.

The distinction that matters:

| Term              | Meaning                                                                  | Example                                         |
| ----------------- | ------------------------------------------------------------------------ | ----------------------------------------------- |
| **Polyglot**      | Two _different_ parsers each accept the file, as their own format        | A PoC‖GTFO issue that is a PDF and a ZIP        |
| **Chimera**       | One file, several formats, each in its own region, none overlapping      | An [`isohybrid`][boot] ISO with an MBR in front |
| **Schizophrenic** | One parser accepts it two _different ways_ depending on version or quirk | Android's Master Key APK bugs                   |
| **Container**     | One format, carrying opaque payloads it does not interpret               | A JAR's entries; a [UKI][boot]'s PE sections    |

Only the first three are multiplicity. A container is the _absence_ of
multiplicity purchased with a tax — see [thesis 3](#the-container-is-a-tax).

### Reflexivity

**Can the artifact be interrogated through a general query surface, and can it
interrogate itself while running?**

Two sub-questions, and they come apart:

- _Interrogable._ Is there a general question-asking surface — SQL, Datalog, a
  typed interface graph — as opposed to a fixed menu of tools? `readelf` answers
  the questions `readelf` was written to answer; [`sqlelf`][sqlelf] answers
  questions nobody anticipated.
- _Self-interrogating._ Can the running process ask about _itself_, live? A
  program reading its own build-id out of `/proc/self/exe` scores 1 here; a
  server whose request handlers are rows in the database it is executing from
  scores 3.

### Closure

**Does the artifact carry its transitive dependencies?**

Closure is what separates "a binary" from "a thing you can `scp` somewhere and
run". It is also the axis with the sharpest cost: carrying dependencies
duplicates them, and the whole [dedup literature](./content-addressed-chunking.md)
exists to make the duplication cheap again. [Nix][nix] computes a closure and
_shares_ it; AppImage computes a closure and _copies_ it; SELF computes a closure
and stores it as rows.

> The word is borrowed from Nix, where a **closure** is the transitive set of
> store paths a derivation references. It is the set-theoretic sense — closed
> under the "references" relation — not the programming-language sense of a
> function capturing its environment.

### Mutability

**Is the artifact also its own state store, transactionally?**

The interesting form is not "the program can write files" but "the program's own
image is the durable state, and updating it is a transaction". `self-httpd`
`INSERT`s a row into a `visits` table inside the file it is executing from;
redbean's `StoreAsset` writes an asset back into its own ZIP, and requires the
explicit `-*` flag to do so, precisely because that is a W^X violation with a
respectable pedigree. Smalltalk images and Emacs `pdumper` are the ancestors.

Mutability is where the axes stop being independent of the substrate: a mutable
artifact cannot be verified by a signature over its whole bytes, which is
[the signing problem](./embedded-provenance.md) the catalog has no good answer
to yet.

---

## The two structural questions

The axes describe _what an artifact is_. These two describe _how it works_, and
they turn out to predict composability better than any taxonomy of formats.

### Where does the index live?

Every format that supports random access has an index, and the index has to be
findable before anything else can be. There are exactly four answers in
practice, and each deep-dive's metadata table names one:

| Anchoring          | How the index is found                                 | Consequence                                                                   |
| ------------------ | ------------------------------------------------------ | ----------------------------------------------------------------------------- |
| **Header**         | At, or at a fixed offset from, byte 0                  | Byte 0 is spoken for; a prefix is impossible without a hole                   |
| **Footer**         | Located by scanning backwards from EOF for a signature | The front of the file is free — **this is what makes suffix-parasitism work** |
| **Stream-scanned** | No index; the reader walks records from the start      | Random access costs a full scan; append is trivial                            |
| **Out-of-band**    | In a different file entirely                           | The artifact does not know its own index; the index can go stale              |

ELF and PE are header-anchored. ZIP, [Parquet, ORC, and the seekable-`zstd`
family](./footer-indexed-formats.md) are footer-anchored. `tar` and raw `gzip`
are stream-scanned. `/etc/ld.so.cache`, `debuginfod`, and `tabix` are
out-of-band — and note that an out-of-band index is a **materialized view**,
with all the staleness properties that implies.

### Who decides what the file is?

Multiplicity is inert until something acts on it. **Dispatch** is the mechanism
that turns superposition into behavior, and it has four owners:

| Dispatcher       | Mechanism                                                      | Deep-dive                             |
| ---------------- | -------------------------------------------------------------- | ------------------------------------- |
| **The kernel**   | `binfmt_misc` magic+mask+offset; `binfmt_elf`; `binfmt_script` | [binfmt_misc][binfmt]                 |
| **The shell**    | Shebang, and the `ENOEXEC` fallback to `sh(1)`                 | [binfmt_misc][binfmt], [APE][ape]     |
| **The loader**   | `DT_NEEDED`, `RUNPATH`, `LD_PRELOAD`, symbol interposition     | [dynamic linking][ld]                 |
| **The consumer** | Content sniffing, extension, declared MIME type                | [parser differentials][differentials] |

The catalog's recurring failure mode — and the whole of
[the adversarial cluster][differentials] — is **two dispatchers disagreeing about
one byte stream**.

---

## Tolerance: a partial order on composability

The two structural questions combine into the property that actually predicts
which formats compose. A format is:

- **Prefix-tolerant** — legal to place arbitrary bytes _before_ it. Requires a
  footer-anchored index (ZIP) or a scanned entry point (PDF's `%PDF-` header is
  conventionally at 0, but readers accept a leading offset and use the
  `startxref` footer).
- **Suffix-tolerant** — legal to place arbitrary bytes _after_ it. Requires a
  header-anchored index that records its own extent (ELF, PE), so a reader knows
  where the format stops and never looks further.
- **Hole-tolerant** — reserves an unused region a foreign format may occupy.
  ISO 9660's first 32 KiB, before its volume descriptors, is the canonical case,
  and it is why an ISO can carry an MBR without either format bending.
- **Neither** — the format claims byte 0 _and_ runs to EOF with no self-declared
  extent.

**A composition is possible when one participant is prefix-tolerant and the
other is suffix-tolerant** (or when one is hole-tolerant and the other fits the
hole). That single rule generates the entire ZIP-suffixed ecosystem — JAR, APK,
`.docx`, EPUB, `.whl`, self-extracting archives — from one structural fact, and
it predicts rather than merely catalogues. [ZIP parasitism][zip] develops the
argument and tests it against a table of formats.

---

## Terms used throughout

**Assimilation** — collapsing a superposition into one native format, discarding
the others. [`--assimilate`][ape] is APE's; it is a one-way operation and the
honest admission that superposition has a runtime cost.

**Content addressing** — naming a blob by the hash of its bytes, so identical
content is stored once. The basis of [Nix][nix], OCI layers, Git objects, and
[casync/desync chunking](./content-addressed-chunking.md).

**Interposition** — a symbol definition earlier in the loader's search scope
shadowing a later one. `LD_PRELOAD` is interposition made available to users;
SELF's claim is that it is more honestly modelled as a row. See
[the runnable demonstration](./self-selfdb/examples/relocation-join.d).

**Materialized view** — a precomputed answer stored alongside (or instead of)
the data it derives from, trading staleness for lookup cost. `ldconfig`'s cache,
`prelink`'s resolved addresses, `.gdb_index`, and `eStargz`'s TOC are all
materialized views, and each one's failure mode is the same: the source moved
and the view did not.

**Page sharing** — two processes running the same image mapping the same
physical pages, because both `mmap` the same file at the same alignment. The
property SELF currently loses, and [the sharpest open question][open] in the
catalog.

**Self-describing** — carrying the schema needed to interpret the payload, _in_
the payload. SQLite carries `sqlite_schema`; ELF carries a section table but not
a schema (nothing in an ELF file says what `.gnu.hash` means). This is
[thesis 2](#self-description-is-what-makes-a-format-survivable).

**Suffix parasitism** — appending a complete, self-locating format to an
unrelated host file so both parse. Named for the direction that actually occurs
in practice; ZIP is the overwhelmingly dominant parasite. See [ZIP
parasitism][zip].

---

## The five cross-cutting theses

Stated here as definitions; each is defended, complicated, or killed in
[comparison.md][comparison] using evidence gathered across the deep-dives.

### Every binary format eventually reimplements a database, badly

ELF's `.gnu.hash` is a hand-rolled bloom filter, `.strtab` is string interning,
and `st_name` is a foreign key maintained by hand with no referential integrity.
The claim is that this is _general_, and it is tested outside ELF — against
Mach-O, PE, Wasm, Parquet, and PDF's `xref` table.

### Self-description is what makes a format survivable

SQLite's stability is attributed to carrying its own schema; formats without one
accrete conventions instead. The test is whether long-lived schema-less formats
(`tar`, ELF) are in fact _less_ survivable, or merely differently so.

### The container is a tax

redbean needs ZIP; SELF needs nothing, because the database is the container.
The general form: which systems pay a container tax that a self-describing store
would eliminate?

### `mmap` is the load-bearing constraint

Every "the executable is X" proposal will be judged on whether it preserves
demand paging and cross-process sharing. See
[image-based systems](./image-based-systems.md) and
[the SELF deep-dive](./self-selfdb/index.md).

### Portability has migrated from the format to the access layer

[APE][ape] achieves reach by satisfying every loader's parse at once — enormous
cleverness spent at the format level. SQLite achieves comparable reach by
holding one format fixed and swapping the substrate beneath it
([the VFS][vfs]). If this holds, redbean is the last great artifact of the old
strategy and SELF an early one of the new.

---

## What is out of scope

Deliberately excluded, so the catalog stays about _autology_ rather than about
file formats in general:

- **General single-binary packaging** — PyInstaller, `deno compile`, `bun build
--compile`, GraalVM `native-image` — unless the artifact is queryable or
  polyglot. Otherwise it is static linking with a self-extractor, and
  [`docs/research/application-packaging/`][packaging] already owns that ground.
- **Container image formats generally**, except where the _index structure_ is
  the point ([eStargz, `zstd:chunked`](./content-addressed-chunking.md)).
- **Embedded interpreters as such.** redbean's Lua matters only because it is
  the thing SELF replaces with a `handlers` table.
- **Distribution, signing infrastructure, and update channels**, which are
  [application-packaging][packaging]'s subject. This tree cares about what is
  _inside_ the artifact; that one cares about how it reaches a machine.

## Sources

- [Grelling–Nelson paradox][grelling] — the autological/heterological distinction
- [SQLite file format][sqlite-format] — the 100-byte header, `application_id` at offset 68
- [PKWARE `.ZIP` File Format Specification][appnote] — the End Of Central Directory record
- [`ld.so(8)`][ldso-man] — search order, `LD_PRELOAD`, interposition
- [Nix manual — closures][nix-closure] — the transitive-reference sense of "closure"

<!-- References -->

[grelling]: https://en.wikipedia.org/wiki/Grelling%E2%80%93Nelson_paradox
[sqlite-format]: https://sqlite.org/fileformat2.html
[appnote]: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
[ldso-man]: https://man7.org/linux/man-pages/man8/ld.so.8.html
[nix-closure]: https://nix.dev/manual/nix/2.24/glossary.html
[ape]: ./cosmopolitan-ape/index.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[zip]: ./zip-parasitism.md
[boot]: ./boot-hybrids.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[differentials]: ./parser-differentials.md
[nix]: ./nix-store-closures.md
[vfs]: ./sqlite-vfs-substrate.md
[open]: ./open-questions.md
[comparison]: ./comparison.md
[packaging]: ../application-packaging/index.md
