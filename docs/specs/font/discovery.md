---
status: draft
owner: sparkles:font
reviewed: 2026-10-28
---

# `sparkles:font` — Discovery, matching and fallback operations (M7)

## Abstract

This page states, operation by operation, what milestone M7 of
[`sparkles:font`](./SPEC.md) delivers: a catalog of face records built from
font sources, cached on disk, a CSS font-matching algorithm over it, fallback
chains that include user routes and a generated box-drawing face, whole-span
fallback trials through the shaper, and the registry of font corrections the
engines apply. For each operation it fixes the inputs, the result, every
outcome and its trigger, and the work and allocation bounds. The catalog
describes faces with the library's own parser only; platforms list files and
nothing more.

## Introduction

[`SPEC.md`](./SPEC.md) § 13 states what discovery, matching and fallback must
achieve, in requirements `FTD1`–`FTD12`. That level fixes scope but not
results: it does not say which name a record's family is, what a width of
`usWidthClass` 0 means, which face wins a tie in matching, when a candidate may
be skipped without shaping, or what a trial reports when every face fails. Each
such choice changes a result, so each is made here, as
[`parsing.md`](./parsing.md) did for M1 and
[`variation-metrics.md`](./variation-metrics.md) for M2.

Discovery is the first part of the library that allocates and performs I/O.
The catalog owns its records' strings and coverage, it reads files, and a
platform source loads a system library at run time. Everything before M7 reads
borrowed bytes and allocates nothing; that stays true of every face operation,
and the catalog keeps the allocation outside them, through base's buffers and
never the garbage collector.

