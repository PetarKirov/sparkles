# Footer-indexed formats (structural family)

ZIP is not a special case. Parquet, ORC, the seekable `zstd` frame format, and eStargz all put their index at the end of the file, for one reason each of them states out loud: the index cannot be written until the data is, and rewriting the front of a large file to insert it is unacceptable — sometimes impossible — for a streaming writer.

| Field           | Value                                                                                                                                                                                                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | A structural family of container, columnar, and compression formats — plus one member (BGZF) that declines to join it                                                                                                                                                                        |
| Language        | Format specifications; reference implementations in Java and C++ (Parquet, ORC), C (`zstd` seekable, `htslib`), Go (stargz, eStargz)                                                                                                                                                         |
| License         | Apache-2.0 (`parquet-format`, `orc`, `stargz-snapshotter`, `crfs`); BSD-3-Clause **or** GPLv2 (`zstd`); MIT/Expat + Modified BSD (`htslib`)                                                                                                                                                  |
| Repository      | [`apache/parquet-format`][pq-repo] · [`apache/orc`][orc-repo] · [`facebook/zstd`][zstd-repo] · [`samtools/htslib`][hts-repo] · [`containerd/stargz-snapshotter`][sgz-repo]                                                                                                                   |
| Documentation   | [parquet.apache.org][pq-docs] · [orc.apache.org ORCv1][orc-docs] · [Zstandard Seekable Format 0.1.0][zseek-spec] · [hts-specs (SAM §4, tabix, CSI)][sam-spec] · [`docs/estargz.md`][estargz-doc]                                                                                             |
| First release   | ORC with Hive 0.11 (2013); Parquet `Version 1.0.0`, the earliest entry in [`CHANGES.md`][pq-changes] (2013); BGZF specified in the SAM format (2009); stargz in Google CRFS (2019, approx.); `zstd` seekable format **0.1.0, 2017-11-04** ([spec][zseek-spec]); eStargz (2020–2021, approx.) |
| Axis profile    | Multiplicity **2** / Reflexivity **2** / Closure **0** / Mutability **1**                                                                                                                                                                                                                    |
| Index anchoring | **Footer**, by definition — with BGZF + tabix included as the [out-of-band](#the-member-that-declined-bgzf-tabix) member that proves the rule                                                                                                                                                |
| Dispatch owner  | **Consumer** — extension, then a trailing magic read from the last 4–9 bytes                                                                                                                                                                                                                 |

> **Revisions surveyed:** `parquet-format` [`24102ed5`][pq-repo] (2026-08-19, spec `Version 2.11.0`), `orc` [`7f1dd182`][orc-repo] (2026-08-13), `zstd` [`0716f554`][zstd-repo] (2026-08-22, seekable format 0.1.0), `htslib` [`a489af14`][hts-repo] (2026-08-26), `stargz-snapshotter` [`c2bf18e5`][sgz-repo] (2026-08-24), `google/crfs` [`71d77da4`][crfs-repo] (2019-11-07, archived). **Measurements:** `zstd` 1.5.7 seekable examples, `glibc` 2.42, Linux x86-64, **August 26, 2026**.

---

## Overview

### What it solves

Every format in this family answers the same question: _how does a writer that streams data once, forward, without seeking, produce a file a reader can randomly access?_

The two halves of that question pull in opposite directions. Random access needs an index — a map from a logical coordinate (a row range, a byte offset in the decompressed stream, a file path inside an archive) to a physical byte range. But the index's contents are not known until the data has been written: a compressor does not know a frame's compressed size before compressing it, a columnar writer does not know a column chunk's offset before laying out the preceding chunks, and a tar-to-gzip pipeline does not know where a member's gzip header will land.

There are exactly three ways out, and the family is defined by which one it takes:

1. **Reserve space at the front and seek back to fill it in.** Requires a seekable, rewritable output. Rules out pipes, HDFS, and object stores; costs a second pass over the front of the file.
2. **Put the index at the end and locate it from EOF.** Requires only that the _reader_ can seek. This is the family.
3. **Do not have an index; make the reader scan.** `tar` and raw `gzip`. Random access degenerates to a full pass.

The choice is forced by the substrate, not by taste, and the sources say so directly. This is the rule the [ZIP parasitism][zip] page generalises from: ZIP's back-scanned `EOCD` is one instance of a design that recurs wherever the same constraint holds, and the constraint — not the ZIP lineage — is what predicts where it will appear next.

> [!NOTE]
> ZIP itself is _not_ re-surveyed here. [`./zip-parasitism.md`][zip] owns the `EOCD` back-scan, the `P = E − S − O` prefix equation, ZIP64, and the 4 GiB / 65 535-entry limits. This page is about the family and about the rule that generates it; ZIP appears only where the comparison earns its place.

### Design philosophy

ORC states the constraint as a fact about its deployment substrate, in the first sentence of its specification's _File Tail_ section:

> _"Since HDFS does not support changing the data in a file after it is written, ORC stores the top level index at the end of the file."_
> — [ORC v1 specification, § File Tail][orc-spec]

Parquet states the same thing as a property of the writer rather than of the filesystem:

> _"File Metadata is written after the data to allow for single pass writing."_
> — [`parquet-format/README.md`, § File format][pq-readme]

And `zstd`'s seekable format states the consequence for the _reader_ of a format that does not know about the index at all:

> _"The frames are appended, so that the decompression of the entire payload still regenerates the original content, using any compliant zstd decoder. … The jump table is simply ignored by zstd decoders unaware of the seekable format."_
> — [`contrib/seekable_format/README.md`][zseek-readme]

Three projects, three vocabularies, one design. The ORC quote is the strongest of the three because it names the substrate: an append-only distributed filesystem makes option 1 not merely expensive but unavailable, and every design decision in ORC's tail follows from that single sentence.

---

## How it works

### The five members, side by side

| Format               | Trailing magic                                      | Length field                                                                      | Where the reader starts                                             | What one ranged read buys                                                   |
| -------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Parquet**          | `PAR1` (or `PARE` when encrypted), 4 B              | 4-byte LE length of `FileMetaData`, immediately before the magic                  | last **8 bytes**, then a second read of exactly `length` bytes      | the whole schema, every row group, every column-chunk offset and statistic  |
| **ORC**              | `"ORC"` inside `PostScript.magic`; also at byte 0   | last **1 byte** = `psLen`; `PostScript.footerLength`, `PostScript.metadataLength` | speculative **16 KiB** tail (`DIRECTORY_SIZE_GUESS`)                | in the common case, `PostScript` + `Footer` + column statistics in one read |
| **Seekable `zstd`**  | `0x8F92EAB1`, 4 B, "must be the last bytes present" | `Number_Of_Frames` (4 B) in the 9-byte `Seek_Table_Footer`                        | last **9 bytes**, then the whole skippable frame                    | `(compressed, decompressed[, checksum])` sizes for every frame              |
| **eStargz / stargz** | `"STARGZ"` inside a gzip `Extra` subfield           | none — the footer is a **fixed 51 bytes** (legacy stargz: 47)                     | last **51 bytes**, parsed as a gzip member                          | the absolute offset of the TOC; a second read gets the whole TOC JSON       |
| **BGZF**             | a 28-byte empty-block EOF marker                    | `BSIZE` in each block's `BC` subfield (per block, not per file)                   | **byte 0**, block by block — or an out-of-band `.tbi`/`.csi`/`.gzi` | nothing; the index is a different file                                      |

Four of the five put the index in the file. The fifth is in the table on purpose; see [the member that declined](#the-member-that-declined-bgzf-tabix).

### Parquet: a two-level footer

The file layout is `PAR1`, then column chunks grouped into row groups, then `FileMetaData`, then a 4-byte little-endian length, then `PAR1` again ([`README.md`][pq-readme]). A reader's first act is a read of the last 8 bytes; the magic confirms the format and the length says exactly how far back to seek for the metadata. No scanning, no bound, no ambiguity — the contrast with ZIP's variable-position `EOCD` and its 65 557-byte back-scan window is total, and it is the single largest robustness difference between the two designs.

`FileMetaData` is a Thrift `TCompactProtocol` structure ([`parquet.thrift`][pq-thrift]) holding the schema, `num_rows`, and a `list<RowGroup>`; each `RowGroup` holds one `ColumnChunk` per column; each `ColumnChunk` holds a `ColumnMetaData` with the offsets that make random access work:

```thrift
// src/main/thrift/parquet.thrift — ColumnMetaData
  /** total byte size of all compressed, and potentially encrypted, pages
   *  in this column chunk (including the headers) **/
  7: required i64 total_compressed_size
  /** Byte offset from beginning of file to first data page **/
  9: required i64 data_page_offset
  /** Byte offset from the beginning of file to first (only) dictionary page **/
  11: optional i64 dictionary_page_offset
```

Every one of these is _absolute from byte 0_, which is why Parquet — unlike ZIP — is not prefix-tolerant even in principle (see [Format identity and multiplicity](#format-identity-and-multiplicity)).

The second level is the **page index**, and its placement is the most instructive decision in the format. `ColumnIndex` (per-page min/max, for skipping) and `OffsetIndex` (per-page `PageLocation{offset, compressed_page_size, first_row_index}`) are _not_ inside `FileMetaData`. They live in their own region near the footer, and `ColumnChunk` carries four fields pointing at them — `offset_index_offset`, `offset_index_length`, `column_index_offset`, `column_index_length`. The spec gives the reason:

> _"The new index structures are stored separately from RowGroup, near the footer. This is done so that a reader does not have to pay the I/O and deserialization cost for reading them if it is not doing selective scans."_
> — [`PageIndex.md`, § Technical Approach][pq-pageindex]

That is a footer index that has itself been split, so the cheap half can be read without the expensive half. The same move is repeated a third time for Bloom filters: `ColumnMetaData.bloom_filter_offset` (field 14) and `bloom_filter_length` (field 15) point at bitsets stored elsewhere in the file. Parquet's footer is therefore not one index but a root pointing at three optional ones — which, structurally, is a two-level tree that stopped one level short of being a b-tree.

Parquet also carries a live warning about what happens when a footer-anchored format has _two_ places to record the same offset:

> _"DEPRECATED: Byte offset in `file_path` to the `ColumnMetaData` … Past use of this field has been inconsistent, with some implementations using it to point to the `ColumnMetaData` and some using it to point to the first page in the column chunk. In many cases, the `ColumnMetaData` at this location is wrong."_
> — [`parquet.thrift`, `ColumnChunk.file_offset`][pq-thrift]

That is the `LOC`-versus-`CEN` disagreement of [ZIP][zip] reproduced independently, twenty-four years later, in a format designed by people who knew better. It is direct support for [thesis 1](./concepts.md#every-binary-format-eventually-reimplements-a-database-badly): the redundant pointer is a denormalisation with no referential integrity, and it drifted.

### ORC: a chain of lengths ending in one byte

ORC's tail is a linked list read backwards ([ORCv1 § File Tail][orc-spec]):

```
[ encrypted stripe statistics ][ stripe statistics: Metadata ][ Footer ][ PostScript ][ psLen: 1 byte ]
```

The `PostScript` is _never compressed_ and must be under 256 bytes, because its length is stored in a single byte at EOF. It carries `footerLength`, `metadataLength`, `compression`, `compressionBlockSize`, the writer `version`, and the fixed string `"ORC"` in field 8000. Once it is parsed, `Footer` — which is compressed — can be located and decompressed, and `Footer` carries `StripeInformation` for every stripe, the type schema, `numberOfRows`, and per-column `ColumnStatistics`.

The reader does not perform four reads. Both the Java and C++ implementations speculate:

```cpp
// c++/src/Reader.hh
static const uint64_t DIRECTORY_SIZE_GUESS = 16 * 1024;

// c++/src/Reader.cc — ReaderImpl construction
uint64_t readSize = std::min(fileLength, DIRECTORY_SIZE_GUESS);
…
postscriptLength = buffer->data()[readSize - 1] & 0xff;
contents->postscript = readPostscript(stream.get(), buffer.get(), postscriptLength);
uint64_t footerSize = contents->postscript->footer_length();
…
if (tailSize > readSize) {           // the guess was too small: one more read
  buffer->resize(footerSize);
  stream->read(buffer->data(), footerSize, fileLength - tailSize);
```

The Java reader uses the identical constant ([`ReaderImpl.java`][orc-readerimpl], `private static final int DIRECTORY_SIZE_GUESS = 16 * 1024`) and the identical fallback. The specification even documents the tactic as part of the format's expected behaviour: _"Rather than making multiple short reads, the ORC reader reads the last 16k bytes of the file with the hope that it will contain both the Footer and Postscript sections."_ A **speculative tail read** is what a footer-anchored format does instead of a b-tree descent, and 16 KiB is the empirical constant two independent implementations converged on.

### Seekable `zstd`: an index made of sizes, not offsets

The seekable format appends one skippable frame containing the seek table, terminated by a 9-byte footer whose last four bytes are `0x8F92EAB1` and which the spec requires to be _"the last bytes present in the compressed file so that decoders can efficiently find it"_ ([spec, `Seek_Table_Footer`][zseek-spec]). The reader's opening move is a single 9-byte read from EOF:

```c
/* contrib/seekable_format/zstdseek_decompress.c — ZSTD_seekable_loadSeekTable() */
CHECK_IO(src.seek(src.opaque, -(int)ZSTD_seekTableFooterSize, SEEK_END));
CHECK_IO(src.read(src.opaque, zs->inBuff, ZSTD_seekTableFooterSize));

if (MEM_readLE32(zs->inBuff + 5) != ZSTD_SEEKABLE_MAGICNUMBER) {
    return ERROR(prefix_unknown);
}
```

`Number_Of_Frames` and the `Seek_Table_Descriptor`'s `Checksum_Flag` are then enough to compute the skippable frame's exact size (`8 + 4·checksum` bytes per entry, plus the 9-byte footer and an 8-byte skippable header), seek to its start, and cross-validate two independent statements of that size: the skippable magic `ZSTD_MAGIC_SKIPPABLE_START | 0xE` and the `Frame_Size` field must agree with the size derived from the frame count. A format that derives its index extent from the footer _and_ checks it against a header is doing what ZIP's `apksig` had to bolt on by hand.

The genuinely important design choice is in the entries. `Seek_Table_Entries` records `Compressed_Size` and `Decompressed_Size` per frame — **sizes, not offsets** — and the reader accumulates them:

```c
entries[idx].cOffset = cOffset;
entries[idx].dOffset = dOffset;
cOffset += MEM_readLE32(zs->inBuff + pos); pos += 4;
dOffset += MEM_readLE32(zs->inBuff + pos); pos += 4;
```

A table of sizes is position-independent. The whole `P = E − S − O` repair machinery that five ZIP implementations had to invent, and that two of them refused to implement, is _structurally unnecessary_ here: prepend a megabyte to a seekable `zstd` archive and every offset the reader computes is still correct relative to the archive's own start. That is the single cleanest improvement any member of this family made over ZIP, and it cost nothing.

### The measurement: what one seek table actually buys

Built from the surveyed tree (`contrib/seekable_format/examples`, `make`), on 11 600 000 bytes of line-structured text, maximum frame size 64 KiB, level 3:

```console
$ seekable_compression data.txt 65536 3
$ ls -l data.txt.zst
-rw-r--r-- 1 petar users 210686 …  data.txt.zst

# the last 9 bytes: Number_Of_Frames, Seek_Table_Descriptor, Seekable_Magic_Number
$ od -A d -t x1 -j 210677 data.txt.zst
0210677 b2 00 00 00 80 b1 ea 92 8f          # 178 frames; descriptor 0x80 = Checksum_Flag; 0x8F92EAB1

# a plain, seekable-unaware decoder still reproduces the input exactly
$ zstd -dc data.txt.zst | cmp - data.txt && echo byte-identical
byte-identical
$ zstd -l data.txt.zst
Frames  Skips  Compressed  Uncompressed  Ratio  Check  Filename
   179      1     206 KiB                        None  data.txt.zst
```

Note `Skips 1`: the stock CLI sees the seek table, counts it as a skippable frame, and ignores it. Extracting 120 bytes from the middle of the decompressed stream, traced with `strace -y` and filtered to the archive's own descriptor:

| Step | Syscall                           | Bytes | What it is                                                |
| ---- | --------------------------------- | ----- | --------------------------------------------------------- |
| 1    | `lseek(-9, SEEK_END)` + `read`    | 9     | `Seek_Table_Footer`                                       |
| 2    | `lseek(-2153, SEEK_CUR)` + `read` | 2 153 | the entire skippable seek-table frame                     |
| 3    | `lseek(89525, SEEK_SET)` + `read` | 1 173 | frame 76 — the one containing decompressed byte 5 000 000 |

Parsing the table independently confirms the arithmetic: 178 entries × 12 bytes (checksums on) + 9 + 8 = **2 153 bytes**, and frame 76 has `cOffset 89525, cSize 1173, dOffset 4980736, dSize 65536` — the reader's third `lseek` lands on `cOffset` exactly. The format-mandated I/O to retrieve 120 bytes from the middle of an 11.6 MB corpus is **3 335 bytes, 1.58 % of the archive and 0.029 % of the original**. The process actually read 30 309 bytes, because the example wraps the file in buffered `stdio` and refills an 8 KiB buffer twice; the gap between 3 335 and 30 309 is the difference between what the format permits and what a naive reader does, and over HTTP range requests that difference is four round trips instead of three.

The seek table cost **1.02 %** of the archive here — 2 153 bytes for 210 686 — which is the price of a 64 KiB frame size. The upstream `README` states the trade explicitly: _"Small frame sizes reduce decompression cost when requesting small segments … But small frame sizes also reduce compression ratio, and increase the cost for the jump table, so there is a balance to find"_ ([`README.md`][zseek-readme]).

### eStargz: a footer inside a format that has no footer

gzip has no index and no trailer that could hold one. stargz's answer, inherited by eStargz, is to append an **empty gzip member** whose `Extra` field carries the offset — so a `tar.gz` gains a footer without ceasing to be a `tar.gz`:

```
- 10 bytes  gzip header
- 2  bytes  XLEN (length of Extra field) = 26
- 2  bytes  Extra: SI1 = 'S', SI2 = 'G'
- 2  bytes  Extra: LEN = 22 (16 hex digits + len("STARGZ"))
- 22 bytes  Extra: subfield = fmt.Sprintf("%016xSTARGZ", offsetOfTOC)
- 5  bytes  flate header: BFINAL = 1(last block), BTYPE = 0(non-compressed block), LEN = 0
- 8  bytes  gzip footer
```

— [`docs/estargz.md`, § Footer][estargz-doc]; the constant is `FooterSize = 51` in [`estargz/types.go`][sgz-types].

The offset is written as **sixteen ASCII hex digits**, not a binary integer — a decision inherited from Google CRFS, whose comment names the format as `"%016xSTARGZ"` and sets `FooterSize = 47` ([`crfs/stargz/stargz.go`][crfs-stargz]). eStargz's 51 bytes differ from stargz's 47 by exactly the 4 bytes of `SI1`/`SI2`/`LEN` that [RFC 1952 § 2.3.1.1][rfc1952] requires of a conforming `Extra` subfield; the doc is explicit that _"eStargz's footer structure is incompatible with stargz's one"_ and that the incompatibility was accepted to become standards-conformant. `stargz-snapshotter` still ships `LegacyGzipDecompressor` with `legacyFooterSize = 47` to read the older shape, so the family's newest member already carries a compatibility footer parser — two footers, distinguished by length.

The index itself is not in the footer; the footer only points at it. The TOC is a regular tar entry named `stargz.index.json`, required to be the last entry, holding a `TOCEntry` per file _and per chunk_, with `offset`, `chunkOffset`, `chunkSize`, `digest` and `chunkDigest`. So a lazy-pulling runtime performs: one ranged read of 51 bytes, one ranged read of the TOC, then one ranged read per file it actually opens.

The most revealing variant is the **external TOC**, which replaces the offset with a constant marker:

```
// 46 comes from:
// 10 bytes  gzip header
// 2  bytes  XLEN (length of Extra field) = 21
// 2  bytes  Extra: SI1 = 'S', SI2 = 'G'
// 2  bytes  Extra: LEN = 17 (len("STARGZEXTERNALTOC"))
// 17 bytes  Extra: subfield = "STARGZEXTERNALTOC"
```

A footer whose entire content is _"the index is somewhere else"_ is the hinge between two of the four anchoring answers in [concepts][concepts]. It converts eStargz from footer-anchored to out-of-band at the cost of one 46-byte marker, and it exists to shrink the blob — which is the size argument of [Closure, dedup, and size model](#closure-dedup-and-size-model) made by the upstream itself.

### The member that declined: BGZF + tabix

BGZF — block-gzip, the container under BAM, VCF.gz and every `bgzip`-compressed file — takes option 3 and pushes the index entirely out of band. Each block is an independent, self-delimiting gzip member with a mandatory `BC` extra subfield ([`bgzf.c`][hts-bgzf], `htslib` `a489af14`):

```c
/* BGZF/GZIP header (specialized from RFC 1952; little endian):
 +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
 | 31|139|  8|  4|              0|  0|255|      6| 66| 67|      2|BLK_LEN|
 +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
  BGZF format is compatible with GZIP. It limits the size of each compressed
  block to 2^16 bytes and adds and an extra "BC" field in the gzip header which
  records the size. */
static const uint8_t g_magic[19] = "\037\213\010\4\0\0\0\0\0\377\6\0\102\103\2\0\0\0";
```

`BGZF_MAX_BLOCK_SIZE` is `0x10000` and the uncompressed payload cap `BGZF_BLOCK_SIZE` is `0xff00`, chosen so `compressBound()` of a full payload still fits ([`htslib/bgzf.h`][hts-bgzfh]). The addressing primitive is a **virtual offset** packing both coordinates into one 64-bit integer:

```c
#define bgzf_tell(fp) (((fp)->block_address << 16) | ((fp)->block_offset & 0xFFFF))
```

Sixteen bits for the intra-block offset is exactly the reason blocks are capped at 64 KiB — the format's block size limit is a consequence of its pointer encoding, which is the same kind of coupling ZIP has between its 16-bit comment length and its back-scan window.

The index lives in a sibling file: `.bai`, `.csi`, or `.tbi`, recognised by the magics `BAI\1`, `CSI\1`, `TBI\1` ([`hts.c`][hts-hts]), each a UCSC-style binning index plus a linear index over virtual offsets, and each itself BGZF-compressed. `bgzip --reindex` produces a third kind, `.gzi`, whose entire content is a count and then pairs:

```c
/* bgzf.c — bgzf_index_dump_hfile() */
if (hwrite_uint64(fp->idx->noffs > 0 ? fp->idx->noffs - 1 : 0, idx) < 0) goto fail;
for (i=1; i<fp->idx->noffs; i++) {
    if (hwrite_uint64(fp->idx->offs[i].caddr, idx) < 0) goto fail;
    if (hwrite_uint64(fp->idx->offs[i].uaddr, idx) < 0) goto fail;
}
```

`(caddr, uaddr)` is `(compressed offset, uncompressed offset)`. **That is the `zstd` seek table, byte for byte in intent, written to a different file.** The two formats made opposite choices about _where_ to put an identical data structure, and the consequences are exactly the ones [concepts][concepts] predicts for a [materialized view][concepts]: the `.gzi` can be regenerated, can be lost, and can go stale. `htslib`'s only defence is an `mtime` comparison and a warning:

```c
/* hts.c — hts_idx_load3() */
if ( stat_idx.st_mtime < stat_main.st_mtime )
    hts_log_warning("The index file is older than the data file: %s", fnidx);
```

The staleness concern runs deep enough that `htslib` keeps a documented hack to make the timestamps come out right when it writes an index concurrently with the data:

```c
/* hts.c */
static int need_idx_ugly_delay_hack(const hts_idx_t *idx)
{
    // Ugly hack for on-the-fly BAI indexes.  As these are uncompressed,
    // we need to delay writing a few bytes of data until file close
    // so that we have something to force a modification time update.
    //
    // (For compressed indexes like CSI, the BGZF EOF block serves the same
    // purpose).
```

What BGZF buys by refusing the footer is **concatenation**: two BGZF files concatenated are one valid BGZF file, and blocks can be appended forever without touching anything already written. What it pays is that the artifact does not know its own index. Both halves of that trade are visible in the source above.

BGZF does keep one thing in the footer position — a 28-byte empty block used purely as a truncation detector, checked with a single seek:

```c
/* bgzf.c — bgzf_check_EOF_common() */
if (hseek(fp->fp, -28, SEEK_END) < 0) { … }
if ( hread(fp->fp, buf, 28) != 28 ) return -1;
return (memcmp("\037\213\010\4\0\0\0\0\0\377\6\0\102\103\2\0\033\0\3\0\0\0\0\0\0\0\0\0", buf, 28) == 0)? 1 : 0;
```

A format that puts _nothing but a sentinel_ at EOF still had to read from EOF, because "is this file complete?" has no other cheap answer.

---

## Format identity and multiplicity

**Score: 2 (designed-in).** Not multiplicity in [APE][ape]'s sense — none of these files is simultaneously an executable — but four of the five deliberately admit **two parses of the same bytes**, and in each case the second parse is the whole point of the design:

| Artifact        | Parse A (index-unaware)                               | Parse B (index-aware)                         | Where B hides                                                                                         |
| --------------- | ----------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Seekable `zstd` | a valid `zstd` stream; `zstd -d` reproduces the input | frames addressable by decompressed offset     | a **skippable frame**, `0x184D2A5E`, which [RFC 8878 § 3.1.2][rfc8878] requires every decoder to skip |
| eStargz         | a valid `tar.gz`; any OCI runtime unpacks it          | a lazily-pullable layer with per-file offsets | an **empty gzip member** with an `Extra` subfield                                                     |
| BGZF            | a valid `gzip` stream                                 | 64 KiB-addressable blocks                     | a **gzip `Extra` subfield**, `BC`                                                                     |
| Parquet, ORC    | none — the file is only itself                        | —                                             | —                                                                                                     |

The pattern is sharp enough to state as a rule: **a footer index is placed in whatever region the base format already ignores.** ZIP found a region no reader inspects (before the central directory) when it needed somewhere to put a signature; `zstd` found one the specification _mandates_ be ignored; gzip's `Extra` field is one the 1996 RFC already reserved. eStargz's own summary is that it is _"a backward-compatible extension which means that images can be pushed to the extension-agnostic registry and can run on extension-agnostic runtimes"_ ([`docs/estargz.md`][estargz-doc]) — which is the same claim [polyglot craft][poly] makes about a polyglot, with the adversarial intent removed.

Parquet and ORC have no such second parse, and correspondingly no such tolerance. Both claim byte 0 (`PAR1`, `"ORC"`) _and_ run to EOF, which is the "neither" cell of the [tolerance partial order][concepts]:

| Format                  | Prefix-tolerant                                       | Suffix-tolerant                                   | Why                                                                                          |
| ----------------------- | ----------------------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Parquet**             | **No** — `data_page_offset` is absolute from byte 0   | **No** — the last 8 bytes must be length + `PAR1` | the footer is located positionally, not by scanning                                          |
| **ORC**                 | **No** — `StripeInformation` offsets are absolute     | **No** — the last byte must be `psLen`            | same                                                                                         |
| **Seekable `zstd`**     | **Yes, structurally** — the seek table stores _sizes_ | **No** — the magic must be the last four bytes    | cumulative sums are relative to the archive's own start                                      |
| **eStargz**             | **No** — `TOCEntry.offset` is absolute                | **No** — the footer is at exactly EOF−51          | but any trailing gzip member is still legal _gzip_, so parse A survives what parse B rejects |
| **BGZF**                | **No** — virtual offsets are absolute                 | **Yes** — concatenation is the intended operation | no whole-file index to invalidate                                                            |
| **ZIP** (for reference) | **Repairably** — `P = E − S − O`                      | **Yes** (≤ 65 535 B of comment)                   | the `EOCD` is _found_, not addressed ([ZIP parasitism][zip])                                 |

The comparison isolates what actually made ZIP the universal parasite, and it is not footer anchoring. It is footer anchoring **plus a scanned entry point**. Parquet, ORC and eStargz all locate their footers by fixed arithmetic from EOF, so a single appended byte destroys them; ZIP searches for its footer, so 65 535 appended bytes do not. Footer anchoring is necessary for prefix tolerance and nowhere near sufficient for suffix tolerance — and only seekable `zstd`, by storing sizes instead of offsets, gets the _referential_ half of prefix tolerance for free.

Parquet also uses the trailing magic as a **version dispatcher**, which is a use of the footer no other member found. In encrypted-footer mode the file ends with `PARE` instead of `PAR1`:

> _"the combined length of this structure and of the encrypted footer is written as a 4-byte little endian integer, followed by a final magic string, "PARE". … the encrypted footer mode uses a new magic string ("PARE") in order to instruct readers to look for a file crypto metadata before the footer - and also to immediately inform legacy readers (expecting "PAR1") that they can't parse this file."_
> — [`Encryption.md`, § Encrypted footer mode][pq-encryption]

Four bytes at EOF that tell a reader both _what to do next_ and _that it cannot_. That is precisely the job [`binfmt_misc`][binfmt] does with magic-plus-mask at a fixed offset, relocated to the other end of the file and executed by the consumer instead of the kernel.

---

## Index anchoring and random access

This section is the page's subject, so the claim is stated as a derivation rather than a description.

**Given** (a) a writer that must emit bytes in one forward pass, (b) a reader that must reach an arbitrary record without reading the preceding ones, and (c) a substrate on which already-written bytes cannot be modified — the index must be written after the data, and must be locatable from the end. Both are forced. Nothing about ZIP, archives, or columnar storage enters the argument.

The derivation predicts, rather than describes, and each prediction is checkable:

1. **Formats born on append-only substrates will be footer-anchored.** ORC says so about HDFS ([§ File Tail][orc-spec]). Parquet was designed for the same filesystem. eStargz targets OCI registries, where a blob is immutable and content-addressed.
2. **Formats whose writer can seek will not be.** SQLite, ELF, and PE all assume a rewritable file and all anchor at byte 0.
3. **Where the substrate is append-only but the _index_ must change independently, the index leaves the file.** BGZF plus `.tbi`; `ldconfig`'s cache; `debuginfod`. These are [materialized views][concepts] and they all inherit the same staleness failure — `htslib`'s `mtime` warning above is the family's entire integrity story.

### What a ranged read costs

| Format              | Round trips to first byte of payload                                         | Bytes fetched before payload                                                           |
| ------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Parquet**         | 3 (8-byte tail → `FileMetaData` → column chunk); 4 if the page index is used | 8 + `len(FileMetaData)` (+ `column_index_length` + `offset_index_length`)              |
| **ORC**             | 2 in the common case, 3 if the tail exceeds 16 KiB                           | ≤ 16 384, or 16 384 + `footerLength`                                                   |
| **Seekable `zstd`** | 3 (9-byte footer → seek table → frame)                                       | 9 + `8·(12·frames + 17)/8`; **2 153 B measured** for a 178-frame, 210 686-byte archive |
| **eStargz**         | 3 (51-byte footer → TOC → file range)                                        | 51 + `len(stargz.index.json)`                                                          |
| **BGZF + tabix**    | 1 for the index _file_ + 1 per query                                         | the whole `.tbi`/`.csi`, which is a separate object                                    |
| **ZIP**             | 3–4 ([ZIP parasitism][zip])                                                  | ≤ 65 557 speculative + the entire central directory                                    |

Two facts stand out. First, **three round trips is the family's floor**, and it is a floor: locate, read index, read payload. ORC beats it only by speculating. Second, every one of these indexes is a _contiguous region that must be read in full_ — Parquet's `FileMetaData` is a Thrift blob, `zstd`'s seek table is a flat array, eStargz's TOC is a single JSON document. None can be partially fetched, binary-searched in place, or descended. On a file with a million small files or a hundred thousand frames, the index read dominates. This is the same criticism [ZIP parasitism][zip] makes of the central directory, and it applies unchanged to every member of this family. See [range-request access][rra] for the general pattern over HTTP.

### The contrast that matters: SQLite is header-anchored and still random-access

The naive reading of this page would be "footer anchoring is how you get random access". SQLite disproves it. Its [file format][sqlite-format] puts a 100-byte header at offset 0, and page 1 is the root of `sqlite_schema` — the table of tables, whose `rootpage` column names the root page of every other table and index. Random access is achieved by _descending a tree from a fixed root pointer_, not by seeking to a contiguous block at a known end.

The difference is structural, and it explains three things at once:

- **Why SQLite does not need a footer.** Its index is reachable in `O(log n)` page reads from byte 0. There is no moment at which "the index is complete" and must be flushed somewhere; the b-tree is rebalanced incrementally as rows are inserted, so the index is _always_ written and _never_ written last.
- **Why the family cannot do the same.** A b-tree requires rewriting interior pages when a leaf splits. On HDFS, or on an OCI blob, or in a pipe, that operation does not exist. ORC's one-sentence justification is exactly this constraint, stated from the substrate's side.
- **Why [SELF][self] needs no footer either.** A `.self` file is a SQLite database whose `application_id` sits at byte 68; the loader reaches `segments` and `needed` by tree descent, and `SELECT soname FROM ldd` touches a handful of 4 KiB pages regardless of whether the image is 50 KiB or 96 MiB. The [SELF deep-dive][self] scores its anchoring as _header, with the qualification that the header names a tree, not a directory of extents_ — and that qualification is the whole pivot between these two pages. Footer anchoring buys single-pass writes on an immutable substrate; header-plus-tree buys logarithmic partial reads and in-place update, and demands a rewritable one.

The trade is not free in either direction, and SQLite itself proves the point from the other side. `appendvfs`, the shim that puts a SQLite database at the _end_ of another file — how a `.sqlar` archive is appended to an executable, and the closest SQLite analogue of the [APE][ape] trick — retrofits a footer to do it:

> _"A special record must appear at the end of the file that identifies the file as an appended database and provides the offset to the first page of the exposed content. … (2) If the file ends with the appendvfs trailer string `"Start-Of-SQLite3-NNNNNNNN"` that file is an appended database. (3) If the file begins with the standard SQLite prefix string `"SQLite format 3"`, that file is an ordinary database."_
> — [`ext/misc/appendvfs.c`][appendvfs]

A 25-byte trailer — 17 ASCII characters plus a 64-bit big-endian offset to page 1 — and a rule that checks EOF _before_ byte 0. The instant SQLite needed prefix tolerance, it grew a footer, exactly as the derivation predicts; and it paid for it with a documented 1 GiB size cap, _"to avoid unnecessary complications with the PENDING_BYTE"_. Header anchoring and footer anchoring are not rival philosophies; they are answers to different questions about the substrate, and the same format will use both when it faces both questions.

---

## Reflexivity and query surface

**Score: 2 (designed-in), with one member at 0.**

The family splits cleanly by whether the footer carries a _schema_ or merely _offsets_.

| Artifact            | What the footer knows about the payload                                                                                           | Query surface                                                                 |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **Parquet**         | the full nested schema (`list<SchemaElement>`), per-chunk `Statistics`, per-page min/max, `column_orders`, optional Bloom filters | SQL engines plan against it — predicate pushdown _is_ a query over the footer |
| **ORC**             | `Type` tree, per-column `ColumnStatistics` at file, stripe, and 10 000-row-index granularity                                      | same                                                                          |
| **eStargz**         | a filesystem: name, type, mode, uid/gid, xattrs, `digest` per file and chunk                                                      | `stat`/`open` served from the TOC without touching the layer                  |
| **Seekable `zstd`** | nothing but sizes                                                                                                                 | none                                                                          |
| **BGZF**            | nothing at all                                                                                                                    | none in-file; the coordinate index is a sibling                               |

Parquet is the family's strongest claim to reflexivity and it is a genuinely different kind of thing from a ZIP central directory. A ZIP `CEN` answers _where is entry X_; a Parquet footer answers _could any row in this column chunk satisfy `WHERE x BETWEEN 3 AND 7`_ — a question about data the reader has not read, answered from metadata alone. That is a **zone map**, and the `ColumnIndex` doubles it at page granularity, with an explicit licence to lie in the safe direction:

> _"These may be the actual minimum and maximum values found on a page, but can also be (more compact) values that do not exist on a page. For example, instead of storing `"Blart Versenwald III"`, a writer may set `min_values[i]="B"`, `max_values[i]="C"`."_
> — [`PageIndex.md`][pq-pageindex]

A deliberately imprecise index whose imprecision is sound in one direction is a database technique, not a file-format technique, and Parquet also ships a Bloom filter (`BloomFilter.md`, reached through `bloom_filter_offset`) for the point-lookup case the zone map cannot serve.

This is the most interesting evidence in the tree against a flat reading of [thesis 1][concepts] — _every binary format eventually reimplements a database, badly_. Parquet did reimplement a catalog, a zone map, and a Bloom filter. It did **not** do it badly: the structures are the ones a column store would choose, they are specified rather than conventional, and the format explicitly forbids the redundancy that usually causes the drift (_"Readers that support `ColumnIndex` should not also use page statistics"_). What Parquet reimplemented badly is the _one_ structure it inherited from the container tradition rather than the database tradition — `ColumnChunk.file_offset`, the denormalised pointer, now deprecated because implementations disagreed about its meaning. The thesis survives in a sharper form: **formats reimplement databases badly exactly where they denormalise a pointer and cannot enforce referential integrity.** Compare [code as a database][cadb], where the index is the artifact, and [sqlelf][sqlelf], where the query surface is retrofitted over a format that has none.

**Self-inspection at runtime: 0, and the reason is categorical.** None of these artifacts executes. There is no process to ask itself a question, no `/proc/self/exe`, no handler table. The family is at the opposite corner of the reflexivity axis from [SELF][self] and [redbean][ape]: maximally self-_describing_, entirely non-self-_interrogating_. That absence is itself the finding — self-description and self-interrogation are independent, and the catalog's two seed artifacts happen to have both only because they are programs.

---

## Closure, dedup, and size model

**Closure: 0.** No member of this family carries a dependency of any kind. A Parquet file references no other Parquet file (`ColumnChunk.file_path` exists but the specification disowns the practice: _"There is no other known usage of this field … Making use of the field for this purpose is not considered part of the Parquet specification"_). An eStargz layer is _part_ of a closure — an OCI image manifest lists it — but the closure is computed outside the artifact, by the registry and the runtime. The axis simply does not engage, and saying so is the honest answer.

**Deduplication: none within the family; borrowed from outside it by exactly one member.** eStargz layers are OCI blobs, so identical layers are shared by digest at the registry, and identical _chunks_ can be shared by the `chunkDigest` mechanism when a snapshotter caches them. That is content addressing supplied by the distribution layer, which is [content-addressed chunking][cac]'s subject and not this page's; the line is that eStargz's _format_ contributes the chunk boundaries and digests, while the _sharing_ happens above it.

**Size model.** The family's index overhead is the one number every member exposes and it decomposes the same way everywhere: a fixed footer plus a term proportional to the number of addressable units.

| Format              | Fixed footer                          | Per-unit index cost                                                               | Measured / specified bound                                                                                 |
| ------------------- | ------------------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Seekable `zstd`** | 9 B + 8 B skippable header            | **8 B per frame**, or 12 B with `Checksum_Flag`                                   | 2 153 B for 178 frames = **1.02 %** of a 210 686-byte archive (measured above)                             |
| **Parquet**         | 8 B (length + magic)                  | one `ColumnChunk` per (row group × column), plus optional `PageLocation` per page | unbounded in principle; `ColumnIndex` truncation exists to bound it                                        |
| **ORC**             | 1 B (`psLen`) + `PostScript` ≤ 255 B  | `StripeInformation` per stripe + `ColumnStatistics` per column per stripe         | readers assume ≤ 16 KiB (`DIRECTORY_SIZE_GUESS`) and re-read when wrong                                    |
| **eStargz**         | 51 B (legacy 47 B, external-TOC 46 B) | one JSON `TOCEntry` per file **and per chunk**                                    | the upstream ships [`docs/smaller-estargz.md`][estargz-small] and an external-TOC mode purely to reduce it |
| **BGZF**            | 28 B EOF marker                       | 18 B header + 8 B footer per ≤ 64 KiB block, plus the whole sibling index         | ≥ 26 B per block, unconditionally, even for incompressible data                                            |

The `zstd` seek table is the cleanest instance of the trade because both terms are exposed as one tunable. Frame size `F` over payload `P` gives roughly `12·P/F` bytes of index, so the 64 KiB frames measured above cost 1.02 %; 4 KiB frames on the same corpus would cost ~16× that _and_ compress worse, because each frame resets the compression window. The upstream's advice — match the frame size to the expected access granularity — is the same advice ZIP's per-entry deflate window forces on its users, arrived at independently.

eStargz is where the size model bites hardest, and it is the only member whose upstream ships two separate mitigations for it: a whole document on shrinking the blob, and the external-TOC footer that removes the TOC from the layer entirely at the cost of a second image to fetch. The TOC is JSON, one entry per file _and per chunk of every large file_, inside the layer it describes — so a layer with a hundred thousand small files pays for a hundred thousand JSON objects before a single file is read. That is the family's general weakness (a contiguous, non-descendable index) meeting its least compact encoding.

---

## Mutability, dispatch, and trust

**Mutability: 1 (incidental, and asymmetric).** In-place modification is impossible for every member — an edit shifts every subsequent absolute offset, which is the same wall [ZIP][zip] hits and the reason `patchelf` exists for [ELF][ld]. But _append_ is cheap in a way it is not for a header-anchored format: truncate the footer, append new data, write a new footer. Seekable `zstd` and BGZF are designed for it; BGZF goes further and makes plain concatenation valid, since it has no whole-file index to invalidate. Parquet and ORC support neither, by design — ORC's founding premise is a filesystem where the question does not arise.

The asymmetry is worth stating as a general property: **footer anchoring makes append cheap and update impossible; header-plus-tree anchoring makes update possible and append no cheaper than any other write.** That is the same trade [SELF][self] makes when it becomes a database — it gains `UPDATE dynamic_entries SET value = ?` and loses the ability to be produced by a pipe.

### Dispatch

The dispatcher is the **consumer**, in every case, and it decides by reading a few bytes from the end:

| Format              | Dispatch evidence                                                                                                                                                  | Failure mode                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| **Parquet**         | last 4 bytes: `PAR1` (plaintext) vs `PARE` (encrypted footer)                                                                                                      | a legacy reader is _told_ it cannot parse the file, rather than misparsing it                         |
| **ORC**             | `"ORC"` at byte 0 for front-scanners, `PostScript.magic` at the tail for readers                                                                                   | a truncated file gives a plausible `psLen`, which is why the reader validates `tailSize < fileLength` |
| **Seekable `zstd`** | last 4 bytes `0x8F92EAB1`; the spec warns the _skippable_ magic alone is insufficient (_"it is not recommended for a decoder to recognize frames solely on this"_) | absent seek table → the file is still a valid `zstd` stream, so the fallback is graceful              |
| **eStargz**         | last 51 bytes parse as a gzip member with `SI1='S', SI2='G'`; the reader tries 51 then 47                                                                          | absent/legacy footer → the file is still a valid `tar.gz`                                             |
| **BGZF**            | per-block `check_header()`: `31,139,8`, `FEXTRA`, `XLEN==6`, `'B','C'`, `slen==2`                                                                                  | a plain gzip file passes the gzip checks and fails the `BC` check, cleanly                            |

ORC has both a header magic and a footer magic, and it says why: _"The Header consists of the bytes 'ORC' to support tools that want to scan the front of the file to determine the type of the file."_ That is the same concession ODF and EPUB make when they pin `mimetype` at byte 38 of a ZIP ([ZIP parasitism][zip]) — a footer-indexed format that wants to be identified by a header-anchored dispatcher such as `file(1)` must smuggle a header back in. ORC got it for three bytes because it never wanted prefix tolerance in the first place; ZIP's descendants had to spend three normative constraints and give up parasitism to buy the same thing.

### Trust

The footer is the file's entire authority. Every byte range a reader touches is named by it, so a forged or corrupted footer redirects _all_ subsequent reads, and — unlike a b-tree, where a bad interior page corrupts one subtree — there is no partial failure mode. The family's answers to that vary widely in ambition:

- **Parquet** has the most developed story, and it had to solve the same self-reference problem [APK Signature Scheme v2][zip] did. In **encrypted-footer** mode a `FileCryptoMetaData` precedes the AES-GCM-encrypted `FileMetaData`, the combined length is written as a 4-byte LE integer, and the file ends `PARE`. In **plaintext-footer** mode the footer is visible but signed, with `FileMetaData.footer_signing_key_metadata` naming the key — an explicit, in-format acknowledgement that a footer everyone must trust needs to be verifiable independently of the data it indexes.
- **eStargz** puts the trust anchor _outside_ the artifact. The TOC's digest travels in the OCI descriptor as `containerd.io/snapshot/stargz/toc.digest`, and each `TOCEntry` carries a `chunkDigest`, so a runtime verifies the TOC against the (already-verified) manifest and then verifies each lazily-fetched chunk against the verified TOC. The design goal is stated plainly: _"an eStargz layer is lazily pulled from the registry in file (or chunk if that file is large) granularity so each one needs to be independently verified every time fetched"_ ([`docs/estargz.md`][estargz-doc]). Two levels of hashing rooted in a signature that is not in the file — the opposite of APK's strategy of inventing a place inside the file to put it.
- **Seekable `zstd`** offers a per-frame `Checksum` — the low 32 bits of the XXH64 of the frame's _uncompressed_ data — which detects corruption and nothing else. The seek table itself is unprotected.
- **ORC** encrypts column data and stripe statistics but the `PostScript` is never compressed and never encrypted, because it must be readable to find anything else. The one byte at EOF is unauthenticated by construction.
- **BGZF** has the 28-byte EOF marker, i.e. truncation detection and no integrity at all, plus the sibling index's `mtime` heuristic.

The generalisation, which is [embedded provenance][prov]'s and [threat model][threat]'s to develop: **a footer-anchored format cannot sign itself without solving self-reference, because the footer records the layout of the thing being signed.** Parquet solves it by encrypting or signing the footer as a unit; eStargz solves it by moving the root of trust out of the file; APK solves it by canonicalising the pointer before hashing. There is no fourth answer in the surveyed sources.

---

## Strengths

- **Single-pass writing.** The defining property. A producer needs no seek, no reserved space, and no second pass; the format works on pipes, HDFS, and immutable object stores alike.
- **Bounded, arithmetic footer location.** Parquet, ORC, `zstd` and eStargz all compute the footer's position from EOF rather than scanning for it — no back-scan window, no "last match wins", none of the [parser differentials][pd] that ZIP's search produces.
- **Random access at three round trips**, and one of those is a handful of bytes. Over HTTP that is the difference between fetching 3 KiB and fetching 200 KiB, measured above.
- **Graceful degradation for the index-in-an-ignored-region members.** A seekable `zstd` archive is a `zstd` archive; an eStargz layer is a `tar.gz`. The index costs nothing in compatibility.
- **Sizes rather than offsets** (seekable `zstd`) make the index position-independent and eliminate the entire class of prefix-skew bugs that ZIP implementations spent thirty years converging on.
- **A footer index can be split.** Parquet's page index and Bloom filters sit near, not in, the footer, so a scan that does not need them never pays for them.
- **Rich self-description where it was wanted.** Parquet and ORC carry schema and statistics, so a reader can plan before it reads — direct support for [thesis 2][concepts].

## Weaknesses

- **The index is a contiguous blob that must be read in full.** No member supports a partial or descending read of its own index. Index cost scales linearly with unit count and dominates on many-small-things workloads.
- **Absolute offsets throughout** (except `zstd`'s), so no prefix tolerance and no in-place edit; every mutation is a rewrite.
- **Positional footers are suffix-_intolerant_.** One appended byte breaks Parquet, ORC and eStargz outright — the property that made ZIP the universal parasite is absent from its four descendants.
- **Total trust in a few trailing bytes.** ORC's `psLen` is one unauthenticated byte on which the whole parse depends; a corrupted footer is an unbounded, silent misparse rather than a localised one.
- **Out-of-band indexes go stale**, and the only deployed defence in the surveyed sources is an `mtime` comparison that emits a warning and continues.
- **Speculative tail reads are an unspecified constant.** 16 KiB is folklore that two ORC implementations happen to share; a file whose tail exceeds it silently costs a second round trip.
- **Denormalised pointers drift.** `ColumnChunk.file_offset` is deprecated after implementations disagreed about its meaning — the same failure ZIP has between `LOC` and `CEN`.
- **The family cannot execute or interrogate itself.** Reflexivity stops at self-description; there is no runtime.

---

## Key design decisions and trade-offs

| Decision                                                                                  | Rationale                                                                                       | Trade-off                                                                                 |
| ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Write the index after the data                                                            | Entry sizes and offsets are unknown until the data is written; the substrate may be append-only | The reader must start at EOF; the writer's last act is the reader's first                 |
| Locate the footer by arithmetic from EOF (Parquet, ORC, `zstd`, eStargz)                  | Deterministic, unbounded-scan-free, no ambiguity about which candidate is the real footer       | Zero suffix tolerance — a single trailing byte invalidates the file                       |
| Locate the footer by reverse scan (ZIP, for contrast)                                     | Accommodates a variable-length trailing comment                                                 | Any four bytes can impersonate the signature; a live differential ([ZIP parasitism][zip]) |
| Store **sizes** in the index (seekable `zstd`)                                            | Cumulative sums are relative to the archive's own origin                                        | An `O(n)` prefix-sum pass at open; no random access _into the index itself_               |
| Store **absolute offsets** (Parquet, ORC, eStargz, BGZF virtual offsets)                  | One read per lookup, no accumulation                                                            | Prefix intolerance; every offset must be rewritten if anything before it moves            |
| Hide the index in a region the base format ignores (`zstd` skippable frame, gzip `Extra`) | Backward compatibility with every existing decoder, for free                                    | The index is invisible to the base format's own integrity checks and easily stripped      |
| Split the index into cheap and expensive halves (Parquet page index, Bloom filters)       | A non-selective scan should not deserialize what it will not use                                | Two more offset/length pairs per column chunk; more pointers to keep consistent           |
| Speculatively read a fixed tail (ORC, 16 KiB)                                             | One read instead of four in the overwhelmingly common case                                      | An unspecified magic constant; files with large tails silently pay an extra round trip    |
| Put the index in a sibling file (BGZF + `.tbi`/`.csi`/`.gzi`)                             | The data stays append-only and concatenable; the index can be rebuilt or replaced independently | The artifact does not know its own index; staleness is detected by `mtime`, if at all     |
| Cap block size at 64 KiB to fit a 16-bit intra-block offset (BGZF)                        | One 64-bit integer addresses both coordinates (`bgzf_tell`)                                     | The pointer encoding dictates the block size, permanently                                 |
| Encode the TOC offset as ASCII hex (stargz, eStargz)                                      | The whole footer stays a legal gzip `Extra` subfield and is trivially inspectable               | 16 bytes to carry 8 bytes of information; two footer lengths (47 / 51) to support forever |
| Change the trailing magic to signal a format variant (Parquet `PARE`)                     | Legacy readers are told they cannot parse the file instead of misparsing it                     | The dispatch decision now lives at EOF, where `file(1)` and MIME sniffing will not look   |
| Anchor at byte 0 and descend a tree instead (SQLite, and therefore [SELF][self])          | `O(log n)` partial reads and in-place update                                                    | Requires a seekable, rewritable substrate — precisely what ORC's HDFS premise denies      |

---

## Sources

- [Apache Parquet — `README.md`, § File format and § Metadata][pq-readme] (`24102ed5`) — the `PAR1` / length / `PAR1` layout and the single-pass-writing rationale
- [Apache Parquet — `src/main/thrift/parquet.thrift`][pq-thrift] — `FileMetaData`, `RowGroup`, `ColumnChunk` (incl. the deprecated `file_offset`), `ColumnMetaData` offsets, `PageLocation`, `OffsetIndex`, `ColumnIndex`, `FileCryptoMetaData`
- [Apache Parquet — `PageIndex.md`][pq-pageindex] — why the page index sits near, not in, the footer; boundary-value truncation
- [Apache Parquet — `Encryption.md`, § 5.4 Encrypted footer mode][pq-encryption] — the `PARE` magic and the plaintext-footer signing mode
- [Apache ORC — ORCv1 specification, § File Tail, § Postscript, § Footer][orc-spec] — the HDFS premise, `psLen`, the 16 KiB read strategy
- [Apache ORC — `c++/src/Reader.cc`][orc-readercc] and [`c++/src/Reader.hh`][orc-readerhh]; [`java/.../ReaderImpl.java`][orc-readerimpl] — `DIRECTORY_SIZE_GUESS = 16 * 1024` in both implementations
- [Zstandard Seekable Format 0.1.0 specification][zseek-spec] — `Seek_Table_Footer`, `Seekable_Magic_Number` `0x8F92EAB1`, `Seek_Table_Entries` as sizes
- [`zstd` — `contrib/seekable_format/README.md`][zseek-readme] — the jump table's invisibility to stock decoders; the frame-size trade
- [`zstd` — `zstdseek_decompress.c`][zseek-dec] (`ZSTD_seekable_loadSeekTable`), [`zstdseek_compress.c`][zseek-comp] (`ZSTD_seekable_writeSeekTable`), [`zstd_seekable.h`][zseek-h] (`ZSTD_seekTableFooterSize 9`, `ZSTD_SEEKABLE_MAXFRAMES 0x8000000`, `ZSTD_SEEKABLE_MAX_FRAME_DECOMPRESSED_SIZE 0x40000000`)
- [RFC 8878 § 3.1.2 — Skippable Frames][rfc8878] and [RFC 1952 § 2.3.1.1 — Extra field][rfc1952] — the two ignored regions this family builds indexes in
- [`htslib` — `bgzf.c`][hts-bgzf] (block header, `check_header`, `bgzf_check_EOF_common`, `bgzf_index_dump_hfile`), [`htslib/bgzf.h`][hts-bgzfh] (`bgzf_tell`, block-size constants), [`hts.c`][hts-hts] (`BAI\1`/`CSI\1`/`TBI\1`, the `mtime` staleness warning, the index-write ordering hack)
- [SAM/BAM format specification, § 4 (BGZF)][sam-spec], [tabix specification][tabix-spec], [CSI specification][csi-spec] — the out-of-band binning and linear indexes
- [eStargz specification (`docs/estargz.md`)][estargz-doc] — the 51-byte footer, the TOC and `TOCEntry`, content verification, the external-TOC variant
- [`stargz-snapshotter` — `estargz/gzip.go`][sgz-gzip] (`gzipFooterBytes`, `ParseFooter`, `LegacyGzipDecompressor`), [`estargz/types.go`][sgz-types] (`FooterSize = 51`, `legacyFooterSize = 47`, `TOCJSONDigestAnnotation`)
- [Google CRFS — `stargz/stargz.go`][crfs-stargz] — the original 47-byte footer and the `"%016xSTARGZ"` encoding
- [SQLite — file format][sqlite-format] and [`ext/misc/appendvfs.c`][appendvfs] — the header-anchored b-tree, and the footer SQLite grew when it needed prefix tolerance
- Related in this tree: [concepts][concepts] · [ZIP parasitism][zip] · [SELF / selfdb][self] · [range-request access][rra] · [content-addressed chunking][cac] · [SQLite as an application file format][sqlite-aff] · [Cosmopolitan / APE][ape] · [parser differentials][pd] · [code as a database][cadb] · [embedded provenance][prov] · [threat model][threat] · [comparison][comparison]

<!-- References -->

[pq-repo]: https://github.com/apache/parquet-format/tree/24102ed5c56e51b610a4897e5f79e76e43732d1d
[pq-readme]: https://github.com/apache/parquet-format/blob/24102ed5c56e51b610a4897e5f79e76e43732d1d/README.md
[pq-thrift]: https://github.com/apache/parquet-format/blob/24102ed5c56e51b610a4897e5f79e76e43732d1d/src/main/thrift/parquet.thrift
[pq-pageindex]: https://github.com/apache/parquet-format/blob/24102ed5c56e51b610a4897e5f79e76e43732d1d/PageIndex.md
[pq-encryption]: https://github.com/apache/parquet-format/blob/24102ed5c56e51b610a4897e5f79e76e43732d1d/Encryption.md
[pq-changes]: https://github.com/apache/parquet-format/blob/24102ed5c56e51b610a4897e5f79e76e43732d1d/CHANGES.md
[pq-docs]: https://parquet.apache.org/docs/file-format/
[orc-repo]: https://github.com/apache/orc/tree/7f1dd1821bac79ccd017ca73d082bcaba1055b86
[orc-spec]: https://github.com/apache/orc/blob/7f1dd1821bac79ccd017ca73d082bcaba1055b86/site/specification/ORCv1.md
[orc-readercc]: https://github.com/apache/orc/blob/7f1dd1821bac79ccd017ca73d082bcaba1055b86/c++/src/Reader.cc
[orc-readerhh]: https://github.com/apache/orc/blob/7f1dd1821bac79ccd017ca73d082bcaba1055b86/c++/src/Reader.hh
[orc-readerimpl]: https://github.com/apache/orc/blob/7f1dd1821bac79ccd017ca73d082bcaba1055b86/java/core/src/java/org/apache/orc/impl/ReaderImpl.java
[orc-docs]: https://orc.apache.org/specification/ORCv1/
[zstd-repo]: https://github.com/facebook/zstd/tree/0716f554df4262cf8530e006bfcc3d9d71e4314e
[zseek-spec]: https://github.com/facebook/zstd/blob/0716f554df4262cf8530e006bfcc3d9d71e4314e/contrib/seekable_format/zstd_seekable_compression_format.md
[zseek-readme]: https://github.com/facebook/zstd/blob/0716f554df4262cf8530e006bfcc3d9d71e4314e/contrib/seekable_format/README.md
[zseek-dec]: https://github.com/facebook/zstd/blob/0716f554df4262cf8530e006bfcc3d9d71e4314e/contrib/seekable_format/zstdseek_decompress.c
[zseek-comp]: https://github.com/facebook/zstd/blob/0716f554df4262cf8530e006bfcc3d9d71e4314e/contrib/seekable_format/zstdseek_compress.c
[zseek-h]: https://github.com/facebook/zstd/blob/0716f554df4262cf8530e006bfcc3d9d71e4314e/contrib/seekable_format/zstd_seekable.h
[hts-repo]: https://github.com/samtools/htslib/tree/a489af14cfcae349ee079b21131cfe2c16dc2118
[hts-bgzf]: https://github.com/samtools/htslib/blob/a489af14cfcae349ee079b21131cfe2c16dc2118/bgzf.c
[hts-bgzfh]: https://github.com/samtools/htslib/blob/a489af14cfcae349ee079b21131cfe2c16dc2118/htslib/bgzf.h
[hts-hts]: https://github.com/samtools/htslib/blob/a489af14cfcae349ee079b21131cfe2c16dc2118/hts.c
[sam-spec]: https://samtools.github.io/hts-specs/SAMv1.pdf
[tabix-spec]: https://samtools.github.io/hts-specs/tabix.pdf
[csi-spec]: https://samtools.github.io/hts-specs/CSIv1.pdf
[sgz-repo]: https://github.com/containerd/stargz-snapshotter/tree/c2bf18e5a94dcfd959cabf744f4bbb4ef8d980a2
[estargz-doc]: https://github.com/containerd/stargz-snapshotter/blob/c2bf18e5a94dcfd959cabf744f4bbb4ef8d980a2/docs/estargz.md
[estargz-small]: https://github.com/containerd/stargz-snapshotter/blob/c2bf18e5a94dcfd959cabf744f4bbb4ef8d980a2/docs/smaller-estargz.md
[sgz-gzip]: https://github.com/containerd/stargz-snapshotter/blob/c2bf18e5a94dcfd959cabf744f4bbb4ef8d980a2/estargz/gzip.go
[sgz-types]: https://github.com/containerd/stargz-snapshotter/blob/c2bf18e5a94dcfd959cabf744f4bbb4ef8d980a2/estargz/types.go
[crfs-repo]: https://github.com/google/crfs/tree/71d77da419c90be7b05d12e59945ac7a8c94a543
[crfs-stargz]: https://github.com/google/crfs/blob/71d77da419c90be7b05d12e59945ac7a8c94a543/stargz/stargz.go
[rfc8878]: https://www.rfc-editor.org/rfc/rfc8878#section-3.1.2
[rfc1952]: https://www.rfc-editor.org/rfc/rfc1952#section-2.3.1.1
[sqlite-format]: https://sqlite.org/fileformat2.html
[appendvfs]: https://sqlite.org/src/doc/trunk/ext/misc/appendvfs.c
[concepts]: ./concepts.md
[zip]: ./zip-parasitism.md
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[poly]: ./polyglot-craft.md
[pd]: ./parser-differentials.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[rra]: ./range-request-access.md
[cac]: ./content-addressed-chunking.md
[sqlite-aff]: ./sqlite-application-file-format.md
[sqlelf]: ./sqlelf.md
[cadb]: ./code-as-database.md
[prov]: ./embedded-provenance.md
[threat]: ./threat-model.md
[comparison]: ./comparison.md
