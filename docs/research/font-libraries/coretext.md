# Core Text (C / Apple platforms)

Apple's system text stack: an attribute-dictionary `CTFontDescriptor` that is
both query and answer, an immutable sized `CTFont` that owns matching,
metrics, raw tables, outlines and per-string fallback, and a
`CTTypesetter` → `CTLine` → `CTRun` ladder that is the only public route to
shaped output.

| Field            | Value                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------- |
| Language         | C (Core Foundation object model; Swift overlays)                                          |
| License          | Proprietary, part of macOS / iOS / iPadOS / tvOS / watchOS / visionOS                     |
| Repository       | none (closed source); [Core Text reference][ref]                                          |
| Documentation    | [Core Text reference][ref], [Core Text Programming Guide][guide] (archived)               |
| Category         | platform text stack                                                                       |
| Layer(s) covered | parse · discover · match/fallback · shape · raster (via Core Graphics) · outline · layout |
| Pinned revision  | n/a (Apple developer documentation, retrieved 2026-10-03)                                 |

## Overview

### What it solves

Core Text is the layer every Apple text view sits on. It answers, in one
framework, the questions that on Linux are split between fontconfig
([`./fontconfig.md`](./fontconfig.md)), HarfBuzz ([`./harfbuzz.md`](./harfbuzz.md)),
FreeType ([`./freetype.md`](./freetype.md)) and Pango ([`./pango.md`](./pango.md)):
which installed face matches a request, which face covers a character the
primary font lacks, how a string becomes positioned glyphs, and what each
glyph's outline and metrics are. Pixels are delegated to Core Graphics:
`CTFontDrawGlyphs` and `CTRunDraw` draw into a `CGContext`.

### Design philosophy

The font database is queried by _describing_ a font, not naming a file. The
reference states the contract of the descriptor:

> A font descriptor is a dictionary of attributes (such as name, point size,
> and variation) that can completely specify a font.
>
> A font descriptor can be an incomplete specification, in which case the
> system chooses the most appropriate font to match the given attributes.
>
> — [`CTFontDescriptor`][descriptor]

And the sharing model is immutability, stated in the programming guide:
"Core Text font objects are immutable, so they can be used simultaneously by
multiple operations, work queues, or threads" ([Core Text Programming Guide][guide]).

## How it works

Five opaque Core Foundation types carry the API; every `Create`/`Copy`
function returns a +1 reference released with `CFRelease`.

- **`CTFontDescriptorRef`** — an attribute dictionary (`kCTFontFamilyNameAttribute`,
  `kCTFontTraitsAttribute`, `kCTFontURLAttribute`, `kCTFontCharacterSetAttribute`,
  `kCTFontVariationAttribute`, `kCTFontFeatureSettingsAttribute`, …). The same
  type is the query and, once _normalized_, the match result
  ([`CTFontDescriptor`][descriptor]).
- **`CTFontRef`** — descriptor + point size + `CGAffineTransform`. All
  metrics, tables, glyph mapping, outlines, variation and feature queries hang
  off it ([`CTFont`][ctfont]).
- **`CTFontManager`** functions — registration and enumeration of the font
  database (`CTFontManagerRegisterFontsForURL`,
  `CTFontManagerCopyAvailableFontFamilyNames`,
  `CTFontManagerCreateFontDescriptorsFromURL` / `…FromData`).
- **`CTTypesetterRef` / `CTLineRef`** — shaping and line breaking over a
  `CFAttributedString` whose runs carry `kCTFontAttributeName`.
- **`CTRunRef`** — "a set of consecutive glyphs sharing the same attributes
  and direction" ([`CTRun`][ctrun]); the shaped output.

The architecture chapter puts the framesetter at the top: "The typesetter
converts the characters in the attributed string to glyphs and fits those
glyphs into the lines that fill a text frame … Each CTLine object contains an
array of glyph run (CTRun) objects" ([Core Text Programming Guide][guide]).

## Analysis spine

### 1. Layering and ownership

