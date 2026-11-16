# ExifTool (Perl)

The reference reader and writer for image, audio and video metadata: about 225 Perl modules (plus 15 `.pl` files) whose tag tables are plain data (tag ID to name, format, conversion, write rules), walked by a small set of container procedures; it is the survey's model for a metadata vocabulary and the natural oracle for a Sparkles metadata explorer.

| Field         | Value                                                                                                                         |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Language      | Perl 5 (core modules only; optional `Compress::Zlib`, `Digest::MD5` and others)                                               |
| License       | Same terms as Perl itself: Artistic License or GPL ([`README`][readme-license]); the `LICENSE` file holds the GPLv3 text      |
| Repository    | [exiftool/exiftool][repo]                                                                                                     |
| Revision read | `2200871d9cef988051d2a99d67df3bda6cbb30a8` (May 27, 2026; version 13.59)                                                      |
| Documentation | [`lib/Image/ExifTool/README`][tt-readme] (tag-table developer reference) · [`ExifTool.pod`][pod-getgroup] · [`exiftool`][cli] |
| Category      | Metadata: container walkers, tag tables, maker notes, metadata writing                                                        |
| Tier          | B                                                                                                                             |
| Last reviewed | November 7, 2026                                                                                                              |

> [!NOTE]
> Claims marked **demonstrated** come from running `exiftool` from the pinned clone (Perl 5.40.0, x86_64 Linux)
> against files crafted by a short Perl script in `/tmp/exiftool-demo`: a JPEG whose `ExifOffset` points back at
> `IFD0`, one whose `IFD0` next-IFD pointer is itself, one with fifteen entries of an invalid TIFF type, one whose
> value size exceeds 2 GiB, and PNG and JPEG files written by ExifTool itself. Counts of tags and groups were read
> from `exiftool -list`, `exiftool -listw` and `Image::ExifTool::GetAllGroups` at the same revision.

---

## Overview

### What it solves

ExifTool answers "what metadata does this file carry, where exactly, and what does it mean", across more than
two hundred file types. Its `README` describes it as "a customizable set of Perl modules plus a full-featured
command-line application for reading and writing meta information in a wide variety of files, including the
maker note information of many digital cameras" ([`README`][readme-intro]). It does not decode pixels: image
data is located (offsets, lengths, an optional hash) and otherwise carried through untouched.

### Design philosophy

The design philosophy is that **knowledge lives in tables, not code**. The developer reference opens with the
contract every format module follows:

> The tables in these files are used as lookups based on the tag ID values. The hash keys are the tag IDs (in
> decimal or hexadecimal if the ID is numerical as with EXIF tables, or the tag name if the ID is ASCII as with
> XMP tables). In the case of a BinaryData table, the IDs are numerical and specify offsets into the binary data
> block … ([`README`][tt-intro])

A handful of generic procedures (`ProcessExif`, `ProcessBinaryData`, `ProcessMOV`, `ProcessPNG`, `ProcessRIFF`,
the XMP parser) interpret those tables; a new camera model is usually a table edit, not a new parser. Writing is
conservative: by default "the original files are preserved with `_original` appended to their names"
([`exiftool` DESCRIPTION][cli-desc]).

## How it works

### Tag tables

A tag table is a Perl hash named after its module (`%Image::ExifTool::Exif::Main`,
`%Image::ExifTool::PNG::Main`). Upper-case keys describe the table; every other key is a tag ID. The `README`
lists "Twenty-eight special keys (`TABLE_NAME`, `SHORT_NAME`, `PROCESS_PROC`, `WRITE_PROC`, `CHECK_PROC`, …)"
([`README`][tt-special]); the important ones are `PROCESS_PROC` (the walker for this directory type),
`WRITE_PROC`, `GROUPS` (default group names), `FORMAT` (default binary format) and `NAMESPACE` (XMP).

The EXIF table header and two entries ([`Exif.pm`][exif-main], [`Exif.pm`][exif-make],
[`Exif.pm`][exif-orient]):

```perl
%Image::ExifTool::Exif::Main = (
    GROUPS => { 0 => 'EXIF', 1 => 'IFD0', 2 => 'Image'},
    WRITE_PROC => \&WriteExif,
    CHECK_PROC => \&CheckExif,
    WRITE_GROUP => 'ExifIFD',   # default write group
    SET_GROUP1 => 1, # set group1 name to directory name for all tags in table
    ...
    0x10f => {
        Name => 'Make',
        Groups => { 2 => 'Camera' },
        Writable => 'string',
        WriteGroup => 'IFD0',
        DataMember => 'Make',
        RawConv => '$val =~ s/\s+$//; $$self{Make} = $val',
    },
    ...
    0x112 => {
        Name => 'Orientation',
        Writable => 'int16u',
        WriteGroup => 'IFD0',
        PrintConv => \%orientation,
        Priority => 0,  # so PRIORITY_DIR takes precedence
    },
```

