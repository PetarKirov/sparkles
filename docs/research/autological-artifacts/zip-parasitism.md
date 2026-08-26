# ZIP suffix parasitism (archive format / ecosystem)

ZIP anchors its index in a footer rather than a header, which makes arbitrary leading bytes legal in practice and turns the format into a universal parasite: every ZIP-suffixed format — JAR, APK, DOCX, ODF, EPUB, `.whl`, `.nupkg`, every self-extracting archive, and redbean itself — exists because a ZIP reader starts at the end of the file and works backwards.

| Field           | Value                                                                                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Container file format, plus the ecosystem of formats that embed it                                                                                                            |
| Language        | Format specification; reference implementations in C (`Info-ZIP`, `libzip`, Cosmopolitan), Java (`java.util.zip`, `apksig`), Python (`zipfile`), C# (NuGet)                   |
| License         | `APPNOTE.TXT` is PKWARE's property, licensed for implementing readers/writers; implementations vary (Info-ZIP license, BSD-3 `libzip`, GPLv2+CE OpenJDK, Apache-2.0 `apksig`) |
| Repository      | [`nih-at/libzip`][libzip-repo] · [Info-ZIP `zip`][izzip-repo] · [Info-ZIP `unzip`][izunzip-repo]                                                                              |
| Documentation   | [PKWARE `APPNOTE.TXT` 6.3.10][appnote] · [libzip.org][libzip-docs] · [infozip.sourceforge.net][infozip]                                                                       |
| First release   | PKZIP 0.9, 1989; `APPNOTE.TXT` first published the same year ([§1.1.1][appnote])                                                                                              |
| Axis profile    | Multiplicity 3 / Reflexivity 1 / Closure 2 / Mutability 1                                                                                                                     |
| Index anchoring | **Footer** — the End of Central Directory record, located by scanning backwards from EOF                                                                                      |
| Dispatch owner  | Consumer sniffing (measured below); kernel/shell only when a self-extracting stub is prepended                                                                                |

> **Latest release / revision surveyed:** `APPNOTE.TXT` **6.3.10**, FINAL, revised **November 1, 2022**. **Implementations measured:** Info-ZIP `UnZip` 6.00 (2009-04-20), Info-ZIP `Zip` 3.0 (2008-07-05), p7zip 17.05, CPython 3.11.15, on Linux x86-64, **August 26, 2026**.

---

## Overview

### What it solves

ZIP was designed in 1989 to aggregate and compress many files into one, on floppy media, with random access to any member without decompressing the ones before it. Two design choices follow from that brief, and together they produce every consequence this page is about:

1. **The index is written last.** A compressor streaming entries onto a disk does not know each entry's compressed size until it has finished compressing it. Writing the directory at the end means one pass, no seeking back, and no reserved space. The [`4.3.6 Overall .ZIP file format`][appnote] layout puts `[central directory header 1..n]` and `[end of central directory record]` after all file data.
2. **The index is found by searching backwards.** Because the End of Central Directory (`EOCD`) record carries a variable-length comment, its position is not a fixed distance from EOF; a reader scans backwards for the signature `0x06054b50` (`"PK\5\6"`), bounded by the 16-bit comment-length field to at most `65535 + 22 = 65557` bytes.

Neither choice was made to enable polyglots. But together they mean that _the first byte of the file is never consulted to find the archive_. Everything before the first local file header is, from the index's point of view, off the map. The `APPNOTE` layout has no slot for such bytes and never grants permission for them — and yet four of the five widely-deployed readers surveyed here accept them anyway, because the skew they introduce is recoverable in closed form (see [The prefix equation](#the-prefix-equation)).

That accident is the substrate for an enormous ecosystem. A JAR is a ZIP with `META-INF/MANIFEST.MF`; an APK is a JAR with a signing block wedged in; DOCX and ODF and EPUB are ZIPs with reserved member names; a Python wheel and a NuGet package are ZIPs with a metadata directory; a self-extracting archive is an executable _followed_ by a ZIP; and [redbean / Cosmopolitan APE][ape] is a ZIP whose prefix is simultaneously a PE image, an ELF image, a Mach-O image, a shell script, and an MBR boot sector.

### Design philosophy

The specification's own position is narrow and, read carefully, does not authorise the practice:

> _"4.1.9 ZIP files MAY be streamed, split into segments (on fixed or on removable media) or "self-extracting". Self-extracting ZIP files MUST include extraction code for a target platform within the ZIP file."_
> — [`APPNOTE.TXT` 6.3.10, §4.1.9][appnote]

Self-extraction is permitted; nothing says where the extraction code goes, and the `§4.3.6` layout diagram begins at `[local file header 1]`. The permissive reading is entirely an artefact of implementations. Info-ZIP states it plainly, in a comment on the seek primitive that every offset in the archive passes through:

> _"NOTE THAT `abs_offset` is intended to be the "proper offset" (i.e., if there were no extra bytes prepended); `cur_zipfile_bufstart` contains the corrected offset."_
> — [`unzip/fileio.c`, `seek_zipf()`][izunzip-fileio]

```c
/* unzip/fileio.c — seek_zipf() */
zoff_t request = abs_offset + G.extra_bytes;
```

One addition, applied at every seek, is the entire mechanism. The OpenJDK expresses the same idea as a subtraction, and names the prefix explicitly:

> _"Get position of first local file (LOC) header, taking into account that there may be a stub prefixed to the ZIP file."_
> — [`java.util.zip.ZipFile`, `Source.initCEN`][jdk-zipfile]

CPython calls the same quantity `concat`, and its comment records why it exists:

> _"# "concat" is zero, unless zip was concatenated to another file"_
> — [`Lib/zipfile/__init__.py`, `_handle_prepended_data`][cpy-zipfile]

Three independent implementations, three names for one number, none of them mandated by the specification. That convergence — and the two major readers that pointedly _declined_ to converge — is the subject matter.

---

## How it works

### The three record families

Every ZIP entry appears twice, and the archive is closed by a fixed-shape footer ([`APPNOTE` §4.3.7, §4.3.12, §4.3.16][appnote]):

