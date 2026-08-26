# Polyglot craft — Corkami and PoC||GTFO (format superposition as a discipline)

The deliberate-polyglot tradition: a body of proofs-of-concept, a taxonomy, and finally a generator (`mitra`) that together answer the question _which formats compose, and why_ — by building files that are simultaneously a PDF, a ZIP, a TAR, an ISO, an iNES ROM, and a boot sector, and then writing down the structural rule that made each composition possible.

| Field           | Value                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Kind            | Craft tradition + PoC corpus + a polyglot generator (`mitra`) + a document series (PoC&#124;&#124;GTFO)                              |
| Language        | Python (`mitra`, `mocky`), NASM/x86, LaTeX (`pdflatex`), and the file formats themselves                                             |
| License         | MIT (`corkami/mitra`, `corkami/pocs` mini corpus); PoC&#124;&#124;GTFO issues released as free PDFs                                  |
| Repository      | [corkami/mitra][mitra] · [corkami/pocs][pocs] · [corkami/docs][ckdocs] · [angea/pocorgtfo][pocorgtfo]                                |
| Documentation   | ["Abusing file formats"][aff] (= PoC&#124;&#124;GTFO 7:6) · [`mitra/README.md`][mitra-readme] · [PDF tricks][pdftricks]              |
| First release   | Corkami PoCs from c. 2009; PoC&#124;&#124;GTFO `0x00` on 2013-08-05; `mitra` `0.3` dated 2023-03-25 in [`mitra.py`][mitra-py]        |
| Axis profile    | Multiplicity 3 / Reflexivity 1 / Closure 1 / Mutability 0                                                                            |
| Index anchoring | **Mixed by construction** — a footer-anchored host (ZIP `EOCD`, PDF `startxref`) wrapping header-anchored and offset-anchored guests |
| Dispatch owner  | Consumer sniffing (libmagic / TrID / the renderer's own recovery heuristics); occasionally the shell, via a renamed extension        |

> **Latest revision surveyed:** `corkami/mitra` at `95e1d2a7`, `corkami/pocs` at `6d277c83`, `corkami/docs` at `fd339bf6`, `angea/pocorgtfo` at `933c020f` (2024-02-11). **Platform:** format-level, so none — the artifacts are byte streams; the verification below was run on Linux with `file` 5.x, Info-ZIP `unzip`, GNU `tar` and Python 3.

---

## Overview

### What it solves

This subject is the catalog's **control group for [thesis 5][index]** — that portability has migrated from the format to the access layer. Polyglot craft is the _old_ strategy taken to its limit: reach is bought by satisfying every parser's grammar at once, in one immutable byte stream, with no substrate, no loader cooperation, and no runtime. [redbean/APE][ape] is the engineering-grade descendant of exactly this technique; everything APE does to a PE/ELF/Mach-O/ZIP/shell-script header, Corkami had already done to a PDF/JPEG/ZIP/TAR/ISO header, first as art and then as a security argument.

Concretely, the tradition solves three separate problems that the rest of this catalog keeps colliding with:

1. **A taxonomy of composability.** Which pairs of formats can share a byte stream, and — the useful part — _from what structural property of each format does that follow_? [`mitra`][mitra] is that taxonomy compiled into code: 48 format parsers, each declaring a handful of tolerance flags and offsets, plus a driver that mechanically tries four layouts on every ordered pair. Its `README.md` publishes the resulting matrix: **288 format combinations** over the surveyed set. This is the [open question in cluster A][open-questions] of the source outline, already answered for a concrete corpus.
2. **A demonstration argument.** A bad format design is not a vulnerability, so it is never fixed. Albertini's response is to make bad design _cheap to exploit_ and therefore visible.
3. **A publication vehicle.** PoC&#124;&#124;GTFO ships each issue as one file that is at once a readable journal, an archive of the code its articles describe, and a running joke about the file's own type — which is the [autological](./concepts.md) move this catalog is named for.

### Design philosophy

The opening of ["Abusing file formats"][aff] states the position that the whole tradition rests on:

> _"First, you must realize that a file has no intrinsic meaning. The meaning of a file - its type, its validity, its contents - can be different for each parser or interpreter."_

And immediately after, the vocabulary the rest of this page uses:

> _"A **polyglot** is a file that has different types simultaneously, which may bypass filters and avoid security counter-measures. A **multiple-personality** (let's call them 'multi') file is one that is interpreted differently depending on the parser. These files may look innocent (or corrupted) to one interpreter, malicious to another. A **chimera** is a polyglot where the same data is interpreted as different types, which is a more advanced kind of filter bypass."_

Three terms, three different claims, and it is worth keeping them apart because the catalog's axes score them differently:

| Term                                 | Claim                                                            | Axis consequence                                                                   |
| ------------------------------------ | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| **Polyglot**                         | One stream, `n` types, all valid simultaneously                  | Multiplicity `n`; parsers agree that the file is _also_ their type                 |
| **Multi** (formerly _schizophrenic_) | One stream, one nominal type, **different content** per parser   | Multiplicity 1, but a [parser differential][pdiff] — the interesting failure mode  |
| **Chimera**                          | Polyglot where the _same bytes_ are the payload of several types | Multiplicity `n` with **no duplication** — the dedup story of [cluster E][closure] |
| **Mock** (`mocky.py`)                | One valid type, plus foreign magic planted where sniffers look   | Multiplicity 1 **claimed** as `n` — attacks the dispatcher, not the parsers        |

The `schizophrenic` label is Albertini's 2014 talk title ([slides][schizo], [`slides/1406-SchizophrenicFiles.pdf`][schizo-pdf] in `corkami/docs`); the current corpus consistently renames it to _multi_, and this page follows the current usage while noting the older term because most citations of the work still use it.

The engineering advice the tradition distils out of ten years of PoCs is stated as a short list of format-design rules in [`mitra/README.md`][mitra-readme]:

> _"Enforcing a magic at offset zero should be standard. Starting at offset zero and not enforcing a magic at zero is still exploitable (PS, MP4). Starting at any offset makes polyglots trivial. Enforcing a footer (like `XZ`, `ID3v1`) is a great way to check if a file isn't truncated, and prevents 'naturally' appended data. Most formats have a way to store parasite data, except very simple ones."_

Those four sentences are the generalizable rule set this page unpacks. They also predict, correctly, which two formats in `mitra`'s whole table combine with _nothing_.

---

## How it works

### The four layouts

`mitra` enumerates exactly four ways two files can share a stream. The names are the tool's own, and its output filenames encode which was used ([`mitra.py`][mitra-py]):

| Layout       | Filename tag   | Shape                                                               | Requires                                                                          |
| ------------ | -------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **Stack**    | `S(off)-A-B`   | `A` then `B` appended                                               | `A.bAppData` **and** `B.start_o > len(A)`                                         |
| **Cavity**   | `C(off)-A_B`   | `A` written _into_ `B`'s leading dead space                         | `A.bAppData` **and** `B.precav_s >= len(A)`                                       |
| **Parasite** | `P(off)-A[B]`  | `B` wrapped in a comment/extension chunk of `A`                     | `A.bParasite`, `A.parasite_o <= B.start_o + B.precav_s`, `A.parasite_s >= len(B)` |
| **Zipper**   | `Z(o-o-o)-A^B` | the two files interleave, each hiding the other's spans as comments | `A.bZipper` and both `bParasite` — only `TAR` and `DICOM` host it today           |

The predicates are literal source. `isStackOk` in [`mitra.py`][mitra-py] is the entire "suffix-tolerant ∘ prefix-tolerant" rule of the source outline, written as four lines of Python:

```python
# mitra.py — isStackOk (abridged)
if not ftype1.bAppData:      # host must tolerate appended data
    result = False
if ftype2.start_o == 0:      # guest must tolerate a non-zero start offset
    return False
elif len(ftype1.data) >= ftype2.start_o:
    result = False           # ... and the host must fit inside that tolerance
```

`start_o` is the guest's **maximum tolerated start offset**, not its actual one — the number of bytes of foreign prefix it will forgive. That single field is the whole prefix-tolerance axis, and its values are startlingly concrete:

| Format               | `start_o`   | Source                                                                               |
| -------------------- | ----------- | ------------------------------------------------------------------------------------ |
| ZIP / RAR / 7z / ARJ | `4 MiB`     | `self.start_o = 4*1024*1024 # no actual downward limit` ([`parsers/zip_.py`][p-zip]) |
| PDF                  | `1016`      | `self.start_o = 1024 - 8` ([`parsers/pdf.py`][p-pdf])                                |
| ISO 9660             | `0x8000`    | as a _cavity_, `precav_s = 0x8000` ([`parsers/iso.py`][p-iso])                       |
| DICOM                | `128`       | the `DICM` magic sits after a 128-byte preamble                                      |
| TAR                  | `0` + slack | magic `\0ustar` at `MAGIC_o = 0x100` ([`parsers/tar.py`][p-tar])                     |
| Everything else      | `0`         | magic enforced at offset zero                                                        |

`1024 - 8` is not folklore; it is the arithmetic of "the whole `%PDF-1.x` signature has to be present in the first kilobyte", and it is directly observable. [`pocs/pdf/1016garbage.pdf`][garbage] is 1648 bytes of which the first 1016 are junk:

```text
$ od -A d -c pocs/pdf/1016garbage.pdf | head -1
0000000 001   P   K 003 004  \0   J   F   i   f   R   a   r   ! 032  \a
$ od -A d -c pocs/pdf/1016garbage.pdf | sed -n '5p'
0001008 360 361 362 363 364 365 366 367   %   P   D   F   -   1   .   4
```

The signature lands at byte 1016 exactly, so the eight-byte magic ends at 1024. The junk is not random: it opens with `PK\3\4`, `JFif`, `Rar!\x1a\x07`, `<html>`, `Acsp` and `PK\5\6` — a deliberate demonstration that the tolerated prefix is a free-fire zone for other formats' magic.

### The format model: tolerance as data

Every `mitra` parser subclasses `FType` ([`parsers/__init__.py`][p-init]), whose constructor _is_ the taxonomy — eleven fields, of which three are booleans and the rest are offsets or sizes:

```python
# mitra/parsers/__init__.py — FType.__init__ (abridged, comments verbatim)
self.cut = None         # minimal cut generic to that format
self.prewrap = 0        # [minimal] size of data to be added before the parasite
self.postwrap = 0       # [minimal] size of data to be added after the parasite
self.start_o = 0        # where the format should start in the file
self.bAppData = True    # does it tolerate appended data - quite common
self.bParasite = False  # does it tolerate any parasite - quite common
self.parasite_o = None  # min offset of a parasite (=cut + prewrap ?)
self.parasite_s = None  # max size of a parasite
self.precav_o = 0       # (fixed) offset of a pre-cavity
self.precav_s = 0       # (max) size of pre-cavity
```

and four methods — `identify`, `getCut`, `wrap`, `fixformat` — which the README reduces to a single sentence:

> _"For example, in a chunk-based format, just find where to `cut` the file, then `wrap` foreign data in a new chunk and insert the chunk. So you just need to teach Mitra how to `identify` the type, where to `cut`, and how to `wrap`."_

PNG is the canonical instance and is 30 lines total ([`parsers/png.py`][p-png]): cut at 8 (immediately after the signature, before `IHDR`), `prewrap = 2*4` (a 4-byte length and a 4-byte type), `postwrap = 4` (the CRC), and:

```python
# mitra/parsers/png.py
def wrap(self, data, type_=b"cOMM"):
    return b"".join([
        int4b(len(data)), type_, data,
        int4b(binascii.crc32(type_ + data) % 0x100000000)
    ])
```

`cOMM` is chosen for its capitalization, not its spelling: in the [PNG chunk grammar][pngspec] the case of each of the four letters carries a property bit. The lowercase first letter makes the chunk **ancillary** — a decoder that does not recognise it _must_ skip it rather than fail — and the uppercase fourth letter makes it **unsafe to copy**, which is honest, since an editor must not carry the parasite across a re-encode. (The uppercase second letter claims a _public_, registered type, which `cOMM` of course is not; nothing enforces that bit.) **PNG's forward-compatibility rule is therefore the parasite mechanism**, and it is a rule the format got right for maintainability and cannot revoke without breaking every decoder.

WASM is structurally identical and even shorter: section id `0` is the custom section, so the wrapper is `\0` + LEB128 length + a name-length-prefixed blob ([`parsers/wasm.py`][p-wasm]), and `bAppData = True # via Wrappending` — appended data is legal because you can always append another custom section. A format designed in 2015 with an explicit extension point inherits the same composability as PNG from 1996. That is not an accident of either spec; it is what "tolerate unknown chunks" means.

### The host/guest asymmetry

Composition is **not symmetric**, and `mitra`'s matrix is deliberately a full square rather than a triangle. `S(x)-PDF-ZIP` and `S(x)-ZIP-PDF` are different files with different failure modes. The four ZIP-family formats and PDF/ISO/DICOM/TAR each combine with 30–41 of the surveyed formats, while ELF, PNG, GIF, PE, Java and BPG each combine with 6–8 — and every one of those 6–8 is "as a _host_ to one of the eight promiscuous guests", never as a guest themselves, because their magic is enforced at zero.

Two formats in the whole table compose with **nothing**: `XZ` and `ID3v1`. The reason is one line each. `parsers/xz.py`:

```python
self.bAppData = False  # Required matching footer
self.bParasite = False # No known strategy
```

and `parsers/id3v1.py`:

```python
self.bAppData = False # it's a footer
```

**A mandatory footer is the only structural feature in this corpus that defeats every layout at once.** It kills stacking (nothing may follow), it kills being stacked _onto_ (`start_o == 0`), and if the format also has no comment/extension chunk it kills parasitism. This is the single most transferable finding on the page, and it is the exact inverse of the property that makes ZIP the universal suffix parasite — see [ZIP parasitism][zip] and [footer-indexed formats][footer].

---

## Format identity and multiplicity

### What the bytes are

There is no one artifact here, so multiplicity is measured per specimen. The PoC&#124;&#124;GTFO series is the best-documented run, because [its `README.md`][pocorgtfo-readme] records, per issue, exactly what the released file simultaneously is. Reproduced and, where marked ✓, verified first-hand against the release blobs at `angea/pocorgtfo@933c020f`:

| Issue  | Date       | Simultaneously                                                   | Verified                                                                                  |
| ------ | ---------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `0x00` | 2013-08-05 | PDF only                                                         | —                                                                                         |
| `0x01` | 2013-10-06 | **ZIP**, PDF                                                     | ✓ 6 files; `EOCD` 63 bytes from EOF ([release][r01])                                      |
| `0x02` | 2013-12-28 | **MBR**, ZIP, PDF — "This OS is also a PDF" ([article][a0208])   | —                                                                                         |
| `0x03` | 2014-03-02 | **JPG**, **AES(PNG)**, ZIP, **AFSK** audio, PDF                  | ✓ `FF D8` at 0, `%PDF` at 25 inside a `FF FE` comment ([release][r03])                    |
| `0x04` | 2014-06-27 | **TrueCrypt volume**, ZIP, PDF                                   | —                                                                                         |
| `0x05` | 2014-08-10 | **ISO**, **SWF**, ZIP, PDF                                       | —                                                                                         |
| `0x06` | 2014-11-25 | **TAR**, ZIP, PDF ([article][a0604])                             | ✓ `ustar` at 257; first TAR member is named `%PDF-1.5` ([release][r06])                   |
| `0x07` | 2015-03-19 | **BPG**, **HTML**, ZIP, PDF — the "Funky Files" issue            | —                                                                                         |
| `0x08` | 2015-06-20 | **Shell script**, ZIP, PDF                                       | —                                                                                         |
| `0x09` | 2015-09-14 | **WavPack**, ZIP, PDF                                            | —                                                                                         |
| `0x10` | 2016-01-16 | **LSMV** (a TAS movie), ZIP, PDF                                 | —                                                                                         |
| `0x11` | 2016-03-17 | **Ruby**, **HTML**, ZIP, PDF                                     | —                                                                                         |
| `0x12` | 2016-06-18 | **APK**, ZIP, PDF                                                | —                                                                                         |
| `0x13` | 2016-10-04 | **PostScript**, ZIP, PDF                                         | —                                                                                         |
| `0x14` | 2017-03-20 | **iNES ROM**, ZIP, PDF — plus MD5 **hashquines** and a collision | —                                                                                         |
| `0x15` | 2017-06-17 | **ILDA** (laser-projector frames), ZIP, PDF                      | —                                                                                         |
| `0x16` | 2017-10-20 | **Bash** (also Python, WebIDE), ZIP, PDF                         | —                                                                                         |
| `0x17` | 2017-12-30 | **Apollo Guidance Computer** source, ZIP, PDF                    | —                                                                                         |
| `0x18` | 2018-06-26 | **HTML**, PDF, ZIP — with a **SHA-1 collision**                  | —                                                                                         |
| `0x19` | 2019-03-27 | HTML, PDF, ZIP — with an **MD5 pileup** across PE/PDF/PNG/MP4    | —                                                                                         |
| `0x20` | 2020-01-21 | PDF, ZIP — **signed**                                            | —                                                                                         |
| `0x21` | 2022-02-12 | **PCAPNG**, PDF, ZIP                                             | —                                                                                         |
| `0x22` | 2024-02-12 | **ISO**, ZIP, PDF + **mocks**: TAR, DICOM, XMS, PIF…             | ✓ `DICM` at 128, `CD001` at 32769, `EOCD` comment covers the PDF trailer ([release][r22]) |

Two structural constants across twenty-three issues are worth naming. **ZIP appears in every polyglot issue from `0x01` onward** — it is the invariant host, for reasons developed under [Index anchoring](#index-anchoring-and-random-access). And **PDF is always the _presentation_ type**, because PDF is the only widely-deployed format that tolerates a kilobyte of leading garbage, tolerates arbitrary appended data, and is parsed bottom-up, so it can be the guest of a header-anchored format and the host of a footer-anchored one at the same time.

### The prefix/suffix partial order

The source outline asks for "a partial order of prefix-tolerant / suffix-tolerant / neither" that would _predict_ polyglots. `mitra`'s field set delivers it, with one refinement: the order is over **four** properties, not two, and the fourth (interior parasitism) is what rescues formats that are strict at both ends.

| Property                        | Field          | Formats in the surveyed set                                                      |
| ------------------------------- | -------------- | -------------------------------------------------------------------------------- |
| Prefix-tolerant (scanned magic) | `start_o > 0`  | ZIP, 7z, ARJ, RAR (`4 MiB`); PDF (`1016`); TAR, DICOM, ISO (fixed offsets)       |
| Prefix-tolerant (cavity)        | `precav_s > 0` | ISO (`0x8000`), PDF-as-cavity (`1018`, [`parsers/pdfc.py`][p-pdfc])              |
| Suffix-tolerant                 | `bAppData`     | almost everything — the default in `FType` is `True`                             |
| Interior-tolerant               | `bParasite`    | every chunked format; PNG, WASM, JPEG, JP2, RIFF, ELF, PE, NES, GZIP, PostScript |
| **None of the above**           | —              | **XZ**, **ID3v1**                                                                |

The predictive rule that falls out: **a pair composes iff one member is interior- or prefix-tolerant at a distance that exceeds the other member's size, or one is suffix-tolerant and the other prefix-tolerant.** Everything else in the matrix is bookkeeping about _how much_ space, which is why the tool records the swap offsets in the output filename: `Z(80-162-286)-DICOM^TIFF.…dcm.tif`.

Note the deliberate line this catalog draws: a **mock** is not a polyglot. `mocky.py` plants foreign magic in a valid PDF's slack until `file --keep-going --raw` reports fourteen types for a file that is only a PDF. That is Multiplicity 1 attacking the _dispatcher_, and it belongs in [threat model][threat] and [parser differentials][pdiff], not here — but issue `0x22` ships both in one file, which is why the `file` output on it is so long.

### Chimeras: multiplicity without duplication

The chimera is the case where multiplicity costs no bytes. The worked example in ["Abusing file formats"][aff] is the JPG/PDF/ZIP chimera, whose byte map the article prints in full; the load-bearing observation is that **all three formats store JPEG data uncompressed and contiguously**, so one copy serves all three:

- The ZIP's local file header is followed _immediately_ by stored file data — and by a duplicate of the filename, which the PDF's `endstream` keyword is made to occupy.
- The PDF stores an image XObject as a raw `stream` of exactly those bytes.
- The JPEG _is_ those bytes, reached from offset 0 by way of a second JFIF header planted before them.

> _"Even better, we only have one copy of the image data; this copy is reused by each of the forms of the chimera."_

The same technique in a different pair is [`pocs/poly/zgip`][zgip], a ZIP/GZIP chimera whose Deflate stream is shared: _"Just to prove that while Zip and Gzip can use the same compression algorithm, neither is an encapsulation of the other."_ This is the sharing/duplication question of [cluster E][closure] answered at the format level rather than the store level — see [content-addressed chunking][cas] for the same idea when the sharing is between artifacts instead of within one.

---

## Index anchoring and random access

### Why ZIP is always the host

ZIP's index is the **End of Central Directory** record, found by scanning backwards from EOF for `PK\x05\x06` within a 64 KiB window (the maximum comment length). Nothing about that procedure references offset 0. ["Abusing file formats"][aff] states the historical reason, which is not the one usually given:

> _"ZIP doesn't require magic at offset zero, and like PDF it's parsed from the bottom up. In this case, it's not to allow for incremental updates; rather, it's to limit those time-consuming floppy swaps when a multi-volume archive is created on the fly, on external storage."_

The consequence, measured on the real releases:

| File              | Size          | first `PK\x03\x04` | `EOCD` offset | bytes after `EOCD`   | `EOCD.cd_off` field | resolves how                                       |
| ----------------- | ------------- | ------------------ | ------------- | -------------------- | ------------------- | -------------------------------------------------- |
| `pocorgtfo01.pdf` | `3 790 438`   | `3 505 149`        | `3 790 375`   | `63`                 | `284 738`           | **relative** — `+3 505 149` lands on `PK\x01\x02`  |
| `pocorgtfo06.pdf` | `101 508 878` | `10 672 929`       | `101 508 814` | `64`                 | `90 824 610`        | **relative** — `+10 672 929` lands on `PK\x01\x02` |
| `pocorgtfo22.pdf` | `53 215 888`  | `9 600`            | `53 215 810`  | `78` (56 in-comment) | `53 214 138`        | **absolute** — already correct                     |

Both behaviours are legal-ish and both work, which is exactly the problem. Info-ZIP prints `warning: 3505149 extra bytes at beginning or within zipfile (attempting to process anyway)` and self-corrects by taking the delta between the `EOCD`'s claimed central-directory offset and where it actually found it. Issue `0x22` instead pre-fixes the pointers, so no warning appears — the fixup Albertini describes under _"Fixing Absolute Pointers"_ and that `zip -A` performs. **A ZIP index is therefore only _conditionally_ random-access: the offsets are relative to a base the format never records.** Consumers reconstruct that base by search. That is the mechanism by which the same archive is simultaneously "valid" and "damaged", and it is the seam every [parser differential][pdiff] in the ZIP ecosystem is built on.

### PDF's two anchors, and Julia Wolf's trick

PDF is the rare format that is anchored at _both_ ends: a header signature that must appear within the first kilobyte, and a `startxref` footer giving the byte offset of the cross-reference table. Because the footer is authoritative, PDF supports incremental update, and because the header is merely "within 1 KiB", it is prefix-tolerant.

The canonical way to nest a ZIP inside a PDF exploits the _space between_ those anchors. From ["Abusing file formats"][aff]:

> _"A good way to embed a ZIP in a PDF, as Julia Wolf showed us with napkins in PoC&#124;&#124;GTFO 1:05, is to create a fake stream object after the xref, where the trailer object is present, before the startxref pointer."_

with the layout given as PDF signature → objects → cross-reference table → _(extra stream object containing the ZIP)_ → trailer → `startxref`. The reason is quantitative, not aesthetic: the `EOCD` must be within 64 KiB of EOF, and the cross-reference table grows linearly with the object count, so a ZIP placed among the normal objects gets pushed out of the window on any large document.

`pocorgtfo01.pdf` is that layout, verifiable byte-for-byte:

```text
startxref → 3 504 383  →  "169 0 obj <</Type /XRef /Index [0 170] /Size 170 …"
3 505 127                  "999 0 obj\n<<>>\nstream\n"      ← the fake object
3 505 149                  PK 03 04 …                        ← the ZIP begins
3 790 375                  PK 05 06 (comment length 0)
3 790 438 (EOF)            "endstream\nendobj\nstartxref\n3504383\n%%EOF\n"
```

Object `999` is declared _after_ the object that `startxref` points at, so no PDF pointer needs adjusting and the xref stream stays byte-identical to what a normal producer emits. `mutool clean` will happily renormalize such a file — the tradition's advice is to run it, because _"it modifies very little, yet rebuilds the XREF table and adjusts objects lengths, which turns your hand-made tolerated PDF into one that looks perfectly standard."_

`pocorgtfo22.pdf` uses the complementary trick: the `EOCD` really is last, and its 56-byte **comment field** swallows the PDF's own trailer —

```text
PK 05 06 … comment_len = 56
comment = "\0\0\0\0" "endstream\nendobj\nstartxref\nstartxref\n37074454\n%%EOF\n"
```

— with four leading NUL bytes so that a ZIP tool displaying the comment as a C string shows an empty one. The archive's index is the last structure in the file _and_ the PDF's `%%EOF` is the last structure in the file, because one is nested in the other's variable-length tail.

### Offset-anchored guests

The third anchoring style — magic at a _fixed non-zero_ offset — is the reason a single file can carry so many claimed types at once. `pocorgtfo22.pdf`, read directly:

| Offset       | Bytes        | Claimed format                     |
| ------------ | ------------ | ---------------------------------- |
| `0`          | `%PDF-1.5`   | PDF header                         |
| `128`        | `DICM`       | DICOM (128-byte preamble by spec)  |
| `9 600`      | `PK\x03\x04` | ZIP local file header              |
| `32 769`     | `CD001`      | ISO 9660 Primary Volume Descriptor |
| `53 215 810` | `PK\x05\x06` | ZIP `EOCD`                         |

A format that puts its magic at a fixed offset has _donated_ every byte before that offset to whoever wants it. DICOM donates 128 bytes; ISO 9660 donates 32 KiB; TAR donates 257 bytes of which the first 100 are a filename field — which is precisely why `pocorgtfo06.pdf`'s first TAR member is _named_ `%PDF-1.5`:

```text
$ tar -tvf pocorgtfo06.pdf | head -1
-rw-r--r-- Manul/Laphroaig   0 2014-10-06 22:33 %PDF-1.5
```

A zero-length file whose name is the other format's signature, with `\0ustar  \0` at 257 and a valid header checksum. The TAR half is not hiding in the PDF; the PDF's _identity_ is a field of the TAR half. That is the article's own title — ["This TAR archive is a PDF!"][a0604] — meant literally.

### Cost of a partial read

For the catalog's comparison purposes: a polyglot has **no unified index**, so the cost of a ranged read is whatever the _chosen_ parse costs, times nothing shared. Fetching `pocorgtfo22.pdf`'s ZIP listing needs the last 64 KiB plus the central directory; fetching its first PDF page needs the last few KiB (for `startxref`) plus the object graph reachable from `/Root`; fetching the ISO's volume descriptor needs bytes `32 769..32 774`. Three parses, three access patterns, zero shared machinery — the opposite of the single b-tree story in [SQLite as an application file format][sqlite-aff]. Whether any of those parses survives HTTP range access is exactly the question in [range-request access][range]; the answer for ZIP-in-PDF is _yes for ZIP, awkwardly for PDF_, and it is awkward because the base-offset reconstruction above requires locating `PK\x03\x04` by scan.

---

## Reflexivity and query surface

**This is the axis on which polyglot craft scores lowest, and the absence is a finding.**

A polyglot carries no schema, no manifest, no self-description. Nothing in `pocorgtfo22.pdf` announces "I am also an ISO". There is no equivalent of [SELF's][selfdb] `sqlite_schema`, no [`sqlelf`][sqlelf] virtual table, no [Wasm component][wasm] type export. The artifact's multiplicity is _implicit_ — recoverable only by trying every parser you own. That is the definition of the problem, not a shortcoming of the implementations: the entire craft depends on each parser believing the file belongs to it and to nobody else.

What interrogation surface exists is entirely **out-of-band and heuristic**, and the tradition's own tooling makes the point:

```text
$ file pocorgtfo22.pdf
pocorgtfo22.pdf: tar archive

$ file --keep-going --raw pocorgtfo22.pdf
pocorgtfo22.pdf: tar archive
- DR-DOS executable (COM)
- Windows Program Information File for 145
- PDF document, version 1.5
- ISO 9660 CD-ROM filesystem data (DOS/MBR boot sector) 'CDROM'
- DICOM medical imaging data
- Nintendo DS ROM image: "%PDF-1.5"
…
```

Two things follow, and both are load-bearing for the catalog:

1. **Default sniffing reports one type, and it is the wrong one.** `file` without `--keep-going` stops at the first match, and its ordering is by internal magic-entry strength, not by what the file "is". A 53 MB journal identifies as `tar archive`. The `mitra` README's own demonstration is blunter: a plain PDF, after `mocky.py --combine`, still passes `pdftotext` and `pdfinfo` cleanly while `file` calls it a TAR. **Content sniffing is not a query surface; it is a guess with a stable tie-break.**
2. **Multiplicity is only ever a lower bound.** `file --keep-going` finds magic; it does not _validate_, as the README says explicitly: _"(it does not validate the formats, but at least gives you some information)"_. A reported type may be a mock; an unreported type may be a real, valid parse whose magic libmagic has no entry for.

The nearest thing to genuine self-interrogation in the corpus is the **PDFLaTeX quine** — a file that is simultaneously its own TeX source and the PDF that compiling that source produces ([`pocs/pdf/quine.pdf`][quine]; the technique, `\pdfcompresslevel=0` plus `\immediate\pdfobj stream file {…}`, is in ["Abusing file formats"][aff]). That is reflexivity in the _autological_ sense this catalog cares about — the artifact contains a complete description of how to rebuild itself — but it is still not _queryable_: there is no language in which to ask it a question, only a compiler that reproduces it. Score: **1**, incidental.

The contrast to draw explicitly, because it is thesis 2 of the source outline: PDF, ZIP and TAR are all formats **without a carried schema**, and all three have accreted exactly the conventions that thesis predicts — libmagic entries, `zip -A` fixups, "attempting to process anyway" recovery, per-reader tolerance of a truncated `%PDF-1.` signature. The polyglot exists in the gap between the spec and the accreted conventions. A format that carried its own schema would not have that gap in the same shape.

---

## Closure, dedup, and size model

### What travels

PoC&#124;&#124;GTFO's ZIP half is a real closure claim, if a modest one: each issue carries **the code, patches, ROMs and tarballs its own articles discuss** — the "feelies". This is the one axis where the artifact is doing something [redbean][ape] also does, and doing it first. Verified contents of `pocorgtfo03.pdf`'s archive (15 members, 14.8 MB):

```text
alexander.txt  bochs-2.6.2.patch  bochs-20140203.patch  defusing.zip
despair.txt    lasta.txt          lastq.txt             netwatch-337f8b1.tar.gz
nokiacipher.png  packed  saucers.txt  tamadec.txt  tetranglix.tar.bz2
pocorgtfo02.pdf  pocorgtfo03-encrypt.py
```

Note `pocorgtfo02.pdf` — the previous issue, carried inside this one, itself a ZIP/MBR/PDF polyglot. And `pocorgtfo03-encrypt.py`, the script that produces this issue's AngeCryption layer: **the artifact carries its own construction recipe**, which is the closest the corpus comes to the reproducibility story in [embedded provenance][prov].

But this is _payload_ bundling, not **dependency closure**. Nothing in the file lets a reader resolve what `netwatch-337f8b1.tar.gz` needs to build, and nothing enumerates the transitive set. There is no equivalent of a [Nix closure][nix] or a `DT_NEEDED` graph. Score: **1**.

### Size model

Polyglot size is _additive minus overlap_, and the overlap term is the whole craft:

| Layout                      | Size cost                                            | Example                                                                   |
| --------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------- |
| Stack                       | `len(A) + len(B)` exactly                            | any ZIP appended to anything                                              |
| Cavity                      | `max(len(A), len(B))` when `A` fits the cavity       | ISO's 32 KiB system area absorbs `A` for free                             |
| Parasite                    | `len(A) + len(B) + wrap` (`wrap` ≈ 12 for PNG)       | PNG `cOMM`: 4 length + 4 type + 4 CRC                                     |
| **Chimera**                 | `max(len(A), len(B))` — payload shared               | JPG/PDF/ZIP: **one** copy of the image; ZIP/GZIP: one Deflate stream      |
| Near-polyglot (`--overlap`) | as chimera, plus the recovered bytes in the filename | `O(5-204){424D4E0100}.bmp.jpg` — 5 overwritten bytes recorded out-of-band |

The chimera row is the only one that beats concatenation, and it beats it _only_ when the two formats agree on a payload encoding. Albertini's list of what makes that possible is short and worth reading as a compatibility table: uncompressed JPEG data (JPG/PDF/ZIP), raw Deflate (ZIP/GZIP/PNG), and — with `ascii-zip`-style Huffman abuse — a Deflate stream that is also printable ASCII, which is how Rosetta Flash worked.

The hard size constraint the tradition keeps hitting is the opposite one — formats with a **required exact size**. From ["Abusing file formats"][aff]:

> _"It's common that ROM and disk images require a specific rounded size, and there is often no workaround to this. You can merge a PDF and an Apple II floppy image, but only if the PDF fits in the 143,360 byte disk image."_

The workaround used for [`pocs/poly/Apple2PDF`][a2pdf] was to move up to a 2 MB hard-disk image; the workaround in [`pocs/poly/SnesMd`][snesmd] (a Super NES + Sega Megadrive + PDF triple) was to put the PDF at the bottom of the ROM rather than after it, _"because the exact rom size is critical for SMC"_. **A size-exact format is prefix- and suffix-hostile even when it is interior-tolerant** — a fifth column the `FType` model does not have a field for, and the one gap in the taxonomy this survey found.

---

## Mutability, dispatch, and trust

### Mutability: zero, by construction

A polyglot is the most _brittle_ artifact in this catalog. Its correctness is a conjunction of `n` invariants, several of which are checksums over overlapping ranges: PNG per-chunk CRC32, ZIP per-member CRC32, TAR's header checksum, PDF's `startxref` offset and per-stream `/Length`, the iNES trainer flag, MBR's `0xAA55`. Change one byte in the shared region and you must recompute every dependent field in every format — which is why `mitra` parsers carry a `fixformat` hook and why [`parsers/pdf.py`][p-pdf] contains a full `xref`/`startxref` rewriter whose comment reads _"dumb [start]xref fix: fixes old-school xref with no holes, with hardcoded \n"_.

The artifact is therefore **not a state store, not transactional, and not incrementally editable** in any sense the [SELF/selfdb][selfdb] line means. Score: **0**. PDF's incremental-update feature is the one exception in principle — appending a new xref section is legal — but doing so in a polyglot moves EOF and so invalidates the ZIP's 64 KiB `EOCD` window and any footer-anchored guest. Editing collapses the superposition.

There is one striking mutability-adjacent exhibit: the **MD5 hashquines** in issue `0x14`, files that display their own MD5 hash. That is self-reference without self-modification — the fixed point is found by collision search at build time, not maintained at runtime — and it belongs with the [measurement][measure] discussion of what "the artifact knows about itself" can be made to mean without a query engine.

### Dispatch: the consumer, and that is the vulnerability

For every other subject in this catalog, dispatch is owned by a named component: the kernel for [`binfmt_misc`][binfmt], the loader for [`ld.so`][dynlink], the shell for a shebang. **For a polyglot, dispatch is owned by whichever consumer happens to open the file**, using whichever of three incompatible mechanisms it prefers:

| Mechanism                 | Used by                                         | What the polyglot does to it                                          |
| ------------------------- | ----------------------------------------------- | --------------------------------------------------------------------- |
| Filename extension        | shells, desktop environments, most upload paths | `pocorgtfo07.pdf` → rename to `.html` and it is a working web page    |
| Magic sniffing            | `file`/libmagic, TrID, AV, IDS, browsers        | reports one type; a mock makes it report the _attacker's chosen_ type |
| The parser's own recovery | PDF readers, ZIP tools, media players           | accepts the file that the sniffer said was something else             |

The security consequence is the tradition's whole argument, and it is stated plainly:

> _"Testing various polyglots on Encase showed that nearly all of them were reported as a single file type, with no warnings whatsoever."_

and, on the ZIP-scanning divergence that breaks signatures:

> _"This is likely why some modern tools take a different approach, ignoring the official structure of a ZIP. These extractors start at offset zero and look for a sequence of Local File Headers. … Sadly, doing this differently makes ZIP multi possible, which can be critical as it can break signatures and the complete chain of trust of a standard system."_

That sentence is the bridge to [parser differentials][pdiff] and to the JAR/APK signing problem in [ZIP parasitism][zip]: a verifier that enumerates members top-down and an extractor that enumerates them from the central directory can disagree about _which bytes were signed_.

### Trust: blacklists, and why they lose

The one deployed mitigation the corpus documents is Adobe's, and it is instructive precisely because it half-worked:

> _"For security reasons, Adobe Reader, the standard PDF reader, has blacklisted known magic signatures such as PNG or PE since version 10.1.5. It is thus not possible anymore to have a valid polyglot that would open in Adobe Reader as PDF. This is a good security measure even if it breaks compatibility with older releases of PoC&#124;&#124;GTFO."_

The immediate bypass is a lesson about what a magic number actually is:

> _"However, it's critical to blacklist the actual signature as opposed to what is commonly appearing in files. JFIF files typically start with the signature, SOI, and an APP0 segment, which make the file start with `FF D8 FF E0`. However, the signature itself is only `FF D8`, which can lead to a blacklist bypass by using a different segment or different marker right after the signature."_

`pocorgtfo03.pdf` is that bypass, and its first 30 bytes still show it:

```text
FF D8                                   JPEG SOI — the entire real magic
00 00 00 10 4A 46 49 46 …               "JFIF" text, but NOT preceded by FF E0
FF FE 00 22                             COM segment, length 0x22
0A 25 50 44 46 2D 31 2E 35 0A           "\n%PDF-1.5\n"  ← at offset 25
39 39 39 20 30 20 6F 62 6A …            "999 0 obj\n<<>>\nstream\n"
```

The JPEG decoder skips from `FF D8` to the next marker and finds the comment; the PDF reader finds `%PDF-1.5` inside that comment, comfortably within its 1 KiB budget; the blacklist, which was looking for `FF D8 FF E0`, sees nothing. (Adobe subsequently fixed the JFIF signature check, and the README records that `pocorgtfo03.pdf` has not opened in Adobe Reader since March 2014 — the mitigation eventually landed, three releases and one bypass later.)

The structural recommendation the tradition offers instead of blacklisting is a whitelist tightening, and it is the single most actionable line in the corpus:

> _"Requiring the PDF signature to appear earlier in the file - even just in the first 64 bytes instead of a whole kilobyte - would proactively prevent a lot of polyglot types, as most recent formats are dense at the start of the file."_

That is a _quantitative_ trust claim — reduce `start_o` from 1016 to 56 and the set of formats that fit in the prefix collapses to almost nothing — and it is the kind of claim the [threat model][threat] page can test directly against the `mitra` matrix.

Finally, on signing: issue `0x20` is _"polyglot: PDF, ZIP — Signed"_, which is the corpus quietly conceding the point. A digitally signed PDF fixes a byte range; once the artifact is signed, the polyglot is frozen, and every technique above becomes a build-time-only affordance. The general problem — signing an artifact whose bytes several verifiers disagree about the extent of — is the subject of [embedded provenance][prov], and it has no answer here.

---

## Strengths

- **The taxonomy is executable.** `mitra` is not a description of which formats compose; it is a program that tries, and its 288-combination matrix is regenerable. A claim in this area is falsifiable in one command.
- **Zero infrastructure.** No loader, no kernel registration, no runtime, no substrate. A polyglot works on any system that has _any_ of its parsers, including systems built decades apart — [`pocs/poly/SnesMd`][snesmd] targets a 1988 console, a 1990 console and a PDF reader from the same 512 KiB.
- **Chimeras achieve multiplicity with no size penalty**, which no other technique in this catalog does — the payload is shared rather than duplicated.
- **The corpus is a real regression suite for parsers.** The `mini` collection ([`pocs/mini/README.md`][mini]) — a valid, minimal, self-describing file for each of ~60 formats, with rules (_"should be fully valid… shows what they are… should be made as small as possible"_) — is directly reusable as fixtures, and the `pdf/` PoCs form a compatibility matrix across readers.
- **The design advice generalizes.** "Magic at zero, mandatory footer, an explicit comment chunk instead of tolerated garbage" is four rules that a new format can adopt for free and that measurably shrink its composability surface.

## Weaknesses

- **No reflexivity whatsoever.** The artifact cannot be asked what it is. Every downstream consumer re-derives multiplicity by brute force, and the answer is a lower bound.
- **Fragility is multiplicative.** `n` formats mean `n` sets of checksums and offsets over overlapping ranges; the file is effectively immutable after construction, and normalization tools routinely destroy it (_"the library — too smart for its britches — removed your dummy chunk, recompressed your intentionally uncompressed data…"_).
- **Compatibility is a heisenbug problem**, in the tradition's own words: _"a single font in a PDF might become corrupted. One image — and only one image! — might go missing."_ The boundary that matters is not valid/invalid but "good enough" versus "let's try to recover".
- **Reach is per-parser and decays.** Every specimen in the corpus is a bet on specific implementations; Adobe's blacklist retired issue `0x03` and `0x05` from the flagship reader within months of each.
- **It is fundamentally the wrong tool for deployment.** Albertini says so himself: _"Archiving files together is much more natural than making a polyglot file. Although opening a polyglot file may be transparent for the targeted software, it's not a natural action for user."_

---

## Key design decisions and trade-offs

| Decision                                                                       | Rationale                                                                                                 | Trade-off                                                                                                          |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Model a format as five booleans + four offsets (`FType`)                       | Composability is decidable from tolerance properties alone; no need to model semantics                    | Misses size-exact formats (ROM/disk images), which the model calls composable and reality does not                 |
| Enumerate four layouts (Stack / Cavity / Parasite / Zipper) rather than search | Each maps to one structural property, so a hit is _explained_, not just found                             | Layouts outside the four (interleaved chimeras, encoding-level sharing) still need hand-crafting                   |
| ZIP as the invariant host of every PoC&#124;&#124;GTFO issue                   | Backwards-scanned `EOCD` + 64 KiB comment makes it the universal suffix parasite                          | Inherits ZIP's relative-offset ambiguity — "damaged" warnings, and a signing surface                               |
| Put the ZIP in a fake PDF object _after_ the xref                              | Keeps `EOCD` inside the 64 KiB window regardless of object count; no PDF pointer needs fixing             | Relies on readers tolerating an undeclared object between xref and trailer — legal by omission, not by statement   |
| PDF as the presentation type everywhere                                        | The only common format that is prefix-tolerant (1 KiB), suffix-tolerant, and footer-authoritative at once | That very tolerance is what got PDF a magic blacklist; the technique attracted the mitigation                      |
| Chimera (shared payload) over concatenation where encodings agree              | Multiplicity at `max(len)` instead of `sum(len)`                                                          | Requires both formats to store the payload uncompressed or with the same codec; brittle to any re-encode           |
| Publish `mocky.py` (mocks) alongside real polyglots                            | Separates "attacks the parsers" from "attacks the dispatcher" — different mitigations                     | Muddies type-counting: `file --keep-going` output for issue `0x22` lists types the file is not                     |
| Record swap offsets in the output _filename_                                   | The metadata has nowhere else to live — the artifact carries no self-description                          | Out-of-band metadata: rename the file and the provenance is gone. The exact gap [SELF][selfdb] closes with a table |

---

## Where this sits in the catalog

- **Against [thesis 1][index] ("every binary format eventually reimplements a database, badly").** Supported, with a twist: PDF's `xref` _is_ a hand-maintained primary-key index over objects, and `mitra`'s [`parsers/pdf.py`][p-pdf] has to reimplement it (_"only very standard object declarations"_) to insert one payload. ZIP goes further and stores **two** copies of the same relation — filenames appear in both the local file headers and the central directory — which is a denormalized index maintained by hand, and Albertini's closing section asks for exactly the schema fix a database person would: _"One that doesn't duplicate file names between Central Directory and Local File Headers?"_
- **For [thesis 2][index] ("self-description is what makes a format survivable").** Strongly supported in the negative. Every format in the corpus that lacks a carried schema has accreted a recovery convention (`file`'s heuristics, `zip -A`, "attempting to process anyway", truncated-signature tolerance), and the polyglot lives in the gap between spec and convention. XZ and ID3v1, the two formats that compose with nothing, are also the two that _enforce_ a structural invariant end-to-end.
- **Against [thesis 3][index] ("the container is a tax").** Complicated. The chimera is the counter-example: when host and guest agree on an encoding, the container costs _zero_ bytes. The tax is real for stacking and parasitism and is exactly quantifiable — 12 bytes per PNG chunk, `2 + 2` per JPEG segment, `~30 + filename` per ZIP member.
- **For [thesis 5][index] ("portability migrated from the format to the access layer").** This page is the strongest evidence _for_ the thesis, precisely by exhausting the alternative. Twenty-three issues of format-level cleverness produced artifacts whose reach shrinks as parsers tighten, that cannot be edited, and whose type nobody can query. See [the comparison table][comparison] for the side-by-side against [APE][ape] and [SELF][selfdb].

---

## Sources

- ["Abusing file formats" — `corkami/docs/AbusingFileFormats/README.md`][aff] (the maintained expansion of PoC&#124;&#124;GTFO 7:6, _"Funky Files, the Novella!"_) — identification, chunk vs. pointer structures, appended data, trailing space, chimeras, blacklisting, normalization
- [`corkami/mitra/README.md`][mitra-readme] — the 288-combination compatibility matrix, the four layouts, near-polyglots, script-polyglot comment/heredoc/terminator table, and the format-design recommendations
- [`corkami/mitra/parsers/__init__.py`][p-init] — the `FType` model: `bAppData`, `bParasite`, `parasite_o/s`, `start_o`, `precav_o/s`, `cut`/`wrap`/`fixformat`
- [`corkami/mitra/mitra.py`][mitra-py] — `isStackOk` / `isCavOk` / `isParasiteOk` / `isZipperOk`, the composability predicates
- Format parsers cited individually: [`png.py`][p-png] · [`zip_.py`][p-zip] · [`pdf.py`][p-pdf] · [`pdfc.py`][p-pdfc] · [`tar.py`][p-tar] · [`iso.py`][p-iso] · [`wasm.py`][p-wasm] · [`nes.py`][p-nes] · [`xz.py`][p-xz] · [`id3v1.py`][p-id3v1]
- [`corkami/pocs`][pocs] — [`pdf/1016garbage.pdf`][garbage], [`pdf/tiny.pdf`][tinypdf], [`mini/README.md`][mini], [`poly/SnesMd/snes_md.txt`][snesmd], [`poly/zgip/README.md`][zgip], [`poly/CorkaMIX/README.md`][corkamix], [`poly/Apple2PDF/AppleII.pdf`][a2pdf]
- [`angea/pocorgtfo/README.md`][pocorgtfo-readme] — per-issue polyglot composition, release hashes, and the `file --keep-going` / `trid` output for issue `0x22`
- Release blobs read directly: [`pocorgtfo01.pdf`][r01] · [`pocorgtfo03.pdf`][r03] · [`pocorgtfo06.pdf`][r06] · [`pocorgtfo22.pdf`][r22]
- Articles: ["This ZIP is also a PDF" (1:05, Julia Wolf)][a0105] · ["This OS is also a PDF" (2:08)][a0208] · ["This PDF is a JPEG" (3:03)][a0303] · ["This TAR archive is a PDF!" (6:04)][a0604] · ["Funky Files, the Novella!" (7:06)][a0706] · ["Mitra and Mocky: Near-polyglots and Mocks" (22:03)][a2203] · ["Inside out; or, Abusing archive file formats" (22:05)][a2205]
- Talks: ["Schizophrenic files"][schizo] (Area41 / MRMCD 2014, w/ Gynvael Coldwind) · ["Funky file formats"][funky] (31C3, 2014) · ["Generating weird files"][weird] (Pass the Salt 2021) · [`corkami/docs/talks.md`][talks] indexes the rest
- [PoC&#124;&#124;GTFO official mirror][alchemist] · [`corkami/docs/PDF/PDF.md` — PDF signature and structure tricks][pdftricks]
- Format specifications: [PDF 32000-1:2008 (ISO 32000-1, Adobe copy)][pdfspec] · [PNG (Third Edition), W3C][pngspec] · [ZIP `APPNOTE.TXT`][appnote]
- Related in this tree: [Cosmopolitan/APE][ape] · [ZIP parasitism][zip] · [parser differentials][pdiff] · [footer-indexed formats][footer] · [boot hybrids][boot] · [threat model][threat] · [embedded provenance][prov] · [concepts][concepts] · [comparison][comparison] · [open questions][open-questions]

<!-- References -->

[mitra]: https://github.com/corkami/mitra
[mitra-readme]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/README.md
[mitra-py]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/mitra.py
[p-init]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/__init__.py
[p-png]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/png.py
[p-zip]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/zip_.py
[p-pdf]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/pdf.py
[p-pdfc]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/pdfc.py
[p-tar]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/tar.py
[p-iso]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/iso.py
[p-wasm]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/wasm.py
[p-nes]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/nes.py
[p-xz]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/xz.py
[p-id3v1]: https://github.com/corkami/mitra/blob/95e1d2a7e4fcac552111a9fbe708223e0c60383a/parsers/id3v1.py
[pocs]: https://github.com/corkami/pocs
[garbage]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/pdf/1016garbage.pdf
[tinypdf]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/pdf/tiny.pdf
[quine]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/pdf/quine.pdf
[mini]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/mini/README.md
[snesmd]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/poly/SnesMd/snes_md.txt
[zgip]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/poly/zgip/README.md
[corkamix]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/poly/CorkaMIX/README.md
[a2pdf]: https://github.com/corkami/pocs/blob/6d277c83efdceb6916ee8c6efe6ff0639cc6193f/poly/Apple2PDF/AppleII.pdf
[ckdocs]: https://github.com/corkami/docs
[aff]: https://github.com/corkami/docs/blob/fd339bf6bebe7aa086a02a95b5a4fd9ef0c1bd28/AbusingFileFormats/README.md
[pdftricks]: https://github.com/corkami/docs/blob/fd339bf6bebe7aa086a02a95b5a4fd9ef0c1bd28/PDF/PDF.md
[talks]: https://github.com/corkami/docs/blob/fd339bf6bebe7aa086a02a95b5a4fd9ef0c1bd28/talks.md
[schizo-pdf]: https://github.com/corkami/docs/blob/fd339bf6bebe7aa086a02a95b5a4fd9ef0c1bd28/slides/1406-SchizophrenicFiles.pdf
[pocorgtfo]: https://github.com/angea/pocorgtfo
[pocorgtfo-readme]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/README.md
[r01]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/releases/pocorgtfo01.pdf
[r03]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/releases/pocorgtfo03.pdf
[r06]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/releases/pocorgtfo06.pdf
[r22]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/releases/pocorgtfo22.pdf
[a0105]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/01-05.pdf
[a0208]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/02-08.pdf
[a0303]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/03-03.pdf
[a0604]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/06-04.pdf
[a0706]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/07-06.pdf
[a2203]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/22-03.pdf
[a2205]: https://github.com/angea/pocorgtfo/blob/933c020f498bcfa85b4ed2cea6fd213eac1c9fe7/contents/articles/22-05.pdf
[alchemist]: https://www.alchemistowl.org/pocorgtfo/
[schizo]: https://speakerdeck.com/ange/schizophrenic-files
[funky]: https://speakerdeck.com/ange/funky-file-formats-31c3
[weird]: https://speakerdeck.com/ange/generating-weird-files
[pdfspec]: https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf
[pngspec]: https://www.w3.org/TR/png-3/
[appnote]: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[open-questions]: ./open-questions.md
[ape]: ./cosmopolitan-ape/index.md
[selfdb]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[zip]: ./zip-parasitism.md
[pdiff]: ./parser-differentials.md
[footer]: ./footer-indexed-formats.md
[boot]: ./boot-hybrids.md
[threat]: ./threat-model.md
[prov]: ./embedded-provenance.md
[binfmt]: ./binfmt-misc.md
[dynlink]: ./dynamic-linking.md
[wasm]: ./wasm-component-model.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[range]: ./range-request-access.md
[sqlite-aff]: ./sqlite-application-file-format.md
[measure]: ./measurement.md
[closure]: ./nix-store-closures.md
