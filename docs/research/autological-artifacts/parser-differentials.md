# Parser differentials and LangSec (security / formal-language theory)

The adversarial dual of every entry in this catalog: when one byte stream satisfies two grammars, and two components of one system each implement a different one, the disagreement is the vulnerability.

| Field           | Value                                                                                                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Analytical lens + a vulnerability class (not a tool or a format)                                                                                                       |
| Language        | Surveyed readers are C (`zip_util.c`, `phar.c`), C++ (`libziparchive`, ART), Java (`java.util.zip`, `apksig`), Go (`archive/zip`), Python (`zipfile`)                  |
| License         | Sources surveyed under GPLv2+CE, Apache-2.0, PHP-3.01, BSD-3-Clause, PSF-2.0                                                                                           |
| Repository      | No single upstream; the corpus read for this page is listed under [Sources](#sources)                                                                                  |
| Documentation   | [langsec.org][langsec] · [LangSec BoF handout][bof] · [MIME Sniffing Standard][mimesniff]                                                                              |
| First release   | Term coined in the LangSec programme, 2011 — [Sassaman, Patterson, Bratus, Locasto][sassaman]; the phenomenon predates it (`%PS`/HTML chameleons, [Barth 2009][barth]) |
| Axis profile    | Multiplicity 3 / Reflexivity 0 / Closure 0 / Mutability 1                                                                                                              |
| Index anchoring | Footer-anchored and stream-scanned — the two anchorings that _create_ the divergence; see [Index anchoring and random access](#index-anchoring-and-random-access)      |
| Dispatch owner  | Consumer (sniffing) and shell (extension). The defining property is that there is **more than one** dispatcher over one stream                                         |

> **Revisions surveyed:** OpenJDK `30df8a5a` (2026-08), Android `apksig` `184702d9` (2025-03), Android `libziparchive` `3861cb86`, Android ART `6484611f`, PHP `php-src` `0c87849d` (8.6.0-dev), Go `620058f8`, CPython `9036982e`, WHATWG `mimesniff` `39aa5351`. **Specifications:** PKWARE APPNOTE 6.3.10, ISO 32000-1:2008, WHATWG MIME Sniffing (Living Standard). **Platform:** format-level; no platform dependence.

---

## Overview

### What it solves

Nothing. This page is the entry that explains why the rest of the catalog is dangerous.

Every other subject here celebrates a property: [ZIP's footer index makes a suffix parasite legal][zip-parasitism]; [APE satisfies six loaders at once][ape]; [a polyglot is a craft object][polyglot]. **Parser differentials** are the same property observed from the other side. A file that admits two parses is not merely charming; it is a file about which two programs in one trust chain can _disagree_, and security decisions are made by exactly such chains — a verifier and a loader, a scanner and a viewer, a filter and a browser.

The LangSec programme (Len Sassaman, Meredith L. Patterson, Sergey Bratus, Michael Locasto, Anna Shubina) names the failure precisely and, unusually for security research, names it as a _language_ problem rather than a memory-safety problem. Its claim is that the vulnerabilities in this class are not bugs in the sense of typos: they are the predictable consequence of writing an input handler that is not a recognizer for a formally specified language.

### Design philosophy

The canonical statement is the LangSec BoF handout, [_Recognition, Validation, and Compositional Correctness for Real World Security_][bof]. Two of its four named anti-patterns are the entire subject of this page. On differentials:

> _"Verifiable composition is impossible without means of establishing parsing equivalence between different components of a distributed system. Different interpretation of messages or data streams by components breaks any assumptions that components adhere to a shared specification and so introduces inconsistent state and unanticipated computation. In addition, it breaks any security schemes in which equivalent parsing of messages is a formal requirement, such as … signed app package contents as seen by the signature verifier versus the same content as seen by the installer (as in the recent Android Master Key bug)."_

And on shotgun parsers:

> _"Mixing of basic input validation ("sanity checks") and logically subsequent processing steps that belong only after the integrity of the entire message has been established makes validation hard or impossible. As a practical consequence, unanticipated reachable state exposed by such premature optimization explodes."_

The prescription is stated in the same document as a hard ordering — a recognizer that "rejects non-conforming inputs and transforms conforming inputs to structured data," after which "the processing code can then access the structured data (but not the raw inputs or parsers' temporary data artifacts)." Two consequences that the rest of this page tests against real source:

1. **Full recognition before processing.** No byte of the input may influence behaviour before the whole input has been accepted. Every case below violates this, and the violations are visible as code that acts on a length, an offset, or a magic number found by scanning.
2. **Reduce the language class.** An input language weaker than deterministic context-free makes parser equivalence _decidable_; anything stronger makes it undecidable, so a system whose security rests on two components agreeing cannot be verified at all.

The bound is not rhetorical. Establishing that two arbitrary context-free grammars accept the same language is undecidable; the deterministic case is decidable but was not proved so until 2001. A format whose "grammar" is "whatever `findEND` accepts" has no grammar to compare.

---

## How it works

A parser differential needs four ingredients. Every case in this page has all four, and the absence of any one of them is the fix.

| Ingredient                                           | Why it is needed                                                   | Concrete example                                                                       |
| ---------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| **One byte stream, two consumers**                   | The disagreement must be _within_ a trust boundary, not across one | APK: Java verifier + C++ installer; PDF: mail scanner + Word; upload: filter + browser |
| **A tolerance in at least one grammar**              | The extra bytes have to be legal somewhere                         | ZIP tolerates a prefix; DEX tolerates a suffix; `phar` tolerates _any_ prefix          |
| **A privilege gradient between the two parses**      | Otherwise the divergence is harmless                               | GIF is inert, JAR runs code; PDF is inert, `.doc` runs VBA                             |
| **A dispatcher that picks the high-privilege parse** | Someone has to actually execute the dangerous reading              | `<applet archive=…>`, `binfmt`/loader magic, the Windows extension association         |

The mechanism is always the same shape, and it is worth stating in the vocabulary this catalog uses elsewhere. **Where a format anchors its index determines which side of the stream it tolerates junk on.** A header-anchored format (`ELF`, `GIF`, `DEX`, `PDF` as specified) fixes byte 0 and is therefore _suffix_-tolerant — bytes past the declared extent are simply never read. A footer-anchored format (`ZIP`, and everything built on it) fixes the tail and is therefore _prefix_-tolerant. Compose one of each and you get a file that both accept. That is the entire recipe, and it is why [footer-indexed formats][footer] are the load-bearing ingredient in nearly every polyglot exploit on record.

A stream-scanned format is worse than either, because it tolerates junk on _both_ sides. PHP's `phar` is the purest specimen: `phar_open_from_fp` slides a 1024-byte window across the whole file looking for a literal token, and the source says why in a comment that is a two-line confession of shotgun parsing.

```c
/* php-src, ext/phar/phar.c — phar_open_from_fp */
static const char token[] = "__HALT_COMPILER();";
...
/* Maybe it's better to compile the file instead of just searching,  */
/* but we only want the offset. So we want a .re scanner to find it. */
while(!php_stream_eof(fp)) {
    if ((got = php_stream_read(fp, buffer+tokenlen, readsize)) < tokenlen) { … }
    …
    if (got > 0 && (pos = php_memnistr(buffer, token, tokenlen, buffer + got + sizeof(token))) != NULL) {
        halt_offset += (pos - buffer);
        return phar_parse_pharfile(fp, fname, fname_len, alias_cstr, alias_len, halt_offset, pphar, compression, error);
    }
    halt_offset += got;
    memmove(buffer, buffer + window_size, tokenlen);
}
```

The recognizer for "is this a PHP archive?" is `memnistr` — a case-insensitive substring search. It is not PHP's parser; the comment admits it should have been. Consequently _any_ file of _any_ format containing that 18-byte token anywhere is a `phar`, which is the enabling condition for the `phar://` deserialization class: an attacker who can upload a JPEG and cause any PHP file function to be called on `phar://uploads/avatar.jpg` gets the archive manifest parsed, and — before PHP 8.0 — its metadata `unserialize`d. The same function also short-circuits on the first window: `PK\x03\x04` at offset 0 routes to `phar_parse_zipfile`, `BZh`/`\x1f\x8b\x08` route to a decompression retry (bounded by `recursion_count = 3`), and 512 bytes of tar checksum route to `phar_parse_tarfile`. One entry point, four grammars, chosen by sniffing.

---

## Format identity and multiplicity

**Multiplicity 3/3.** Multiplicity is not incidental here; it _is_ the subject. Each case below is one byte stream with two complete, independently valid parses, and in every case both parses are produced by shipping, mainstream code.

| Case                         | Parse A (low privilege)          | Parse B (high privilege)                 | Tolerance exploited                               | Year |
| ---------------------------- | -------------------------------- | ---------------------------------------- | ------------------------------------------------- | ---- |
| **GIFAR**                    | GIF87a/89a image                 | Signed Java JAR applet                   | ZIP prefix tolerance (`locpos = cenpos - cenoff`) | 2008 |
| **Content-sniffing XSS**     | PostScript / PNG / text upload   | `text/html` with script                  | Browser sniffers not prefix-disjoint              | 2009 |
| **Master Key** (`#8219321`)  | APK, verifier's view             | APK, installer's view                    | Duplicate CD entry names, unresolved              | 2013 |
| **Extra-field** (`#9695860`) | APK, C++ view                    | APK, Java view                           | `int16` vs `uint16` on `extraLength`              | 2013 |
| **Janus** (CVE-2017-13156)   | Signed APK (ZIP)                 | Raw DEX loaded by ART                    | DEX suffix tolerance × ZIP prefix tolerance       | 2017 |
| **MalDoc in PDF**            | PDF document                     | Word `.doc` with VBA macros              | MHT recognizer scanning past the PDF body         | 2023 |
| **`phar://` prefix**         | Any uploaded file (JPEG, GIF, …) | PHP archive with `unserialize`d metadata | Stream-scan for `__HALT_COMPILER();`              | 2018 |

### GIFAR: prefix tolerance written into the JDK, on purpose

A GIFAR is a GIF concatenated with a JAR. NVD's record for [CVE-2008-5343][cve-gifar] is the primary description — Java Web Start and the Java Plug-in through JDK/JRE 6u10 "allows remote attackers to make unauthorized network connections and hijack HTTP sessions via a crafted file that validates as both a GIF and a Java JAR file, aka 'GIFAR'". Billy Rios and Nate McFeters disclosed it at Black Hat USA 2008 and Rios [reported Sun's patch on 2008-12-17][rios].

The GIF half is trivial: GIF is header-anchored at `GIF87a`/`GIF89a` and terminated by a `;` trailer, so trailing bytes are outside the image. The JAR half is the interesting one, and the mechanism is still in OpenJDK today. `findEND` in [`zip_util.c`][jdk-zip-util] scans **backwards** from EOF for `PK\005\006` over 128-byte blocks, up to 64 KiB + 22 bytes, and accepts a candidate either when the declared comment length exactly reaches EOF _or_ when `verifyEND` confirms it:

```c
/* openjdk/jdk, src/java.base/share/native/libzip/zip_util.c */
static jboolean verifyEND(jzfile *zip, jlong endpos, char *endbuf) {
    /* ENDSIG matched, however the size of file comment in it does not
       match the real size. One "common" cause for this problem is some
       "extra" bytes are padded at the end of the zipfile.
       … */
```

Then `readCEN` derives the archive's origin rather than assuming it:

```c
    cenpos = endpos - cenlen;

    /* Get position of first local file (LOC) header, taking into
     * account that there may be a stub prefixed to the zip file. */
    zip->locpos = cenpos - cenoff;
```

The identical comment and the identical arithmetic appear in the pure-Java reader, [`ZipFile.Source.initCEN`][jdk-zipfile]. `zip->locpos` is the whole story: the JDK never asks what is at byte 0. It computes where the archive _would have_ started if the central-directory offsets are to be believed, and treats everything before that as a stub. A 4 KiB GIF prepended to a JAR yields `locpos == 4096` and a perfectly valid archive. And it is _not_ an accident — the same file also notes that the entry count is untrustworthy: "we do not trust `ENDTOT`, but treat it only as a strong hint."

Two observations that matter for the rest of the catalog:

- **The specification does not sanction this.** PKWARE [APPNOTE 6.3.10][appnote] §4.3.6, "Overall .ZIP file format," lists `[local file header 1]` as the first element of the archive; §4.1.9 permits "self-extracting" ZIPs which "MUST include extraction code for a target platform within the ZIP file" and says nothing about a prefix, an offset base, or how a reader should reconcile a non-zero `cenoff` derivation. The de-facto grammar every reader implements is strictly larger than the written one, and each reader extended it differently. This is LangSec's fourth anti-pattern — specification drift — observable as a diff between five implementations.
- **The tolerance survives the fix.** The comment above is in OpenJDK at `30df8a5a` (August 2026). Sun's 2008 patch changed the _applet loading_ path, not the ZIP reader. I could not verify from source what that patch did — the plugin is not in the OpenJDK repository — and mark it unverified below.

### Janus: two header-anchored formats, opposite ends

CVE-2017-13156 is the cleanest case in the table because both halves are visible in AOSP. The [December 2017 Android Security Bulletin][absb] lists it as `A-64211847`, EoP, High, affecting 5.1.1 through 8.0.

ART decides what a file is by reading four bytes at offset 0 and branching:

```cpp
// art, libdexfile/dex/dex_file_loader.cc — DexFileLoader::Open
uint32_t magic;
if (!InitAndReadMagic(/*header_offset=*/0, &magic, error_msg)) { return false; }

if (IsZipMagic(magic)) {            // 'P','K' → open as an archive, read classes.dex
    …
}
if (IsMagicValid(magic)) {          // "dex\n0nn" → the whole file IS the dex container
    …
    size_t file_size = dex_files->back()->GetHeader().file_size_;
    CHECK_LE(file_size, root_container_->Size() - header_offset);
```

`IsZipMagic` is two byte comparisons (`'P'`, `'K'`) in [`file_magic.cc`][art-magic]. The DEX branch is bounded by the header's own `file_size_` field — DEX is header-anchored _and_ self-delimiting, so everything after `file_size_` is invisible to it. Meanwhile v1 JAR signing covers only the digests of named entries recorded in `META-INF/MANIFEST.MF`; nothing in the v1 scheme covers byte 0, the file length, or the offsets. So a DEX header prepended to a v1-signed APK is: a valid DEX to ART (magic at 0, suffix ignored), and a validly signed APK to the verifier (EOCD at the tail, entries unchanged).

The fix, in [`libziparchive`][janus-fix], is four lines and is the single most instructive patch in this page:

```cpp
  uint32_t lfh_start_bytes;
  if (!archive->mapped_zip.ReadAtOffset(reinterpret_cast<uint8_t*>(&lfh_start_bytes),
                                        sizeof(uint32_t), 0)) { … return -1; }

  if (lfh_start_bytes != LocalFileHeader::kSignature) {
    ALOGW("Zip: Entry at offset zero has invalid LFH signature %" PRIx32, lfh_start_bytes);
    android_errorWriteLog(0x534e4554, "64211847");
    return -1;
  }
```

Android's ZIP reader now **requires that byte 0 be `PK\x03\x04`**, deleting prefix tolerance from the grammar entirely. The regression test is named `LeadingNonZipBytes`. The check is still present at `3861cb86`, at [`zip_archive.cc`][lza-archive] line 649. The JDK, which is the reader that made GIFAR possible, still does not have it.

### MalDoc in PDF: dispatch by filename

JPCERT/CC [documented this on 2023-08-28][jpcert]. The construction is an MHT file with a Word macro appended after a valid PDF's objects — "the attacker adds an mht file created in Word and with macro attached after the PDF file object and saves it." The result "can be opened in Word even though it has magic numbers and file structure of PDF."

The dispatch mechanism is the notable part, and it is not sniffing at all: "In the attack confirmed by JPCERT/CC, the file extension was `.doc`. Therefore, if a `.doc` file is configured to open in Word in Windows settings, the file created by MalDoc in PDF is opened as a Word file." The _shell_ picks the parse. The bytes are ambiguous; the name breaks the tie. Compare [`binfmt_misc`][binfmt], where the kernel resolves the same ambiguity from magic-and-mask at a configured offset — the same decision, moved down a layer and made explicit.

Note what ISO 32000-1 actually requires, because the tolerance here is not on the PDF side. §7.5.2 states that "the first line of a PDF file shall be a header consisting of the 5 characters `%PDF–`", and §7.5.5 that "the last line of the file shall contain only the end-of-file marker, `%%EOF`", with `startxref` on the line before. On paper PDF is both header-anchored _and_ footer-terminated, which would make it neither prefix- nor suffix-tolerant. It is real readers, not the standard, that scan for `%%EOF` backwards and accept whatever precedes it — and the second recognizer, Word's MHT reader, that accepts a MIME part it did not find at offset 0.

### MIME sniffing: the standardized differential

Content sniffing is a parser differential _institutionalized_: the server's `Content-Type` is one claim about the language, and the browser's sniffer is a second, independent recognizer over the same bytes. The [MIME Sniffing Standard][mimesniff]'s own introduction is the clearest available statement of why this class exists:

> _"Without a clear specification for how to 'sniff' the MIME type, each user agent has been forced to reverse-engineer the algorithms of other user agents in order to maintain interoperability. Inevitably, these efforts have not been entirely successful, resulting in divergent behaviors among user agents. In some cases, these divergent behaviors have had security implications, as a user agent could interpret an HTTP response as a different MIME type than the server intended."_

> _"These security issues are most severe when an 'honest' server allows potentially malicious users to upload their own files and then serves the contents of those files with a low-privilege MIME type. For example, if a server believes that the client will treat a contributed file as an image (and thus treat it as benign), but a user agent believes the content to be HTML (and thus privileged to execute any scripts contained therein), an attacker might be able to steal the user's authentication credentials and mount other cross-site scripting attacks."_

That is the privilege-gradient ingredient, stated by a standards body. The algorithm the standard specifies derives from [Barth, Caballero and Song (2009)][barth], whose title — _"Secure Content Sniffing for Web Browsers, or How to Stop Papers from Reviewing Themselves"_ — describes a polyglot attack on a conference management system: a submitted paper that "both is valid PostScript and contains HTML," which HotCRP accepted as PostScript and Internet Explorer 7 rendered as script.

---

## Index anchoring and random access

This is the structural core, and the place where a survey of five ZIP readers pays for itself. All five locate the same index — the End of Central Directory record — and no two do it the same way. Because EOCD is variable-length (a 16-bit comment length follows it), _every_ reader must scan, and scanning is where grammars diverge.

| Reader                                         | EOCD search                                                                | Ambiguity policy                                                                                                           | Prefix policy                                                                | Duplicate names                                  |
| ---------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------ |
| OpenJDK [`zip_util.c`][jdk-zip-util] (C)       | backwards over 128-byte blocks, up to `0xFFFF + 22`                        | first hit scanning backwards; `verifyEND` accepts a _wrong_ comment length if CEN+LOC signatures check out                 | rebases: `locpos = cenpos - cenoff`                                          | last wins (head insertion)                       |
| OpenJDK [`ZipFile.Source`][jdk-zipfile] (Java) | same shape                                                                 | same                                                                                                                       | same rebasing, same comment ("there may be a stub prefixed to the ZIP file") | last wins (head insertion)                       |
| Android [`libziparchive`][lza-archive]         | one read of the last `0xFFFF + 22`, backwards for `0x06054b50`             | **rejects** unless `eocd_offset + 22 + comment_length == file_length`                                                      | **rejects** unless byte 0 is `PK\x03\x04`                                    | **rejects** (`kDuplicateEntry`)                  |
| Go [`archive/zip`][go-zip]                     | last 1 KiB, then last 65 KiB; backwards                                    | **rejects** on a truncated comment, with a source note that "some parsers (such as Info-ZIP) ignore the truncated comment" | derives `baseOffset`, then **second-guesses it** (below)                     | `fs.FS` view errors; `r.File` slice exposes both |
| CPython [`zipfile`][cpython-zip]               | exact-tail fast path, else `data.rfind(stringEndArchive)` over 64 KiB + 22 | **last occurrence, no comment-length check at all**                                                                        | derives `concat`, adds it to every `header_offset`                           | last wins (`NameToInfo` dict)                    |
| Android [`apksig`][apksig-utils]               | probes the zero-comment offset first, then expands to 64 KiB               | requires `cdEnd == eocdStart` before a signing block is read                                                               | offsets treated as absolute                                                  | **rejects** (`JAR_SIG_DUPLICATE_ZIP_ENTRY`)      |

Three of these deserve their exact wording.

**CPython states its assumption and does not check it.** From [`Lib/zipfile/__init__.py`][cpython-zip]: _"It is assumed that the 'end of central directory' magic number does not appear in the comment."_ `rfind` then takes the last occurrence anywhere in the trailing 64 KiB window. A file with two EOCD records — the situation saurik constructed by hand, below — is resolved by CPython to whichever is later in the file, and by `apksig` to whichever satisfies the zero-comment probe first.

**Go documents its own ambiguity heuristic.** [`readDirectoryEnd`][go-zip] computes `baseOffset = directoryEndOffset - directorySize - directoryOffset` and then immediately distrusts it:

```go
// go, src/archive/zip/reader.go
// If the directory end data tells us to use a non-zero baseOffset,
// but we would find a valid directory entry if we assume that the
// baseOffset is 0, then just use a baseOffset of 0.
// We've seen files in which the directory end data gives us
// an incorrect baseOffset.
if baseOffset > 0 {
    off := int64(d.directoryOffset)
    rs := io.NewSectionReader(r, off, size-off)
    if readDirectoryHeader(&File{}, rs) == nil {
        baseOffset = 0
    }
}
```

This is a probe-and-prefer disambiguation between two candidate parses of the same file, committed to the standard library, with the empirical justification stated in the comment. It is a perfectly reasonable engineering decision and it is also, precisely, a place where Go's grammar for ZIP differs from the JDK's by construction — Go prefers the absolute reading, the JDK always prefers the rebased one.

**`apksig` requires the sections to abut.** Signature verification cannot tolerate a gap it does not digest, so [`ApkUtilsLite.findApkSigningBlock`][apksig-lite] fails closed:

```java
// apksig, src/main/java/com/android/apksig/apk/ApkUtilsLite.java
if (centralDirEndOffset != eocdStartOffset) {
    throw new ApkSigningBlockNotFoundException(
            "ZIP Central Directory is not immediately followed by End of Central Directory"
                    + ". CD end: " + centralDirEndOffset + ", EoCD start: " + eocdStartOffset);
}
```

That is a recognizer clause: it does not fix up, it does not prefer, it rejects. Compare `verifyEND`, which exists specifically to _accept_ a stream where the same arithmetic does not add up.

### Random access is what makes this exploitable at scale

The reason a footer index is worth having — that a consumer can read 22 bytes at the tail, then a few kilobytes of directory, and name every member without reading the body — is the same reason it can be lied to. [Range-request access][range] to a remote ZIP or Parquet reads exactly the bytes the footer points at; a footer that points somewhere else redirects the whole read with no additional cost to the attacker. Header-anchored formats do not have this problem and do not have this capability either. The trade is not incidental to the design; it _is_ the design, which is why it recurs in [footer-indexed formats][footer] generally rather than in ZIP specifically.

---

## Reflexivity and query surface

**Reflexivity 0/3, and the zero is the finding.**

None of the formats in this page can be interrogated about _which_ parse a given consumer will take. There is no schema, no manifest of "the reading I intend", no way to ask a file what it is. The only available query is operational: run a parser and observe. That is why the tooling around this class is a set of _competing recognizers_ rather than a query surface, and why each of them is itself a differential:

- JPCERT/CC notes that for MalDoc in PDF "there is a high possibility that PDF analysis tools such as `pdfid` cannot detect its malicious parts," while `olevba` — a recognizer for the _other_ grammar — "outputs the embedded macros" and is "still an effective countermeasure." Two analysis tools, two languages, two answers about one file. The published mitigation is a YARA rule that matches the _conjunction_ — the PDF magic `0x46445025` together with MHT headers and `<w:WordDocument>` — i.e. a third recognizer whose entire job is to detect that the first two disagree.
- `apksig` is the closest thing in this survey to a reflexive query surface, and it works precisely because it refuses to be a single parser. `ApkVerifier` verifies against a `[minSdkVersion, maxSdkVersion]` _range_ and reports which schemes each platform generation would honour: "Platforms prior to Android N ignore APK Signature Scheme v2 signatures and always attempt to verify JAR signatures. Android N onwards verifies JAR signatures only if no APK Signature Scheme v2 (or newer scheme) signatures were found." It models the population of consumers as data. That is the reflexive move the formats themselves do not make.

Contrast with the reflexive end of this catalog. A [SELF binary][selfdb] answers "what is in me?" in SQL, over a schema carried in the artifact, with one answer. A GIFAR answers it differently depending on who asks. The reflexivity axis and the differential class are close to inverses: **the more a format carries a single authoritative self-description, the less room there is for two consumers to disagree** — which is thesis 2 of the source outline (_self-description is what makes a format survivable_) restated as a security property rather than a maintenance one. See [concepts][concepts] for the axis definitions and [comparison][comparison] for where each subject lands.

---

## Closure, dedup, and size model

**Closure 0/3** — a differential carries nothing; it is a property of a stream, not a package. **Mutability 1/3** — incidental: the artifact is not a state store, but its _effective content_ changes with the reader, which is a strange sort of mutability worth naming.

The size model is where this section becomes non-vacuous, because in a differential **the size of the artifact is parser-relative**. The same bytes have different extents depending on who reads them, and the exploits are engineered against those extents:

| Quantity                             | Value                  | Consequence                                                                          |
| ------------------------------------ | ---------------------- | ------------------------------------------------------------------------------------ |
| ZIP comment length field             | 16-bit → max 65 535    | Bounds every backwards EOCD search; sets the 64 KiB scan windows in all five readers |
| `mimesniff` resource header          | 1445 bytes             | The sniffing algorithm is _bounded_ by construction — see below                      |
| Central directory record, fixed part | 46 bytes + name        | 64 KiB of "extra" hides ~1400 forged directory entries (saurik's merge)              |
| `extraLength` misread as `int16`     | 65 533 read as `-3`    | Java's data offset moves 3 bytes _backwards_ into the filename (`#9695860`)          |
| Practical payload ceiling, that bug  | 64 KiB, then 32 KiB    | Why the extra-field bug was "less generic" than Master Key                           |
| DEX `file_size_` header field        | declared, `CHECK_LE`'d | Everything past it is invisible to ART — the Janus suffix window                     |
| `phar` scan window                   | 1024 + 18 bytes        | Sliding; the whole file is searched, so there is no size bound at all                |

The dedup analogue is the strangest artifact in the class, and it is saurik's second technique on bug `#9695860`: because a large `extraLength` is honoured by C++ and clamped to zero by Java, one can place a second, complete central directory _inside_ what the C++ reader considers extra data. He describes the result exactly:

> _"as 64kB is a large amount of space (a central directory entry is only 46 bytes plus the length of the filename), we can then just continue each chain normally, merging two entirely different zip files together, sharing only a single common file."_

Two archives, one stream, one shared member. Which central directory is authoritative is not a question the format answers; it is a question each reader answers differently. This is [ZIP parasitism][zip-parasitism] with the polarity reversed — the same suffix-index property that lets [redbean carry its own assets][ape] lets an attacker carry a second archive that only one reader will see.

---

## Mutability, dispatch, and trust

### The signing schemes are the interesting artifact

A signature is a claim about bytes. A differential is a disagreement about which bytes matter. The evolution of APK signing is therefore the best-documented natural experiment in this whole catalog, because Google shipped three schemes and each one narrows the language.

| Scheme           | What is covered                                                                                   | Differentials it closes                                          | Left open                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------- |
| v1 (JAR signing) | The digest of each named entry's _uncompressed contents_, per `META-INF/MANIFEST.MF`              | Content substitution for entries actually listed                 | Byte 0, file length, offsets, duplicate names, extra fields, ordering |
| v2 (Android 7.0) | Byte ranges: contents from offset 0 to the signing block, the signing block, the CD, and the EOCD | Janus, prefix/suffix insertion, offset games, unsigned entries   | Nothing about the _interpretation_ of covered bytes                   |
| v3 / v4          | v2 plus rotation lineage; v4 adds an fs-verity Merkle tree in a side file                         | Key rotation without reinstall; incremental install verification | Same                                                                  |

[Android's v2 documentation][apkv2] states the goal plainly — "a whole-file signature scheme that increases verification speed and strengthens integrity guarantees by detecting any changes to the protected parts of the APK" — protecting "sections 1, 3, 4, and the `signed data` blocks of the APK signature scheme v2 block contained inside section 2."

The mechanically interesting part is how v2 handles the one field it _cannot_ leave alone. The EOCD's central-directory-offset field necessarily changes when a signing block is inserted, so digesting it verbatim would be self-defeating. `apksig` normalizes instead of excluding:

```java
// apksig, src/main/java/com/android/apksig/internal/apk/ApkSigningBlockUtils.java
// For the purposes of verifying integrity, ZIP End of Central Directory (EoCD) must be
// treated as though its Central Directory offset points to the start of APK Signing Block.
// We thus modify the EoCD accordingly.
…
ZipUtils.setZipEocdCentralDirectoryOffset(modifiedEocd, beforeApkSigningBlock.size());
```

That is a **canonicalization step inside the verifier** — the LangSec-correct answer to "a field whose value is not stable but whose meaning is". The signature covers a canonical form of the record rather than a raw byte range with a hole in it. The same document's open question about [signing a mutable artifact][provenance] runs into exactly this: a canonical serialization is the prerequisite, and it is not optional.

### Master Key and the discipline of rejection

`#8219321` is the case LangSec's own handout cites, and its fix is the purest demonstration of "reject, do not resolve". The bug is that ZIP does not require entry names to be unique, and the two implementations resolved the collision oppositely. saurik's account, cited by the LangSec handout, is exact on both sides. Java's `ZipFile` built a `LinkedHashMap` keyed by name, so `PackageParser`'s iteration "means that only the last entry with a given name is considered for signature verification: all previous duplicates are discarded." The C++ reader used an open-addressed table without replacement:

> _"This algorithm is an unchained hashtable with linear probing, without replacement. … The algorithm for finding entries is the same as that for adding them: you scan forward looking for a match. This means earlier entries are used instead of later ones."_

Verifier sees the last; loader runs the first. Both readings are defensible; the format underdetermines the choice. The comment on Hacker News that saurik quotes had worked it out from the JAR signing algorithm alone: _"The zip format doesn't structurally guarantee uniqueness of names in file entries. If the APK signature verification chooses the first matching file entry for a given name, and unpacking chooses the last then you're screwed in the way described."_

Both fixes are recognizer clauses. `libziparchive` now refuses:

```cpp
// libziparchive, zip_cd_entry_map.cc — CdEntryMapZip32::AddToMap
while (hash_table_[ent].name_offset != 0) {
    if (ToStringView(hash_table_[ent], start) == name) {
      // We've found a duplicate entry. We don't accept duplicates.
      ALOGW("Zip: Found duplicate entry %.*s", …);
      return kDuplicateEntry;
    }
    ent = (ent + 1) & (hash_table_size_ - 1);
}
```

and `apksig` refuses before it verifies anything, in [`V1SchemeVerifier`][apksig-v1]: `checkForDuplicateEntries` runs over the parsed central directory and, if it reports any error, `verify` returns immediately — full recognition of the entry-name set before any signature processing. Neither implementation now needs to know which duplicate the _other_ one would have picked, which is the point.

### Dispatch: who decides, and how many deciders there are

The catalog's second structural question — _who decides what the file is?_ — is here the whole threat model, because the answer is "more than one party, without coordination".

| Decider           | Mechanism                                                     | Ambiguity behaviour                                                             |
| ----------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Kernel            | [`binfmt_misc`][binfmt]: magic + mask at a configured offset  | Deterministic and configurable, but registration is itself a privileged surface |
| Loader            | ART's `IsZipMagic` / `IsMagicValid` on byte 0                 | First matching branch wins; the DEX branch is checked after ZIP                 |
| Shell / desktop   | Filename extension (MalDoc in PDF)                            | Bytes ignored entirely                                                          |
| Consumer sniffing | [`mimesniff`][mimesniff] pattern tables over a bounded header | Standardized, but only after a decade of divergence                             |
| Substring scan    | `phar`'s `__HALT_COMPILER();` window                          | Any position, any surrounding format                                            |

The `mimesniff` design is worth studying as the one case where a standards body confronted a differential and _shrank_ the language rather than documenting it. Three mechanisms do the work:

1. **A bounded, prefix-anchored recognizer.** The "resource header" is at most 1445 bytes from the front, and the note explains why: "If the number of bytes in `buffer` is greater than or equal to 1445, the MIME type sniffing algorithm will be deterministic for the majority of cases." No backwards scanning, no unbounded window.
2. **An explicit opt-out.** The `no-sniff flag`, set by `X-Content-Type-Options: nosniff` (defined in [Fetch][fetch]), short-circuits the algorithm entirely: "If the `no-sniff` flag is set, the computed MIME type is the supplied MIME type." The server is allowed to declare that there is exactly one grammar.
3. **A privilege-escalation floor**, in a normative warning: "It is critical that the rules for distinguishing if a resource is text or binary never determine the computed MIME type to be a scriptable MIME type, as this could allow a privilege escalation attack."

Items 1 and 3 are Barth, Caballero and Song's two principles, adopted verbatim. Their paper is where the general answer lives, and it is the right place to end.

---

## Making superposition impossible

Barth et al. formulated the necessary property, and their name for it generalizes far beyond browsers:

> _"Use prefix-disjoint signatures. A content-sniffing algorithm uses prefix-disjoint signatures if its HTML signature does not share a prefix with a signature for another type commonly used on the Web. More precisely, a set of signatures is prefix-disjoint if there does not exist two distinct sequences of bytes with a common prefix such that one matches the HTML signature and the other matches a signature for a non-HTML type commonly used on the Web."_

Prefix-disjointness is exactly the condition that makes a _streaming_ recognizer decide the format after a bounded prefix and never revise. Generalized to file formats, a format that cannot participate in a superposition must satisfy all of the following. Each clause corresponds to a case above, and each has been implemented _somewhere_ — but no widely deployed format implements the set.

| Requirement                                                                                                                     | What it forecloses                         | Who does it                                                                                                  | Who does not                                              |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------- |
| **1. Magic at offset 0, mandatory, checked**                                                                                    | Prefix parasitism (GIFAR, Janus)           | ELF, DEX, `libziparchive` since 2017, `mimesniff`                                                            | OpenJDK ZIP, CPython, Go (rebasing), PDF in practice      |
| **2. Total length declared in the header and enforced equal to the file size**                                                  | Suffix parasitism, appended second archive | `libziparchive` (EOCD length check); DEX declares `file_size_` but does **not** require it to equal the file | ZIP generally, GIF, PDF                                   |
| **3. No scanning: every offset absolute from byte 0, never derived**                                                            | Rebasing, double central directories       | `apksig`, `libziparchive`                                                                                    | OpenJDK (`locpos`), CPython (`concat`), Go (`baseOffset`) |
| **4. Canonical encoding — no duplicate keys, no redundant fields, one encoding per value**                                      | Master Key, extra-field games              | `libziparchive`, `apksig`                                                                                    | ZIP as specified; APPNOTE requires nothing here           |
| **5. A signature over the _entire_ byte range, with an explicit canonicalization of any field the signing process must change** | Everything above, at the trust boundary    | APK Signature Scheme v2/v3                                                                                   | JAR/v1 signing, PDF incremental-update signatures         |
| **6. Full recognition before processing — no length, offset or magic acted upon before the whole input is accepted**            | The shotgun-parser class as a whole        | (aspirational)                                                                                               | every reader surveyed here                                |

Requirement 6 is the one nobody meets, and its cost is the reason. `libziparchive` comes closest and pays for it in compatibility: it rejects trailing bytes, rejects a prefix, and rejects duplicates, which means it rejects self-extracting archives, rejects [APE binaries][ape], and rejects a large fraction of the ZIPs in the wild. That is not an oversight in the other readers — it is a different position on the same trade. The tolerance is not a bug that survived; it is a feature that was demanded, is still demanded, and is the enabling condition for most of this catalog.

Which sharpens the catalog's own claim. **Format tolerance is not incidental to superposition; it is identical to it.** Every property that makes a format hospitable to an autological artifact — a derivable base offset, an index you can find by scanning, an unknown-bytes policy of "ignore" — is the same property that makes two of its readers disagree. There is no version of [redbean][ape] that runs on six loaders and also satisfies requirements 1 through 4, because those requirements are precisely the negation of what makes it possible. The [threat model][threat] page is where the consequences for a self-modifying artifact are worked out; the observation here is narrower and, I think, harder: _the polyglot and the vulnerability are the same object, described by different observers._

---

## Strengths

As a lens, not as a thing to build:

- **Predictive rather than descriptive.** Knowing where a format anchors its index and how it treats unknown bytes predicts which polyglots are possible, before anyone constructs one. Every case in this page falls out of `header-anchored × footer-anchored`, `stream-scanned × anything`, or `unresolved-duplicate × two-consumers`.
- **The fixes are small and checkable.** Four lines for Janus. One `HashSet` for Master Key. A field normalization for v2. Every one is a recognizer clause that can be read, tested, and grepped for — unlike "validate your input", which cannot.
- **It names the trust boundary correctly.** The bug is not in either parser; both are individually defensible. Locating the defect in the _pair_ is what makes the class tractable, and it is what the two-consumer framing buys.
- **The decidability argument gives a real design lever.** "Keep the input language at or below deterministic context-free" is a constraint a format designer can act on, with a known consequence (parser equivalence becomes decidable).
- **Empirically grounded prescriptions.** Barth et al. evaluated their principles against "over a billion HTTP responses" and got them adopted by Chrome and the HTML working group; `mimesniff` is the standardized result. This is not a purely theoretical programme.

## Weaknesses

- **Full recognition before processing is often not affordable.** It requires reading the whole input before acting on any of it, which is incompatible with streaming, with 200 MiB archives read over range requests, and with the [random access][range] that footer indexes exist to provide.
- **The discipline breaks compatibility, visibly.** `libziparchive`'s three refusals cost it self-extracting archives and every prefixed ZIP in existence. A general-purpose library that made the same choices would be replaced.
- **Undecidability is a real ceiling, not a rhetorical one.** For an input language above deterministic context-free — which HTML, PDF and PostScript all are — there is no procedure that establishes two parsers equivalent. For those formats the programme offers analysis, not assurance.
- **It says nothing about semantic differentials.** Two parsers can agree on the tree and disagree on what a node _means_ (a relative path, a Unicode normalization, a locale-dependent comparison). Those are real vulnerabilities that this framing does not reach.
- **Retrofitting is nearly impossible.** Requirements 1–4 are all _narrowings_. Applying them to a deployed format invalidates existing files by construction, which is why v2 signing was added _beside_ v1 rather than replacing it, and why `apksig` still has to model six platform generations at once.
- **"Two consumers" is not always knowable.** The number of programs that will parse a given byte stream is open-ended. `apksig` models it as an SDK range because Android's population is enumerable; the web's is not.

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                                             | Trade-off                                                                                                    |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Treat input handling as _recognition_ of a formal language                  | Makes verification possible at all; separates the checkable part from the part that assumes           | Requires a written grammar, which most deployed formats do not have and cannot retroactively acquire         |
| Reduce the input language to the least powerful class that suffices         | Below deterministic context-free, parser equivalence is decidable                                     | Rules out expressive formats people actually want (HTML, PDF, PostScript)                                    |
| Reject ambiguity rather than resolve it (`kDuplicateEntry`, LFH-at-0)       | The resolving reader and the other reader will resolve differently; refusal is the only stable choice | Breaks real files: self-extracting archives, prefixed ZIPs, [APE][ape]                                       |
| Anchor the recognizer at byte 0 with a bounded window (`mimesniff`, 1445 B) | Deterministic, streamable, prefix-disjoint by construction                                            | Cannot describe footer-indexed formats at all; forfeits [random access][range]                               |
| Sign byte _ranges_ rather than logical entries (APK v2 over v1)             | Removes every offset, ordering and metadata game in one move                                          | Any legitimate rewrite invalidates the signature; needs a canonicalization for fields the signer must change |
| Offer an explicit opt-out from sniffing (`X-Content-Type-Options: nosniff`) | Lets the producer assert one grammar without the format changing                                      | Opt-in, so the insecure default persists; only covers the HTTP path                                          |
| Keep a compatibility fallback (`verifyEND`, Go's `baseOffset` probe)        | Real corpora contain files that a strict reader rejects                                               | The fallback _is_ the second grammar; it is where the next differential comes from                           |
| Model the consumer population as data (`apksig`'s SDK range)                | The only honest answer when several parser generations coexist                                        | Only possible where the population is enumerable; the web's is not                                           |

---

## Sources

- [LangSec: Recognition, Validation, and Compositional Correctness for Real World Security — BoF handout][bof] (mission statement; the four anti-patterns; the Master Key footnote)
- [Sassaman, Patterson, Bratus, Locasto — _The Halting Problems of Network Stack Insecurity_][sassaman] and the [langsec.org][langsec] paper index
- [Momot, Bratus, Hallberg, Patterson — _Curing the Vulnerable Parser: Design Patterns for Secure Input Handling_, `;login:` Spring 2017][curing]
- [Barth, Caballero, Song — _Secure Content Sniffing for Web Browsers, or How to Stop Papers from Reviewing Themselves_, IEEE Symposium on Security and Privacy, 2009][barth] (privilege escalation; prefix-disjoint signatures)
- [WHATWG MIME Sniffing Standard][mimesniff] · source: [`mimesniff.bs`][mimesniff-src] · [Fetch: `X-Content-Type-Options`][fetch]
- [PKWARE APPNOTE.TXT 6.3.10 — .ZIP File Format Specification][appnote] (§4.1.9, §4.3.6)
- [ISO 32000-1:2008 (PDF 1.7)][pdf32000] (§7.5.2 File Header, §7.5.5 File Trailer)
- OpenJDK: [`zip_util.c`][jdk-zip-util] (`findEND`, `verifyEND`, `readCEN`, `locpos`) · [`java/util/zip/ZipFile.java`][jdk-zipfile]
- Android: [`libziparchive/zip_archive.cc`][lza-archive] · [`zip_cd_entry_map.cc`][lza-map] · [the Janus fix, `9dced162`][janus-fix] · [ART `dex_file_loader.cc`][art-loader] · [`file_magic.cc`][art-magic]
- Android `apksig`: [`ApkUtilsLite.java`][apksig-lite] · [`internal/zip/ZipUtils.java`][apksig-utils] · [`internal/apk/v1/V1SchemeVerifier.java`][apksig-v1] · [`internal/apk/ApkSigningBlockUtils.java`][apksig-block]
- [Android Security Bulletin, December 2017 (CVE-2017-13156, Janus)][absb] · [APK Signature Scheme v2][apkv2]
- [NVD CVE-2008-5343 — GIFAR][cve-gifar] · [Billy Rios, "SUN Fixes GIFARs" (2008-12-17), as quoted by cgisecurity][rios]
- [Jay Freeman (saurik) — _Exploit (& Fix) Android "Master Key"_][saurik17] · [_Android Bug Superior to Master Key_][saurik18]
- [JPCERT/CC — _MalDoc in PDF: Detection bypass by embedding a malicious Word file into a PDF file_ (2023-08-28)][jpcert]
- PHP: [`ext/phar/phar.c`][php-phar] (`phar_open_from_fp`, lazy metadata)
- Go: [`src/archive/zip/reader.go`][go-zip] · CPython: [`Lib/zipfile/__init__.py`][cpython-zip]
- Related in this tree: [ZIP parasitism][zip-parasitism] · [Polyglot craft][polyglot] · [Footer-indexed formats][footer] · [Threat model][threat] · [`binfmt_misc`][binfmt] · [redbean / Cosmopolitan / APE][ape] · [Embedded provenance][provenance] · [Boot hybrids][boot] · [Range-request access][range] · [SELF / selfdb][selfdb] · [Concepts][concepts] · [Comparison][comparison]

> [!NOTE]
> **Unverified.** I could not establish from primary source what Sun's fix for CVE-2008-5343 actually changed — the Java Plug-in and Web Start applet-loading path is not in the OpenJDK repository, and the original `xs-sniper.com` post is reachable only through mirrors. The claim made here is narrower and is source-grounded: the ZIP reader's prefix tolerance (`locpos = cenpos - cenoff`) that makes a GIF-prefixed JAR parse is still present in OpenJDK at `30df8a5a`, so whatever the 2008 fix did, it was not to remove that tolerance.

<!-- References -->

[langsec]: https://langsec.org/
[bof]: https://langsec.org/bof-handout.pdf
[sassaman]: https://langsec.org/papers/Sassaman.pdf
[curing]: https://langsec.org/papers/curing-the-vulnerable-parser.pdf
[barth]: https://www.adambarth.com/papers/2009/barth-caballero-song.pdf
[mimesniff]: https://mimesniff.spec.whatwg.org/
[mimesniff-src]: https://github.com/whatwg/mimesniff/blob/39aa53511b13953d84fef8d4131d6f61d0ccbde6/mimesniff.bs
[fetch]: https://fetch.spec.whatwg.org/#x-content-type-options-header
[appnote]: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
[pdf32000]: https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf
[jdk-zip-util]: https://github.com/openjdk/jdk/blob/30df8a5af29ff682f9b6d50e51c46efcf19c920f/src/java.base/share/native/libzip/zip_util.c
[jdk-zipfile]: https://github.com/openjdk/jdk/blob/30df8a5af29ff682f9b6d50e51c46efcf19c920f/src/java.base/share/classes/java/util/zip/ZipFile.java
[lza-archive]: https://android.googlesource.com/platform/system/libziparchive/+/3861cb86976b51f61193255f61b7bcf99c5f2918/zip_archive.cc
[lza-map]: https://android.googlesource.com/platform/system/libziparchive/+/3861cb86976b51f61193255f61b7bcf99c5f2918/zip_cd_entry_map.cc
[janus-fix]: https://android.googlesource.com/platform/system/core/+/9dced1626219d47c75a9d37156ed7baeef8f6403
[art-loader]: https://android.googlesource.com/platform/art/+/6484611fd45e69db9f33f98bfd6864014b030ecf/libdexfile/dex/dex_file_loader.cc
[art-magic]: https://android.googlesource.com/platform/art/+/6484611fd45e69db9f33f98bfd6864014b030ecf/libartbase/base/file_magic.cc
[apksig-lite]: https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/main/java/com/android/apksig/apk/ApkUtilsLite.java
[apksig-utils]: https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/main/java/com/android/apksig/internal/zip/ZipUtils.java
[apksig-v1]: https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/main/java/com/android/apksig/internal/apk/v1/V1SchemeVerifier.java
[apksig-block]: https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/main/java/com/android/apksig/internal/apk/ApkSigningBlockUtils.java
[absb]: https://source.android.com/docs/security/bulletin/2017-12-01
[apkv2]: https://source.android.com/docs/security/features/apksigning/v2
[cve-gifar]: https://nvd.nist.gov/vuln/detail/CVE-2008-5343
[rios]: https://www.cgisecurity.com/2008/12/sun-fixes-gifars.html
[saurik17]: https://www.saurik.com/id/17
[saurik18]: https://www.saurik.com/id/18
[jpcert]: https://blogs.jpcert.or.jp/en/2023/08/maldocinpdf.html
[php-phar]: https://github.com/php/php-src/blob/0c87849da5a67a6f4cac4b6225cf026a7db5377b/ext/phar/phar.c
[go-zip]: https://github.com/golang/go/blob/620058f867b26c29f76198b170e816004ecd4144/src/archive/zip/reader.go
[cpython-zip]: https://github.com/python/cpython/blob/9036982ed73d17848d45b60b7550f097371214e4/Lib/zipfile/__init__.py
[zip-parasitism]: ./zip-parasitism.md
[polyglot]: ./polyglot-craft.md
[footer]: ./footer-indexed-formats.md
[threat]: ./threat-model.md
[binfmt]: ./binfmt-misc.md
[ape]: ./cosmopolitan-ape/index.md
[provenance]: ./embedded-provenance.md
[boot]: ./boot-hybrids.md
[range]: ./range-request-access.md
[selfdb]: ./self-selfdb/index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