| Layer             | Type                              | Owns                                                | Mutability                                     |
| ----------------- | --------------------------------- | --------------------------------------------------- | ---------------------------------------------- |
| query / match key | `CTFontDescriptorRef`             | attribute dictionary                                | immutable; `…CreateCopyWith…` derives new ones |
| database          | `CTFontManager*` (process global) | registered faces per `CTFontManagerScope`           | global, mutated by register/unregister         |
| sized font        | `CTFontRef`                       | descriptor, size, matrix, variation, features       | immutable                                      |
| shaper / layout   | `CTTypesetterRef`, `CTLineRef`    | attributed string → lines                           | immutable after creation                       |
| output            | `CTRunRef`                        | glyphs, positions, advances, string indices, status | immutable, borrowed from its line              |

There is no unsized "face" type: a typeface without a size is a descriptor,
and a `CTFont` always has a size (`0.0` means 12 pt —
[`CTFontCreateWithFontDescriptor`][create-desc]). Thread-safety is immutability
plus a caveat: "Core Text functions may be invoked from multiple threads
simultaneously provided that the client is not mutating any parameters such
as attributed strings that are shared between threads" ([guide]).

Error model: mostly sentinels. Matching _never fails_ — "A best match font is
always returned, and default values are used for any unspecified parameters"
([`CTFontCreateWithFontDescriptor`][create-desc]); `CTFontCreatePathForGlyph`
returns `NULL` on error; `CTFontManagerCreateFontDescriptorsFromData` "returns
an empty array in the event of invalid or unsupported font data"
([`…FromData`][from-data]). Only the font-manager registration calls take a
`CFErrorRef *`.

### 2. Face loading and table access

From a path: `CTFontManagerCreateFontDescriptorsFromURL` (one descriptor per
face, so `.ttc`/`.otc` collections are enumerated, not indexed). From bytes:
`CTFontManagerCreateFontDescriptorsFromData`, which Apple calls "the preferred
function when the data contains a font collection (TTC or OTC)" — but those
descriptors "are not available through font descriptor matching"
([`…FromData`][from-data]). Making a file matchable by name is a separate act,
`CTFontManagerRegisterFontsForURL (url, scope, &error)`, with scope
`process`, `session`, `user` or `persistent` ([`RegisterFontsForURL`][register],
[`CTFontManagerScope`][scope]).

Raw tables are exposed: `CTFontCopyAvailableTables (font, options)` lists tags
and `CTFontCopyTable (font, tag, options)` returns a `CFData` — "The table data
is not actually copied; however, the data reference must be released"
([`CTFontCopyTable`][copy-table]). That is a borrowed view with a refcount,
the same shape as HarfBuzz's sub-blob. The face index of a collection member,
and the file it came from, are reachable only through descriptor attributes
(`kCTFontURLAttribute`).

### 3. Shaping

Shaping is not a function call on a font; it is a side effect of layout.
The caller builds a `CFAttributedString` with font, `kCTFontFeatureSettingsAttribute`
and paragraph attributes, creates a `CTLine` (`CTLineCreateWithAttributedString`)
or a `CTTypesetter`, and reads `CTLineGetGlyphRuns`. Each `CTRun` yields
`CTRunGetGlyphs`, `CTRunGetPositions`, `CTRunGetAdvances`,
`CTRunGetStringIndices` (the cluster→UTF-16 index map), `CTRunGetStatus`
(right-to-left, non-monotonic) and `CTRunGetAttributes`, whose font entry
reveals **which fallback font** the typesetter substituted
([`CTRun`][ctrun]). Units are points at the font's size, in UTF-16 indices.

Script, direction and bidi are inferred by the typesetter; features are the
legacy AAT type/selector pairs, with the rule "In the case of duplicate or
conflicting settings, the last setting in the list takes precedence"
([`kCTFontFeatureSettingsAttribute`][feature-settings]). OpenType tag/value
pairs are accepted in the same array on newer systems.

Below layout there is only `CTFontGetGlyphsForCharacters`, documented as
"basic character-to-glyph mapping" which returns `0` for unmapped characters
and leaves "the Unicode properties of the input characters" to the caller
([`CTFontGetGlyphsForCharacters`][glyphs-for-chars]) — a `cmap` lookup, no
`GSUB`. Terminals that want ligatures therefore must run `CTLine`
(see [`./ghostty.md`](./ghostty.md)).

### 4. Variation and instances

