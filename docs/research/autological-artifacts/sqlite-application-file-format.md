# SQLite as an application file format (format · design position)

The design position [SELF][self] is a maximal instance of, argued explicitly by its authors: stop writing a bespoke file format, and make the application's document a database that carries its own schema. Two SQLite whitepapers state the case; Fossil is the existence proof; Git's packfile plus `.idx` is the control group.

| Field           | Value                                                                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | File format + an argued design position (two SQLite whitepapers) + its shipped instances                                                                                     |
| Language        | C (the reference implementation, ANSI C); the artifact itself is language-neutral                                                                                            |
| License         | Public domain (SQLite); Fossil is 2-clause BSD ([`COPYRIGHT-BSD2.txt`][fossil-license])                                                                                      |
| Repository      | [sqlite/sqlite][sqlite-repo] (GitHub mirror of the canonical Fossil repository) · [fossil-scm.org][fossil-src]                                                               |
| Documentation   | [SQLite As An Application File Format][appfileformat] (the whitepaper) · [Benefits of SQLite As A File Format][aff-short] (the summary) · [Database File Format][fileformat] |
| First release   | SQLite 3.0.0, 2004-06-18 — the format has been backwards compatible ever since; the `application_id` field and its `PRAGMA` are later additions                              |
| Axis profile    | Multiplicity **1** / Reflexivity **3** / Closure **2** / Mutability **3**                                                                                                    |
| Index anchoring | **header** — a 100-byte header at offset 0; page 1 is the root of `sqlite_schema`, which names the root page of every other b-tree                                           |
| Dispatch owner  | **consumer** — the 16-byte magic string plus `application_id` at offset 68, read by `file(1)` and by the application itself                                                  |

> **Latest release / revision surveyed:** SQLite trunk [`8a988271`][sqlite-repo] (2026-08-26), `VERSION` = `3.54.0` · Fossil check-in [`b8c7665e`][fossil-checkin] (2026-08-24) · `git/git` [`f78ce2f7`][git-repo] (2026-08-25). **Platform:** any platform with an 8-bit byte, two's-complement 32- and 64-bit integers, and a C compiler; the _file_ is byte-identical across word size and endianness.

> [!NOTE]
> This page is about the **format as a design position**, not about SQLite the engine. The engine's swappable access layer — the property that lets the same bytes be read from a Unix file, an HTTP range request, or a browser's OPFS — is [the VFS as substrate][vfs]. The specific case of making an _executable_ out of this format is [SELF/selfdb][self]. The umbrella is [Autological Artifacts][index].

---

## Overview

### What it solves

An application that persists more than one kind of object has to invent a way to write it down, and [the whitepaper][appfileformat] observes that the industry has produced only three answers, all of which it names and criticises:

| Category                  | Examples given                                  | The complaint                                                                                                                                    |
| ------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Fully custom format**   | `DOC`, `DXF`, `PDF`, `XLS`, `PPT`               | "usually 'opaque blobs'"; needs a tool engineered for that format; the spec "typically runs on for hundreds of pages"                            |
| **Pile-of-files**         | **Git**, and "one-off and bespoke applications" | uses the filesystem as a key/value database; breaks "the document metaphor"; hard to move or attach                                              |
| **Wrapped pile-of-files** | `EPUB`, `ODT`, `ODP`                            | preserves the document metaphor by paying for a ZIP container; "usually the entire file must be rewritten in order to change any component part" |

The paper's whole purpose is to "argue in favor of a fourth new category of application file format: An SQLite database file." Two of its incidental observations matter to this catalog more than the argument does.