File access goes through base's [capability VFS](../base/vfs/SPEC.md): the
catalog is generic over a backend, so tests build catalogs over the in-memory
backend with exact modification times, and programs use the blocking backend
with its memory-mapped reads ([`VFO11`](../base/vfs/SPEC.md#vfo11-mapping)).

Three owner decisions shape the page (2026-10-28): the platform lists are
reached by loading fontconfig and Core Text at run time, so the library's link
line stays free of C libraries ([`FTA7`](./SPEC.md#_5-objects-and-ownership));
the on-disk catalog uses a small versioned format of this library's own, to be
replaced by wired's Flat format by a version change once that exists; and the
box-drawing face is a real TrueType font generated in memory, so every face
operation, the shaper included, treats it as any other face.

This page covers the M7 obligations in
[`PLAN.md`](./PLAN.md#m7-discovery-and-fallback). Operation names are proposed,
not delivered symbols. In cost bounds, `F` is the number of files a build
lists, `R` the number of records, `E` the entries of a chain, `C` the
candidates a trial tries, and `n` the scalars of a run.

## Contract at a glance

1. **Platforms list files; the parser describes them.** A record holds only
   what this library read from the face's bytes, plus where the bytes came
   from.
2. **A build never fails as a whole.** A missing platform service, an
   unreadable file or a malformed face is an outcome in the build report, and
   the catalog is built from the rest.
3. **Records are deterministic.** The same sources and files give the same
   records in the same order, whatever the number of worker threads and
   whether the cache was used.
4. **Matching follows CSS, step by step.** Width, then style, then weight,
   with each step's search order written out here; the result says how far
   the match is from the request and what must be synthesized.
5. **Coverage prunes; shaping decides.** A chain answers a character lookup
   from coverage, but a span is resolved only by shaping it whole with a
   candidate; a candidate is skipped without shaping only where this page
   proves the shaper would give it `.notdef`.

## 1. Common rules

**FTD13: Where discovery lives.** Sources, records, the catalog, its cache,
matching, chains, routes, the box-drawing face and the correction registry
**must** be in the `library` configuration. Whole-span trials need the shaper
and **must** be in the `engine` configuration only. No operation on this page
**may** use the garbage collector; owned storage comes from base's buffers.
Operations that perform I/O are `@safe nothrow @nogc` and not `pure`; every
other operation keeps the library's `@safe pure nothrow @nogc`.

**FTD14: Values and threads.** A built catalog **must not** change, and
**may** be read from any number of threads at once; a chain is a value over
it with the same property. A face store ([`FTD32`](#_5-fallback-chains)) and
a character cache are owned by one thread at a time: a program that resolves
on several threads gives each its own. A memory source's bytes are borrowed;
the caller keeps them alive while any catalog or store built from them lives.

**FTD15: Outcomes.** A build, a chain and a trial **must** report each
problem as an outcome attached to the source, file, face or entry it
concerns, of one of these kinds: `io` (base's `IoError`), `font` (a
`FontError`), `libraryUnavailable` and `symbolMissing` (a platform library or
one of its functions, with its name), `serviceFailed` (a platform call that
returned failure), `directoryUnavailable` (a platform font directory that
does not exist), `cacheDiscarded` (with the reason of `FTD23`), `stale` (a
file changed since its record was made), `boxFace` (the box-drawing face could
not be built, with the `FontError`), and `linkLimit` (more than 40 links on
one path). Only a caller's misuse, an invalid request value or a malformed
shaping request, fails an operation itself, and it fails before any output.

## 2. Sources and records

**FTD16: Source kinds.** A build takes an ordered list of sources, each with
a caller-chosen label, unique in the list (a repeated label is `badValue`),
that names it in reports and in the cache:

| Source                       | Lists                                                                                       | Read by |
| ---------------------------- | ------------------------------------------------------------------------------------------- | ------- |
| `files(dir, names)`          | the named files under a directory handle                                                    | `read`  |
| `directory(dir, recurse)`    | the font files under a directory handle, its subdirectories too when `recurse`              | `read`  |
| `bundle(dir)`                | as `directory(dir, true)`, recorded as the bundled fonts                                    | `map`   |
| `memory(name, bytes, hash?)` | one caller-owned buffer; Android assets arrive this way; `hash` is its BLAKE3 hash if known | —       |
| `platform(options)`          | the files the platform lists ([`FTD18`](#_2-sources-and-records))                           | `map`   |

A source's read mode **may** be overridden by the caller. `map` is used only
for files their owner replaces rather than rewrites in place, as installed
and bundled fonts are, because a mapped file truncated by another process
faults on the next read of a lost page ([`VFO11`](../base/vfs/SPEC.md#vfo11-mapping));
`read` copies the file into owned memory and has no such hazard.

A directory or platform source lists entries whose names end in `.ttf`,
`.otf`, `.ttc` or `.otc`, compared without regard to ASCII case, and counts
the others as skipped. An entry that is a symbolic link is followed: its
target is read with `readlinkAt` and opened from a root at the target's
directory, opened with the ambient authority the source was given (without
it, a link is skipped and counted), at most 40 links per path (`linkLimit`).
A recursive walk stops at base's depth limit, reported. Every face of a
collection becomes a record.

**FTD17: Identity and order.** A file's identity is its source's label and its
path from the source's directory, joined with `/`, or for a memory source its
label and BLAKE3 hash. When two sources give the same resolved path (the
followed target, for a link), only the first lists it. Records **must** be
ordered by source, then by identity in byte order, then by collection index.
This is the catalog order every later tie is broken by, and the order of the
build report's outcomes.

**FTD18: Platform lists.** `platform(options)` **must** list:

- on Linux, FreeBSD and other POSIX systems that are neither Apple's nor
  Android: the distinct `FC_FILE` values of `FcFontList` over an empty pattern
  in the current fontconfig configuration, through `libfontconfig.so.1`, or
  the path `options` names, loaded at run time;
- on macOS: the file URLs of `CTFontManagerCopyAvailableFontURLs`, through the
  Core Text and Core Foundation frameworks loaded at run time;
- on Windows: the system font directory (`GetWindowsDirectoryW`, then
  `Fonts`) and the per-user directory (`%LOCALAPPDATA%\Microsoft\Windows\Fonts`),
  each as a non-recursive directory;
- on Android: `/system/fonts` as a non-recursive directory.

The platform source applies `FTD16`'s extension filter to the paths listed. A
platform directory that does not exist gives a `directoryUnavailable`
outcome. A library, framework,
function or directory that cannot be loaded or opened **must** give its
outcome, and the build continues with the remaining sources (`FTD2`). A
platform listing contributes paths only; a face's index, family and every
other field are read by the parser (`FTD1`).

**FTD19: The face record.** A record **must** hold:

| Field                        | Read from                                                                                                                                                               |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| source, identity, index      | the build ([`FTD17`](#_2-sources-and-records))                                                                                                                          |
| file size, modification time | the file's `Stat`; a memory source has its length and no time                                                                                                           |
| family                       | name ID 16, else 1, by the name choice below                                                                                                                            |
| style name                   | name ID 17, else 2                                                                                                                                                      |
| full name, PostScript name   | name IDs 4 and 6                                                                                                                                                        |
| family aliases               | every distinct value (byte for byte) of name IDs 1, 16 and 21 in any language, the family first, then in name-table order, at most 32                                   |
| weight range                 | the `wght` axis's minimum and maximum, clamped to 1–1,000; else `usWeightClass` as one value, where 1–9 is multiplied by 100, and 0 or a value above 1,000 reads as 400 |
| width range                  | the `wdth` axis, as percentages clamped to 50–200; else `usWidthClass` 1–9 as 50, 62.5, 75, 87.5, 100, 112.5, 125, 150 and 200 %, any other value read as 100 %         |
| style                        | below                                                                                                                                                                   |
| spacing                      | the M1 spacing report                                                                                                                                                   |
| coverage                     | the character map's ranges (`FTP27`), under the corrections the face triggers ([`FTD11`](./SPEC.md#_13-discovery-matching-and-fallback))                                |
| colour formats               | the M2 colour capability report                                                                                                                                         |
| axes                         | each `fvar` axis's tag, minimum, default and maximum                                                                                                                    |
| corrections                  | the registry entries the face triggers, which include whether it requires bytecode ([`FTD12`](./SPEC.md#_13-discovery-matching-and-fallback))                           |
| outline format, upem, glyphs | the face                                                                                                                                                                |
| glyph 0 substitutable        | whether `morx` exists or a `GSUB` subtable can see glyph 0 ([`FTD40`](#_7-whole-span-trials))                                                                           |
| field errors                 | [`FTD20`](#_2-sources-and-records)                                                                                                                                      |

A name is chosen from the records with that ID, in order: Windows platform
and US English (`0x0409`); any Windows record whose language's primary
language is English (`languageID & 0x3FF == 9`); Macintosh platform, Roman,
English; the first record that decodes. A name longer than 1,024 bytes of
UTF-8 is cut at the last scalar boundary at or before byte 1,024, and the
record says so. A missing name is empty.

The style is a set of points (italic, oblique angle in degrees), the angle
positive clockwise as CSS counts it:

- with an `ital` axis, its range gives the italic values; with a `slnt` axis,
  its negated range gives the oblique angles; a face with either axis takes
  every point the two ranges allow (an absent axis contributing the value 0);
- otherwise `OS/2` `fsSelection` bit 9 (oblique, version 4 and later) makes
  the face the single point (0, −`post.italicAngle`), or (0, 14°) when that
  angle is 0; else bit 0 (italic), or without `OS/2` `head.macStyle` bit 1,
  makes it (1, 0); else it is (0, 0), upright.

**FTD20: Faces that do not open.** A file that cannot be read, or whose
container header fails, **must** give one file outcome and no record. A
collection member that fails `openFace` **must** give a face outcome with its
index and error, and the other members keep their records. A face that opens
but fails a single field (an unreadable `name`, `OS/2`, `fvar` or character
map) **must** keep its record with that field defaulted (no names, 400, 100 %,
upright, no coverage) and the error listed in the record.

**FTD21: Building.** `buildCatalog(vfs, sources, options)` lists every
source, then describes the files over `options.workers` threads (0 for one
per processor, at most 64), each file independently, and returns the catalog
and its report. The result **must not** depend on the worker count. The
report counts files listed, skipped, described, reused from the cache and
failed, and lists every outcome in catalog order. Cost: O(F) stats; for each
described file its open cost and the cost of reading its `name` records, its
`OS/2`, its `fvar` and its character map's ranges; O(R · k) storage for `k`
coverage ranges per record. A memory source without a hash is hashed, O(size).

## 3. The persistent catalog

**FTD22: Cache key.** The cache **must** key a file by its identity, its size
and its modification time in nanoseconds; a memory source by its identity,
which holds its content hash. A file whose key matches **must** have its
records, or its `font` outcome, reused without reading the file; any other
listed file is described again; a cached file no longer listed is dropped.
`io` outcomes are never cached, so a transient failure is retried at the next
build. A cache built under another correction policy is discarded whole.

**FTD23: Cache format.** The cache **must** be one file: the eight bytes
`SPKFCAT\0`, a little-endian 32-bit format version, the correction policy as
one byte, the payload's length as a little-endian 64-bit integer, the
payload, and the payload's 32-byte BLAKE3 hash. A cache whose magic, version,
policy, length or hash does not match, or whose payload does not decode
completely, **must** be discarded whole with the reason (`magic`, `version`,
`policy`, `length`, `hash`, `structure`), never migrated or partly read. The
payload holds, per file, its key and either its outcome or its records, every
field of `FTD19`; integers are little-endian, strings UTF-8 with 32-bit
lengths. Changing a record's fields or their meaning **must** change the
version. The format is this library's own, replaced by wired's Flat format by
a version change.

**FTD24: Reading and writing the cache.** A build given a cache file reads
it before listing and, when any entry was added, changed or dropped, writes
it with the VFS's atomic write (`VFO9`), so a reader sees the old cache or
the new one. A cache that cannot be read or written **must** be reported, and
the build succeeds without it. Reading costs O(size) and allocates the
records it keeps.

## 4. Matching

**FTD25: The request.** A request **must** carry an ordered list of family
names, a weight (1–1,000), a width percentage (50–200), a style (`normal`,
`italic`, or `oblique` at an angle from −90° to 90°), and
whether weight and style may be synthesized, the style one with CSS's
`oblique-only` choice too. A value outside its range is `badValue`. Generic
families (`monospace`, `emoji`, …) are not catalog names: the caller resolves
them to family names. Values are compared exactly, as F16.16 fixed point.

**FTD26: Family.** The first name in the list that equals, ignoring ASCII
case, an alias of some record selects every record having that name among
its aliases; later names are not consulted. No such name **must** give
`noMatch`.

**FTD27: Narrowing.** The family's records are narrowed as CSS Fonts Level 4
§5.2 step 4 does (Working Draft of 22 October 2026). Each step searches the
values the remaining records support, phase by phase, and within a phase in
the stated direction; the first value supported is the one found, and records
not supporting it are removed. A range supports every value in it.

1. **Width.** For a desired width at most 100 %: phase 1, widths at most the
   desired one, descending; phase 2, wider ones, ascending. Above 100 %:
   phase 1, widths at least the desired one, ascending; phase 2, narrower
   ones, descending.
2. **Style.** Italic phases consider only points with italic 1; oblique
   phases only points with italic 0. With `a` the requested angle:

   | Request                    | Phases, in order                                                                             |
   | -------------------------- | -------------------------------------------------------------------------------------------- |
   | `italic`                   | italic; oblique ≥ 14°, ascending; oblique in (0°, 14°), descending; oblique ≤ 0°, descending |
   | `oblique a`, `a ≥ 11°`     | oblique ≥ `a`, ascending; oblique in (0°, `a`), descending; italic; oblique ≤ 0°, descending |
   | `oblique a`, `0 < a < 11°` | oblique in (0°, `a`], descending; oblique > `a`, ascending; italic; oblique ≤ 0°, descending |
   | `normal`, `oblique 0°`     | oblique ≥ 0°, ascending; italic; oblique < 0°, descending                                    |
   | `oblique a`, `a < 0°`      | the rows above for `−a`, with every angle negated and every direction reversed               |

   A record's `ital` axis is set to 1 when an italic phase found the value,
   else 0; an oblique request never sets it to 1 except through the italic
   phase.

3. **Weight.** For a desired weight from 400 to 500: phase 1, weights at
   least it up to 500, ascending; phase 2, weights below it, descending;
   phase 3, weights above 500, ascending. Below 400: phase 1, weights at most
   it, descending; phase 2, above it, ascending. Above 500: phase 1, weights
   at least it, ascending; phase 2, below it, descending.

When several records remain, the first in catalog order wins. `testing.md`
traces each phase of each step over a synthetic family, and a variable family
must give the answers of its expanded static faces.

**FTD28: The match.** A match **must** carry the record, the width, style
point and weight found, the user coordinates that realize them on a variable
record (`wdth`, `wght`, `slnt` as the negated angle, `ital`), the synthesis,
and a score: the family's position in the request list, then for each of
width, style and weight the pair (phase index, distance from the desired
value), compared lexicographically, lower being closer. The style's desired
value is the requested angle, or 14° for `italic`; an italic point's distance
is 0. Distances are exact F16.16.

**FTD29: Synthesis.** Emboldening **must** be requested, at 1/24 em
(`Synthesis.emboldenStrength` 2,731), exactly when weight synthesis is
allowed, the desired weight is at least 600 and the record's maximum weight
is below 600. A slant **must** be requested exactly when style synthesis is
allowed, the request is `italic` (as 14°, unless the choice is
`oblique-only`) or `oblique a` with `a ≠ 0`, and the point found is upright;
its `Synthesis.obliqueSlant` is the tangent of the angle rounded to a whole
degree and clamped to ±89°, in F16.16, from a table of correctly rounded
tangents. A variable axis is not synthesis.

**FTD30: Cost.** Matching **must** cost O(L + m) for `L` request names and
`m` records in the selected family, through a family index the build makes;
it allocates nothing.

## 5. Fallback chains

**FTD31: The chain specification.** A chain is built from a catalog, a
primary request and an ordered list of items:

| Item               | Contributes                                                                                                                         |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `primary`          | the primary request's match                                                                                                         |
| `family(request)`  | that request's match                                                                                                                |
| `route(ranges, r)` | the match of request `r`, answering only for the scalars in `ranges`                                                                |
| `boxDrawing`       | the generated face of [§6](#_6-the-box-drawing-face), over the primary match                                                        |
| `everything`       | for every other family, ordered by ASCII-case-folded family name and then catalog order, its match for the primary request's values |

The list **must** be the routes, then `primary`, then any other items;
anything else is `badValue`. An item whose request matches nothing
contributes nothing, recorded; without a
primary match, `boxDrawing` contributes nothing either. The default list is:
the routes the caller gives, `primary`, `boxDrawing`, the caller's fallback
families, `everything`. Routes come first because a user who routes a range
means it to win over the primary, as kitty, Ghostty and iTerm2 route
([`FTX16`](./decisions.md#ftx16-codepoint-routes-override-the-primary));
`SPEC.md`'s `FTD5` is amended to say a chain begins with its routes and then
the match, which remains the source of cell metrics. An entry **must** appear once per
(record, coordinates, synthesis), at its first position, except that a route
entry may repeat one found elsewhere, because its scalars differ. Faces with
coverage identical to an earlier entry's, or a subset of it, stay (`FTD5`).

**FTD32: Entries and the face store.** Each entry **must** carry its record
(or the box-drawing face), its match, the item that contributed it, and the
request family that selected it, as selection provenance. A face store, a
value beside the chain (`FTA5`), opens an entry's face the first time it is
needed: it stats the file, and a size or time unlike the record's, or a
memory source's content unlike its hash, gives a
`stale` outcome; otherwise it maps or reads the file by its source's mode,
opens the face, and keeps both until the store is destroyed. An entry whose
face cannot be opened answers nothing for the rest of that store's life, and
its outcome says why. The box-drawing face is built once per ppem; every
build is kept until the store is destroyed or the caller, holding no result
that borrows them, releases them, so a result that borrows one stays valid.
A store holds O(ppems drawn) box faces of O(w · h) bytes each.

**FTD33: Character lookup.** `characterEntry(cp, presentation)` **must**
return the first entry whose coverage holds `cp` (a route: also its ranges),
without opening any face. With emoji presentation, the first such entry with
a colour format wins, else the first such entry; with text presentation, the
first without a colour format, else the first. A face with a colour format
counts as colour for every scalar, even where only some glyphs are coloured.
No entry holding `cp` is `noEntry`. A character cache, a separate value,
memoizes answers under the key (chain identity, `cp`, presentation). Cost:
O(E log k) uncached.

`routeEntry(cp)` **must** return the first route whose ranges hold `cp` and
whose face covers it, or `noEntry`: a route overrides the primary for its
scalars, and one whose face lacks a scalar lets it fall through to the rest of
the chain. Because a trial shapes a span whole with one face (`FTD41`), a
route inside a mixed span would never be chosen; layout, which owns span
boundaries (`FTD7`), **must** split spans so that the clusters a route claims
by their base scalar are tried apart from the rest. Cost: O(routes · log k).

**FTD34: Chain identity.** A chain **must** have a 128-bit identity: the
BLAKE3 hash, truncated, of the catalog's correction policy and every record
key, the primary request, the item list and every entry's record identity
and coordinates. Caches key on it, so no cache answers for another chain.

## 6. The box-drawing face

**FTD35: What it covers.** The box-drawing face **must** cover U+0020, an
empty glyph one cell wide, U+2500–U+257F (box drawing) and U+2580–U+259F
(block elements), one glyph each, and nothing else; glyph 0 is an empty
`.notdef`.

**FTD36: Its bytes.** It **must** be a TrueType font with the tables `head`,
`hhea`, `maxp` (version 1.0), `OS/2` (version 4), `hmtx`, `cmap` (format 4,
platform 3 encoding 1), `loca` (long), `glyf`, `name` and `post` (version 3),
generated into caller storage sized by a measuring call, as `FTR1`'s regions
are, from the primary entry's cell metrics (`FTM19`)
at the integer ppem nearest the instance's, ties up, and opened with
`openFace` like any other face. Its units per em are `ppem · k`, `k` the
largest power of two at most 64 with `ppem · k ≤ 16,384`, so one pixel is `k`
units; a ppem above 16,384, or a coordinate that does not fit `glyf`'s 16
bits, is `limitExceeded`; a ppem of 0, a cell under one pixel, a baseline
outside the cell or an underline thicker than the cell is `badValue`. Any of
these, or a cell metric error, is the `boxFace` outcome. Its ascender is the
cell's baseline offset from the top, its descender the rest of the cell's
height, its line gap 0; every advance is the cell width. Building it costs
O(w · h) for a cell of `w` by `h` pixels.

**FTD37: Its geometry.** In pixels, with the cell `w` wide and `h` high and
`y` measured down from the cell's top:

- **Strokes.** Light is `t = max(1, round(underlineThickness))` (1 without an
  underline), heavy `2t`; a stroke of width `s` sits at `[⌊(w − s) / 2⌋,
⌊(w − s) / 2⌋ + s)` across a vertical line and `[⌊(h − s) / 2⌋, … + s)`
  across a horizontal one. A double line is two light strokes `t` apart,
  centred the same way on their total width `3t`.
- **Lines.** Each of U+2500–U+254B, U+2550–U+256C and U+2574–U+257F names a
  weight (none, light, heavy, double) for up, right, down and left. A light
  or heavy half runs from the cell's edge to the far side of the strokes it
  meets, or of a centred stroke of its own weight when it meets none, so
  joins are square and halves of different weights meet without gaps; a
  light half crosses a double at a crossing or corner and stops at the far
  side of its near stroke at a tee. A double half's outer stroke runs to the
  far side of a perpendicular double, its inner stroke to the far side of
  that double's near stroke; where doubles cross or form a tee, each stroke
  stops at the first stroke it meets, leaving the corners open, as ghostty
  and kitty draw them.
- **Dashes.** U+2504–U+250B and U+254C–U+254F split their line into `n` (2,
  3 or 4) slots `[⌊i · L / n⌋, ⌊(i + 1) · L / n⌋)` of the line's length `L`,
  each drawn short of its end by a gap of `t`.
- **Arcs.** U+256D–U+2570 join the two light stroke rectangles they connect
  through a quarter turn of centre-line radius `r = min(⌊w / 2⌋, ⌊h / 2⌋)`,
  clamped to the distance from the stroke's centre to the edges it runs to,
  its inner and outer edges each one quadratic segment with its control
  point at the corner of the arc's square, extended straight to the edges
  when `w ≠ h`.
- **Diagonals.** U+2571–U+2573 run corner to corner as bands whose
  horizontal width is `t`, clipped to the cell, so diagonals of neighbouring
  cells join.
- **Blocks.** U+2580–U+2590 and U+2594–U+259F are the named rectangles with
  edges at `⌊i · w / 8⌋` and `⌊i · h / 8⌋`.
- **Shades.** U+2591–U+2593 fill one, two or three of every four squares of
  a two-by-two pattern of `u`-pixel squares, `u = ⌈max(w, h) / 64⌉`, clipped
  to the cell, so a shade has at most 3,072 contours: light the squares at
  even row and column, medium a checkerboard, dark all but odd row and
  column.

A glyph whose contours overlap **must** set `OVERLAP_SIMPLE` on its first
point, so rasterizing it takes the union (`FTX9`); contours that only share
edges do not overlap, as their coverage adds exactly.

**FTD38: Its record.** The face's record **must** be generated alongside it,
with the family `Sparkles Box Drawing`, the primary match's weight and style,
and the coverage of `FTD35`. It is never cached on disk.

## 7. Whole-span trials

**FTD39: The trial request.** `trySpan(chain, store, request, size, policy,
attempts, workspace)` takes a shaping request under `FTS7` (the source, the
run, the segment properties, features and text-boundary flags), the instance
size, a policy, and caller storage for attempts. The policy says whether RGI
emoji sequences must ligate (default yes), whether the caller's rasterizer
interprets hinting bytecode (default no), and the most candidates to shape
(default 32). A request `FTS7` refuses **must** fail the trial with that
error before any face opens.

**FTD40: Candidates and pruning.** Candidates are the chain's entries in
order. A route entry whose ranges do not hold every scalar of the run that is
not default-ignorable is recorded `outsideRoute` and skipped. A candidate
**may** be pruned without shaping only when the run is horizontal and has a
scalar `s` such that:

- the face does not cover `s` (under its corrections);
- `s` is not in HarfBuzz 14.6.0's default-ignorable list
  (`hb_unicode_funcs_t::is_default_ignorable`), not a space separator, and
  not U+2011;
- `s` has canonical combining class 0, no canonical decomposition, and is
  the second scalar of no canonical composition;
- the scalar after `s`, if any, has canonical combining class 0, does not
  have Unicode's `Variation_Selector` property, and forms no canonical
  composition with `s`;
- `s` has no Bidi mirror the face covers;
- `s`'s script is Common, Latin, Greek, Cyrillic, Armenian, Georgian, Han,
  Hiragana, Katakana or Bopomofo, scripts no shaper of HarfBuzz decomposes,
  composes or remaps (its Arabic, Hebrew, Thai, Lao, Hangul, Indic, Khmer,
  Myanmar and universal shapers touch only their own scripts' scalars);
- the face's record says no substitution can see glyph 0: it has no `morx`,
  and no `GSUB` subtable, extensions unwrapped, has a Coverage that covers
  glyph 0, lists glyph 0 among ligature components or in a glyph sequence of
  a contextual rule, or has class 0 at a position after the first of a
  class-based contextual rule. The record's build scans `GSUB` once for this,
  O(its size).

These are conditions under which HarfBuzz's normalizer, mirroring and
shapers map `s` to glyph 0 and no lookup rewrites it; every other case is
shaped. A face that
requires bytecode, under a policy whose rasterizer does not interpret it, is
recorded `bytecodeRequired` and skipped (`FTD12`).

**FTD41: Success.** A candidate succeeds when shaping the run whole, with
the request's context, at the entry's instance, gives no glyph 0, and, when
RGI emoji sequences must ligate, every grapheme of the run that base's emoji
data lists as `RGI_Emoji_ZWJ_Sequence`, `RGI_Emoji_Modifier_Sequence`,
`RGI_Emoji_Flag_Sequence`, `RGI_Emoji_Tag_Sequence` or
`Emoji_Keycap_Sequence` (UTS #51 at base's Unicode release) has exactly
one glyph with a nonzero advance among the glyphs whose clusters lie inside
it. The first candidate that succeeds is the result.

**FTD42: The outcome.** A trial **must** return either a resolution, with
the entry, its instance, the shaped glyphs, source spans and boundaries of
`FTS4` and `FTS9`, the provenance of `FTD32`, and the attempts before it; or
an unresolved outcome with the exact run range and every attempt. An attempt
records the candidate and one of: `outsideRoute`, `pruned` (with the
proving scalar), `bytecodeRequired`, `unopened` (with the entry's outcome),
`notdef` (with the source spans holding glyph 0), or `unligated` (with the
grapheme's range). Attempts beyond the caller's storage are counted, not
kept. A shaping `limitExceeded` ends the trial with that error and its
outputs uncommitted. The trial **must not** shape any part of the run alone
or return a sub-span; a caller that wants a smaller span asks again (`FTD7`).
Cost: O(n) per candidate for pruning plus the shaping and face-open cost of
each shaped candidate, at most the policy's limit; the glyph, span and
attempt storage are the caller's.

**FTD43: Trial keys.** `trialKey` **must** be the BLAKE3 hash, truncated to
128 bits, of the chain identity, the run's absolute byte range, the bytes the
shaper reads (the run and up to five scalars of context each side) with their
absolute offsets, the segment properties, features, text-boundary flags, size
and policy. A resolution or unresolved outcome with no `unopened` attempt is
cacheable: within one store, equal keys give equal cacheable outcomes. Text
edited before a run shifts its offsets and so its key; a cache keyed this way
answers only for unmoved runs.

## 8. The correction registry

**FTD44: Opening with corrections.** `openFace` **must** take a correction
policy, `off` by default ([`FTX15`](./decisions.md#ftx15-compatibility-quirks-the-engines-apply-applied-visibly)); the GUI stack asks for `apply`. Under `apply` the face records the registry
entries its signature matches at open; under `off` it records none and every
result is the stored value. A face's `corrections` lists them; each entry's
identifier, engine, engine revision, signature and effect are readable from
the registry. Recognizing the entries costs O(1) per entry from the directory
and table headers, except `FTD12`'s, which decodes the family name records,
O(their length), and sums a `cvt `, `fpgm` or `prep` only when its length
equals a listed one, as FreeType does, so at most 97,337 bytes per table.

**FTD45: Results that say so.** A result an entry changes **must** carry the
entry's identifier: `FTD9`'s two `MATH` constants; `FTD10`'s glyph classes,
mark attachment classes, mark glyph sets and ligature carets, all absent; a
character lookup that `FTD11`'s mapping answers; and `FTD12`'s refusal by the
rasterizer, `unsupportedCapability`.

**FTD46: Signatures as the engines read them.**

- `FTD9`: the `MATH` table's length is 25,722 and its stored
  `delimitedSubFormulaMinHeight` and `displayOperatorMinHeight` are 3,000 and
  2,500 (`MATH::is_bad_cambria`).
- `FTD10`: the lengths of `GDEF`, `GSUB` and `GPOS` in the table directory
  equal one of the triples of `OT::GDEF::is_blocklisted`, a missing table
  counting as length 0. HarfBuzz measures sanitized tables, so a table it
  rejects counts 0 there and its stored length here; no listed font has one.
- `FTD11`: the face's character map uses the symbol subtable (platform 3,
  encoding 0), and `OS/2` has version 0 and an `fsSelection` high byte of
  `0xB2` or `0xB3`. A lookup tries the scalar first, then the code the page
  maps it to, as `get_glyph_from_symbol` does; the page's map replaces the
  symbol subtable's U+F000 duplication, in lookups and in coverage. The maps
  are generated from `ArabicPUASimplified.txt` and `ArabicPUATraditional.txt`
  of the pinned HarfBuzz source, the last row for a scalar winning.
- `FTD12`: only a face without `CFF` or `CFF2` outlines, as FreeType checks
  in its TrueType driver, which also opens bitmap-only faces. Its family is
  FreeType's: when `OS/2` exists and
  `fsSelection` bit 8 is set, name ID 16, else 1; otherwise 21, else 16, else
  1. For an ID, FreeType's choice (`tt_face_get_name`) takes the last Windows
     record of encoding 0, 1 or 10 whose language is English, else the first
     such record of any language, unless a Macintosh record exists (English,
     else Roman) and the Windows record is not English, in which case the
     Macintosh one; else the last Unicode or ISO record. Records with an empty
     string, or one outside the table, are not considered. The name becomes
     ASCII with
     every code below 32 or above 127 written `?`, ending at the first NUL. If
     it starts with six capital letters, `+` and at least one more character,
     those seven are skipped. The face requires bytecode when the result has
     one of the 20 tricky names as a substring, or when its `cvt `, `fpgm` and
     `prep` match one of the 31 listed faces by length and computed checksum, a
     missing table matching a listed length of 0 (`tt_check_trickyness`,
     FreeType 2.14.3).

## 9. Oracles

| Operations      | Oracle                                                                                                                                             | Known divergence, and the substitute oracle                                                                                                                                                                                                                                                                                                                     |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FTD16`–`FTD21` | `fc-scan` over the bundle for family, style, weight, width and coverage; the records of hand-built fixtures                                        | fontconfig maps weights onto its own scale, reads a width from the style name when `usWidthClass` is absent, reads an oblique slant from a style name such as "Oblique" (DejaVu Sans Mono Oblique), and leaves C0 controls mapped to empty glyphs out of the charset; this page reads `OS/2` and the axes only. Substitute: fixtures and the raw `OS/2` values. |
| `FTD18`         | `fc-list` on Linux; on macOS and Windows the CI runners' listing                                                                                   | —                                                                                                                                                                                                                                                                                                                                                               |
| `FTD22`–`FTD24` | scenarios over `MemVfs`, whose modification times are set exactly                                                                                  | —                                                                                                                                                                                                                                                                                                                                                               |
| `FTD25`–`FTD30` | hand-derived traces of CSS Fonts Level 4 §5.2 over a synthetic family of nine weights, two widths and four styles, and a variable family           | CSS leaves the synthesis threshold to the browser; this page follows Blink's 600.                                                                                                                                                                                                                                                                               |
| `FTD31`–`FTD34` | fixtures with known coverage                                                                                                                       | —                                                                                                                                                                                                                                                                                                                                                               |
| `FTD35`–`FTD38` | HarfBuzz and FreeType over the generated face: every glyph opens, shapes and rasterizes; hand-computed pixel coverage of lines, blocks and shades  | —                                                                                                                                                                                                                                                                                                                                                               |
| `FTD40`         | a property over the bundle's faces: for each face and each scalar the rule prunes it for, alone and in sampled sequences, `hb_shape` gives glyph 0 | —                                                                                                                                                                                                                                                                                                                                                               |
| `FTD39`–`FTD43` | real faces with inspected coverage: a mark sequence, an RGI ZWJ sequence and an Arabic word, each with a failing primary                           | —                                                                                                                                                                                                                                                                                                                                                               |
| `FTD44`–`FTD46` | HarfBuzz 14.6.0 (`hb_ot_math_get_constant`, `hb_ot_layout_get_glyph_class`, `hb_font_get_nominal_glyph`); FreeType's `FT_IS_TRICKY`                | The signatures' fonts may not be redistributed; fixtures rebuild them byte for byte, as `testing.md` describes.                                                                                                                                                                                                                                                 |