Axes: `CTFontCopyVariationAxes` returns dictionaries keyed by
`kCTFontVariationAxisIdentifierKey`, `…MinimumValueKey`, `…MaximumValueKey`,
`…DefaultValueKey`, `…NameKey` (localized) and `…HiddenKey`
([variation axis keys][axis-keys], [`CTFontCopyVariationAxes`][axes]). Current
coordinates: `CTFontCopyVariation`. Coordinates are **user-space** values in a
`CFDictionary` from axis identifier to `CFNumber`; normalization and `avar` are
internal and not exposed.

Setting coordinates is again an attribute: `kCTFontVariationAttribute` on a
descriptor (`CTFontDescriptorCreateCopyWithVariation`) or via
`CTFontCreateCopyWithAttributes`. As a _matching_ attribute it is soft: "fonts
with the specified axes are primary match candidates; if no such fonts exist,
this attribute is ignored" ([`kCTFontVariationAttribute`][variation-attr]).
Because the coordinate lives on the immutable `CTFont`, the same object
carries it into the typesetter, metrics, `CTFontCreatePathForGlyph` and
drawing — one source of truth, no separate plumbing. Named instances are
surfaced as ordinary descriptors from matching rather than through a
dedicated `fvar` instance API.

### 5. Rasterization and outlines

Outline: `CTFontCreatePathForGlyph (font, glyph, matrix)` returns a +1
`CGPathRef`; "The path reflects the font point size, matrix, and transform
parameter, applied in that order" ([`CTFontCreatePathForGlyph`][path]). Units
are therefore points (size-scaled), y-up; the consumer walks it with
`CGPathApply` (a callback sink over move/line/quad/cubic/close elements). To
get font units, create the font at `size == unitsPerEm`.

Raster: Core Text has no bitmap API. `CTFontDrawGlyphs` renders into a
`CGContext` (a bitmap context for an atlas), and antialiasing, font smoothing
and subpixel positioning are `CGContext` state. Color glyphs (`sbix`, `COLR`,
`SVG`) draw through the same call; `kCTFontTraitColorGlyphs` flags such faces.
Glyph caching is internal and invisible. An atlas, gamma policy or
GPU path is the client's job.

### 6. Metrics and measurement

`CTFontGetAscent`, `GetDescent`, `GetLeading`, `GetCapHeight`, `GetXHeight`,
`GetUnderlinePosition`, `GetUnderlineThickness`, `GetSlantAngle`,
`GetBoundingBox` all return `CGFloat` points at the font's size;
`CTFontGetUnitsPerEm` and `CTFontGetGlyphCount` are size-free ([`CTFont`][ctfont]).
The documentation does not say which table (`hhea`, `OS/2` typo or win)
feeds ascent/descent — the choice is opaque, which is exactly the
cross-platform cell-height discrepancy terminals report. Per glyph:
`CTFontGetAdvancesForGlyphs` and `CTFontGetBoundingRectsForGlyphs` (both batched,
with an orientation and an optional total), `CTFontGetOpticalBoundsForGlyphs`,
`CTFontGetVerticalTranslationsForGlyphs`. Line-level:
`CTLineGetTypographicBounds`, `CTRunGetImageBounds`.

### 7. Discovery, matching and fallback

Enumeration: `CTFontManagerCopyAvailableFontFamilyNames`, or matching an
empty descriptor. Matching: `CTFontDescriptorCreateMatchingFontDescriptors
(descriptor, mandatoryAttributes)` returns _normalized_ descriptors — "the
input values were matched up with actual existing fonts" — while the set
lists attributes "that must be identically matched"
([`…MatchingFontDescriptors`][matching]). Everything not mandatory is a
soft preference; the scoring is undocumented.

Fallback is a first-class two-tier API:

- **Per string**: `CTFontCreateForString (currentFont, string, range)`
  "Returns a font reference that most accurately maps the string range based
  on the current font", returning `currentFont` itself when it covers the
  range ([`CTFontCreateForString`][for-string]);
  `CTFontCreateForStringWithLanguage` adds a language hint.
- **Cascade list**: `CTFontCopyDefaultCascadeListForLanguages` returns "An
  ordered list of CTFontDescriptors for font fallback", whose entries "match
  the original font's style, weight, and width"
  ([`…CascadeListForLanguages`][cascade]). A custom list overrides it via
  `kCTFontCascadeListAttribute`.

