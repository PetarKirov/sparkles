# Font libraries — comparison and verdicts

The synthesis of the [font-libraries survey](./index.md): 34 subjects read for
the six questions the survey exists to answer, each question closed with a
verdict that the `sparkles:font` specification can cite. Vocabulary is defined
in [`concepts.md`](./concepts.md).

**Last reviewed:** October 3, 2026

> [!IMPORTANT]
> The verdicts here are recommendations backed by the cited deep-dives and by
> two runnable programs in the survey's `examples/` directory, not settled design. The
> library specification under `docs/specs/font/` is where they become
> requirements, and it may overrule any of them with a stated reason.

---

## At a glance

| Question                                             | Verdict                                                                                                                                              | Strongest evidence                                                                                                        |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| [RQ1](#rq1-layering-and-ownership) Layering          | Five objects: borrowed bytes, immutable face, value-type font instance, shaper with caller scratch, font database. Caches live beside, never inside. | [HarfBuzz](./harfbuzz.md), [fontations](./fontations.md), [Ghostty](./ghostty.md), [parley](./parley.md)                  |
| [RQ2](#rq2-rasterization-and-gpu) Raster             | **Go** for a D grayscale CPU rasterizer. **No-go** for D shaping. **Defer** GPU compute and hinting.                                                 | [fontdue](./fontdue.md), [ab_glyph](./ab-glyph.md), [rustybuzz](./rustybuzz.md), [Vello](./vello.md), example 2           |
| [RQ3](#rq3-variation-and-shaping) Variation          | One normalized coordinate vector per instance, `avar` applied once, fed to shaper, metrics, outlines and the cache key alike.                        | [fontations](./fontations.md), [DirectWrite](./directwrite.md), [ttf-parser](./ttf-parser.md)'s regret                    |
| [RQ4](#rq4-discovery-matching-and-fallback) Fallback | A scanned, cached face index; an ordered, coverage-pruned fallback **list** as the primary API; per-codepoint memo; lazy face opening.               | [fontconfig](./fontconfig.md), [Ghostty](./ghostty.md), [go-text](./go-text-typesetting.md), [crossfont](./crossfont.md)  |
| [RQ5](#rq5-what-an-inspector-must-expose) Inspector  | Tables as reflectable structs, plus enumeration of features per script and language, axes, instances, coverage and all three metric sets.            | [opentype.js](./opentype-js.md), [lib-font](./lib-font.md), [fontTools](./fonttools.md)                                   |
| [RQ6](#rq6-outline-access) Outlines                  | Both forms over one decoder: a DbI sink and a flat segment array, in font units, with explicit contour boundaries.                                   | [FreeType](./freetype.md), [fontTools](./fonttools.md) pens, [Go `sfnt`](./golang-image-font.md), [msdfgen](./msdfgen.md) |

---

## RQ1: Layering and ownership

**The field converges on five objects**, and the deep-dives disagree only on
where the edges go ([`concepts.md` § object layers](./concepts.md#the-object-layers)):

1. **Bytes** — owned, memory-mapped or borrowed. [HarfBuzz](./harfbuzz.md)
   models the face as a `tag → bytes` function (`hb_face_create_for_tables`),
   and [allsorts](./allsorts.md) as a `tag → Cow<bytes>` provider; both make
   WOFF decoding, subsetting and synthetic faces another provider rather than
   another face type.
2. **Face** — immutable, shareable across threads, cheap to construct.
   [ttf-parser](./ttf-parser.md), [fontations](./fontations.md) and
   [stb_truetype](./stb-truetype.md) all reduce it to a slice plus a dozen table
   offsets located eagerly, with glyph data decoded lazily.
3. **Font instance** — face × size × variation coordinates × synthesis ×
   hinting choice. This is the layer that differs most and matters most:
   `FT_Size`, `hb_font_t`, `SkFont`, `PxScaleFont`, Go's `Face` beside its
   `Font`. [SixLabors.Fonts](./sixlabors-fonts.md) and
   [stb_truetype](./stb-truetype.md) skip it and pass size per call;
   [font-kit](./font-kit.md)'s deep-dive records the consequence —
   `FT_Set_Char_Size` per glyph and no place for a cache.
4. **Shaper** — a function of (instance, text, script, language, direction,
   features) with a reusable buffer the caller owns. [rustybuzz](./rustybuzz.md)
   makes "codepoints in, glyphs out" a typestate (`UnicodeBuffer` →
   `GlyphBuffer`), an improvement over HarfBuzz's runtime content-type flag.
5. **Database** — enumerates and matches; never holds open faces it was not
   asked for.

**Caches are beside the objects, not inside them.** [FreeType](./freetype.md)'s
shared `FT_GlyphSlot` is why an `FT_Face` is single-threaded;
[allsorts](./allsorts.md) puts lazy caches behind `&mut self` and cannot share a
face; [cosmic-text](./cosmic-text.md)'s single `&mut FontSystem` is correct and
confines everything to one thread. The designs that scale split a long-lived,
shareable database from per-thread scratch: [parley](./parley.md)'s
`FontContext` plus `LayoutContext`, [Go](./golang-image-font.md)'s caller-owned
`*sfnt.Buffer` per call, [Ghostty](./ghostty.md)'s `Collection` (storage),
`CodepointResolver` (policy) and `SharedGrid` (cache) as three owners.

**Errors distinguish malformed from absent.** [ttf-parser](./ttf-parser.md)'s
`Option` everywhere makes diagnosis impossible; [fontations](./fontations.md)
returns structural errors and clamps field reads to defaults;
[allsorts](./allsorts.md) returns the partial result with the first error.
An inspector needs the third.

> **Verdict.** `Face` is a `@safe pure nothrow @nogc` value over
> `scope const(ubyte)[]` with eager table offsets. `FontInstance` is a value
> holding the face, ppem, a normalized-coordinate slice and a `Synthesis`
> value. Shaping, outline and raster calls take a caller-owned scratch by
> `ref`. Glyph and shape caches are separate objects with their own owner.
> Errors are `Expected`, and a decoder that can continue returns what it read.

---

## RQ2: Rasterization and GPU

### A CPU rasterizer in D: go

Every from-scratch rasterizer in the survey uses one algorithm, signed-area
accumulation, and its core is small:

| Implementation                                            | Rasterizer core | Notes                                                               |
| --------------------------------------------------------- | --------------- | ------------------------------------------------------------------- |
| [This survey's example](./examples/outline-sink-raster.d) | 71 lines of D   | exact coverage, uniform curve flattening, no gamma                  |
| [fontdue](./fontdue.md)                                   | ~200 lines      | plus cached per-glyph geometry, which is where its speed comes from |
| [ab_glyph_rasterizer](./ab-glyph.md)                      | ~200 lines      | `abs()` overlap defect noted                                        |
| [stb_truetype v2](./stb-truetype.md)                      | ~700 lines      | overlapping-contour overestimate                                    |
| [Go `x/image/vector`](./golang-image-font.md)             | ~1,500 lines    | plus 1,019 lines of generated SSE4.1 accumulation assembly          |

The example renders Noto Sans `g` and Maple Mono `a` at 28 ppem with correct
coverage from HarfBuzz's outline callbacks alone. What is _not_ small sits
around the core, and each item is a decision rather than a cost to absorb:

- **Overlap and winding.** Accumulation computes nonzero coverage only when
  contours do not overlap; variable fonts routinely overlap contours. Two
  deep-dives name this defect ([stb_truetype](./stb-truetype.md),
  [ab_glyph](./ab-glyph.md)); the fix is per-contour accumulation or a
  FreeType-`smooth`-style cell list.
- **Hinting.** A TrueType bytecode interpreter is the largest piece of every
  rasterizer that has one. [Typography](./typography.md)'s C# port is ~2,100
  lines and incomplete; [fontations](./fontations.md) wrote a whole autohinter in
  Rust and proves it differentially against FreeType. Grayscale unhinted text at
  terminal sizes on high-DPI panels is the default of [fontdue](./fontdue.md),
  [Vello](./vello.md) and [cosmic-text](./cosmic-text.md).
- **Gamma and stem darkening.** Coverage is linear; every serious stack adjusts
  it. The adjustment is a lookup table, but choosing it needs the A/B oracle.
- **Colour.** `COLR` v0 is layered outlines through the same rasterizer.
  `CBDT` and `sbix` are embedded PNGs, so a D path needs a PNG decoder (inflate
  plus filters). `COLR` v1 is a paint graph with gradients and compositing; it
  is a small vector renderer of its own ([fontations](./fontations.md)'
  `ColorPainter`, [HarfBuzz](./harfbuzz.md)'s `hb_paint_funcs_t`).
- **Proof.** [fontations](./fontations.md)' `fauntlet` diffs its outlines
  against FreeType across the Google Fonts corpus. A D rasterizer gets the same
  oracle for free: FreeType stays in the dev shell as the reference, and the
  per-face raster hashes the explorer decision already calls for become the
  regression suite.

> **Verdict: go,** for grayscale, unhinted, `glyf` + `CFF` + `CFF2` outlines and
> `COLR` v0, with per-contour accumulation and a gamma table, differentially
> tested against FreeType. Bitmap colour strikes (`CBDT`, `sbix`) wait on a PNG
> decoder and keep FreeType as the path until then. Hinting is out of scope;
> `COLR` v1 is a later milestone.

### Shaping in D: no-go

Four independent shapers measured the cost of owning OpenType layout:

| Shaper                                                   | Size                                                    | Fate                                                                  |
| -------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------- |
| [rustybuzz](./rustybuzz.md) (HarfBuzz port)              | ~17 KLOC hand-written, ~10 KLOC without complex scripts | archived; its maintainers moved to HarfRust, a fresh port, to keep up |
| [go-text](./go-text-typesetting.md) (HarfBuzz port)      | ~16 KLOC hand-written                                   | maintained, by porting HarfBuzz releases                              |
| [SixLabors.Fonts](./sixlabors-fonts.md) (own)            | ~30 KLOC of C#                                          | maintained                                                            |
| [allsorts](./allsorts.md) (own)                          | ~17 KLOC core                                           | maintained; ignores `HVAR` in shaping                                 |
| [fontkit](./fontkit.md), [opentype.js](./opentype-js.md) | partial engines                                         | opentype.js's per-script feature wiring is the deep-dive's "dead end" |

The code is feasible; the **upstream tracking** is not. Every port that
survived does it as standing work, and the one that stopped was archived. The
survey found no evidence that a D shaper would be faster or safer than
HarfBuzz, which is already in every consumer's closure.

> **Verdict: no-go.** HarfBuzz stays, reached through hand-declared `extern(C)`
> prototypes over opaque handles (both examples do exactly this, with no
> ImportC and no C shim) or through ImportC of the real headers.

### GPU compute: defer

- [Slug](./slug.md) evaluates quadratics per pixel from per-glyph band lists:
  scale-independent and exact, but around 40× the cost of a textured quad in the
  best case, and its own optimisations stop paying at 10–16 px — terminal sizes.
- [Vello](./vello.md) runs a full vector pipeline in about 5,400 lines of
  shaders. A glyph-only subset (flatten, bin, fine) is the plausible
  `sparkles:shader` target.
- [glyphon](./glyphon.md) shows the opposite trade: CPU coverage into an R8
  atlas plus an RGBA colour atlas, one instanced draw, 28 bytes per glyph.
- [msdfgen](./msdfgen.md) is the middle path for scalable text from one bitmap.

> **Verdict: defer.** The explorer's specimens are block bitmaps through the
> image primitive, so its raster path is the CPU one. A GPU path earns its
> place only for zoomable or transformed text, and the glyph-only Vello subset
> on `sparkles:shader` is the candidate when it does.

---

## RQ3: Variation and shaping

**Where coordinates live is the most-regretted decision in the survey.**
[ttf-parser](./ttf-parser.md) stores them on the face behind a mutable
`set_variation`, caps axes at 64, and its own comment calls this an API
simplification; [ab_glyph](./ab-glyph.md) inherits it and must clone per
instance. The designs that work make the coordinates immutable per instance:

- [DirectWrite](./directwrite.md) — a variation instance **is** a new face
  (`IDWriteFontResource::CreateFontFace(axisValues)`), so nothing downstream
  takes a variation parameter.
- [fontations](./fontations.md) — user coordinates become normalized `F2Dot14`
  once, through `avar`, and a borrowed `LocationRef` is passed to metrics,
  outlines, hinting and paint.
- [HarfBuzz](./harfbuzz.md), [CoreText](./coretext.md), [Pango](./pango.md) —
  on the sized font, so one object feeds shaping, metrics and outlines.

**Variation must reach advances, not only outlines.** [allsorts](./allsorts.md)
ignores `HVAR` in shaping; [opentype.js](./opentype-js.md) drops
`FeatureVariations` and `GPOS` deltas; [cosmic-text](./cosmic-text.md) derives
two coordinate sets independently. The
[outline example](./examples/outline-sink-raster.d) shows the single-object
case working: one `hb_font_set_variations(wght=900)` moves the advance from 16
to 18 px and the ink from 47 to 250 px², while the segment count stays at 2
moves, 8 lines, 31 quadratics. **Variation moves points and never changes
contour topology**, so an outline cache may key on glyph plus coordinates
without re-decoding structure.

**Programming ligatures survive a cell grid.** The
[shaping example](./examples/harfbuzz-shape-features.d) shapes `a -> b != c ffi`
in Maple Mono with `calt` and `liga` on and off. Both runs have 15 glyphs at
600 units each. `->` becomes `hyphen.sta.seq` plus `greater_hyphen.end.seq`;
`!=` becomes a zero-ink spacer plus one glyph that overhangs it. The font, not
the renderer, keeps one glyph per cell, so a terminal can shape a whole run and
still place glyphs by cell. Fonts that use `liga` with true glyph-count changes
remain the case [Ghostty](./ghostty.md) handles by shaping per run and
assigning clusters to cells.

**Shape at upem, scale outside.** [HarfBuzz](./harfbuzz.md) with scale = upem,
[rustybuzz](./rustybuzz.md) (no scale at all) and [cosmic-text](./cosmic-text.md)
(em-fraction advances) make shaping results size-independent and cacheable
across zoom; only the raster key carries pixels.

> **Verdict.** `FontInstance` owns one normalized coordinate vector computed
> once (user → `fvar` normalize → `avar`), keeps user values for display, and
> passes the normalized slice to `hb_font_set_var_coords_normalized`, to the
> metrics reader (`HVAR`, `MVAR`), to the outline decoder (`gvar`, `CFF2`
> blends) and into the glyph cache key as a first-level partition, as
> [Vello](./vello.md) does. Shaping runs at upem; results are cached per
> (instance, run, features).

---

## RQ4: Discovery, matching and fallback

Three fallback strategies appear, and the systems that work combine them:

| Strategy                     | Subjects                                                                                                                                          | Weakness alone                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| ordered fallback list        | [fontconfig](./fontconfig.md) `FcFontSort`, [SixLabors](./sixlabors-fonts.md), [Pango](./pango.md) fontsets                                       | the list is long; opening every face is slow  |
| per-codepoint OS query       | [CoreText](./coretext.md) `CTFontCreateForString`, [DirectWrite](./directwrite.md) `MapCharacters`, [Skia](./skia.md) `matchFamilyStyleCharacter` | platform-only; nothing to inspect or test     |
| per-script preference tables | [cosmic-text](./cosmic-text.md), [go-text](./go-text-typesetting.md), [parley](./parley.md)/fontique                                              | stale tables; misses fonts the user installed |

What the strong designs add:

- **The list is the API; the best match is its head.**
  [fontconfig](./fontconfig.md)'s `FcFontSort` with `trim` prunes faces that add
  no coverage; [crossfont](./crossfont.md) builds a terminal on exactly that.
- **Faces open lazily.** [Ghostty](./ghostty.md)'s deferred faces answer
  coverage and presentation from discovery metadata, so a long fallback list
  costs nothing until a miss.
- **A cached face index.** [go-text](./go-text-typesetting.md)'s `Footprint`
  (family, aspect, rune set, script set, languages, location, mtime-validated)
  and [cosmic-text](./cosmic-text.md)'s mtime-keyed index remove the start-up
  scan; [font-kit](./font-kit.md) shows the cost of skipping it, opening every
  face to read `OS/2`.
- **Matching as a transcription of CSS Fonts §5.2.** [font-kit](./font-kit.md)'s
  ~130-line `find_best_match` and [fontdb](./fontdb.md)'s `query` are reference
  ports; [Ghostty](./ghostty.md) encodes precedence as a packed integer so the
  comparison is one compare.
- **The answer says what it did.** [parley](./parley.md) returns `Synthesis`
  (embolden, skew, or "set `wght` to 600"), and the [CoreText](./coretext.md)
  deep-dive argues for returning the score so a UI can say "fell back from X
  to Y".
- **Discovery separated from loading** by a serializable handle,
  `{path | bytes, index}` ([font-kit](./font-kit.md)), so a fontconfig answer,
  a CoreText answer and a bundle directory scan all open through one parser.

> **Verdict.** A `FontDatabase` built from per-platform sources (fontconfig on
> Linux, CoreText on macOS, DirectWrite on Windows, directory scans for the
> bundle and Android) into one cached `FaceRecord` index keyed by
> (path, index, mtime), with coverage from the own `cmap` parser so no platform
> needs fontconfig. Matching is CSS §5.2 with a packed score. Fallback is a
> `FallbackChain`: an ordered, coverage-pruned list of deferred faces with a
> per-codepoint memo. Results carry the score and a `Synthesis` value.

---

## RQ5: What an inspector must expose

The browser inspectors are thin shells over their parsers, so the parsers set
the list. Taking the union of [opentype.js](./opentype-js.md) (FontDrop's
engine), [lib-font](./lib-font.md) (Wakamai Fondue's), [fontkit](./fontkit.md),
[fontTools](./fonttools.md) `ttx` and the product survey behind the
[explorer decisions](./index.md#how-this-survey-was-scoped):

| Group          | Items                                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| identity       | every `name` record by platform and language; version; vendor (`OS/2.achVendID`); license and embedding (`OS/2.fsType`, name IDs 13–14)          |
| classification | `usWeightClass`, `usWidthClass`, `fsSelection`, `post.isFixedPitch`, measured monospace, `PANOSE`, `sFamilyClass`                                |
| metrics        | upem; all three ascender/descender/gap sets with `USE_TYPO_METRICS`; x-height, cap height; underline and strikeout; per-glyph advance and bounds |
| layout         | scripts → language systems → features from `GSUB` and `GPOS`, deduplicated; per feature, its substitutions as records (`{ sub, by }`)            |
| variation      | `fvar` axes with user ranges, named instances, `avar` segments, `STAT` axis values                                                               |
| coverage       | `cmap` codepoints grouped by Unicode block and script; Nerd Font and Powerline ranges; missing characters for a chosen language sample           |
| glyphs         | names from `post`/`CFF`; outline kind; composite structure; colour layers                                                                        |
| colour         | which of `COLR` v0, `COLR` v1, `CPAL` palettes, `CBDT`, `sbix`, `SVG ` are present                                                               |
| raw            | table directory with tags, offsets, lengths, checksums; any table as bytes                                                                       |

Two design lessons ride along. [opentype.js](./opentype-js.md)'s explorer
loops over table properties reflectively, which `sparkles:reflection` gives a D
parser for free if tables are plain structs. [lib-font](./lib-font.md) and
[fontkit](./fontkit.md) expose `GSUB` as an enumerable structure, not only an
engine that applies it, which is what a ligature list needs.

> **Verdict.** Every parsed table is a plain struct (or a view with named
> accessors) so the inspector is a reflection walk. Layout tables are
> enumerable per script and language. The table directory and raw bytes are
> always reachable. This list is the acceptance surface of `font-explorer
inspect`.

---

## RQ6: Outline access

| Form          | Subjects                                                                                                                                                                                                                                                        | Good for                                  |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| callback sink | [FreeType](./freetype.md) `FT_Outline_Funcs`, [HarfBuzz](./harfbuzz.md) `hb_draw_funcs_t`, [fontTools](./fonttools.md) pens, [fontations](./fontations.md) `OutlinePen`, [SixLabors](./sixlabors-fonts.md) `IGlyphRenderer`, [CoreText](./coretext.md) `CGPath` | rasterizers, path builders, `@nogc`       |
| segment array | [stb_truetype](./stb-truetype.md) `stbtt_vertex`, [ab_glyph](./ab-glyph.md) `OutlineCurve`, [Go `sfnt`](./golang-image-font.md) `Segments`, [opentype.js](./opentype-js.md) `Path`                                                                              | caching, inspection, editing, tests       |
| path object   | [msdfgen](./msdfgen.md) `Shape`, [Skia](./skia.md) `SkPath`                                                                                                                                                                                                     | random access: neighbours, edge colouring |

The deep-dives agree on four details. Keep **font units at the parser
boundary**: [Go `sfnt`](./golang-image-font.md) bakes ppem and the y-flip into
`LoadGlyph` and its own comment concedes that blocks hinting. Keep **explicit
contour boundaries**: [ab_glyph](./ab-glyph.md)'s self-contained segments lose
them, which an inspector needs. Let a sink **declare what it accepts**:
HarfBuzz synthesizes cubics from quadratics on request. And a **contour-count
prologue** ([Typography](./typography.md)'s `BeginRead(contourCount)`) lets a
builder reserve once.

> **Verdict.** One decoder, two faces of it: a DbI `isOutlineSink!S` concept
> (`moveTo`, `lineTo`, `quadTo`, optional `cubicTo` with quad-to-cubic
> elevation when absent, `close`, optional `begin(contours)`) and a
> `decodeOutline` that fills a caller-owned `Segment[]` with contour marks. Both
> in font units.

---

## Consensus shape for `sparkles:font`

```d
// Bytes and faces: borrowed, immutable, @nogc.
struct FontBytes  { const(ubyte)[] data; }               // owned elsewhere
struct Face       { /* slice + table offsets */ }        // Face.open(bytes, index)
struct FontInstance                                       // face × ppem × coords × synthesis
{
    Face face; float ppem; const(F2Dot14)[] coords; Synthesis synthesis;
}

// Reading: tables as plain structs; enumeration for the inspector.
auto os2 = face.table!OS2;              // Expected!(OS2, FontError)
auto feats = face.layoutFeatures(script, lang);
auto axes  = face.axes; auto inst = face.namedInstances;

// Outlines: sink or array, font units.
face.drawOutline(gid, coords, sink);    // isOutlineSink!S
face.decodeOutline(gid, coords, segments[]);

// Shaping: HarfBuzz behind a typed buffer pair.
auto glyphs = shaper.shape(instance, text, ShapeOptions(features: [...]), scratch);

// Rasterizing: coverage into a caller region.
rasterize(instance, gid, subpixelX, target[]);

// Discovery: cached index, CSS matching, fallback chains.
auto db = FontDatabase.build(sources);  // fontconfig | CoreText | DirectWrite | dirs
auto chain = db.fallbackChain(query);   // ordered, coverage-pruned, deferred
auto face = chain.faceFor(codepoint);   // memoized
```

### Architectural trade-offs the specification must decide

| Decision                        | Option A                                      | Option B                                                             | Survey leaning                                                                                               |
| ------------------------------- | --------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Table readers                   | hand-written views                            | generated at compile time from declared layouts                      | B ([fontations](./fontations.md), [go-text](./go-text-typesetting.md), [fontTools](./fonttools.md) `otData`) |
| Variation instance              | coordinates on the instance value             | instance as a new face ([DirectWrite](./directwrite.md))             | A, with the face shared                                                                                      |
| Raster target                   | per-glyph allocation                          | caller-owned region or atlas slot                                    | B ([msdfgen](./msdfgen.md), [fontdue](./fontdue.md)'s regret)                                                |
| Glyph cache                     | inside the font object                        | separate, keyed by `(face, gid, ppem bits, coords, subpixel, flags)` | B ([Skia](./skia.md), [glyphon](./glyphon.md), [cosmic-text](./cosmic-text.md))                              |
| Procedural glyphs (box drawing) | renderer special case                         | a synthetic face in the fallback chain                               | B ([Ghostty](./ghostty.md) sprite face)                                                                      |
| HarfBuzz access                 | hand-declared `extern(C)` over opaque handles | ImportC of the real headers                                          | either; no C shim in both                                                                                    |

---

## Delta: the `raylib-text` spike against the verdicts

What exists today in `libs/raylib-text` (PR #555's shaping spike over the
original `FontSet`), set against where the verdicts point.

| Capability        | Today                                                                                       | Verdict target                                                     |
| ----------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Face loading      | raylib `LoadFontEx` (stb) for the primary; FreeType `FT_New_Face` per path in `shaping_c.c` | one `Face` over borrowed bytes, any collection index               |
| Raster paths      | two: stb atlas for single codepoints, FreeType bitmaps for clusters and fallbacks           | one: D accumulation rasterizer, FreeType as test oracle            |
| Shaping           | HarfBuzz per cluster inside a C shim, no feature control                                    | HarfBuzz per run, features and coordinates as typed options        |
| Variation         | none                                                                                        | normalized coordinates on the instance, end to end                 |
| Metrics           | cell width/height, ascent only                                                              | all three metric sets, underline/strikeout, a named terminal set   |
| Outlines          | none exposed                                                                                | sink and segment array                                             |
| Colour            | `FT_LOAD_COLOR` bitmaps in the shim                                                         | `COLR` v0 in D; `CBDT`/`sbix` via FreeType until PNG decode exists |
| Discovery         | `fc-match` subprocess, CoreText by dlopen, shallow directory scan; no Linux enumeration     | cached `FaceRecord` index over per-platform sources                |
| Fallback          | fixed named fields (bold, italic, regular and Nerd fallbacks) plus up to 8 codepoint maps   | `FallbackChain`, coverage-pruned, deferred, memoized               |
| Procedural glyphs | `drawBox` special case in the renderer                                                      | a synthetic face in the chain                                      |
| Inspection        | none                                                                                        | reflectable tables, enumerations, raw access                       |
| Threading         | one `FontSet` per host, GL-bound                                                            | shareable faces and database; per-thread scratch and caches        |

## Sources

All claims above are cited in the linked deep-dives, which carry the pinned
revisions. The two programs in the survey's `examples/` directory reproduce the
measured numbers:

- [`harfbuzz-shape-features.d`](./examples/harfbuzz-shape-features.d) — feature
  inventory, axes, and `calt`/`liga` on and off.
- [`outline-sink-raster.d`](./examples/outline-sink-raster.d) — outline sink,
  variation reaching outlines, and the 71-line accumulation rasterizer.