First, it identifies Git by name as the canonical pile-of-files, and it identifies exactly the part that fails the accessibility claim: _"even if many of the files in a pile-of-files format are easily readable, there are usually some files that have their own custom format (example: Git 'Packfiles') and are hence 'opaque blobs' that are not readable or writable without specialized tools."_ [The packfile analysis below](#the-control-group-the-git-packfile-and-its-index) takes that seriously and checks whether it is fair.

Second, it gives the minimal reduction that makes the comparison concrete — any pile-of-files is a two-column table:

```sql
CREATE TABLE files(filename TEXT PRIMARY KEY, content BLOB);
```

and reports that a compressed archive built on exactly that schema is _"the same size (±1%) as an equivalent ZIP archive, and it has the advantage of being able to update individual 'files' without rewriting the entire document."_ That is the [SQLite Archive][sqlar] format, and the measured instance is the SQLite 3.22.0 source tree, 1,743 files: **10,754,048 bytes** as a `sqlar` against **10,662,365 bytes** as an Info-ZIP archive — **0.86% larger**. Read against [ZIP parasitism][zip], this is thesis 3 with a price tag: the container tax that redbean pays to ZIP is under one percent, and what it buys back is a schema, transactions and a query language.

### Design philosophy

The two whitepapers are the cleanest existing statement of this catalog's theses 2 and 3, and they state them as engineering advice rather than as claims about formats in general. The [summary page][aff-short], under "Accessibility":

> _"Content stored in an SQLite database is more likely to be recoverable decades in the future, long after all traces of the original application have been lost. **Data lives longer than code.**"_

The [long-form paper][appfileformat] makes the self-description argument explicitly, and it is thesis 2 in one sentence:

> _"If the application file format is an SQLite database, the complete documentation for that file format consists of the database schema, with perhaps a few extra words about what each table and column represents. The description of a custom file format, on the other hand, typically runs on for hundreds of pages."_

and then leans on three authorities who all say the same thing about representation — Fred Brooks (_"Show me your flowcharts and conceal your tables, and I shall continue to be mystified. Show me your tables, and I won't usually need your flowcharts; they'll be obvious"_), Rob Pike (_"Data dominates"_), and, pointedly, Linus Torvalds on the Git mailing list, 2006-06-27:

> _"Bad programmers worry about the code. Good programmers worry about data structures and their relationships."_

The container-tax argument is stated as a comparison rather than a slogan, and its force is that it is about _cost_, not elegance:

> _"The power of an SQLite database could, in theory, be achieved using a custom file format. But any custom file format that is as expressive as a relational database would likely require an enormous design specification and many tens or hundreds of thousands of lines of code to implement. And the end result would be an 'opaque blob' that is inaccessible without specialized tools."_

The commitment behind the durability claim is separately documented and unusually concrete. [Long Term Support][lts] states the intent to support SQLite "through the year 2050", and the promise that matters here is about bytes rather than code: _"the developers also promise to keep the SQLite C-language API and on-disk format fully backwards compatible … Our goal is to make the content you store in SQLite today as easily accessible to your grandchildren as it is to you."_ [File Format Changes][formatchng] gives the operative rule: newer SQLite can always read and write files back to 3.0.0 (2004-06-18); older SQLite can read newer files _unless_ they use a feature it does not know — with WAL mode, added in 3.7.0 (2010-07-21), as the named forward-compatibility break.

---

## How it works

### The 100-byte header

The [file format documentation][fileformat] is normative and the same layout is repeated as a comment in [`src/btreeInt.h`][btreeint] — a useful cross-check, since the comment is what the implementation was written against. The fields this catalog cares about:

| Offset | Size | Field                                                                                  |
| -----: | ---: | -------------------------------------------------------------------------------------- |
|      0 |   16 | The header string `SQLite format 3\000` — the only fixed magic                         |
|     16 |    2 | **Page size**, big-endian; a power of two in 512…32768, or the value `1` meaning 65536 |
|     18 |    1 | File format **write** version — `1` for rollback journalling, `2` for WAL              |
|     19 |    1 | File format **read** version — same encoding                                           |
|     20 |    1 | **Reserved** bytes at the end of each page. "Usually 0."                               |
|     24 |    4 | File change counter                                                                    |
|     28 |    4 | The **in-header database size**, in pages                                              |
|     32 |    4 | Page number of the first freelist trunk page                                           |
|     36 |    4 | Total number of freelist pages                                                         |
|     40 |    4 | The schema cookie                                                                      |
|     56 |    4 | Text encoding — `1` UTF-8, `2` UTF-16le, `3` UTF-16be                                  |
|     60 |    4 | **`user_version`**, as read and set by `PRAGMA user_version`                           |
|     68 |    4 | **`application_id`**, as set by `PRAGMA application_id`                                |
|     92 |    4 | Version-valid-for number                                                               |
|     96 |    4 | `SQLITE_VERSION_NUMBER` of the library that last wrote                                 |

Three consequences are structural rather than incidental. The page size is fixed for the whole file and is bounded above at 65536 and below at 512; the **usable size** of a page is the page size less the reserved bytes at offset 20, and _"the usable size is not allowed to be less than 480"_, which caps reserved space at 32 bytes on a 512-byte page and at 255 anywhere (the field is one byte). And offsets 21–23 — the payload fractions — _"must be"_ 64, 32 and 32; the documentation records that they "were originally intended to be tunable parameters" and that the tunability "is not supported and there are no current plans to add support in the future". A format with three dead bytes it refuses to reuse is a format that takes forward compatibility seriously.

[`examples/sqlite-header-probe.d`](./self-selfdb/examples/sqlite-header-probe.d) decodes this header from real databases and from a synthesized SELF one, which is the cheapest way to see that `application_id`, `page_size` and the reserved-bytes field are all exactly where the specification says.

### Pages, b-trees, and the freelist

_"The main database file consists of one or more pages"_, all the same size, numbered from 1, with a maximum page number of 4294967294 — so the format's own ceiling is about 281 TB, which it notes is "usually" beyond the filesystem's. Every page has exactly one use at any instant: a b-tree page (table or index, interior or leaf), a freelist trunk or leaf page, a payload overflow page, a pointer-map page, or the lock-byte page. Reads and writes are whole pages, _"with the one exception that when the database is first opened, the first 100 bytes of the database file … are read as a sub-page size unit."_

A b-tree page is a fixed sequence of regions: the 100-byte file header (page 1 only), an 8-byte (leaf) or 12-byte (interior) page header, the cell-pointer array, unallocated space, the cell content area growing down from the end, and the reserved region. Table b-trees key on a 64-bit signed integer (the rowid) and store all data in leaves; index b-trees carry an arbitrary key and no data. When a cell's payload exceeds the page's capacity the surplus spills to a linked list of overflow pages — **the fact that decides whether a large BLOB in this format can ever be mapped**, and the reason the [SELF page-sharing analysis][self-mmap] concludes it cannot.

The freelist is the format's answer to deletion, and it is a linked list, not a bitmap: each trunk page is an array of 4-byte big-endian integers whose first entry is the next trunk and whose second is the count of leaf pointers that follow. Freelist leaf pages _"contain no information"_ and SQLite "avoids reading or writing" them, so a deletion costs page-header writes rather than data writes. One detail is a small monument to the compatibility promise: a bug in versions before 3.6.0 (2008-07-16) mis-reported corruption when the last six trunk entries were non-zero, and _"newer versions of SQLite still avoid using the last six entries in the freelist trunk page array in order that database files created by newer versions of SQLite can be read by older versions."_ The format gives up six pointers per trunk page, forever, to keep 2008 readers working.

### `sqlite_schema` — the self-description

Page 1 is always the root of a table b-tree named `sqlite_schema`, and the format documentation gives its shape as if it were declared:

```sql
CREATE TABLE sqlite_schema(
  type text,
  name text,
  tbl_name text,
  rootpage integer,
  sql text
);
```

One row per table, index, view and trigger; `rootpage` is the page number where that object's b-tree begins; `sql` is the normalized `CREATE` statement that would recreate the object. There is no row for `sqlite_schema` itself — its root page is a constant, which is the base case that stops the recursion.

This is the whole of thesis 2 in one table. A reader that knows the 100-byte header and the b-tree page layout can recover _the schema_ from the file, and from the schema it can recover the meaning of everything else. Compare ELF, which has a section header table but nothing that says what a section _means_; nothing in an ELF file explains `.gnu.hash`, and the knowledge lives in [binary inspection libraries][bin-inspect] and in the reader's head. The contrast is the reason [`sqlelf`][sqlelf] had to be written, and why [SELF][self] gets its equivalent for free.

### Identification: `application_id`, `user_version`, and a registry that is a text file

`PRAGMA application_id = INTEGER` writes a signed 32-bit integer big-endian into offset 68; `PRAGMA user_version` does the same at offset 60. SQLite never interprets either. Their purpose is dispatch by the consumer, and the registry is [`magic.txt`][magic] in the SQLite source tree — a `magic(5)` fragment for `file(1)`:

```text
0    string  =SQLite\ format\ 3
>68  belong  =0x0f055112  Fossil checkout -
>68  belong  =0x0f055113  Fossil global configuration -
>68  belong  =0x0f055111  Fossil repository -
>68  belong  =0x47504b47  OGC GeoPackage file -
>68  belong  =0x4d504258  MBTiles tileset -
>60  belong  =0x5f4d544e  Monotone source repository -
```

Two things are worth reading off it. The Fossil identifiers are `0x0f055111`/`112`/`113` — "FOSSIL" spelled in hex, one per database _role_ rather than one per application, which is the discrimination SELF's converter and closure packer notably fail to make. And the Monotone line is at **offset 60**, not 68: the file's own comment records that _"The Monotone application used `PRAGMA user_version=1598903374;` to set its identifier long before `PRAGMA application_id` became available"_, and the rule survives "for historical compatibility only". A format that grew an identification field late, and then kept honouring the field applications had abused in its absence, is a small case study in the accretion of conventions that thesis 2 says schema-less formats suffer — with the difference that here the convention was absorbed _into_ the spec.

Dispatch on this pair is what [`binfmt_misc`][binfmt] turns into execution, and it is the only reason a database can be a program at all; the mechanism is developed there and in [SELF][self].

### Durability: rollback journal, WAL, and the asterisk on "one file"

The sales pitch is "single-file documents", and the canonical page says so with a footnote it does not hide: _"A database in SQLite is a single disk file¹"_ — footnote one being _"Temporary journal files are created as part of transaction control, but those extra files are not part of the steady-state database"_ ([Single-file Cross-platform Database][onefile]).

That footnote is doing real work, and the two journalling modes differ in exactly how much:

| Mode                    | Sidecar files while a transaction or connection is live | Steady state                 | Header bytes 18/19 |
| ----------------------- | ------------------------------------------------------- | ---------------------------- | ------------------ |
| Rollback journal        | `NAME-journal`, written then deleted at commit          | **one file**                 | `1`                |
| WAL (3.7.0, 2010-07-21) | `NAME-wal` **and** `NAME-shm`, quasi-persistent         | one file _after clean close_ | `2`                |

The [WAL documentation][wal] lists the consequence in its own disadvantages section, and the wording is unusually direct about what it costs this design position:

> _"There is an additional quasi-persistent '-wal' file and '-shm' shared memory file associated with each database, which can make SQLite less appealing for use as an application file-format."_

The rest of that list is the honest fine print for anyone shipping a document format: WAL _"does not work over a network filesystem"_, because the wal-index lives in shared memory and _"processes on separate host machines obviously cannot share memory"_; the page size cannot be changed once in WAL mode; and until 3.22.0 (2018-01-22) a WAL-mode database could not be opened read-only at all, because the opener needs write access to `-shm`. So the artifact is transiently three files, and the property "you can `scp` the document" is true of a _cleanly closed_ database and false of a live one. [SELF's `self-httpd` example][self] makes this a runtime flag and measures both arms — WAL is roughly 3× faster per request and leaves two sidecars next to the executable for as long as it is serving. That is the single-file property being traded for throughput, at the access layer rather than in the format, which is [thesis 5][concepts] visible in a two-row benchmark table.

### The control group: the Git packfile and its index

Git is the paper's named counter-example, so it deserves to be read rather than paraphrased. A packfile ([`gitformat-pack`][gitformat-pack]) is a four-byte `PACK` signature, a version, an object count, then a sequence of entries — each a variable-length type-and-length header followed by zlib-compressed data, or, for `OBJ_OFS_DELTA`/`OBJ_REF_DELTA`, a base reference followed by a compressed delta — and a trailing checksum. There is no index inside it. Random access comes from a sidecar `.idx`, whose v2 layout is:

- a 4-byte magic `\377tOc` chosen because it is "an unreasonable `fanout[0]` value" — i.e. version detection by making the old format's first field impossible;
- a **256-entry fan-out table**, `fanout[N]` being the number of objects whose first name byte is ≤ N;
- a table of sorted object names, deliberately _"packed together without offset values to reduce the cache footprint of the binary search"_;
- a table of 4-byte CRC32 values, _"new in v2 so compressed data can be copied directly from pack to pack during repacking without undetected data corruption"_;
- a table of 4-byte offsets, with a 31-bit limit and an escape into a second table of 8-byte offsets;
- the pack checksum and an index checksum.

Read as a database, that is a clustered store with a hand-rolled one-byte hash bucket index, a per-row checksum column, and a manually managed 32-to-64-bit column widening. And it did not stop there. The synopsis of the same man page lists `pack-*.pack`, `pack-*.idx`, `pack-*.rev`, `pack-*.mtimes` and `multi-pack-index`; the `.rev` file is _"a table of index positions … sorted by their corresponding offsets in the packfile"_ — a **secondary index in a different sort order**, i.e. the thing you add when one clustering is not enough. Alongside them: reachability `.bitmap` files, and `commit-graph`, described in its own design notes as _"a supplemental data structure that accelerates commit graph walks"_ whose absence is harmless because _"the existing object database is sufficient"_ — the textbook definition of a [materialized view][concepts].

Two of these have gone further and produced _general_ machinery. [`gitformat-chunk`][gitformat-chunk] factors out a reusable container: a header, then a table of contents of `(4-byte chunk ID, 8-byte offset)` rows terminated by four zero bytes, with the chunks stored contiguously in TOC order — a columnar file layout with a footer-style directory, shared by `commit-graph` and the multi-pack index. And [`reftable`][reftable] replaces `packed-refs` with _"a portable binary file format customized for reference storage"_ using sorted records, "variable sized blocks", "prefix compression … within a single block", binary search, and writer-tunable block size and alignment. That is an SSTable, written from scratch, with a stated objective list — near-constant-time single-key lookup on a cold cache, efficient prefix range scans, atomic multi-key updates in `O(size_of_update)` — that reads as the requirements section of a key-value store.

So the paper's charge lands, and this catalog's [thesis 1][concepts] lands with it: Git's object store has, over twenty years, grown a hash index, a secondary index, per-row checksums, reachability bitmaps, a materialized graph view, a generic chunked-column container, and an SSTable. Each was justified individually; collectively they are a database, assembled by hand.

> [!IMPORTANT]
> **Being fair to Git.** The packfile is not an index-free format because nobody thought of indexes. It is a **wire format** that happens to also be the on-disk format, and the trade is on the record in the tree, in Linus Torvalds' 2006-02-10 IRC explanation preserved at [`Documentation/technical/pack-heuristics.adoc`][pack-heuristics]:
>
> > _"Anyway, the pack-file could easily be denser still, but because it's used both for streaming (the Git protocol) and for on-disk, it has a few pessimizations."_
> >
> > _"In particular, while the pack-file is then compressed, it's compressed just one object at a time, so the actual compression factor is less than it could be in theory. But it means that it's all nice random-access with a simple index to do `object name->location in packfile` translation."_
>
> Three properties follow from that choice and none of them are available from a b-tree file. A packfile can be **generated and consumed as a stream**, so `git fetch` writes bytes to a socket that the receiver indexes on arrival, and the same bytes are a [bundle][gitformat-pack]. **Delta chains against arbitrary bases** compress a version history far below per-object compression, which is the entire economics of cloning a large repository. And Git in 2005 took **no storage dependency beyond `zlib` and the filesystem** — no embedded database, no b-tree library, nothing to vendor. A SQLite-backed Git would have had to invent a streaming representation anyway — which is precisely what Fossil did, in [a sync protocol][fossil-sync] that is a separate wire format from its storage, and [the next section](#fossil-the-existence-proof) shows the shape it took.

### Fossil: the existence proof

[Fossil][fossil-src] is the strongest available answer to "does anyone actually do this at scale": a distributed version control system whose repository — history, tickets, wiki, forum, chat, and the web UI's own configuration — is one SQLite database file. Its [technical overview][fossil-tech] states the position plainly:

> _"Fossil stores state information in SQLite database files. SQLite keeps an entire relational database, including multiple tables and indices, in a single disk file. … SQLite updates are atomic, so even in the event of a system crashes or power failure the repository content is protected."_

There are three database _classes_, not one — a per-user configuration database, a per-project repository, and a per-checkout database — opened on one connection with `ATTACH`, and each stamped with its own identifier: `252006673` = `0x0f055111` for the repository, `252006674` for the checkout, `252006675` for the global configuration, set in [`src/schema.c`][fossil-schema] with the comment _"The application ID helps the unix 'file' command to identify the database as a fossil repository."_

The repository schema is 25 `CREATE TABLE` and 14 `CREATE INDEX` statements. The two tables that hold the project are:

```sql
CREATE TABLE blob(
  rid INTEGER PRIMARY KEY,        -- Record ID
  rcvid INTEGER,                  -- Origin of this record
  size INTEGER,                   -- Size of content. -1 for a phantom.
  uuid TEXT UNIQUE NOT NULL,      -- hash of the content
  content BLOB,                   -- Compressed content of this record
  CHECK( length(uuid)>=40 AND rid>0 )
);
CREATE TABLE delta(
  rid INTEGER PRIMARY KEY,                 -- BLOB that is delta-compressed
  srcid INTEGER NOT NULL REFERENCES blob   -- Baseline for delta-compression
);
```

This is worth staring at, because it is the packfile — content-addressed by `uuid`, zlib-compressed, chained deltas — expressed as two tables with a foreign key and a `CHECK` constraint. Fossil did not give up delta compression or content addressing to use a database; it gave up hand-writing the index. The comment above the tables says exactly which half is the enduring artifact: _"The blob and delta tables collectively hold the 'global state' of a Fossil repository."_

The other twenty-eight tables are the sharpest structural point on this page. Fossil's schema is split into `zRepositorySchema1`, _"parts of the schema that are fixed and unchanging across versions"_, and `zRepositorySchema2`, _"parts of the schema that can change from one version to the next"_, and the source comment states the relationship: _"The information in Schema2[] is reconstructed from the information in Schema1[] by the 'rebuild' operation."_ Tables like `mlink` (which check-in changed which file from which parent version), `plink`, `leaf`, `event` and `tagxref` are **materialized views over the blob store**, derived by parsing the manifest artifacts and re-insertable at any time by `fossil rebuild`. The archival format is the artifact text documented in [`fileformat.wiki`][fossil-fileformat]; SQLite is the _storage and index_ layer over it, and Fossil is explicit that the two are different documents.

That distinction is the most transferable idea here, and it is the answer to the obvious objection that betting an archive on a b-tree is reckless: **Fossil does not**. The enduring state is a set of hash-named immutable artifacts; the database is a query accelerator that can be thrown away and rebuilt. What the database buys is the questions. [Fossil versus Git][fossil-v-git] gives the canonical example, and it is a query-planning argument, not an ergonomics one:

> _"One notable example is that it is difficult to find the descendants of check-ins in Git. One can easily locate the ancestors of a particular Git check-in by following the pointers embedded in the check-in object, but going the other direction is difficult enough that neither native Git nor the big 'forge' facilities like GitHub and GitLab provide this capability short of crawling the commit log. In Fossil, we can find descendants using a simple SQL query."_

A parent pointer is a foreign key with an index on only one side. Git's answer to the missing reverse index was `commit-graph` — a second file, out of band, that can go stale. Fossil's answer was `CREATE INDEX`.

### What the artifact gets, and what it pays

The whole page reduces to two ledgers. What an artifact **gets**, purely by being a SQLite database:

| Gets                             | Concretely                                                                                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **A schema, in the file**        | `sqlite_schema` holds the `CREATE` text of every object; `.schema` is the format specification, and it travels with the document                 |
| **Transactions**                 | Atomic, durable commit and rollback across an arbitrary set of changes; a crash mid-write leaves the previous state, not a truncated file        |
| **A query language**             | SQL against any table, plus indexes, views, triggers, recursive CTEs, FTS5 and R-Tree — questions nobody anticipated at design time              |
| **A stable, portable format**    | Bit-identical across word size and endianness; backwards compatible to 2004-06-18 with an explicit promise through 2050                          |
| **Incremental update**           | Only changed pages are written; a one-byte edit is a page write, not a document rewrite — the property `EPUB` and `ODT` structurally cannot have |
| **Every VFS SQLite has**         | The same bytes read from a Unix file, an HTTP range request, OPFS in a browser, or memory, with no format work — [the substrate seam][vfs]       |
| **Tooling nobody wrote for you** | `sqlite3`, `sqldiff`, `sqlite3_analyzer`, `.recover`, `.dump`, `VACUUM INTO`, Datasette, and a binding in every language                         |
| **Multi-process access**         | Reader/writer coordination and locking, correct by default, in a place notorious for application bugs                                            |

And what it **pays**:

| Pays                                     | Concretely                                                                                                                                                                   |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **B-tree overhead**                      | Page headers, cell pointer arrays, unallocated slack, freelist pages, index b-trees; ~1% over ZIP for an archive, 2–3.5× for a small [SELF][self] binary                     |
| **No mapped, shared payload**            | A row's bytes are cells and overflow-page runs, never a page-aligned contiguous extent; `mmap` gets you _pages_, not _objects_ — [see below](#mutability-dispatch-and-trust) |
| **`VACUUM` rewrites the file**           | Copies into a temporary database and overwrites the original; needs 2× free space, may change rowids, and destroys any byte-level signature or trailer                       |
| **The one-file property is conditional** | WAL leaves `-wal` and `-shm` beside the document for as long as a connection is open                                                                                         |
| **Not greppable**                        | The paper concedes it: `grep` and `awk` are useless on the file, and argues SQL is a better trade                                                                            |
| **A library dependency**                 | One C file, but a dependency — the thing Git deliberately did not take in 2005                                                                                               |
| **The schema is executable**             | A hostile document's schema can name functions and virtual tables; see [trust](#mutability-dispatch-and-trust)                                                               |

---

## Format identity and multiplicity

**Multiplicity = 1.** One byte stream, one grammar, and that is the design's whole point.

A SQLite database claims byte 0 with a 16-byte magic string, and its extent is `page_size × N` where `N` is the in-header page count at offset 28. It is therefore **neither prefix-tolerant nor suffix-tolerant** in [the sense this catalog defines][concepts]: nothing may precede it, and while trailing bytes are physically ignorable — the documentation makes the in-header size authoritative whenever the change counter at offset 24 matches the version-valid-for number at offset 92 — any tool that round-trips the database (`VACUUM`, the backup API, `.dump`, `VACUUM INTO`) drops them. There is a hole-tolerance story of a kind, the per-page reserved region at offset 20, but it is a per-page _tail_ of at most 255 bytes designed to hold a nonce or checksum for the encryption extension, not a region a second format could occupy.

So this format cannot be a polyglot host and cannot be a polyglot parasite. What it has instead is a **second identity within one parse**: `application_id` at offset 68 tells a consumer _which application's document this is_ without changing what the bytes are. `file(1)` reports "SQLite 3.x database, application id 0x0f055111" and both halves of that sentence are simultaneously true, because the second half is a field the first half's specification reserved for the purpose. That is identity by declaration rather than by [ambiguity][differentials] — the opposite technique from every entry in the polyglot cluster, and it is why this format has no interesting parser-differential surface: there is exactly one parser, aggressively fuzzed, with a documented policy that any crash on a malformed database is _"a serious bug"_.

The trade is stated by the paper without spin: an SQLite document is _"not as compact"_ as a ZIP or tarball, "is not an opaque blob" but is also not readable by `grep`, and needs a library. Reach is bought by holding one format fixed rather than by satisfying several — which is [thesis 5][concepts] stated as a design choice rather than as a historical observation.

---

## Index anchoring and random access

**Header-anchored, and then a tree.** The 100-byte header at offset 0 names the page size and the root of the schema; `sqlite_schema` on page 1 names the root page of every other b-tree; each b-tree is descended in `O(log n)` page reads. This is the third distinct answer to the catalog's anchoring question: not a contiguous directory you seek to (as in [footer-indexed formats][footer]), and not a sidecar (as in Git), but a _rooted tree_ whose entry point is at a fixed offset.

The practical differences from a footer index are worth being precise about.

- **The smallest useful read is a page, and the number of pages is `O(log n)`.** Opening a database costs the 100-byte header plus page 1; answering a point query costs the depth of one b-tree. A footer-indexed format costs one seek plus a read of the entire directory before it can answer anything — cheap for a JAR, expensive for a 200 MB Parquet footer.
- **Random access does not require the whole index to be well-formed.** A corrupt page below a healthy root still yields the rest of the tree, which is what `.recover` exploits.
- **The page size is a tuning knob with measured effects.** The [internal-versus-external BLOB study][intern-v-extern] reports the crossover: _"For BLOBs smaller than 100KB, reads are faster when the BLOBs are stored directly in the database file. For BLOBs larger than 100KB, reads from a separate file are faster,"_ with 8192- or 16384-byte pages best for large BLOB I/O. At an 8192-byte page, reading 10 KB BLOBs out of the database is 2.24× faster than reading them as files; at 1 MB it is 0.72×. The companion measurement is [35% Faster Than The Filesystem][fasterthanfs] — small blobs read and written ~35% faster than `fread`/`fwrite` on individual files, and about 20% smaller on disk, because _"individual files are padded out to the next multiple of the filesystem block size, whereas the blobs are packed more tightly."_ Both pages are candid about the caveats; the honest summary they themselves give is that SQLite's latency is _competitive_ with direct I/O, which is already enough to defeat the assumption the design position has to overcome.
- **Ranged remote access falls out of page orientation.** Because every read is a page-aligned window at a computable offset, an HTTP range request is a legal `xRead`. That is not a property of the format so much as a property of the format's _granularity_, and it is developed in [range-request access][range] and [the VFS page][vfs].

### Where the index lives, compared

| Artifact                       | Index location                                                    | Cost of one lookup                            | Staleness risk                                                                      |
| ------------------------------ | ----------------------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------- |
| SQLite database                | **In-file, header-anchored tree** rooted at page 1                | `O(log n)` page reads                         | None — the index is the data                                                        |
| ZIP / [footer formats][footer] | In-file, footer-anchored contiguous directory                     | one seek + full directory read                | None                                                                                |
| Git packfile                   | **Out-of-band** `.idx` sidecar                                    | fan-out lookup + binary search in the sidecar | The sidecar can be regenerated; `commit-graph` and `.bitmap` genuinely can go stale |
| ELF                            | In-file, header-anchored table; `.gnu.hash` is a per-object index | bloom filter + bucket chain                   | None in-file; `ld.so.cache` out of band                                             |

Git is the only row where the index is a different file, and it is also the only row that has needed to invent _more_ index files over time. That is not a coincidence: an out-of-band index is a [materialized view][concepts], and materialized views multiply.

---

## Reflexivity and query surface

**Reflexivity = 3**, and this is the axis the design position exists to max out.

Two properties combine, and it is worth separating them because most formats have at most one.

**The artifact carries its own vocabulary.** `sqlite_schema` is not documentation _about_ the file, it is a table _in_ the file whose `sql` column is the `CREATE` text. `sqlite3 doc.db .schema` prints the format specification. Views ship in the same table, so an application can define the reader's vocabulary (`CREATE VIEW ldd AS …`) and have it travel with the document rather than with a tool that must be installed alongside. Contrast the pile-of-files, where the schema is a naming convention in a README, and the wrapped pile-of-files, where it is a catalog file in a bespoke format inside the ZIP.

**The query surface is general and pre-existing.** Anything that can open a SQLite file can ask a question the format's designer never anticipated — which is what "general query surface" means in [the concepts page][concepts], and what distinguishes this from a fixed menu of tools. The paper's own framing of why this matters is a claim about _where developer attention goes_: _"Developers can write SQL that expresses 'what' information they want and let the database engine figure out how to best retrieve that content. This helps developers operate 'heads up' … and avoid time spent 'heads down' fiddling with low-level file formatting details."_

The limits are real and this catalog has already met them. Transitive questions — reachability, closure, resolution order — are exactly the questions an artifact format most wants to answer and exactly the ones SQL serves worst; recursive CTEs work and are ergonomically hostile, which is why [code-as-a-database systems][code-as-db] overwhelmingly chose Datalog instead, and why Fossil materializes `plink`/`leaf`/`event` at write time rather than computing them per query. Materializing is the same move `commit-graph` makes; the difference is that Fossil's materialization lives _inside_ the transaction that produces it and cannot be stale, while Git's lives in a separate file and can.

**Self-interrogation while running** is not a property of the format on its own — a document is not a process. It becomes one when the artifact is also the program, which is [SELF and `self-httpd`][self], and when an operating system exposes itself this way, which is [relational system surfaces][relational]. What this format contributes is that the step from "queryable by tools" to "queryable by the running program" is nothing: the same `sqlite3_open` call, on `argv[0]`.

---

## Closure, dedup, and size model

**Closure = 2.** The design's pitch is that "diverse content which might otherwise be stored as a 'pile-of-files' is encapsulated into a single disk file for simpler transport via scp/ftp, USB stick, and/or email attachment" — designed-in containment of everything the _document_ consists of. What it explicitly does not carry is the code: the artifact needs a SQLite library and an application, which is why this is 2 and not 3, and why the honest comparison for a distributed artifact is against [Nix closures][nix-closures] and [application packaging][packaging] rather than against a static binary.

Fossil is the strongest demonstration of the score. A `.fossil` file holds the entire project — every version of every file, the wiki, the tickets, the forum, the chat log, the ticket report formats, the user table, and the site's display configuration — and cloning is copying one file. The [all-in-one rationale][whyallinone] argues the closure directly: remote workers "get the entire website including versioned documentation, wiki articles, tickets, forum posts", so the artifact is useful offline in a way that a repository plus a hosted forge is not.

**Dedup is by content hash, inside the schema, and is the application's job.** Nothing in the file format deduplicates; SQLite stores what you insert. Fossil deduplicates by making `blob.uuid` `UNIQUE` and by delta-chaining through the `delta` table — the same technique as a packfile, expressed as a constraint plus a foreign key instead of as a serializer. That is the general pattern for this design position: dedup and chunking policy move _up_ into the schema, where they are visible, indexable and queryable, instead of down into a hand-written encoder. [Content-addressed chunking][chunking] covers the policies themselves.

### The size model, with the numbers the sources give

| Comparison                                                  |  SQLite side |   Other side | Ratio                     |
| ----------------------------------------------------------- | -----------: | -----------: | ------------------------- |
| SQLite 3.22.0 source tree, 1,743 files: `sqlar` vs Info-ZIP | 10,754,048 B | 10,662,365 B | **1.009×**                |
| The same, vs `zipfile`-produced ZIP                         | 10,754,048 B | 10,390,215 B | 1.035×                    |
| The same, vs tarball (whole-archive compression)            | 10,754,048 B |  9,781,109 B | 1.099×                    |
| 10 KB blobs: one database vs individual files on disk       |            — |            — | **0.8×** (≈20% less disk) |
| A small ELF converted to [SELF][self], unstripped           |     57,344 B |     15,856 B | 3.10×                     |
| `coreutils`, stripped by `DELETE` + `VACUUM`                |  1,794,048 B |  1,768,632 B | 1.014×                    |

The shape is consistent and is the useful generalization: **b-tree overhead is a per-object constant that amortizes away**, so the ratio is dominated by how much _optional_ structure the schema carries rather than by the format. A 57 KiB database for a 15 KiB binary is 350% overhead; the same schema over 1,123 objects is 6%. Where the artifact is already an archive of compressed payloads, the overhead is under 1% and buys transactional incremental update — the property the wrapped pile-of-files structurally cannot have, since _"usually the entire file must be rewritten in order to change any component part."_

---

## Mutability, dispatch, and trust

**Mutability = 3**, and it is the axis this design position most obviously wins. The [summary page][aff-short] states the consequence for application design in one line: _"Updates happen automatically as application content is revised so the File/Save menu option becomes superfluous. The File/Save_As menu option can be implemented using the backup API."_ Continuous, incremental, atomic mutation of the document _is_ the pitch, and the paper's supporting example is exactly the paranoid-archival use case one would expect to be hostile to it — _"The Fossil DVCS uses this technique to verify that no repository history has been lost prior to each change"_ — which [Fossil's self-check documentation][fossil-selfcheck] expands: every content file written during a transaction is re-extracted, re-hashed and compared _before_ commit, and the transaction rolls back if anything fails. Verification inside the write transaction is not available to a format whose writer is a serializer.

### `mmap`, and why "the file is mapped" is not "the object is mapped"

[Thesis 4][concepts] says `mmap` is the load-bearing constraint, and this format's answer needs stating carefully, because the obvious summary is wrong in both directions.

SQLite _can_ map the database file. Since 3.7.17 (2013-05-20) the VFS has `xFetch`/`xUnfetch`, and with `PRAGMA mmap_size` set, SQLite asks the OS for a pointer to a page instead of copying it: _"if the requested page has been or can be mapped into the application address space, then xFetch returns a pointer to that page for SQLite to use without having to copy anything."_ Two processes reading the same database therefore _do_ share physical pages through the unified buffer cache. So "SQLite loses page sharing" is false at the page level. It is also off by default, and the [documentation][mmap] is candid about why: an I/O error on a mapped file _"causes a signal which, if not caught by the application, results in a program crash"_, a unified buffer cache is required and _"in some operating systems that claim to have a unified buffer cache, the implementation is buggy and can lead to corrupt databases"_, and Windows cannot truncate a mapped file, so `VACUUM` silently fails to shrink it.

What is genuinely unavailable is mapping an **object**. A row's payload is a cell, and a payload larger than the page's capacity spills into a chain of overflow pages _"the first four bytes of each"_ being the next page number. The bytes of a large BLOB are therefore delivered as runs of `usable_size − 4` at offsets congruent to 4 modulo the page size — never contiguous and never page-aligned, at any page size, since the link is a fixed per-page cost. And because the chain is built by the pager _above_ the VFS, a custom VFS can relocate whole pages but cannot remove those four bytes. So: file-backed sharing of _pages_, yes; a `PROT_EXEC` mapping of a _stored object_, no. That is the precise form of the constraint that [SELF's page-sharing problem][self-mmap] runs into, and it is why the only viable repair there leaves the database entirely and appends a page-aligned trailer — which collides head-on with the next paragraph.

### `VACUUM` versus any signature over the bytes

[`VACUUM`][vacuum] _"works by copying the contents of the database into a temporary database file and then overwriting the original with the contents of the temporary file"_, needs up to twice the database size in free space, purges the freelist of recoverable deleted content, and _"may change the ROWIDs of entries in any tables that do not have an explicit INTEGER PRIMARY KEY."_ Every one of those is a feature for a document and a catastrophe for an attestation. The bytes of a semantically unchanged database are not stable: a no-op `VACUUM` produces a different file, and so does a single `INSERT`.

This is [the signing problem][provenance] in its sharpest form, and this design position makes it strictly harder rather than easier. A byte-hash — `fs-verity`, IMA, a detached signature, a reproducible-build attestation — measures a file that this format is designed to keep changing. The shape of an answer is a canonical _row_ serialization with per-table Merkle roots, signing only the tables the application declares immutable; nobody has built it, and no one should quote a "SQLite documents are signable" claim without noticing that `VACUUM INTO` producing a _"minimal in size"_ copy with _"no forensic traces"_ is deliberately not the same bytes as the original.

### Dispatch and the trust boundary

**Dispatch is the consumer's.** Nothing in the kernel or the loader knows what a `.fossil` or a `.gpkg` is; `file(1)` reads sixteen bytes plus offset 68 and the application decides. That is the weakest dispatch owner in this catalog's [taxonomy][concepts] and also the least dangerous: a mis-identification is a wrong icon, not an execution. It becomes the strongest and most dangerous only when [`binfmt_misc`][binfmt] is taught the same field — at which point the kernel runs an interpreter for anything whose bytes 0–15 and 68–71 match, and the registration itself is a privilege surface.

The trust story inside the file is genuinely subtle and the SQLite developers document it rather than assert safety. The design position's threat model is stated in the whitepaper's own §4: _"SQLite is robust against maliciously malformed database files and SQL inputs. An attacker will not be able to provoke a memory error by corrupting an SQLite database used as an application file. There are attacks that a clever attacker can carry out against an application by tricking a user to open an application file that is an SQLite database."_ [Defense Against The Dark Arts][dark-arts] names the mechanism: **the schema is executable**. A `CREATE VIEW`, a trigger, a default-value expression or a virtual-table declaration in a hostile document's `sqlite_schema` can invoke the application's own custom SQL functions and virtual tables, so a document that is merely _opened_ can call code the application registered for its own use. The mitigations are `SQLITE_DBCONFIG_TRUSTED_SCHEMA` off, `SQLITE_DBCONFIG_DEFENSIVE`, `sqlite3_set_authorizer`, reduced `sqlite3_limit` values, a hard heap limit, and a progress handler as a watchdog.

Read against this catalog: the moment a format's self-description is _expressive_, opening a document is running one. That is the price of thesis 2 stated as a threat model, and it is the same trade [parser differentials][differentials] catalogue on the other side — those formats are dangerous because their grammar is ambiguous, this one because its schema is Turing-adjacent. The application-level answer is the authorizer callback; the system-level answer is [the sandboxing primitives the threat-model page collects][threat].

---

## Strengths

- **The specification is the schema, and it travels in the file.** `sqlite_schema` reduces "document your format" to "name your tables well". This is the single most transferable idea on the page and the concrete content of [thesis 2][concepts].
- **Mutation is transactional, incremental and continuous.** Only changed pages are written; a crash leaves the previous state; File/Save becomes redundant. The wrapped pile-of-files formats structurally cannot offer this — they rewrite the archive.
- **The compatibility promise is unusually specific and unusually cheap to verify.** Backwards compatible to 3.0.0 (2004-06-18), with a stated intent through 2050 and a format that gives up six freelist slots per trunk page to keep 2008 readers working.
- **A general query surface arrives for free, along with tools nobody wrote for this application** — `sqldiff`, `sqlite3_analyzer`, `.recover`, `VACUUM INTO`, FTS5, and a binding in every language.
- **The size cost is small where it is measurable.** ~0.9% over Info-ZIP for an archive of 1,743 files; ~20% _less_ disk than individual files for 10 KB blobs, because filesystems round up to block size.
- **Concurrency correctness is inherited.** Multi-process reader/writer coordination is where hand-rolled formats produce their worst bugs, and it is not the application's code here.
- **Portability is a property of the bytes**, not of the reader: identical across word size and endianness, with UTF-8/UTF-16 handled by the engine.

## Weaknesses

- **The single-file property is conditional.** WAL leaves `-wal` and `-shm` beside the document, does not work over network filesystems, and until 3.22.0 (2018-01-22) made read-only opening impossible. The documentation itself says this "can make SQLite less appealing for use as an application file-format".
- **`VACUUM` rewrites the file and may renumber rowids**, which defeats byte-level signatures, appended trailers, and any external index into the file. `mmap` and `VACUUM` are in direct opposition.
- **A stored object is never a contiguous, page-aligned extent.** Overflow chains put a 4-byte link at the head of every spilled page, above the VFS, so no substrate swap can produce a mappable blob.
- **The schema is executable, so opening an untrusted document is a code-execution surface** unless `SQLITE_DBCONFIG_TRUSTED_SCHEMA` and friends are set.
- **Transitive queries — the ones an artifact format most wants — are SQL's weakest area.** Recursive CTEs work and are hostile; every serious consumer materializes instead, which reintroduces the staleness problem the design position criticized Git for.
- **Not greppable, and it takes a dependency.** Both are conceded in the whitepaper. The dependency is one C file, but it is the thing Git specifically declined in 2005 and the reason a streaming wire format still has to be invented separately.
- **Nothing about it deduplicates.** Content addressing and delta chaining are the application's problem; Fossil had to write both, and they are ordinary tables.
- **Zero format multiplicity.** Byte 0 is claimed, the extent is self-declared, and the only spare room is 255 bytes per page designed for a per-page nonce. This format cannot participate in any polyglot construction.

---

## Key design decisions and trade-offs

| Decision                                                                               | Rationale                                                                                                                   | Trade-off                                                                                                              |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| The schema lives in the file as `CREATE` text (`sqlite_schema`)                        | The documentation of the format _is_ the format; a reader decades later needs only the b-tree layout                        | Opening a document means loading a schema that can name functions and virtual tables — an execution surface            |
| A header at offset 0 rooting a b-tree, rather than a footer directory                  | Point queries cost `O(log n)` pages, not one seek plus a full directory read; partial reads are the normal case             | Byte 0 is claimed and the extent is self-declared: no prefix tolerance, no polyglot, no suffix parasitism              |
| One fixed page size for the whole file, 512–65536                                      | Every read and write is a page-aligned window at a computable offset — which is what makes an HTTP-range VFS trivial        | Wrong choice costs measurably (2.24× vs 0.72× on 10 KB vs 1 MB BLOBs) and cannot be changed at all in WAL mode         |
| Payload spills into a linked chain of overflow pages                                   | Large values need no special case; the b-tree stays uniform and the page allocator stays simple                             | **A stored object is never contiguous or page-aligned**, and the 4-byte link is added above the VFS — no `mmap` repair |
| `application_id` at offset 68, uninterpreted by the engine                             | Gives every application a free, registry-free identity that `file(1)` already reads                                         | It is advisory: nothing enforces that two databases with one ID share a schema, and `user_version` was abused first    |
| Deleted space goes on a freelist rather than being reclaimed                           | Deletion costs page-header writes, not data movement; the file does not thrash                                              | Deleted content stays recoverable until `VACUUM` or `secure_delete`, and the file does not shrink on its own           |
| WAL as an _option_, not the default                                                    | ~3× faster writes and readers that do not block writers, for applications that want a database more than a document         | Two sidecar files, no network filesystems, no page-size change — the single-file property is suspended while serving   |
| `VACUUM` rebuilds via a temporary file and overwrites                                  | Reclaims space, defragments, and purges forensic traces in one well-understood operation                                    | Needs 2× free space, may renumber rowids, and invalidates any signature, appended trailer, or external offset index    |
| Compatibility over cleverness (dead payload-fraction bytes, six unused freelist slots) | The promise of readability in 2050 is worth more than three bytes and six pointers                                          | The format carries permanent scar tissue and can never reclaim it                                                      |
| Fossil: enduring artifacts in `blob`/`delta`, everything else rebuildable              | The archival format is the artifact text; SQLite is storage and index, and `fossil rebuild` can regenerate the derived half | Two documents to keep honest, and the derived tables are a materialized view with the invalidation duties that implies |

---

## Sources

- [SQLite As An Application File Format][appfileformat] — the long-form whitepaper: the three-category taxonomy, Git and Packfiles named as the pile-of-files case, the `files(filename, content)` reduction, the twelve advantages, the Brooks/Pike/Torvalds quotations, and §4's security position
- [Benefits of SQLite As A File Format][aff-short] — the summary page: "Data lives longer than code", the File/Save argument, the Library of Congress recommendation
- [SQLite Database File Format][fileformat] — the normative spec: the 100-byte header table, page types, b-tree page regions, overflow chains, the freelist, `sqlite_schema`
- [`src/btreeInt.h`][btreeint] and [`magic.txt`][magic], `sqlite/sqlite` at [`8a988271`][sqlite-repo] (2026-08-26, `VERSION` 3.54.0) — the header layout as an implementation comment, and the `file(1)` magic registry with Fossil, GeoPackage, MBTiles, Esri, Bentley and the Monotone `user_version` exception
- [Write-Ahead Logging][wal] — the "quasi-persistent `-wal` and `-shm`" admission, the network-filesystem and read-only limitations, checkpointing
- [Single-file Cross-platform Database][onefile] — "a single disk file¹" and its footnote
- [`VACUUM`][vacuum] · [Memory-Mapped I/O][mmap] · [SQLite Archive Files][sqlar] · [35% Faster Than The Filesystem][fasterthanfs] · [Internal Versus External BLOBs][intern-v-extern] — the rewrite semantics, the `xFetch` sharing story, the ±1%-of-ZIP measurement, and the 100 KB BLOB crossover
- [Long Term Support][lts] and [File Format Changes in SQLite][formatchng] — the 2050 intent and the exact backwards/forwards compatibility rule
- [Defense Against The Dark Arts][dark-arts] — untrusted database files, `SQLITE_DBCONFIG_TRUSTED_SCHEMA`, the authorizer, the limit table
- [Fossil — A Technical Overview][fossil-tech], [`src/schema.c`][fossil-schema], [Fossil Versus Git][fossil-v-git], [Repository Integrity Self-Checks][fossil-selfcheck], [Why Add Forum, Wiki, and Web Software To Your DVCS?][whyallinone], [The Fossil File Format][fossil-fileformat] — read at check-in [`b8c7665e`][fossil-checkin] (2026-08-24): three database classes, the `0x0f055111` family, `blob`/`delta`, the Schema1/Schema2 split and `rebuild`, the descendants-query argument
- [`Documentation/gitformat-pack.adoc`][gitformat-pack], [`gitformat-chunk.adoc`][gitformat-chunk], [`technical/commit-graph.adoc`][commit-graph], [`technical/reftable.adoc`][reftable], [`technical/bitmap-format.adoc`][bitmap], [`technical/pack-heuristics.adoc`][pack-heuristics] — `git/git` at [`f78ce2f7`][git-repo] (2026-08-25): the pack and `.idx` v2 layouts, the `.rev` secondary index, the chunk TOC, the reftable objectives, and Linus Torvalds' streaming-versus-density explanation
- Runnable companion: [`self-selfdb/examples/sqlite-header-probe.d`](./self-selfdb/examples/sqlite-header-probe.d) — decodes the 100-byte header, `application_id`, `page_size` and the reserved-bytes field from a synthesized SELF header and from real databases
- Related in this tree: [SELF / selfdb][self] · [the VFS as substrate][vfs] · [ZIP parasitism][zip] · [footer-indexed formats][footer] · [range-request access][range] · [content-addressed chunking][chunking] · [Nix store closures][nix-closures] · [image-based systems][image-based] · [code as a database][code-as-db] · [relational system surfaces][relational] · [binary inspection libraries][bin-inspect] · [`sqlelf`][sqlelf] · [`binfmt_misc`][binfmt] · [parser differentials][differentials] · [embedded provenance][provenance] · [threat model][threat] · [concepts][concepts] · [comparison][comparison] · [open questions][open] · [umbrella][index]

<!-- References -->

[appfileformat]: https://sqlite.org/appfileformat.html
[aff-short]: https://sqlite.org/aff_short.html
[fileformat]: https://sqlite.org/fileformat2.html
[onefile]: https://sqlite.org/onefile.html
[wal]: https://sqlite.org/wal.html
[vacuum]: https://sqlite.org/lang_vacuum.html
[mmap]: https://sqlite.org/mmap.html
[sqlar]: https://sqlite.org/sqlar.html
[fasterthanfs]: https://sqlite.org/fasterthanfs.html
[intern-v-extern]: https://sqlite.org/intern-v-extern-blob.html
[lts]: https://sqlite.org/lts.html
[formatchng]: https://sqlite.org/formatchng.html
[dark-arts]: https://sqlite.org/security.html
[sqlite-repo]: https://github.com/sqlite/sqlite/tree/8a9882714dab097da40edc963d0e4226bda1ee07
[btreeint]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/btreeInt.h
[magic]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/magic.txt
[fossil-src]: https://fossil-scm.org/home/doc/trunk/www/index.wiki
[fossil-license]: https://fossil-scm.org/home/file/COPYRIGHT-BSD2.txt?ci=b8c7665e121b25c3ccc268edbab86ec27c72f7a3c0cd56fa1ed2762a84fadc38
[fossil-checkin]: https://fossil-scm.org/home/info/b8c7665e121b25c3ccc268edbab86ec27c72f7a3c0cd56fa1ed2762a84fadc38
[fossil-tech]: https://fossil-scm.org/home/doc/trunk/www/tech_overview.wiki
[fossil-sync]: https://fossil-scm.org/home/doc/trunk/www/sync.wiki
[fossil-schema]: https://fossil-scm.org/home/file/src/schema.c?ci=b8c7665e121b25c3ccc268edbab86ec27c72f7a3c0cd56fa1ed2762a84fadc38
[fossil-v-git]: https://fossil-scm.org/home/doc/trunk/www/fossil-v-git.wiki
[fossil-selfcheck]: https://fossil-scm.org/home/doc/trunk/www/selfcheck.wiki
[fossil-fileformat]: https://fossil-scm.org/home/doc/trunk/www/fileformat.wiki
[whyallinone]: https://fossil-scm.org/home/doc/trunk/www/whyallinone.md
[git-repo]: https://github.com/git/git/tree/f78ce2f7b6df702f93d40b85d6bda92a3f65da79
[gitformat-pack]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitformat-pack.adoc
[gitformat-chunk]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitformat-chunk.adoc
[commit-graph]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/technical/commit-graph.adoc
[reftable]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/technical/reftable.adoc
[bitmap]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/technical/bitmap-format.adoc
[pack-heuristics]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/technical/pack-heuristics.adoc
[self]: ./self-selfdb/index.md
[self-mmap]: ./self-selfdb/index.md#the-lost-page-sharing
[vfs]: ./sqlite-vfs-substrate.md
[zip]: ./zip-parasitism.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[chunking]: ./content-addressed-chunking.md
[nix-closures]: ./nix-store-closures.md
[image-based]: ./image-based-systems.md
[code-as-db]: ./code-as-database.md
[relational]: ./relational-system-surfaces.md
[bin-inspect]: ./binary-inspection-libraries.md
[sqlelf]: ./sqlelf.md
[binfmt]: ./binfmt-misc.md
[differentials]: ./parser-differentials.md
[provenance]: ./embedded-provenance.md
[threat]: ./threat-model.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[open]: ./open-questions.md
[index]: ./index.md
[packaging]: ../application-packaging/index.md