Classification: `kCTFontTraitsAttribute` → `kCTFontSymbolicTrait` (bold,
italic, monospace, color glyphs, …), weight/width/slant numbers, and
`CTFontStylisticClass`; coverage: `CTFontCopyCharacterSet` /
`kCTFontCharacterSetAttribute`; languages: `CTFontCopySupportedLanguages`.
An inspector gets the rest from the font: `CTFontCopyAvailableTables`,
`CTFontCopyFeatures` ("an array of font feature dictionaries" —
[`CTFontCopyFeatures`][features]), `CTFontCopyVariationAxes`, and
`CTFontCopyName` / `CTFontCopyLocalizedName` for `name`-table strings.

**In sparkles today.** [`font_coretext.d`][sparkles-ct] `dlopen`s Core Text and
uses only the discovery slice: `CTFontDescriptorCreateWithAttributes` with
`kCTFontFamilyNameAttribute`, `CTFontDescriptorCreateMatchingFontDescriptors`,
`CTFontDescriptorCopyAttribute` to read `kCTFontURLAttribute`,
`kCTFontTraitsAttribute`/`kCTFontSymbolicTrait` (italic, bold, monospace,
color-glyph bits) and `kCTFontCharacterSetAttribute` (decoded with
`CFCharacterSetCreateBitmapRepresentation` into codepoint ranges),
`CTFontManagerCreateFontDescriptorsFromURL` for file → family, and
`CTFontManagerCopyAvailableFontFamilyNames` for enumeration. It never creates
a `CTFont`, never calls `CTFontCreateForString`, and excludes `.ttc` files
because `stb_truetype` is loaded at offset 0.

## What it teaches `sparkles:font`

- **One descriptor type for query and result.** A D `FontQuery` that a match
  returns _filled in_ (path, index, traits, coverage) keeps the matcher's
  input and output in one vocabulary and makes "mandatory vs preferred"
  attributes an explicit set, as `mandatoryAttributes` does.
- **Expose fallback as `fontFor(string, range)` plus an inspectable cascade
  list.** Core Text's two-tier answer is what a terminal needs per cell
  cluster; the macOS backend of `sparkles:font` should call
  `CTFontCreateForString` rather than re-derive the system cascade.
- **Variation coordinates belong on the immutable sized font.** One object
  then feeds shaping, metrics and outlines; but keep both user and
  normalized coordinates visible, which Core Text does not.
- **Borrowed table views with explicit release** (`CTFontCopyTable`) map to a
  D `TableView` that aliases the font's bytes — the own parser should work on
  bytes obtained this way, so the inspector can read any table on macOS.
- **Do not make matching infallible.** Core Text's "a best match is always
  returned" hides misses; `sparkles:font` should return `Expected` with the
  match score so a UI can say "fell back from X to Y".
- **Read shaping output from the run, including its chosen font** — the
  `CTRun` attribute dictionary is the template for a D `GlyphRun` that names
  its face.

## Strengths

- Complete stack in one framework: matching, fallback, shaping, bidi, line
  breaking, metrics, outlines, color glyphs, all consistent with the OS.
- Immutable objects make cross-thread sharing free.
- First-class per-string fallback and language-aware cascade lists.
- Sees every font the user installed through Font Book, with registration
  scopes for app-bundled fonts.

## Weaknesses

- Closed source; matching scores, metric-table selection and glyph caching
  are undocumented.
- No shaping entry below `CTLine`; a terminal pays for attributed strings and
  line objects to get `GSUB`.
- UTF-16 indices and CF object overhead at every boundary.
- No bitmap raster API; quality knobs are `CGContext` state, and the glyph
  cache cannot be shared with a custom GPU atlas.