Each entry's tag-information hash carries, among nearly seventy documented keys ([`README`][tt-name]):

- **Identity and docs:** `Name` ("Tag names need not be unique"), `Description`, `Notes`, `Groups`.
- **Decoding:** `Format`, `Count`, `Mask`/`BitShift` for packed fields in `BinaryData` tables.
- **Three conversion stages:** `RawConv` runs at extraction time and may drop the tag or record state;
  `ValueConv` turns the raw value into a usable one; `PrintConv` makes it human-readable, often as a lookup hash
  whose misses print as "Unknown (X)" ([`README`][tt-conv], [`README`][tt-printconv]). Each has an inverse
  (`RawConvInv`, `ValueConvInv`, `PrintConvInv`) for writing.
- **Dispatch:** `Condition`, a Perl expression over `$self`, `$$valPt` (the first 128 bytes of the value),
  `$format` and `$count`; "If used in a list of alternate tag definitions, the first list entry with a true
  condition is taken" ([`README`][tt-condition]).
- **Writing:** `Writable` (a write format, `0` for read-only), `WriteGroup`, `WriteAlso`, `Protected`
  ("Bit 0x01 indicates an 'Unsafe' tag … Bit 0x02 indicates a 'Protected' tag, which should not be set directly
  by the user", [`README`][tt-protected]), `Permanent`, `Shift` for date arithmetic ([`README`][tt-writable]).
- **Structure:** `SubDirectory { TagTable, Start, Base, ByteOrder, Validate, ProcessProc, … }`, which turns a tag
  into a pointer to another directory ([`README`][tt-subdir]).

`GetTagTable` loads a module on first reference to one of its tables, fills default family 0 and 1 groups from
the module name, registers XMP namespaces and merges user-defined tags from the config file
([`ExifTool.pm`][gettagtable]). `Image::ExifTool::TagLookup` is a generated index ("the lists below were
generated by `Image::ExifTool::BuildTagLookup`") from tag name to the tables that define it, used to find where a
tag may be written ([`TagLookup.pm`][taglookup]). The same build step produces the `TagNames` HTML documentation,
so the tables are their own reference manual.

**Demonstrated:** at this revision `exiftool -list` prints 21,488 tag names and `exiftool -listw` 7,235 writable
ones.

### Composite tags

Each module may declare a composite table (`%Image::ExifTool::Exif::Composite`), registered with `AddCompositeTags` into the shared `%Image::ExifTool::Composite`; it holds derived tags with `Require`, `Desire` and `Inhibit` lists of source tags.
`ImageSize` requires `ImageWidth` and `ImageHeight`, desires `ExifImageWidth`, `ExifImageHeight` and
`RawImageCroppedSize`, and picks among them by `TIFF_TYPE` ([`Exif.pm`][composite-imagesize]). A metadata
explorer needs this layer: what a user means by "the image size" is a rule over several raw tags.

### Walking containers

`ExtractInfo` reads the first `$testLen = 1024` bytes and tries each type in `@fileTypes` against a regular
expression in `%magicNumber` ([`ExifTool.pm`][magic-table]), then calls `Process<Type>` from the module named in
`%moduleName`. If nothing matches, it scans for an embedded JPEG or TIFF signature and warns "Processing
$type-like data after unknown $skip-byte header" ([`ExifTool.pm`][magic-loop]).

Every nested directory goes through `ProcessDirectory`, which keeps the metadata path (`$$self{PATH}`), saves and
restores byte order, and refuses a directory whose absolute address it has already processed
([`ExifTool.pm`][processdir]). Per container:

- **JPEG.** `ProcessJPEG` walks markers. `APP1` with `Exif\0` hands the payload to `ProcessTIFF`, after
  joining "multi-segment EXIF" across consecutive `APP1` segments ([`ExifTool.pm`][jpeg-app1]); `APP2`
  `ICC_PROFILE\0` reassembles numbered chunks, warning on duplicates and zero counts, before handing the whole
  profile to the `ICC_Profile` table ([`ExifTool.pm`][jpeg-app2]). `APP10` to `APP15` cover HDR gain curves,
  JUMBF, Ducky, Photoshop, Adobe and GraphicConverter segments ([`ExifTool.pm`][jpeg-appn]).
- **TIFF IFDs.** `ProcessExif` reads the 12-byte entries; a tag with a `SubDirectory` (`0x8769 ExifOffset`,
  `0x8825 GPSInfo`, `0x8773 ICC_Profile`) recurses into a sub-directory: the same table for `ExifIFD`, the GPS or
  ICC table otherwise ([`Exif.pm`][exif-exifoffset], [`Exif.pm`][exif-gps]).
- **ISOBMFF and QuickTime.** `ProcessMOV` reads 8-byte `size`/`type` headers, handles `size == 1` (64-bit
  extended size, refused above `0x7fffffff` unless `LargeFileSupport` is set) and `size == 0` (to end of file at the top
  level; inside a container, tolerated as the terminator Canon writes in `CNTH`), and maps `ftyp` brands to file types ([`QuickTime.pm`][mov-header],
  [`QuickTime.pm`][mov-size]). Atom tables are keyed by the four-character type.
- **RIFF.** `ProcessRIFF` reads `a4V` chunk headers; a `LIST` chunk's tag ID is synthesised as `LIST_<type>`
  so `LIST_INFO` and `LIST_hdrl` get separate tables, and an all-zero chunk ID aborts with "Encountered empty
  null chunk" ([`RIFF.pm`][riff-loop]).
- **PNG.** `ProcessPNG` walks chunks keyed by chunk type (`iCCP`, `eXIf`, `cICP` as `CICodePoints`, `caBX`
  for C2PA, `iTXt` carrying XMP), and the same procedure writes when `$$dirInfo{OutFile}` is set
  ([`PNG.pm`][png-main], [`PNG.pm`][png-cicp], [`PNG.pm`][png-process]).

### Maker notes

EXIF tag `0x927c` is not a tag but a conditional list: "handle maker notes as a conditional list"
([`Exif.pm`][exif-makernote]). `@Image::ExifTool::MakerNotes::Main` is "NOT a normal tag table"; each entry
picks a vendor table by header bytes or by the `Make` captured earlier by `RawConv`
([`MakerNotes.pm`][mn-main]):

```perl
    {
        Name => 'MakerNoteNikon',
        Condition => '$$valPt=~/^Nikon\x00\x02/',
        SubDirectory => {
            TagTable => 'Image::ExifTool::Nikon::Main',
            Start => '$valuePtr + 18',
            Base => '$start - 8',
            ByteOrder => 'Unknown',
        },
    },
```

`Start` and `Base` encode each vendor's offset convention, and `ByteOrder => 'Unknown'` guesses from the entry
count. Editors that move a maker note without fixing its internal offsets are common, so `FixBase` collects the
value pointers, compares them with where the data sits, and shifts the base (with a Canon special case that
reads the original offset from a TIFF footer) ([`MakerNotes.pm`][mn-fixbase]).

### Groups

Every extracted tag is labelled in nine group families ([`ExifTool.pod`][pod-families]):

```text
    0) Information Type         (eg. EXIF, XMP, IPTC)
    1) Specific Location        (eg. IFD0, ExifIFD, XMP-dc)
    2) Category                 (eg. Author, Time)
    3) Document Number          (eg. Main, Doc1, Doc3-2)
    4) Instance Number          (eg. Copy1, Copy2, Copy3)
    5) Metadata Path            (eg. JPEG-APP1-IFD0-ExifIFD)
    6) EXIF/TIFF Format         (eg. int8u, int32u, undef, string)
    7) Tag ID                   (eg. ID-271, ID-rights, ID-a9aut)
    8) Alternate File Number    (eg. File1, File2, File3)
```

Families 0 and 1 follow file structure, family 2 is a logical category, and families 5 and 6 are produced only
with `SavePath` and `SaveFormat` ([`ExifTool.pod`][pod-family-notes]). **Demonstrated:** `GetAllGroups` lists 115 family 0, 507 family 1 and 14
family 2 names; on the crafted JPEG,

```text
$ exiftool -G0:1:2:5:6:7 -api SavePath -api SaveFormat -s -Make -Orientation cycle.jpg
[EXIF:IFD0:Camera:JPEG-APP1-IFD0:string:ID-271] Make: Tst
[EXIF:IFD0:Image:JPEG-APP1-IFD0:int16u:ID-274] Orientation: Rotate 90 CW
```

and after ExifTool writes the same tags into a PNG (`-EXIF:Make=Tst -Orientation#=6`), the path becomes
`PNG-EXIF-IFD0` (a bare `-Make=` goes to `PNG-TextualData` instead), while XMP lands at
`PNG-InternationalText-XMP`. Names are not unique, so a tag is addressed as `Group:Name` on the command line and
`GetGroup($tag, ':3:1:2')` in the API.

## Analysis

### 3. Colour and metadata

ExifTool is the widest catalogue of [image metadata][c-meta] in the survey: EXIF, GPS, IPTC, XMP, Photoshop
IRB, MPF, JUMBF and C2PA, [ICC profiles][c-icc] parsed tag by tag, PNG `cICP` as [CICP][c-cicp], and maker notes
for dozens of vendors. It interprets, but it never applies: orientation is a value (`Rotate 90 CW`, raw `6` under
`-n`), not a transform. The contrast with libraries that carry metadata as opaque blobs is direct: `image-rs`
keeps four byte vectors and a parsed `Orientation` ([image-rs][image-rs-meta]); ImageSharp parses EXIF lazily into
typed profiles ([ImageSharp][imagesharp-meta]); OpenImageIO flattens metadata into `ImageSpec` attributes
([OpenImageIO][oiio-meta]). ExifTool's three-level value (raw, value, print) and its location labels are what
those models lack when a user asks why two readers disagree. Precedence between duplicates is explicit: a tag
`Priority`, a `PRIORITY_DIR` (XMP wins in QuickTime except HEIC, [`QuickTime.pm`][mov-header]), and `Copy1`,
`Copy2` instances in family 4.

### 4. I/O and codec architecture

Pull-based and random-access: walkers `Seek` and `Read` on a `File::RandomAccess` object or slice an in-memory
buffer. There is no suspension; the unit of work is a whole file. The architecture is **one table-driven
interpreter per [container family][c-container]** (TIFF IFD, ISOBMFF atom, RIFF chunk, PNG chunk, JPEG segment,
binary record) plus per-format tables, which is the split `sparkles:wired` would express as a binary
description ([wired baseline][bl-wired]). Reading and writing share tables, and for PNG the same procedure.
`FastScan` levels trade completeness for speed by stopping early or skipping trailers.

### 5. Hostile input and safety

Robustness comes from bounds checks and warnings, not from a memory-safe decoder (Perl strings are bounded, so
an over-read yields a short string, not a fault). The mechanisms, all **demonstrated** on crafted files:

- **Cycles.** `ProcessDirectory` records each directory address; `ExifOffset` pointing back at `IFD0` yields
  "ExifIFD pointer references previous IFD0 directory", and a next-IFD pointer to itself yields "IFD1 pointer
  references previous IFD0 directory" ([`ExifTool.pm`][processdir]).
- **Warning budget.** `ProcessExif` aborts an IFD after more than ten warnings ("Too many warnings -- $dir
  parsing aborted"); with one valid entry followed by fifteen invalid-type entries the output holds eleven
  `Bad format (99)` warnings and the abort ([`Exif.pm`][exif-warncount], [`Exif.pm`][exif-badfmt]). An invalid
  format in the first entry abandons the IFD at once, after one warning.
- **Size limits.** A value whose `count * size` exceeds `0x7fffffff` is skipped with "Invalid size
  (2415919104) for IFD0 tag 0x010e ImageDescription" ([`Exif.pm`][exif-size]); arrays of more than 500
  numeric values are summarised as "(large array of $count $formatStr values)" unless `IgnoreMinorErrors`
  is set ([`Exif.pm`][exif-largearray]).
- **Writes refuse corruption.** Writing `Orientation` into the cyclic JPEG fails with "Error: Corrupted JPEG
  image" and "0 image files updated".

`Warn` deduplicates messages and grades them minor or not; `IgnoreMinorErrors` lets a user push past minor ones
([`ExifTool.pm`][warn]). Warnings are themselves tags (`ExifTool:Warning`), so a malformed file still produces
a report. See [hostile input][c-hostile] and the [hostile-input papers][p-hostile]; what ExifTool does not have is
a fuzzing harness in the tree.

### 9. Temporal, animation and containers

The QuickTime module reads timed metadata streams (GPS tracks, camera telemetry) under `ExtractEmbedded`, each
sample a family 3 document (`Doc1`, `Doc2-3`; [`ExifTool.pod`][pod-family-notes]), and loads
`QuickTimeStream.pl` only when `ExtractEmbedded` or an image-data hash is requested
([`QuickTime.pm`][mov-header]). The document-number family is the general answer to "metadata about the third
frame of the second embedded image": a path of indices, not a flat list.

### 10. Testing and conformance

`t/` holds 114 `.t` scripts, 194 sample files in `t/images`, and expected-output `.out` files compared by
`t/TestLib.pm` `check` with tolerance for floats and times ([`TestLib.pm`][testlib-check]). Each line records
families 0, 1 and 2, the tag ID and both description and value, for example
`[PNG, PNG, Image] 9 - Color Type: Grayscale` ([`PNG_2.out`][png-out]); write tests round-trip through memory
and re-read ([`PNG.t`][png-t]). These outputs are a ready conformance corpus for a reader that wants to match
ExifTool's names.

Not covered: 1, 2, 6, 7, 8 (ExifTool never decodes pixels, so it has no pixel model, generic pixel code,
SIMD or GPU path, and its allocation is Perl's own strings and hashes).

## Lessons for Sparkles

- **Q5** The minimum metadata model has more than blobs: a tag needs a location (family 1), a container path
  (family 5), an on-disk format (family 6), an ID (family 7) and an instance, and a value in raw and display
  forms. ExifTool shows the full set; the design chooses how much to keep.
- **Q5** Tag tables as static data map onto D well: a table of records with ID, name, format, write rules and a
  lookup for display names fits compile-time data and the `sparkles:metadata` UDA vocabulary, and the
  `PrintConv` hashes are enum name tables. What does not transfer is the Perl `eval` in `Condition`,
  `RawConv` and `SubDirectory` `Start`/`Base`; a D port needs those as functions or a small expression language.
- **Q5** Write rules are part of the vocabulary (`Writable`, `Protected`, `Permanent`, `WriteGroup`); a read-only
  model would need a second pass to add them.
- **Q4** Container walking is a few interpreters (IFD, atom, chunk, segment, binary record) driven by
  declarations; this is the evidence for what a `sparkles:wired` binary description must express: offsets
  relative to a movable base, byte order discovered at run time, pointers to sub-directories, conditional
  dispatch on leading bytes.
- **Q4** Maker notes need relocatable bases (`Start`, `Base`, `FixBase`); any IFD reader that hard-codes
  "offsets are from the TIFF header" will misread them.
- **Q8** ExifTool is the oracle for a metadata explorer modelled on [the font-explorer spec][font-explorer]:
  `exiftool -j -G0:1:7 -n` gives keys such as `EXIF:IFD0:ID-271:Make` that a differential test can compare
  field by field, `-v3` and `-htmlDump` give byte offsets for an explorer's hex view, and the `t/*.out` files are
  expected outputs. It is GPL or Artistic licensed Perl, so it fits as a test-time oracle through Nix, not as
  shipped code; its tables are facts, but copying them wholesale would carry the licence.
- **Q8** The warning model (deduplicated, graded, reported as tags, capped per directory) suits an explorer
  that must show a damaged file rather than reject it.
- **Q9** ExifTool keeps metadata wholly apart from pixel decoding; that supports a separate metadata package
  that codecs feed with located byte ranges.

## Strengths

- The widest coverage of formats, vendors and maker notes in any open tool, maintained continuously.
- Tables double as documentation; the `TagNames` pages are generated from them.
- Raw, converted and printed values are all reachable (`-n`, `-b`, `#` suffix on write).
- Precise provenance per tag through nine group families, including full metadata path and on-disk format.
- Tolerant reader with explicit, deduplicated warnings, cycle detection and size limits.
- Conservative writer: preserves originals by default, refuses corrupt input, rebases maker notes.

## Weaknesses

- Behaviour lives partly in Perl code strings (`Condition`, `RawConv`, `Start`), so the tables are not
  portable data without an interpreter.
- No in-tree fuzzing; robustness rests on bounds checks and a large sample corpus.
- Whole-file, synchronous processing; no streaming or suspension.
- Tag names are not unique, so consumers must carry group qualifiers to be unambiguous.
- Single-process Perl startup and module loading make it a poor library dependency for a native viewer.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                 | Trade-off                                                     |
| ------------------------------------------------ | --------------------------------------------------------- | ------------------------------------------------------------- |
| Format knowledge as tag tables, not parsers      | a new camera or tag is a table edit; tables generate docs | behaviour leaks into Perl strings (`Condition`, `RawConv`)    |
| Conditional lists for maker notes                | one EXIF tag dispatches to dozens of vendor layouts       | entry order matters; vendor offset quirks need `FixBase`      |
| Raw, value and print forms for every tag         | users and scripts each get the form they need             | three conversions, and their inverses, to maintain per tag    |
| Nine group families label every tag              | duplicate names stay addressable with exact provenance    | consumers must carry group qualifiers to be unambiguous       |
| Warn and continue, with a per-IFD warning budget | a damaged file still yields a report                      | robustness rests on hand-written checks, not a fuzzed decoder |
| Preserve originals and refuse corrupt input      | a metadata write cannot silently destroy a file           | a malformed file cannot be repaired by writing to it          |

## Sources

- The pinned clone of [exiftool/exiftool][repo] at `2200871d9cef988051d2a99d67df3bda6cbb30a8`: the tag-table
  reference [`lib/Image/ExifTool/README`][tt-readme], `ExifTool.pm`, `Exif.pm`, `MakerNotes.pm`,
  `QuickTime.pm`, `RIFF.pm`, `PNG.pm`, `TagLookup.pm`, `ExifTool.pod`, the `exiftool` script and `t/`.
- Scratch demonstrations in `/tmp/exiftool-demo` (crafted JPEG and PNG files), as described in the note above.
- Related deep-dives: [image-rs][image-rs-meta], [ImageSharp][imagesharp-meta], [OpenImageIO][oiio-meta],
  [libvips][libvips-meta], [SAIL][sail], [Wuffs][wuffs], [libavif][libavif]; the [concepts page][concepts];
  the [existing-code baseline][bl-existing].

<!-- References -->

[repo]: https://github.com/exiftool/exiftool/tree/2200871d9cef988051d2a99d67df3bda6cbb30a8
[readme-intro]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/README#L4-L7
[readme-license]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/README#L172-L176
[cli]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/exiftool
[cli-desc]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/exiftool#L5107-L5119
[tt-readme]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README
[tt-intro]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L12-L18
[tt-special]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L20-L27
[tt-name]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L281-L300
[tt-protected]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L517-L521
[tt-conv]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L587-L640
[tt-printconv]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L673-L685
[tt-condition]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L752-L773
[tt-writable]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L812-L838
[tt-subdir]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/README#L1047-L1110
[pod-getgroup]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pod#L2285-L2390
[pod-families]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pod#L2322-L2332
[pod-family-notes]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pod#L2334-L2375
[magic-table]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L923-L945
[magic-loop]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L3010-L3075
[warn]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L5616-L5642
[jpeg-app1]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L7747-L7795
[jpeg-app2]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L7929-L7972
[jpeg-appn]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L8280-L8428
[gettagtable]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L8950-L9039
[processdir]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool.pm#L9046-L9095
[exif-main]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L411-L416
[exif-make]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L578-L589
[exif-orient]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L686-L692
[exif-exifoffset]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L2006-L2020
[exif-gps]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L2130-L2141
[exif-makernote]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L2495-L2496
[exif-warncount]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L6452-L6457
[exif-badfmt]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L6461-L6475
[exif-size]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L6502-L6509
[exif-largearray]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L6774-L6779
[composite-imagesize]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L4747-L4765
[mn-main]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/MakerNotes.pm#L26-L58
[mn-fixbase]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/MakerNotes.pm#L1277-L1484
[mov-header]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/QuickTime.pm#L9965-L10024
[mov-size]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/QuickTime.pm#L10032-L10077
[riff-loop]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/RIFF.pm#L2096-L2129
[png-main]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/PNG.pm#L100-L104
[png-cicp]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/PNG.pm#L343-L353
[png-process]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/PNG.pm#L1410-L1440
[taglookup]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/TagLookup.pm#L1-L29
[testlib-check]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/t/TestLib.pm#L324-L383
[png-out]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/t/PNG_2.out#L1-L20
[png-t]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/t/PNG.t#L19-L50
[c-meta]: ./concepts.md#image-metadata
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[concepts]: ./concepts.md
[p-hostile]: ./papers/hostile-input-safety.md
[image-rs-meta]: ./image-rs.md#_3-colour-and-metadata
[imagesharp-meta]: ./imagesharp.md#_3-colour-and-metadata
[oiio-meta]: ./openimageio.md#_3-colour-and-metadata
[libvips-meta]: ./libvips.md#_3-colour-and-metadata
[sail]: ./sail.md
[wuffs]: ./wuffs.md
[libavif]: ./libavif.md
[bl-wired]: ./baseline/wired.md
[bl-existing]: ./baseline/existing-code.md
[font-explorer]: ../../specs/font-explorer/SPEC.md