| Record                            | Signature    | Where                         | Key fields                                                                                                                                                 |
| --------------------------------- | ------------ | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local file header (`LOC`)         | `0x04034b50` | immediately before entry data | `compression method`, `crc-32`, `compressed size`, `uncompressed size`, `file name length`, `extra field length`                                           |
| Central directory header (`CEN`)  | `0x02014b50` | contiguous block near EOF     | everything in `LOC` plus `file comment`, `external file attributes`, **`relative offset of local header`** (4 bytes)                                       |
| End of central directory (`EOCD`) | `0x06054b50` | last record in the file       | `total number of entries`, **`size of the central directory`** (4 bytes), **`offset of start of central directory`** (4 bytes), `.ZIP file comment length` |
| Digital signature (optional)      | `0x05054b50` | after the last `CEN`          | `size of data`, `signature data` — see [Mutability, dispatch, and trust](#mutability-dispatch-and-trust)                                                   |
| ZIP64 EOCD                        | `0x06064b50` | before the ZIP64 locator      | 8-byte widenings of the counts, sizes, and the central-directory offset                                                                                    |
| ZIP64 EOCD locator                | `0x07064b50` | immediately before `EOCD`     | **`relative offset of the zip64 end of central directory record`** (8 bytes)                                                                               |

The `LOC`/`CEN` duplication is what makes both a streaming reader (walk `LOC` records forward) and a random-access reader (read `CEN` once, seek per entry) possible over the same bytes. It is also the format's first structural redundancy, and it will matter for [parser differentials][pd].

The offset fields are the load-bearing part. `APPNOTE` §4.4.16 defines `relative offset of local header` as:

> _"This is the offset from the start of the first disk on which this file appears, to where the local header SHOULD be found."_

"Start of the disk", not "start of the archive". For a floppy holding exactly one archive those are the same byte, and the ambiguity never surfaced. For a 200 MiB self-extracting `.exe` they differ by the size of the stub — and that single unresolved word is where the ecosystem splits.

### The back-scan

Locating the `EOCD` is a bounded reverse search. All four implementations read do the same thing with different constants:

| Implementation                                    | Window                                                       | Acceptance test                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Info-ZIP `unzip` ([`process.c`][izunzip-process]) | `MIN(ziplen, 66000)`, or the whole file under `zipinfo` mode | last signature found wins; no comment-length cross-check                               |
| OpenJDK ([`ZipFile.findEND`][jdk-zipfile])        | `END_MAXLEN = 0xFFFF + ENDHDR` = 65 557 bytes                | if `endpos + ENDHDR + comlen != ziplen`, re-validate by probing `CEN` and `LOC` magics |
| CPython ([`_EndRecData`][cpy-zipfile])            | `ZIP_MAX_COMMENT + sizeEndCentDir`                           | `rfind` — last signature wins                                                          |
| `apksig` ([`ZipUtils`][apksig-ziputils])          | 65 535 comment bytes                                         | **exact**: the candidate's comment-length field must equal the remaining byte count    |
| Cosmopolitan ([`GetZipEocd`][cosmo-eocd])         | `i + 0x10000 + 0x1000 >= n`                                  | full structural validation via [`IsZipEocd32`][cosmo-iseocd]                           |

Cosmopolitan's version is SSE2-vectorised — it compares sixteen bytes at a time against a splat of `"PK"` and skips 13 bytes when none match — because unlike the others it runs _at every process start_, inside the C runtime of the executable that contains the archive:

```c
/* cosmopolitan/libc/str/getzipeocd.c
 * "The ZIP spec says this header can be anywhere in the last 64kb. We
 *  search it backwards for the ZIP-64 "PK♠•" magic number. If that's not
 *  found, then we search again for the original "PK♣♠" magnum." */
while (magic = ZIP_READ32(p + i), magic != kZipCdir64LocatorMagic &&
                                  magic != kZipCdirHdrMagic &&
                                  i + 0x10000 + 0x1000 >= n && i > 0) {
  --i;
}
```

Note the divergence already visible in that table: `apksig` requires the comment length to match exactly, so a candidate signature that happens to occur inside entry data is rejected; Info-ZIP and CPython take the last match unconditionally. Two readers, two different archives, same bytes.

### The prefix equation

The `EOCD` carries three facts that over-determine the layout: its own position `E` (known once found), the central directory's size `S`, and the central directory's declared offset `O`. In an unprefixed archive the central directory ends exactly where the `EOCD` begins, so `E = S + O`. Any prefix of length `P` shifts the file contents but not the recorded offsets, so:

> **`P = E − S − O`**

That is the whole trick, and it is why prefix tolerance could become universal without a specification change: the skew is not merely detectable, it is _measurable exactly, from the footer alone, before reading anything else_. Five implementations compute it, under five names:

| Implementation                                  | Expression                                                    | Name            |
| ----------------------------------------------- | ------------------------------------------------------------- | --------------- |
| Info-ZIP `unzip` [`process.c`][izunzip-process] | `G.extra_bytes = G.real_ecrec_offset - G.expect_ecrec_offset` | `extra_bytes`   |
| Info-ZIP `zip -A` [`zipfile.c`][izzip-zipfile]  | `adjust_offset = zftello(in_file) - 4 - in_cd_start_offset`   | `adjust_offset` |
| OpenJDK [`ZipFile`][jdk-zipfile]                | `locpos = cenpos - end.cenoff`                                | `locpos`        |
| CPython [`zipfile`][cpy-zipfile]                | `concat = endrec[_ECD_LOCATION] - size_cd - offset_cd`        | `concat`        |
| CPython [`zipimport`][cpy-zipimport]            | `arc_offset = header_position - central_directory_position`   | `arc_offset`    |

`zipimport`'s comment says exactly who this is for:

> _"On just-a-zipfile these values are the same and `arc_offset` is zero; if the file has some bytes prepended, `arc_offset` is the number of such bytes. This is used for pex as well as self-extracting `.exe`."_
> — [`Lib/zipimport.py`][cpy-zipimport]

Two significant readers deliberately do **not** compute it. `apksig` [reads `cdStartOffset` literally][apksig-apkutils] and validates only that it precedes the `EOCD`. `libzip` seeks to `cd->offset` as an absolute file position and errors out if the `CEN` magic is not there; its source even carries the unimplemented check as a comment:

```c
/* libzip/lib/zip_open.c — _zip_read_cdir()
 * possible consistency check: cd->offset = len-(cd->size+cd->comment_len+EOCDLEN) ? */
if (zip_source_tell(za->src) != (zip_int64_t)cd->offset) {
    zip_error_set(error, ZIP_ER_NOZIP, 0);
```

The comment describes the prefix equation and declines to apply it. That is a defensible security posture — a reader that cannot be confused about where entries live cannot be tricked into disagreeing with a signature checker — and it is the same choice Android made.

### ZIP64 applies the same skew twice

ZIP64 ([`APPNOTE` §4.3.14, §4.3.15][appnote]) widens the counts and offsets to 64 bits by adding two records before the classic `EOCD`, and it reintroduces the problem one level down: the **ZIP64 EOCD locator** stores the _absolute_ `relative offset of the zip64 end of central directory record`, which is subject to exactly the same prefix skew as the central directory offset. A reader that corrects one and not the other reads garbage.

CPython handles it by trial, and says so:

```python
# Lib/zipfile/__init__.py — _EndRecData64
# First, check the assumption that there is no prepended data.
fpin.seek(reloff)
extrasz = offset - reloff
data = fpin.read(sizeEndCentDir64)
...
if not data.startswith(stringEndArchive64) and reloff != offset:
    # Since we already have seen the Zip64 EOCD Locator, it's
    # possible we got here because there is prepended data.
    # Assume no 'zip64 extensible data'
    fpin.seek(offset)
    extrasz = 0
```

The second seek uses the _positional_ location (immediately before the locator) rather than the recorded one — that is, it falls back from the pointer to the layout. `zipimport` takes the positional route first and leaves a note for anyone who might reverse the preference:

> _"N.b. if someday you want to prefer the standard (non-zip64) EOCD, you need to adjust position by 76 for arc to be 0."_
> — [`Lib/zipimport.py`][cpy-zipimport]

76 = 56 (ZIP64 EOCD) + 20 (ZIP64 locator). The number is a layout constant standing in for a pointer, which is the ZIP64 story in miniature: an extension that widened the fields but did not resolve the "start of the disk" ambiguity that made the fields hard to interpret in the first place.

### `zip -A` and `zip -F`: repair versus tolerance

Info-ZIP ships both strategies, and the distinction is the cleanest statement of the design space:

| Flag         | Name                    | What it does                                                                                                                                                               |
| ------------ | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-A`         | `--adjust-sfx`          | Measures `adjust_offset` and **rewrites** every `CEN` offset and the `EOCD` offset so the prefix becomes part of the file's absolute coordinate system. Result: `P = 0`.   |
| `-J`         | `--junk-sfx`            | Deletes the prefix, restoring a plain archive.                                                                                                                             |
| `-F` / `-FF` | `--fix` / full recovery | Reconstructs the central directory by scanning forward for `LOC` signatures when the footer is damaged or absent — i.e. temporarily treats ZIP as a stream-scanned format. |

`zip`'s own help text states the reason `-A` exists:

> _"`-A` Adjust offsets - a self extractor is created by prepending the extractor executable to archive, but internal offsets are then off. Use `-A` to fix offsets."_
> — [`zip/zip.c`][izzip-zipc]

`-A` normalises; `unzip` tolerates. Both produce a working archive from the same bytes; only `-A` produces one that `libzip` and a strict Android verifier will also open. Measured, on the fixture in [Format identity and multiplicity](#format-identity-and-multiplicity):

```console
$ zip -A fixed.zip
Zip entry offsets appear off by 4110 bytes - correcting...

# EOCD fields, before and after
prefixed.zip  eocd@4405  cdsize 150  cdoff  145  implied prefix 4110
fixed.zip     eocd@4405  cdsize 150  cdoff 4255  implied prefix    0
```

---

## Format identity and multiplicity

### What the bytes are

A ZIP-suffixed file admits, in the general case, at least three simultaneous parses:

1. **As the prefix format.** Whatever the leading bytes declare themselves to be — PE, ELF, a shell script, a SQLite database, a PNG — read by a parser that starts at offset 0 and never looks at the tail.
2. **As a ZIP archive.** Read by a parser that starts at EOF and never looks at the head.
3. **As the semantic format layered on the ZIP.** JAR, APK, DOCX, EPUB, `.whl`: the ZIP member names and their contents constitute a second schema on top of the container.

The three parsers do not merely coexist; they cannot see each other. That mutual blindness is the definition of _format superposition_, and it is what [polyglot craft][poly] industrialises and [parser differentials][pd] weaponise.

### The composition rule

Reduce every format to two independent properties:

- **Prefix-tolerant** — a parser can locate its entry point, and resolve its internal pointers, when an arbitrary byte string precedes the format's own bytes.
- **Suffix-tolerant** — arbitrary bytes may follow without invalidating the parse.

Then, for an ordered pair, the composition rule is one line:

> **`A ∘ B` (A's bytes, then B's) is a valid polyglot iff A is suffix-tolerant and B is prefix-tolerant.**

The relation is on _ordered_ pairs, so it induces a partial order rather than a symmetric compatibility graph. Prefix tolerance itself decomposes into two separate abilities, and separating them is what makes the taxonomy predictive rather than descriptive:

| Sub-property              | Question                                                  | ZIP's answer                                                                      |
| ------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **Locating tolerance**    | Can the parser _find_ its entry point despite the prefix? | Yes, by construction — the back-scan starts at EOF                                |
| **Referential tolerance** | Do the format's internal pointers survive the shift?      | Not intrinsically, but the skew is _recoverable in closed form_ (`P = E − S − O`) |

A format that has locating tolerance and recoverable references is _repairably_ prefix-tolerant, and that is the strongest position short of using only self-relative offsets. It is precisely why ZIP, and only ZIP, became the universal parasite: header-anchored formats fail the first test, and footer-anchored formats with unrecoverable absolute pointers fail the second.

### Tested against nine formats

Every row below was verified on this machine on 2026-08-26 except where the Evidence column says otherwise. Prefixes were 4 096 bytes (and 513/1 024 bytes for `tar`, to test alignment); suffixes were non-empty garbage.

| Format         | Index anchoring                                               | Prefix-tolerant                                                                                                                  | Suffix-tolerant                                         | Unknown bytes             | Evidence                                                                                                                                                 |
| -------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ZIP**        | footer (`EOCD`, back-scan ≤ 65 557 B)                         | **Yes** (repairable; 2 of 5 readers decline)                                                                                     | **Yes** (≤ 65 535 B, or more with lax readers)          | ignored                   | `unzip`, `zipfile`, `7z -tzip` all read a 4 110-byte-prefixed archive                                                                                    |
| **SQLite**     | header at byte 0 (magic, page size @16, `application_id` @68) | No                                                                                                                               | **Yes** (page count is in the header)                   | ignored after last page   | `sqlite3` opened a file with a 512-byte tail; rejected a 4 096-byte prefix                                                                               |
| **tar**        | stream-scanned, 512-byte records                              | **Only at 512-byte alignment**, with a warning                                                                                   | **Yes**                                                 | skipped with a diagnostic | GNU `tar` recovered from 1 024- and 4 096-byte prefixes, failed at 513                                                                                   |
| **gzip**       | header magic `1f 8b`, stream                                  | No                                                                                                                               | **Yes** — a concatenated member is _part of the stream_ | consumed as a member      | `gzip -dc` on two concatenated members emitted both payloads; rejected a 100-byte prefix                                                                 |
| **ELF**        | header at byte 0; `e_phoff`/`e_shoff` absolute                | No                                                                                                                               | Yes                                                     | ignored                   | `e_ident` must be at 0 by definition; see [dynamic linking][dyn]                                                                                         |
| **PE**         | `MZ` at 0, `e_lfanew` → `PE\0\0`; absolute RVAs               | No                                                                                                                               | Yes                                                     | ignored                   | header-anchored by construction; see [boot hybrids][boot]                                                                                                |
| **Java class** | magic `CAFEBABE` at 0; fully length-driven                    | No                                                                                                                               | Yes                                                     | ignored                   | header-anchored by construction                                                                                                                          |
| **Wasm**       | magic `\0asm` at 0; section-length-driven                     | No                                                                                                                               | **No** — trailing bytes are a decode error              | rejected                  | `WebAssembly.validate` (Node 24.19.0) returned `false` for both a 7-byte prefix and a 7-byte suffix on a minimal module; see [the component model][wasm] |
| **PDF**        | footer (`startxref` + `%%EOF` back-scan)                      | Partially — readers accept a shifted `%PDF-` header and adjust `xref` offsets (**unverified here**, no PDF tooling on this host) | Yes                                                     | ignored                   | see [polyglot craft][poly]                                                                                                                               |

Two things fall out immediately.

**First, footer-anchoring is necessary but not sufficient.** PDF is the only other mainstream footer-anchored format in the table, and it is the only other one with a documented polyglot culture. Wasm, which is header-anchored _and_ suffix-intolerant, is the only format in the table that composes with nothing at all in either direction — the strictest identity in current wide deployment, and a deliberate one.

**Second, the order predicts new polyglots.** `SQLite ∘ ZIP` should compose: SQLite is suffix-tolerant, ZIP is prefix-tolerant. Nothing in the literature required this pair to work; the table says it must.

### A predicted polyglot, constructed

```python
# build a file that is simultaneously a SQLite database and a ZIP archive
db = open('poly.db', 'rb').read()          # 8192 bytes, two pages
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('README.txt', 'This entry lives after a complete SQLite database.\n')
    z.writestr('hello.py',   'print("hello from the zip half")\n')
open('poly.sqlite.zip', 'wb').write(db + buf.getvalue())   # 8488 bytes total
```

Verified by four independent readers:

```console
$ python3 -c "import sqlite3; print(sqlite3.connect('poly.sqlite.zip').execute('select * from notes').fetchall())"
[(1, 'the file you are reading is both a database and an archive')]

$ python3 -c "import zipfile; print(zipfile.ZipFile('poly.sqlite.zip').namelist())"
['README.txt', 'hello.py']

$ unzip -l poly.sqlite.zip
warning [poly.sqlite.zip]:  8192 extra bytes at beginning or within zipfile
  (attempting to process anyway)
       51  ...  README.txt
       33  ...  hello.py

$ file -b poly.sqlite.zip
SQLite 3.x database, last written using SQLite version 3053003, ... database pages 2, ...
```

Running `zip -A` on it rewrites the ZIP half's offsets into file-absolute coordinates without touching the first 8 192 bytes, so the result is _also_ readable by the strict readers (`libzip`, an unforced 7-Zip) while remaining a valid database:

```console
$ zip -A poly_fixed.zip
Zip entry offsets appear off by 8192 bytes - correcting...
$ python3 -c "import sqlite3; print(sqlite3.connect('poly_fixed.zip').execute('select count(*) from notes').fetchall())"
[(1,)]
```

The reverse order fails, exactly as the partial order requires — `ZIP ∘ SQLite` yields a file the ZIP readers still accept (the appended database is within the back-scan window as trailing junk) and SQLite rejects (`file is not a database`), because SQLite has no locating tolerance.

> [!NOTE]
> This is the direct answer to the outline's cluster-A open question. The taxonomy is not a catalogue of found polyglots; it is a two-bit classification from which a previously-unlisted polyglot was derived and then built. The interesting consequence for this catalog is that a [SELF][self] binary — a SQLite database that is also an executable — inherits ZIP suffix-parasitism _for free_, because SQLite's suffix tolerance is what the composition needs.

### The ZIP-suffixed ecosystem

Every format below is "a ZIP plus reserved member names". They differ in exactly one further dimension: whether they re-establish a **header-anchored identity** on top of the footer-anchored container.

| Format                     | Reserved names                                                                | Header identity re-established?                                                                  | Prefix tolerance in practice                                   |
| -------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| **JAR**                    | `META-INF/MANIFEST.MF`, `META-INF/*.SF`, `META-INF/*.RSA` / `*.DSA` / `*.EC`  | No — `JarFile` finds the manifest by scanning the central directory                              | Yes (`ZipFile` computes `locpos`)                              |
| **APK**                    | JAR's set, plus the APK Signing Block before the `CEN`                        | No                                                                                               | **No** — `apksig` reads `cdStartOffset` literally              |
| **OOXML** (DOCX/XLSX/PPTX) | `[Content_Types].xml`, `_rels/`                                               | No — the content-type part is located by name                                                    | Reader-dependent                                               |
| **ODF**                    | `mimetype` (**first entry, stored, no extra field**), `META-INF/manifest.xml` | **Yes** — magic at byte 30/38                                                                    | Would break the magic; the ZIP still parses                    |
| **EPUB** (OCF)             | `mimetype` (same three constraints), `META-INF/container.xml`                 | **Yes** — registered media-type magic: `0: PK 0x03 0x04, 30: mimetype, 38: application/epub+zip` | Same                                                           |
| **Python wheel**           | `{name}-{ver}.dist-info/{METADATA,RECORD,WHEEL}`                              | No                                                                                               | Yes, and load-bearing — a shebang-prefixed wheel is importable |
| **NuGet `.nupkg`**         | `*.nuspec`, `[Content_Types].xml`, `.signature.p7s`                           | No                                                                                               | No — the signing code parses the `EOCD` and `CEN` literally    |
| **Self-extracting `.exe`** | none                                                                          | **Yes**, incidentally — the `MZ` stub _is_ the header identity                                   | Required                                                       |
| **APE / redbean**          | `/zip/…` paths resolved by the C runtime                                      | **Yes** — the prefix is simultaneously PE, ELF, Mach-O, shell and MBR                            | Required; offsets are fixed at link time                       |

The ODF/EPUB row is the most instructive. Both specifications spend three mandatory constraints — first entry, stored uncompressed, no extra field — on nothing but pinning a string at a fixed byte offset, and ODF's own note says why:

> _"The purpose is to allow the type of document represented by the package to be discovered through 'magic number' mechanisms, such as Unix's file/magic utility. If a Zip file contains a file at the beginning of the file that is uncompressed, and has no extra data in the header, then its file name and data can be found at fixed positions from the beginning of the package. More specifically, one will find: the string 'PK' at position 0 of all zip files; the string 'mimetype' beginning at position 30; the media type itself beginning at position 38."_
> — [OpenDocument v1.2 Part 3, §3.3][odf3]

EPUB 3.3 restates the same constraints normatively and registers the resulting layout as the media type's magic number ([§ OCF ZIP container media type identification][epub33] and the `application/epub+zip` registration). The pattern is worth naming: **a footer-indexed format that needs to be identified by a header-anchored dispatcher must smuggle a header back in by constraining its first entry.** ODF and EPUB pay for identification by giving up exactly the prefix tolerance that makes ZIP parasitic in the first place — a prefix does not break the archive, but it does break the media type. Both properties cannot be had at once.

---

## Index anchoring and random access

ZIP is the catalog's canonical **footer-anchored** format; it and Parquet/ORC are why [footer-indexed formats][fif] deserves its own entry.

**What a ranged read costs.** Opening a remote ZIP over HTTP range requests takes a fixed three round trips in the common case and four with ZIP64:

| Step | Range                                                                | Bytes                                         |
| ---- | -------------------------------------------------------------------- | --------------------------------------------- |
| 1    | `bytes=-65557` (or a smaller speculative tail)                       | ≤ 65 557 — enough to contain any legal `EOCD` |
| 2    | ZIP64 locator + ZIP64 `EOCD`, if the 32-bit fields are `0xFFFFFFFF`  | 76                                            |
| 3    | `bytes=O-(O+S-1)` — the whole central directory                      | `S`, typically ~46 + name length per entry    |
| 4    | `bytes=hdr-(hdr+len-1)` — one entry's `LOC` plus its compressed data | one entry                                     |

Step 3 is the cost that matters: the central directory is a _linear array of variable-length records_, not a searchable structure. You cannot binary-search it, because you cannot find the `k`-th record without walking the first `k−1`. Every reader therefore materialises it in full and builds a real index on top — and every reader builds a _different_ one:

| Reader                                                   | Index built over the central directory                                                                                                                                |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPython [`zipfile`][cpy-zipfile]                         | `NameToInfo`, a `dict` of name → `ZipInfo`                                                                                                                            |
| OpenJDK [`ZipFile`][jdk-zipfile]                         | `int[] entries` — a hand-packed open-hash table of `(hash, next, pos)` triples, deliberately storing a 32-bit name hash rather than the name "in order to save space" |
| Cosmopolitan [`zipos`][cosmo-ziposget]                   | `__zipos_generate_index` — an array of `CEN` offsets sorted by name, searched with `qsort_r`/binary search                                                            |
| `apksig` [`ApkSigningBlockUtilsLite`][apksig-blockutils] | none for entries; a linear walk of ID-value pairs for the signing block                                                                                               |

This is thesis 1 of the source outline — _every binary format eventually reimplements a database, badly_ — with four witnesses in one format. ZIP's "index" is a serialised table scan; the actual index is reconstructed at open time, from scratch, by every consumer, and no two agree on the data structure. Compare [SQLite as an application file format][sqlite-aff], where the b-tree _is_ the on-disk index and the reader builds nothing.

**Can it be consumed without reading it all?** Yes for extraction of a known member (four ranged reads), no for enumeration (the whole `CEN` is mandatory), and no at all for a streaming consumer that cannot seek — which is why `JarInputStream` exists as a separate, _front_-anchored reader with its own rules (below), and why the wheel format's tolerance for `zipimport` matters: `zipimport` maps the file and reads the footer, so a wheel on `sys.path` costs one open and one directory materialisation, not an unpack. See [range-request access][rra] for the general pattern.

---

## Reflexivity and query surface

**Score: 1 (incidental).** ZIP is self-describing about _its own layout_ and about nothing else. The central directory is a manifest of the archive's contents — names, sizes, CRCs, timestamps, attributes — which is genuinely more than tar offers, and it is queryable in the weak sense that `unzip -l`, `zipinfo`, and `ZipFile.infolist()` enumerate it. There is no query language, no predicate pushdown, no join, and no way to ask a question the `CEN` fields do not already answer.

What the ecosystem does instead is **layer a second, textual index inside the archive** — one per ecosystem, each hand-rolled:

| Format        | Secondary index                    | What it adds over the `CEN`                                                           |
| ------------- | ---------------------------------- | ------------------------------------------------------------------------------------- |
| JAR           | `META-INF/MANIFEST.MF`             | Per-entry digests over _uncompressed_ content, `Class-Path`, `Multi-Release`, sealing |
| Wheel         | `{dist}.dist-info/RECORD`          | Per-file hash and size, for install-time verification and uninstall                   |
| NuGet         | `*.nuspec`, `[Content_Types].xml`  | Dependency graph, licence, content-type mapping                                       |
| OOXML/ODF/OPC | `[Content_Types].xml`, `_rels/`    | MIME type per part, plus a typed relationship graph between parts                     |
| EPUB          | `META-INF/container.xml` → OPF     | Spine, manifest, reading order                                                        |
| APK           | `AndroidManifest.xml` (binary XML) | Permissions, components, SDK levels                                                   |

Every one of these is a dependency/type/integrity table serialised as text inside a container that already has a table. The JAR manifest is the oldest and the most explicitly database-shaped — a sequence of RFC-822-style sections keyed by `Name:`, with per-key attributes:

```
Manifest-Version: 1.0
Created-By: 1.8.0 (Oracle Inc.)

Name: common/class1.class
SHA-256-Digest: (base64 representation of SHA-256 digest)
```

— [JAR File Specification][jarspec]

The JAR spec's own framing is exactly the parasitic one: _"A JAR file is essentially a zip file that contains an optional `META-INF` directory."_ Reflexivity here is a convention layered by consumers, not a property of the container — the contrast with [sqlelf][sqlelf] and [code as a database][cadb], where the query surface is the point, could not be sharper. See also [binary inspection libraries][bil] for the equivalent layer over ELF.

**Self-inspection at runtime** is the one place ZIP scores above zero honestly. A running APE binary reads its own archive through `open("/zip/...")`, and Cosmopolitan's `__zipos_dismiss` walks the central directory to compute the byte range the local file entries occupy so it can `munmap` the executable text underneath them:

```c
/* cosmopolitan/libc/runtime/zipos-get.c — __zipos_dismiss()
   determine the byte range of zip file content (excluding central dir) */
c = GetZipCdirOffset(cdir);
n = GetZipCdirRecords(cdir);
for (lo = c, hi = i = 0; i < n; ++i, c += ZIP_CFILE_HDRSIZE(map + c)) { ... }
mo = ROUNDDOWN(lo, __gransize);
if (mo && !IsWindows()) munmap(map, mo);
```

The program consults its own footer index to decide which of its own pages to unmap. That is genuine reflexivity, but it is Cosmopolitan's, not ZIP's — see [Cosmopolitan / APE][ape].

---

## Closure, dedup, and size model

**Score: 2 (designed-in, at the ecosystem layer).**

ZIP itself carries no dependency notion. What the suffixed formats add is a _declared_ closure — `Class-Path` in a JAR manifest, `dependencies` in a `.nuspec`, `Requires-Dist` in a wheel's `METADATA`, `uses-library` in an `AndroidManifest.xml` — and, in the fat-artifact case, the actual transitive contents: an uber-JAR, an APK's bundled `lib/*/`, a wheel's vendored shared objects. That is closure by inclusion, not by content-addressed reference, and it is the tradeoff [Nix store closures][nix] and [content-addressed chunking][cac] resolve the other way.

**Deduplication: none, at three levels.**

1. _Within an archive_, two identical members are stored twice. There is no content addressing, no reference-by-hash, and no shared-block mechanism.
2. _Across archives_, nothing is shared. Ten JARs that each vendor the same library ship ten copies. The [application-packaging comparison][artifact-formats] quantifies the distribution consequences.
3. _Within an entry_, the deflate window is per-member and is reset at each entry boundary — ZIP's original streaming requirement. A tarball compressed as one stream (`tar.gz`) therefore compresses a directory of similar small files substantially better than a ZIP of the same tree, at the cost of losing exactly the random access ZIP was built for. That trade is the format's oldest and least negotiable.

**Size model.** Per-entry overhead is deterministic: 30 bytes of `LOC` + 46 bytes of `CEN` + twice the UTF-8 name length + extra fields, plus 22 bytes of `EOCD` (plus 76 for ZIP64). For the two-file fixture used above, `plain.zip` was 317 bytes for 19 bytes of payload. On a JAR with thousands of short class names the central directory alone runs to hundreds of kilobytes, which is precisely why the OpenJDK stores a 32-bit name hash instead of the name in its in-memory index and why the whole `CEN` must be fetched before any member can be located.

The APK Signing Block adds one more, unusual, size constraint: when the `VERITY_CHUNKED_SHA256` content digest is in use, `apksig` requires the block to be **page-aligned**, and enforces it as an assertion:

```java
// apksig ApkSigningBlockUtils.verifyIntegrity
if ((beforeApkSigningBlock.size() % ANDROID_COMMON_PAGE_ALIGNMENT_BYTES != 0)) {
    throw new RuntimeException("APK Signing Block is not aligned on 4k boundary: " + ...);
}
```

Padding a footer-indexed archive to a page boundary so a _different_ verifier can `mmap` it is the clearest case in this catalog of thesis 4 — `mmap` as the load-bearing constraint — asserting itself on a format that predates the concern by two decades.

---

## Mutability, dispatch, and trust

**Mutability: 1 (incidental).** A ZIP can be extended in place: append the new entries after the last existing one, write a fresh central directory over the old one, write a new `EOCD`. Deleting or modifying an entry, by contrast, requires a rewrite, because everything after it shifts and every recorded offset becomes stale. There is no transaction, no journal, no atomicity: a crash mid-append leaves an archive whose footer describes a directory that is not there — recoverable only by `zip -FF`'s forward scan for `LOC` signatures. This is the whole distance between ZIP and [SQLite as an application file format][sqlite-aff], and the reason redbean's `StoreAsset` is gated behind an explicit opt-in flag.

### Dispatch: who decides what the file is

Measured, on the fixtures above (2026-08-26):

| Consumer                    | `prefixed.zip` (shell-script prefix + ZIP)                      | `concat.zip` (two complete ZIPs)                                                                 |
| --------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `file(1)` 5.48              | `POSIX shell script executable (binary data)` — **header wins** | `Zip archive data`                                                                               |
| Info-ZIP `unzip` 6.00       | opens, warns `4110 extra bytes at beginning or within zipfile`  | lists **`c.txt`** — the _second_ archive; last `EOCD` wins                                       |
| CPython `zipfile` 3.11      | opens silently                                                  | lists **`c.txt`**                                                                                |
| p7zip 17.05, default        | `Open ERROR: Can not open the file as [zip] archive`            | lists **`a.txt`, `b.txt`** — the _first_ archive; reports `Physical Size = 317, Tail Size = 164` |
| p7zip 17.05, `-tzip` forced | opens                                                           | same as above                                                                                    |

Two findings, both load-bearing.

**7-Zip's rejection is a dispatch decision, not a parse failure.** Forcing the handler with `-tzip`, or renaming the file to `.exe`, makes the identical bytes open successfully. 7-Zip's _parser_ is prefix-tolerant; its _dispatcher_ is header-anchored and sniffs the leading bytes. This is the outline's second structural sub-question — who decides what the file is — answered empirically: for ZIP, the consumer decides, and the consumer usually decides by looking at byte 0 of a format that does not put anything meaningful there.

**Concatenating two archives is a live, trivially reproducible parser differential.** `unzip` and CPython see one file; 7-Zip sees a different one; neither errors. A signature checker on one side of that disagreement and an extractor on the other is the classic shape of an archive-confusion vulnerability, and it is precisely the class of bug [parser differentials][pd] catalogues. Note that Info-ZIP's back-scan takes the last `EOCD` unconditionally while `apksig` requires the comment-length field to match exactly — the _only_ structural defence against this in the readers surveyed.

### Signing a footer-indexed format

ZIP has had a native `[digital signature]` record (`0x05054b50`, `APPNOTE` §4.3.13) since the 1990s. Essentially nothing uses it, and the three large ecosystems that had to sign ZIP-suffixed artifacts each invented something else. Their solutions form a clean taxonomy of the ways to sign a format whose index is a self-referential footer.

**1. JAR v1 — sign the _contents_, ignore the _container_.** `META-INF/MANIFEST.MF` holds a digest per entry over the entry's **uncompressed** bytes; `*.SF` digests the manifest; the PKCS#7 blob signs the `.SF`. No offset, no compression method, and no ZIP metadata is covered. The scheme is therefore completely offset-agnostic — a prefixed, re-`zip -A`'d, or recompressed JAR still verifies — and correspondingly weak: Android's documentation notes the consequence, that v1 leaves the container itself unprotected and requires the verifier to reject entries not listed in the manifest.

**2. APK v2/v3 — invent a new place to put bytes.** Android Signature Scheme v2 (Android 7.0, 2016) treats the APK as four sections and signs three of them plus the signed data of the fourth:

> _"For the purposes of protecting APK contents, an APK consists of four sections: (1) Contents of ZIP entries (from offset 0 until the start of APK signing block), (2) APK signing block, (3) ZIP Central Directory, (4) ZIP End of Central Directory."_
> — [APK Signature Scheme v2][apkv2]

The **APK Signing Block** is inserted immediately before the central directory — the one region a ZIP reader is guaranteed never to look at, because the `EOCD` points _over_ it. Its layout is deliberately self-locating in both directions:

```
uint64  size of block (excluding this field)
        sequence of uint64-length-prefixed (uint32 ID, value) pairs
uint64  size of block (repeated)
uint128 magic "APK Sig Block 42"
```

`apksig` finds it by reading the 24 bytes immediately below `centralDirStartOffset`, checking the magic, and using the trailing size to jump to the block's own header, where the size is repeated and must match ([`ApkUtilsLite.findApkSigningBlock`][apksig-apkutils]). It insists that `centralDirEndOffset == eocdStartOffset` — no trailing slack — before it will look.

Then comes the part that makes this the sharpest case in the catalog. The `EOCD` contains the central directory's offset, which _changes whenever the signing block's size changes_ — including when a signature is added. Signing a record that points past the thing being signed is circular. Both the specification and the implementation resolve it by canonicalising the pointer away:

> _"Protection of section 4 (ZIP End of Central Directory) is complicated by the section containing the offset of ZIP Central Directory. The offset changes when the size of the APK signing block changes, for instance, when a new signature is added. Thus, when computing digest over the ZIP End of Central Directory, the field containing the offset of ZIP Central Directory must be treated as containing the offset of the APK signing block."_
> — [APK Signature Scheme v2][apkv2]

```java
// apksig ApkSigningBlockUtils.verifyIntegrity
// For the purposes of verifying integrity, ZIP End of Central Directory (EoCD) must be
// treated as though its Central Directory offset points to the start of APK Signing Block.
// We thus modify the EoCD accordingly.
ZipUtils.setZipEocdCentralDirectoryOffset(modifiedEocd, beforeApkSigningBlock.size());
```

**Signing a footer-indexed format requires inventing a new place to put bytes, and then deleting the footer's pointer before hashing it.** That sentence is the whole design, and it generalises: any format whose index records its own layout has this problem, and every solution is some form of "hash a normalised layout, not the real one". Compare the equivalent problem for a mutable self-storing artifact in [embedded provenance][prov] and [threat model][threat].

Android layers two further defences on top, both of which exist because the parasitism is bidirectional: an `X-Android-APK-Signed` attribute in the v1 `.SF` file names the schemes the APK is also signed with, so a v2-signed APK cannot be downgraded to v1 verification; and the list of signature algorithm IDs is inside the signed data, so stronger signatures cannot be stripped.

**3. NuGet — sign an entry, then un-add it.** NuGet puts the signature in a ZIP member named `.signature.p7s` and, to verify, reconstructs the archive as it was before signing: it copies everything up to the signature's `LOC`, skips the entry, copies up to its `CEN` record, skips that, and subtracts the removed sizes from every subsequent offset and from the `EOCD`. NuGet's signing code contains a full, independent re-implementation of the ZIP record structures for exactly this purpose — `EndOfCentralDirectoryRecord.cs`, `CentralDirectoryHeader.cs`, `Zip64EndOfCentralDirectoryLocator.cs`, `Zip64ExtendedInformationExtraField.cs` — because `System.IO.Compression` will not give it byte-exact control ([`SignedPackageArchiveIOUtility`][nuget-io]).

Three ecosystems, three answers, one shared root cause. Summarised:

| Scheme     | Where the signature lives                    | How the footer's self-reference is neutralised                                     | Covers ZIP metadata? |
| ---------- | -------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------- |
| ZIP native | `[digital signature]` record after the `CEN` | not specified in detail; effectively unused                                        | n/a                  |
| JAR v1     | `META-INF/*.SF` + PKCS#7, per-entry digests  | not applicable — offsets are never hashed                                          | **No**               |
| APK v2/v3  | a new block before the `CEN`                 | the `EOCD`'s CD-offset field is overwritten with the block's offset before hashing | **Yes** (1, 3, 4)    |
| NuGet      | a `.signature.p7s` ZIP entry                 | the entry is logically removed and all later offsets are decremented               | Partly               |

### Threat model

Prefix tolerance is a security property, not just a convenience. A reader that computes `P = E − S − O` and one that does not will disagree about the byte offsets of every entry in a prefixed archive — and _both_ will report success. Add a second `EOCD` and the disagreement extends to which entries exist at all, as the `concat.zip` measurement shows. The historical family is well known — GIFAR (a file that is both a GIF and a JAR, dispatched differently by an image loader and a JVM), MalDoc-in-PDF, Android's Master Key bugs, MIME-sniffing confusion — and all of it is the same mechanism: one byte stream, several parsers, no shared notion of identity. [Parser differentials][pd] and [threat model][threat] carry that thread; [polyglot craft][poly] carries the constructive side.

The mitigations visible in the source surveyed are, in increasing strictness: cross-check the `EOCD` comment length against the remaining bytes (`apksig`, and the OpenJDK's re-validation path); refuse to compensate for a prefix at all (`libzip`, `apksig`); require the central directory to end exactly at the `EOCD` (`apksig`); and sign a canonicalised layout rather than the observed one (APK v2). None of these is in `APPNOTE.TXT`.

---

## Strengths

- **Universal availability.** A ZIP reader exists in every language runtime and every operating system shipped in the last thirty years, which is why every new packaging format that could reuse it, did.
- **Random access per member.** The central directory makes "extract one file from a 2 GiB archive" a bounded operation, which tar cannot do at all and which is the entire basis of [range-request access][rra] to remote archives.
- **Streaming write, seeking read.** Producers need one forward pass; consumers get an index. Very few formats give both.
- **Prefix tolerance is recoverable in closed form.** The `P = E − S − O` identity means the skew introduced by an arbitrary prefix is exactly measurable from 22 bytes, which is why five independent implementations converged on the same repair without coordination.
- **Suffix parasitism is the cheapest form of composition available.** Adding a ZIP to any suffix-tolerant format costs a concatenation; no other container has this property at this level of ubiquity.
- **`zip -A` provides an escape hatch.** A parasitic archive can be normalised into a strictly-conforming one without moving a byte of the prefix.

## Weaknesses

- **The permission is unwritten.** `APPNOTE.TXT` never sanctions leading bytes; the ecosystem runs on convention, which is why `libzip`, `apksig`, and 7-Zip's dispatcher each opted out at different points and no one is wrong.
- **The central directory is not an index.** It is a linear array of variable-length records that every consumer must read entirely and re-index in memory, with a different data structure each time.
- **Two indexes that can disagree.** `LOC` and `CEN` duplicate every entry's metadata with no requirement that they match, and different readers prefer different ones — a permanent parser-differential surface.
- **No deduplication at any level**, and a per-entry deflate window that compresses a tree of similar files far worse than a single-stream `tar.gz`.
- **32-bit fields everywhere**, patched by ZIP64 records that reintroduce the same absolute-offset ambiguity one level down and are handled by trial-and-error in at least one major implementation.
- **Signing is a retrofit.** The native `[digital signature]` record is effectively dead; the three real schemes each had to invent a container-level story, and two of them re-implemented ZIP parsing to do it.
- **No transactions.** In-place mutation is append-and-rewrite-the-footer; a crash yields an archive whose footer describes a directory that is not there.
- **`EOCD` back-scan is unbounded in the adversarial case.** The 65 557-byte bound is a bound on the _comment_, not on how far a lax reader will search a hostile file for a plausible signature.

---

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                                           | Trade-off                                                                                                                       |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Write the index last (`EOCD` + central directory at EOF)                   | Single-pass streaming write on sequential media; entry sizes are unknown until compression finishes | The index must be _found_, not addressed — every read starts with a backwards scan                                              |
| Locate the `EOCD` by reverse signature scan                                | The comment field makes its position variable                                                       | Any 4 bytes in the file can impersonate the record; the last match wins in most readers; a live differential                    |
| Duplicate entry metadata in `LOC` and `CEN`                                | Serves streaming readers and random-access readers from the same bytes                              | Two indexes that may disagree; the primary confusion surface in ZIP security history                                            |
| Record `relative offset of local header` as "from the start of the disk"   | Correct and unambiguous for single-archive floppies                                                 | Undefined for prefixed files; every implementation had to pick archive-relative or file-relative independently                  |
| Tolerate a prefix by computing `P = E − S − O`                             | Makes self-extracting archives work with no format change and no flag                               | Not in the specification; strict readers reject; the same file has two legitimate readings                                      |
| Offer both `-A` (rewrite offsets) and implicit tolerance                   | Repair produces a strictly-conforming archive; tolerance requires no writer cooperation             | Two coexisting conventions; an archive can be valid to one half of the ecosystem and not the other                              |
| ZIP64 as extra records rather than a format revision                       | Backward compatible — a legacy reader sees a well-formed `EOCD` with `0xFFFFFFFF` sentinels         | The locator's absolute offset re-creates the prefix ambiguity; CPython resolves it by trying both interpretations               |
| Per-entry deflate window                                                   | Preserves per-member random access                                                                  | Substantially worse compression than single-stream `tar.gz` on many similar small files                                         |
| ODF/EPUB: constrain the first entry to pin a magic at byte 38              | Restores header-anchored identification for `file(1)` and media-type dispatch                       | Spends three normative constraints to buy back what footer anchoring gave away; a prefix breaks identification                  |
| APK: a new block before the central directory, with a canonicalised `EOCD` | The only region of a ZIP no reader inspects; makes whole-file signing possible                      | Requires a bespoke parser, page alignment for `fs-verity`, and a rule that the `EOCD`'s own pointer be rewritten before hashing |
| NuGet: signature as a removable ZIP entry                                  | Keeps the artifact a plain ZIP for every consumer                                                   | Verification must reconstruct the pre-signing byte layout and decrement every later offset                                      |

---

## Sources

- [PKWARE `APPNOTE.TXT` — .ZIP File Format Specification, version 6.3.10 (2022-11-01)][appnote] — §4.1.9 self-extracting archives, §4.1.11 manifest files, §4.3.6 overall layout, §4.3.7/§4.3.12/§4.3.16 record layouts, §4.3.13 digital signature, §4.3.14/§4.3.15 ZIP64, §4.4.16 relative offset of local header, §4.5.3 ZIP64 extra field
- [Info-ZIP `unzip` — `process.c` (`find_ecrec`, `extra_bytes`)][izunzip-process] and [`fileio.c` (`seek_zipf`)][izunzip-fileio]
- [Info-ZIP `zip` — `zipfile.c` (`adjust_offset`, `zipbeg`)][izzip-zipfile] and [`zip.c` (`-A`/`-J` documentation)][izzip-zipc]
- [OpenJDK — `java.util.zip.ZipFile` (`findEND`, `initCEN`, `locpos`, the packed entry hash table)][jdk-zipfile]
- [OpenJDK — `java.util.jar.JarInputStream` (streaming manifest-first rule)][jdk-jaris] and [`JarFile`][jdk-jarfile]
- [CPython — `Lib/zipfile/__init__.py` (`_EndRecData`, `_EndRecData64`, `_handle_prepended_data`)][cpy-zipfile], [`Lib/zipimport.py` (`arc_offset`)][cpy-zipimport], [`Lib/zipapp.py` (shebang prefix)][cpy-zipapp]
- [`libzip` — `lib/zip_open.c` (`_zip_find_central_dir`, literal `cd->offset` seek)][libzip-open]
- [Android — APK Signature Scheme v2][apkv2] and [v3][apkv3]; [`apksigner` tool documentation][apksigner]
- [`apksig` — `ApkUtilsLite.findApkSigningBlock`][apksig-apkutils], [`ApkSigningBlockUtils.verifyIntegrity`][apksig-blockutils2], [`ApkSigningBlockUtilsLite.findSignature`][apksig-blockutils], [`ZipUtils.findZipEndOfCentralDirectoryRecord`][apksig-ziputils]
- [JAR File Specification (Java SE 21)][jarspec]
- [EPUB 3.3 — OCF ZIP container media type identification][epub33]
- [OASIS OpenDocument v1.2 Part 3 §3.3 — MIME Media Type][odf3]
- [ECMA-376 — Office Open XML / Open Packaging Conventions][ecma376]
- [Python packaging — Binary distribution format (the wheel spec)][wheelspec]
- [NuGet — `SignedPackageArchiveIOUtility`][nuget-io], [`SigningSpecificationsV1`][nuget-spec], [signing a package][nuget-sign]
- [Cosmopolitan — `GetZipEocd`][cosmo-eocd], [`IsZipEocd32`][cosmo-iseocd], [`zipos-get.c`][cosmo-ziposget], [`libc/zip.h`][cosmo-ziph]
- Related in this tree: [Cosmopolitan / APE][ape] · [polyglot craft][poly] · [parser differentials][pd] · [footer-indexed formats][fif] · [range-request access][rra] · [threat model][threat] · [SQLite as an application file format][sqlite-aff] · [SELF / selfdb][self] · [embedded provenance][prov] · [comparison][comparison]
- Adjacent tree: [application packaging — artifact formats][artifact-formats]

<!-- References -->

[appnote]: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
[infozip]: http://web.archive.org/web/20260825003637/https://infozip.sourceforge.net/
[libzip-docs]: https://libzip.org/
[libzip-repo]: https://github.com/nih-at/libzip
[izzip-repo]: https://github.com/thejoshwolfe/info-zip-zip
[izunzip-repo]: https://github.com/thejoshwolfe/info-zip-unzip
[izunzip-process]: https://github.com/thejoshwolfe/info-zip-unzip/blob/8dc3744e68a0ce7d3cf95de274f7be2e1c2713c3/process.c
[izunzip-fileio]: https://github.com/thejoshwolfe/info-zip-unzip/blob/8dc3744e68a0ce7d3cf95de274f7be2e1c2713c3/fileio.c
[izzip-zipfile]: https://github.com/thejoshwolfe/info-zip-zip/blob/c02577fe070ece9f674744e7c6a6ccfd69416b3d/zipfile.c
[izzip-zipc]: https://github.com/thejoshwolfe/info-zip-zip/blob/c02577fe070ece9f674744e7c6a6ccfd69416b3d/zip.c
[libzip-open]: https://github.com/nih-at/libzip/blob/31eefd70f27d33a442466914f5919c84784eafd8/lib/zip_open.c
[jdk-zipfile]: https://github.com/openjdk/jdk/blob/30df8a5af29ff682f9b6d50e51c46efcf19c920f/src/java.base/share/classes/java/util/zip/ZipFile.java
[jdk-jaris]: https://github.com/openjdk/jdk/blob/30df8a5af29ff682f9b6d50e51c46efcf19c920f/src/java.base/share/classes/java/util/jar/JarInputStream.java
[jdk-jarfile]: https://github.com/openjdk/jdk/blob/30df8a5af29ff682f9b6d50e51c46efcf19c920f/src/java.base/share/classes/java/util/jar/JarFile.java
[cpy-zipfile]: https://github.com/python/cpython/blob/9036982ed73d17848d45b60b7550f097371214e4/Lib/zipfile/__init__.py
[cpy-zipimport]: https://github.com/python/cpython/blob/9036982ed73d17848d45b60b7550f097371214e4/Lib/zipimport.py
[cpy-zipapp]: https://github.com/python/cpython/blob/9036982ed73d17848d45b60b7550f097371214e4/Lib/zipapp.py
[apksig-apkutils]: https://github.com/LineageOS/android_tools_apksig/blob/6447768c0e8ab4385a47e7bb85e6bdba0085dced/src/main/java/com/android/apksig/apk/ApkUtilsLite.java
[apksig-blockutils]: https://github.com/LineageOS/android_tools_apksig/blob/6447768c0e8ab4385a47e7bb85e6bdba0085dced/src/main/java/com/android/apksig/internal/apk/ApkSigningBlockUtilsLite.java
[apksig-blockutils2]: https://github.com/LineageOS/android_tools_apksig/blob/6447768c0e8ab4385a47e7bb85e6bdba0085dced/src/main/java/com/android/apksig/internal/apk/ApkSigningBlockUtils.java
[apksig-ziputils]: https://github.com/LineageOS/android_tools_apksig/blob/6447768c0e8ab4385a47e7bb85e6bdba0085dced/src/main/java/com/android/apksig/internal/zip/ZipUtils.java
[apkv2]: https://source.android.com/docs/security/features/apksigning/v2
[apkv3]: https://source.android.com/docs/security/features/apksigning/v3
[apksigner]: https://developer.android.com/tools/apksigner
[jarspec]: https://docs.oracle.com/en/java/javase/21/docs/specs/jar/jar.html
[epub33]: https://www.w3.org/TR/epub-33/
[odf3]: https://docs.oasis-open.org/office/v1.2/os/OpenDocument-v1.2-os-part3.html
[ecma376]: https://ecma-international.org/publications-and-standards/standards/ecma-376/
[wheelspec]: https://packaging.python.org/en/latest/specifications/binary-distribution-format/
[nuget-io]: https://github.com/NuGet/NuGet.Client/blob/b2c37dfcb1b34bd980c5b83219097d3533c11158/src/NuGet.Core/NuGet.Packaging/Signing/Archive/SignedPackageArchiveIOUtility.cs
[nuget-spec]: https://github.com/NuGet/NuGet.Client/blob/b2c37dfcb1b34bd980c5b83219097d3533c11158/src/NuGet.Core/NuGet.Packaging/Signing/Specifications/SigningSpecificationsV1.cs
[nuget-sign]: https://learn.microsoft.com/en-us/nuget/create-packages/sign-a-package
[cosmo-eocd]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/str/getzipeocd.c
[cosmo-iseocd]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/str/iszipeocd32.c
[cosmo-ziposget]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/runtime/zipos-get.c
[cosmo-ziph]: https://github.com/jart/cosmopolitan/blob/3293fad0a9eac7865c019be98fb993eeb933405e/libc/zip.h
[ape]: ./cosmopolitan-ape/index.md
[poly]: ./polyglot-craft.md
[pd]: ./parser-differentials.md
[fif]: ./footer-indexed-formats.md
[rra]: ./range-request-access.md
[threat]: ./threat-model.md
[prov]: ./embedded-provenance.md
[sqlite-aff]: ./sqlite-application-file-format.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[cadb]: ./code-as-database.md
[bil]: ./binary-inspection-libraries.md
[dyn]: ./dynamic-linking.md
[boot]: ./boot-hybrids.md
[wasm]: ./wasm-component-model.md
[nix]: ./nix-store-closures.md
[cac]: ./content-addressed-chunking.md
[comparison]: ./comparison.md
[artifact-formats]: ../application-packaging/artifact-formats.md