- Collections are addressable only as descriptors, not by face index.
- Apple-only; a cross-platform library still needs fontconfig/DirectWrite peers.

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                   | Trade-off                                                    |
| ---------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------ |
| Descriptor = attribute dictionary        | One extensible type for query, match result and font config | Stringly typed CF keys; soft vs mandatory is easy to misread |
| No unsized face; `CTFont` always sized   | Metrics and outlines come back in points directly           | Font units need a font created at `size == upem`             |
| Immutable fonts                          | Free thread sharing                                         | Each variation/feature change allocates a new font           |
| Matching never fails                     | UI text must always render                                  | Misses are silent                                            |
| Shaping only via typesetter/line         | One code path for bidi, fallback and features               | Heavy for grid text; no direct shaper                        |
| Fallback per string range + cascade list | System-quality fallback with language preference            | Selection logic is opaque                                    |
| Rendering delegated to Core Graphics     | Single rasterizer across the OS                             | No bitmap/coverage API for custom atlases                    |

## Sources

- **Reference** — [`CTFont`][ctfont], [`CTFontDescriptor`][descriptor],
  [`CTRun`][ctrun], [`CTFontCreateWithFontDescriptor`][create-desc],
  [`CTFontDescriptorCreateMatchingFontDescriptors`][matching],
  [`CTFontCreateForString`][for-string],
  [`CTFontCopyDefaultCascadeListForLanguages`][cascade],
  [`CTFontCopyTable`][copy-table], [`CTFontCreatePathForGlyph`][path],
  [`CTFontGetGlyphsForCharacters`][glyphs-for-chars],
  [`CTFontCopyVariationAxes`][axes], [variation axis keys][axis-keys],
  [`kCTFontVariationAttribute`][variation-attr],
  [`kCTFontFeatureSettingsAttribute`][feature-settings],
  [`CTFontCopyFeatures`][features],
  [`CTFontManagerRegisterFontsForURL`][register], [`CTFontManagerScope`][scope],
  [`CTFontManagerCreateFontDescriptorsFromData`][from-data].
- **Guide** — [Core Text Programming Guide, overview][guide].
- **sparkles** — [`libs/raylib-text/…/font_coretext.d`][sparkles-ct].
- Siblings: [`./fontconfig.md`](./fontconfig.md), [`./directwrite.md`](./directwrite.md),
  [`./crossfont.md`](./crossfont.md), [`./ghostty.md`](./ghostty.md),
  [`./skia.md`](./skia.md).

<!-- References -->

[ref]: https://developer.apple.com/documentation/coretext
[guide]: https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/CoreText_Programming/Overview/Overview.html
[ctfont]: https://developer.apple.com/documentation/coretext/ctfont
[descriptor]: https://developer.apple.com/documentation/coretext/ctfontdescriptor
[ctrun]: https://developer.apple.com/documentation/coretext/ctrun
[create-desc]: https://developer.apple.com/documentation/coretext/ctfontcreatewithfontdescriptor(_:_:_:)
[matching]: https://developer.apple.com/documentation/coretext/ctfontdescriptorcreatematchingfontdescriptors(_:_:)
[for-string]: https://developer.apple.com/documentation/coretext/ctfontcreateforstring(_:_:_:)
[cascade]: https://developer.apple.com/documentation/coretext/ctfontcopydefaultcascadelistforlanguages(_:_:)
[copy-table]: https://developer.apple.com/documentation/coretext/ctfontcopytable(_:_:_:)
[path]: https://developer.apple.com/documentation/coretext/ctfontcreatepathforglyph(_:_:_:)
[glyphs-for-chars]: https://developer.apple.com/documentation/coretext/ctfontgetglyphsforcharacters(_:_:_:_:)
[axes]: https://developer.apple.com/documentation/coretext/ctfontcopyvariationaxes(_:)
[axis-keys]: https://developer.apple.com/documentation/coretext/font-variation-axis-dictionary-keys
[variation-attr]: https://developer.apple.com/documentation/coretext/kctfontvariationattribute
[feature-settings]: https://developer.apple.com/documentation/coretext/kctfontfeaturesettingsattribute
[features]: https://developer.apple.com/documentation/coretext/ctfontcopyfeatures(_:)
[register]: https://developer.apple.com/documentation/coretext/ctfontmanagerregisterfontsforurl(_:_:_:)
[scope]: https://developer.apple.com/documentation/coretext/ctfontmanagerscope
[from-data]: https://developer.apple.com/documentation/coretext/ctfontmanagercreatefontdescriptorsfromdata(_:)
[sparkles-ct]: ../../../libs/raylib-text/src/sparkles/raylib_text/font_coretext.d
