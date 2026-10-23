/**
Shaping with HarfBuzz, in the `engine` configuration
(`docs/specs/font/SPEC.md` § 12, FTA4, FTA8, FTS1–FTS11).

A `Shaper` owns the HarfBuzz objects of one instance: a blob borrowing
the face's bytes, a face, and a font set to the face's units per em and
to the instance's normalized coordinates exactly as stored (FTS3; no
renormalization). Every supported Unicode callback is supplied from
`sparkles:base`'s pinned tables (FTS8), and creation checks the engine
version: a HarfBuzz whose version differs from the pinned one is
`unsupportedEngine`. The Unicode-release half of the check compares
constants and so never fails, and no manifest yet shows that
HarfBuzz's internal tables match base's Unicode 18.0.0; FTS8 is not yet
met.

`shape` shapes a run range of a borrowed source with the surrounding
source as context (FTS7). Inputs are validated with base's strict UTF-8
rules before any output is written, but HarfBuzz decodes them;
capacity exhaustion returns `limitExceeded` with caller outputs
uncommitted. Results are glyph IDs and font-unit advances/offsets
(FTS1), source spans that partition the run (FTS4), and per-boundary
safety flags (FTS9). Glyph, outline and shaping caches do not exist
here (FTA5): each call shapes afresh, and HarfBuzz objects are released
with their owner (FTS5); the owner does not yet hold the face bytes'
lifetime, so it must not outlive them.
*/
module sparkles.font.shaping;

import sparkles.base.text.unicode_tables : canonicalCombiningClass, canonicalComposition,
    canonicalDecomposition, canonicalDecompositionValue, bidiMirror, generalCategory,
    GeneralCategory, script, Script, unicodeVersion;
import sparkles.base.text.utf8 : indexOfInvalidUtf8;

import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult,
    fontErr, fontOk, Tag;
import sparkles.font.harfbuzz;
import sparkles.font.instance : Instance;

@safe pure nothrow @nogc:

/// The pinned HarfBuzz version of the accepted engine profile (FTS8).
enum pinnedHarfBuzzVersion = "14.6.0";
/// The pinned base Unicode release of the accepted profile (FTS8).
enum pinnedUnicodeVersion = "18.0.0";
/// A text direction for shaping (FTS2).
enum ShapingDirection : ubyte
{
    leftToRight,
    rightToLeft,
    topToBottom,
    bottomToTop,
}

/// Segment properties resolved by the caller (FTS2, FTS8).
struct SegmentProperties
{
    @safe pure nothrow @nogc:

    ShapingDirection direction;
    /// The script as an OpenType tag (`Latn`, `Arab`, …).
    Tag script;
    /// The language as a BCP 47 string; empty is the engine default.
    const(char)[] language;
}

/**
A feature setting (FTS2): a tag, a value, and the absolute source-byte
range it applies to; without a range it applies to the whole text.
*/
struct ShapingFeature
{
    @safe pure nothrow @nogc:

    Tag tag;
    uint value;
    size_t start, end;
    bool hasRange;

    /// A setting for the whole text.
    static ShapingFeature global(Tag tag, uint value) => ShapingFeature(tag, value, 0, 0, false);
}

/// One shaped glyph (FTS1), in font units at the instance's coordinates.
struct ShapedGlyph
{
    @safe pure nothrow @nogc:

    uint glyphId;
    /// The source cluster: an absolute UTF-8 byte offset into the source.
    uint cluster;
    int xAdvance, yAdvance, xOffset, yOffset;
    /// The engine's glyph flags (FTS9): unsafe-to-break and friends.
    uint flags;
}

/// The glyph flag bits `ShapedGlyph.flags` carries (FTS9).
enum uint glyphFlagUnsafeToBreak = 1;
/// ditto
enum uint glyphFlagUnsafeToConcat = 2;
/// ditto
enum uint glyphFlagSafeToInsertTatweel = 4;

/**
A source span of the shaped run (FTS4): a half-open byte range and the
range of glyphs, in pen order, that belong to it. Spans are in source
order and partition the run; a span may hold no glyphs.
*/
struct SourceSpan
{
    @safe pure nothrow @nogc:

    size_t start, end;
    size_t glyphStart, glyphEnd;
}

/// Break/concat safety at one source boundary (FTS9).
struct BoundarySafety
{
    @safe pure nothrow @nogc:

    /// The span start this boundary sits at.
    size_t offset;
    /// Whether the engine's flags determine the other fields at all.
    bool known;
    bool unsafeToBreak;
    bool unsafeToConcat;
    bool safeToInsertTatweel;
}

/// A shaping request (FTS7): source, run range, properties, features.
struct ShapeRequest
{
    @safe pure nothrow @nogc:

    /// The whole shaping text; the run is shaped with this as context.
    const(char)[] source;
    /// The half-open run range, at scalar boundaries.
    size_t runStart, runEnd;
    SegmentProperties properties;
    /// The coordinated path: properties are used as given, never guessed.
    bool propertiesExplicit;
    const(ShapingFeature)[] features;
    /// Whether the run's edges are genuine text boundaries.
    bool beginningOfText, endOfText;
}

/// What a shaping call used and produced (FTS2, FTS7).
struct ShapeInfo
{
    @safe pure nothrow @nogc:

    size_t glyphCount, spanCount;
    ShapingDirection direction;
    Tag script;
    /// Bytes of the used language written to the caller's buffer.
    size_t languageLength;
    bool directionGuessed, scriptGuessed, languageGuessed;
    bool beginningOfText, endOfText;
}

/// The accepted engine profile and whether this build matches it (FTS8).
struct EngineProfile
{
    @safe pure nothrow @nogc:

    /// The running HarfBuzz version string.
    const(char)[] harfBuzzVersion;
    /// Base's Unicode release.
    const(char)[] unicodeRelease = unicodeVersion;
    /// Whether both match the pinned profile.
    bool compatible;
}

/**
The running engine profile (FTS8): `compatible` when the HarfBuzz
version is the pinned one and base's Unicode release is the pinned one.
A system upgrade changes the version string and so changes
`compatible`. Pinning the version does not show that HarfBuzz's
internal tables match base's release, and no manifest yet checks it.
*/
EngineProfile engineProfile() @trusted
{
    import core.stdc.string : strlen;

    const v = hb_version_string();
    const text = v[0 .. strlen(v)];
    return EngineProfile(text, unicodeVersion,
        text == pinnedHarfBuzzVersion && unicodeVersion == pinnedUnicodeVersion);
}

private FontError profileError() @trusted
{
    const v = hb_version_string();
    import core.stdc.string : strlen;

    return FontError(v[0 .. strlen(v)] == pinnedHarfBuzzVersion
        ? FontErrorKind.unsupportedUnicodeVersion : FontErrorKind.unsupportedEngine);
}

// ---------------------------------------------------------------------------
// Unicode callbacks from base (FTS8)
// ---------------------------------------------------------------------------

private hb_tag_t hbScriptOf(dchar cp) @safe pure nothrow @nogc
{
    static immutable hb_tag_t[Script.max + 1] tags = () {
        hb_tag_t[Script.max + 1] t;
        static foreach (name; __traits(allMembers, Script))
            t[__traits(getMember, Script, name)] = Tag(name).value;
        return t;
    }();
    return tags[script(cp)];
}

private extern (C) nothrow @nogc
{
    hb_unicode_general_category_t shapingCategory(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
    {
        switch (generalCategory(cast(dchar) cp))
        {
            case GeneralCategory.Cc: return hb_unicode_general_category_t.control;
            case GeneralCategory.Cf: return hb_unicode_general_category_t.format;
            case GeneralCategory.Co: return hb_unicode_general_category_t.privateUse;
            case GeneralCategory.Cs: return hb_unicode_general_category_t.surrogate;
            case GeneralCategory.Ll, GeneralCategory.LC:
                return hb_unicode_general_category_t.lowercaseLetter;
            case GeneralCategory.Lm: return hb_unicode_general_category_t.modifierLetter;
            case GeneralCategory.Lo, GeneralCategory.L:
                return hb_unicode_general_category_t.otherLetter;
            case GeneralCategory.Lt: return hb_unicode_general_category_t.titlecaseLetter;
            case GeneralCategory.Lu: return hb_unicode_general_category_t.uppercaseLetter;
            case GeneralCategory.Mc: return hb_unicode_general_category_t.spacingMark;
            case GeneralCategory.Me: return hb_unicode_general_category_t.enclosingMark;
            case GeneralCategory.Mn, GeneralCategory.M:
                return hb_unicode_general_category_t.nonSpacingMark;
            case GeneralCategory.Nd: return hb_unicode_general_category_t.decimalNumber;
            case GeneralCategory.Nl: return hb_unicode_general_category_t.letterNumber;
            case GeneralCategory.No, GeneralCategory.N:
                return hb_unicode_general_category_t.otherNumber;
            case GeneralCategory.Pc: return hb_unicode_general_category_t.connectPunctuation;
            case GeneralCategory.Pd: return hb_unicode_general_category_t.dashPunctuation;
            case GeneralCategory.Pe: return hb_unicode_general_category_t.closePunctuation;
            case GeneralCategory.Pf: return hb_unicode_general_category_t.finalPunctuation;
            case GeneralCategory.Pi: return hb_unicode_general_category_t.initialPunctuation;
            case GeneralCategory.Ps: return hb_unicode_general_category_t.openPunctuation;
            case GeneralCategory.Po, GeneralCategory.P:
                return hb_unicode_general_category_t.otherPunctuation;
            case GeneralCategory.Sc: return hb_unicode_general_category_t.currencySymbol;
            case GeneralCategory.Sk: return hb_unicode_general_category_t.modifierSymbol;
            case GeneralCategory.Sm: return hb_unicode_general_category_t.mathSymbol;
            case GeneralCategory.So, GeneralCategory.S:
                return hb_unicode_general_category_t.otherSymbol;
            case GeneralCategory.Zl: return hb_unicode_general_category_t.lineSeparator;
            case GeneralCategory.Zp: return hb_unicode_general_category_t.paragraphSeparator;
            case GeneralCategory.Zs, GeneralCategory.Z:
                return hb_unicode_general_category_t.spaceSeparator;
            default: return hb_unicode_general_category_t.unassigned;
        }
    }

    uint shapingCombiningClass(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => canonicalCombiningClass(cast(dchar) cp);

    hb_codepoint_t shapingMirroring(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => cast(hb_codepoint_t) bidiMirror(cast(dchar) cp);

    hb_tag_t shapingScript(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => hbScriptOf(cast(dchar) cp);

    hb_bool_t shapingCompose(hb_unicode_funcs_t*, hb_codepoint_t a, hb_codepoint_t b,
        hb_codepoint_t* ab, void*)
    {
        const c = canonicalComposition(cast(dchar) a, cast(dchar) b);
        if (c == 0)
            return 0;
        *ab = cast(hb_codepoint_t) c;
        return 1;
    }

    hb_bool_t shapingDecompose(hb_unicode_funcs_t*, hb_codepoint_t cp, hb_codepoint_t* a,
        hb_codepoint_t* b, void*)
    {
        const span = canonicalDecomposition(cast(dchar) cp);
        if (span.length == 0)
            return 0;
        *a = cast(hb_codepoint_t) canonicalDecompositionValue(span.offset);
        *b = span.length > 1
            ? cast(hb_codepoint_t) canonicalDecompositionValue(span.offset + 1) : 0;
        return 1;
    }
}

// ---------------------------------------------------------------------------
// Shaper (FTS3, FTS5)
// ---------------------------------------------------------------------------

/**
The HarfBuzz objects of one instance (FTS5): created from the instance,
released when the shaper is destroyed. The blob borrows the face's
bytes, which must outlive the shaper. A shaper cannot be copied.
*/
struct Shaper
{
    @safe pure nothrow @nogc:

    @disable this(this);

    private hb_blob_t* blob_;
    private hb_face_t* hbFace_;
    private hb_font_t* font_;
    private hb_unicode_funcs_t* unicodeFuncs_;
    private Instance instance_;

    ~this() @trusted
    {
        if (font_) hb_font_destroy(font_);
        if (unicodeFuncs_) hb_unicode_funcs_destroy(unicodeFuncs_);
        if (hbFace_) hb_face_destroy(hbFace_);
        if (blob_) hb_blob_destroy(blob_);
    }

    /// The instance this shaper shapes with.
    Instance instance() const return scope @safe pure nothrow @nogc => instance_;

    /**
    Shapes `request` (FTS7), writing glyphs to `glyphs`, source spans to
    `spans`, boundary safety to `boundaries` (same length as `spans`),
    and the used language to `languageOut`. Nothing is written when the
    result is an error.
    */
    FontResult!ShapeInfo shape(in ShapeRequest request, scope ShapedGlyph[] glyphs,
        scope SourceSpan[] spans, scope BoundarySafety[] boundaries, scope char[] languageOut)
        @safe nothrow @nogc
    {
        const invalid = validateRequest(request);
        if (invalid != FontError.init)
            return fontErr!ShapeInfo(invalid);
        return runShape(this, request, glyphs, spans, boundaries, languageOut);
    }
}

/**
A shaper for `inst` (FTS3, FTS5, FTS8): `unsupportedEngine` or
`unsupportedUnicodeVersion` when the running engine profile is not the
pinned one.
*/
FontResult!Shaper shaper(in Instance inst) @trusted
{
    if (!engineProfile().compatible)
        return fontErr!Shaper(profileError());
    Shaper s;
    s.instance_ = inst;
    const face = inst.face;
    const bytes = face.bytes;
    s.blob_ = hb_blob_create(cast(const(char)*) bytes.ptr, cast(uint) bytes.length,
        HB_MEMORY_MODE_READONLY, null, null);
    if (s.blob_ is null)
        return fontErr!Shaper(FontError(FontErrorKind.unsupportedEngine));
    s.hbFace_ = hb_face_create(s.blob_, face.index);
    s.font_ = hb_font_create(s.hbFace_);
    if (s.hbFace_ is null || s.font_ is null)
        return fontErr!Shaper(FontError(FontErrorKind.unsupportedEngine));
    hb_font_set_scale(s.font_, face.unitsPerEm, face.unitsPerEm);
    int[64] coords;
    foreach (i, c; inst.coords)
        coords[i] = c;
    hb_font_set_var_coords_normalized(s.font_, coords.ptr, cast(uint) inst.coords.length);
    s.unicodeFuncs_ = hb_unicode_funcs_create(null);
    hb_unicode_funcs_set_general_category_func(s.unicodeFuncs_, &shapingCategory, null, null);
    hb_unicode_funcs_set_combining_class_func(s.unicodeFuncs_, &shapingCombiningClass, null, null);
    hb_unicode_funcs_set_mirroring_func(s.unicodeFuncs_, &shapingMirroring, null, null);
    hb_unicode_funcs_set_script_func(s.unicodeFuncs_, &shapingScript, null, null);
    hb_unicode_funcs_set_compose_func(s.unicodeFuncs_, &shapingCompose, null, null);
    hb_unicode_funcs_set_decompose_func(s.unicodeFuncs_, &shapingDecompose, null, null);
    import std.algorithm.mutation : move;
    return fontOk(move(s));
}

/**
Shapes `source` with `inst` as a standalone convenience call (FTS1,
FTS2): direction, script and language are guessed and reported in the
result. Coordinated callers use a `Shaper` with explicit properties
instead (FTS8).
*/
FontResult!ShapeInfo shapeText(in Instance inst, scope const(char)[] source,
    scope ShapedGlyph[] glyphs, scope SourceSpan[] spans, scope BoundarySafety[] boundaries,
    scope char[] languageOut)
{
    auto owned = shaper(inst);
    if (owned.hasError)
        return fontErr!ShapeInfo(owned.error);
    auto request = ShapeRequest(source, 0, source.length, SegmentProperties.init, false);
    return owned.value.shape(request, glyphs, spans, boundaries, languageOut);
}

// ---------------------------------------------------------------------------
// Validation (FTS7)
// ---------------------------------------------------------------------------

private bool isBoundary(scope const(char)[] source, size_t at)
    => at == 0 || at == source.length || (cast(ubyte) source[at] & 0xC0) != 0x80;

private FontError validateRequest(in ShapeRequest request)
{
    const source = request.source;
    if (indexOfInvalidUtf8(source) != source.length)
        return FontError(FontErrorKind.invalidEncoding, Tag.init,
            indexOfInvalidUtf8(source));
    if (request.runStart > request.runEnd || request.runEnd > source.length)
        return FontError(FontErrorKind.invalidRange, Tag.init, request.runStart);
    if (!isBoundary(source, request.runStart) || !isBoundary(source, request.runEnd))
        return FontError(FontErrorKind.splitScalar, Tag.init, request.runStart);
    foreach (feature; request.features)
    {
        if (!feature.hasRange)
            continue;
        if (feature.start > feature.end || feature.start < request.runStart
            || feature.end > request.runEnd
            || !isBoundary(source, feature.start) || !isBoundary(source, feature.end))
            return FontError(FontErrorKind.invalidFeatureRange, feature.tag, feature.start);
    }
    return FontError.init;
}

// ---------------------------------------------------------------------------
// The engine call (trusted: HarfBuzz object handling only)
// ---------------------------------------------------------------------------

private FontResult!ShapeInfo runShape(ref Shaper shaper, in ShapeRequest request,
    scope ShapedGlyph[] glyphs, scope SourceSpan[] spans, scope BoundarySafety[] boundaries,
    scope char[] languageOut) @trusted
{
    auto buffer = hb_buffer_create();
    if (buffer is null)
        return fontErr!ShapeInfo(FontError(FontErrorKind.unsupportedEngine));
    scope (exit) hb_buffer_destroy(buffer);
    hb_buffer_set_unicode_funcs(buffer, shaper.unicodeFuncs_);
    hb_buffer_set_cluster_level(buffer, hb_buffer_cluster_level_t.monotoneCharacters);
    uint flags = HB_BUFFER_FLAG_PRESERVE_DEFAULT_IGNORABLES
        | HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT | HB_BUFFER_FLAG_PRODUCE_SAFE_TO_INSERT_TATWEEL;
    if (request.beginningOfText)
        flags |= HB_BUFFER_FLAG_BOT;
    if (request.endOfText)
        flags |= HB_BUFFER_FLAG_EOT;
    hb_buffer_set_flags(buffer, flags);
    const source = request.source;
    hb_buffer_add_utf8(buffer, source.ptr, cast(int) source.length,
        cast(uint) request.runStart, cast(int)(request.runEnd - request.runStart));
    if (request.propertiesExplicit)
    {
        hb_buffer_set_direction(buffer, toHbDirection(request.properties.direction));
        if (!request.properties.script.isNone)
            hb_buffer_set_script(buffer, request.properties.script.value);
        if (request.properties.language.length)
        {
            char[128] language;
            const n = request.properties.language.length < 127
                ? request.properties.language.length : 127;
            language[0 .. n] = request.properties.language[0 .. n];
            language[n] = 0;
            hb_buffer_set_language(buffer, hb_language_from_string(language.ptr, cast(int) n));
        }
    }
    else
        hb_buffer_guess_segment_properties(buffer);

    hb_feature_t[512] features;
    if (request.features.length > features.length)
        return fontErr!ShapeInfo(callerStorageError(request.features.length));
    foreach (i, feature; request.features)
        features[i] = hb_feature_t(feature.tag.value, feature.value,
            feature.hasRange ? cast(uint) feature.start : 0,
            feature.hasRange ? cast(uint) feature.end : uint.max);
    hb_shape(shaper.font_, buffer,
        request.features.length ? features.ptr : null, cast(uint) request.features.length);

    uint length;
    const infos = hb_buffer_get_glyph_infos(buffer, &length);
    const positions = hb_buffer_get_glyph_positions(buffer, &length);
    if (length > glyphs.length)
        return fontErr!ShapeInfo(callerStorageError(length));

    // Distinct cluster starts, in pen order (monotone by direction).
    size_t distinct;
    foreach (i; 0 .. length)
        if (i == 0 || infos[i].cluster != infos[i - 1].cluster)
            ++distinct;
    size_t spanCount = distinct;
    if (length == 0)
        spanCount = request.runStart < request.runEnd ? 1 : 0;
    else if (!hasCluster(infos, length, cast(uint) request.runStart))
        spanCount = distinct + 1;
    if (spanCount > spans.length)
        return fontErr!ShapeInfo(callerStorageError(spanCount, Tag.init, 0));
    if (boundaries.length && spanCount > boundaries.length)
        return fontErr!ShapeInfo(callerStorageError(spanCount, Tag.init, 0));

    foreach (i; 0 .. length)
        glyphs[i] = ShapedGlyph(infos[i].codepoint, infos[i].cluster,
            positions[i].x_advance, positions[i].y_advance,
            positions[i].x_offset, positions[i].y_offset, infos[i].mask & 0x07);

    buildSpans(request, glyphs[0 .. length], spans[0 .. spanCount]);
    foreach (i; 0 .. spanCount)
        if (i < boundaries.length)
            boundaries[i] = boundaryAt(request, glyphs[0 .. length], spans[i]);

    ShapeInfo info;
    info.glyphCount = length;
    info.spanCount = spanCount;
    info.direction = fromHbDirection(hb_buffer_get_direction(buffer));
    info.script = Tag(hb_buffer_get_script(buffer));
    info.beginningOfText = request.beginningOfText;
    info.endOfText = request.endOfText;
    info.directionGuessed = info.scriptGuessed = info.languageGuessed
        = !request.propertiesExplicit;
    if (languageOut.length)
    {
        const language = hb_language_to_string(hb_buffer_get_language(buffer));
        if (language !is null)
        {
            import core.stdc.string : strlen;

            const text = language[0 .. strlen(language)];
            const n = text.length < languageOut.length ? text.length : languageOut.length;
            languageOut[0 .. n] = text[0 .. n];
            info.languageLength = n;
        }
    }
    return fontOk(info);
}

private bool hasCluster(const(hb_glyph_info_t)* infos, uint length, uint cluster) @trusted
{
    foreach (i; 0 .. length)
        if (infos[i].cluster == cluster)
            return true;
    return false;
}

/// Fills `spans` from the shaped glyphs' clusters (FTS4).
private void buildSpans(in ShapeRequest request, scope const ShapedGlyph[] glyphs,
    scope SourceSpan[] spans) @safe pure nothrow @nogc
{
    if (spans.length == 0)
        return;
    if (glyphs.length == 0)
    {
        if (request.runStart < request.runEnd)
            spans[0] = SourceSpan(request.runStart, request.runEnd, 0, 0);
        return;
    }
    // Span starts: the run start plus every distinct cluster start.
    size_t written;
    void addStart(size_t at)
    {
        foreach (i; 0 .. written)
            if (spans[i].start == at)
                return;
        // Insert in ascending order.
        size_t i = written;
        while (i > 0 && spans[i - 1].start > at)
        {
            spans[i].start = spans[i - 1].start;
            --i;
        }
        spans[i].start = at;
        ++written;
    }

    addStart(request.runStart);
    foreach (g; glyphs)
        addStart(g.cluster);
    foreach (i; 0 .. written)
    {
        spans[i].end = i + 1 < written ? spans[i + 1].start : request.runEnd;
        // The glyphs of this span: those whose cluster is its start.
        size_t first = glyphs.length, last = glyphs.length;
        foreach (j, g; glyphs)
            if (g.cluster == spans[i].start)
            {
                if (first == glyphs.length)
                    first = j;
                last = j + 1;
            }
        spans[i].glyphStart = first;
        spans[i].glyphEnd = last;
    }
}

/// The safety view at `span`'s start (FTS9).
private BoundarySafety boundaryAt(in ShapeRequest request, scope const ShapedGlyph[] glyphs,
    in SourceSpan span) @safe pure nothrow @nogc
{
    BoundarySafety b;
    b.offset = span.start;
    if (span.glyphStart == span.glyphEnd)
        return b;
    if (span.start == request.runStart || span.start == request.runEnd)
        return b;
    b.known = true;
    foreach (g; glyphs[span.glyphStart .. span.glyphEnd])
    {
        b.unsafeToBreak |= (g.flags & glyphFlagUnsafeToBreak) != 0;
        b.unsafeToConcat |= (g.flags & glyphFlagUnsafeToConcat) != 0;
        b.safeToInsertTatweel |= (g.flags & glyphFlagSafeToInsertTatweel) != 0;
    }
    return b;
}

private hb_direction_t toHbDirection(ShapingDirection direction)
{
    final switch (direction)
    {
        case ShapingDirection.leftToRight: return hb_direction_t.ltr;
        case ShapingDirection.rightToLeft: return hb_direction_t.rtl;
        case ShapingDirection.topToBottom: return hb_direction_t.ttb;
        case ShapingDirection.bottomToTop: return hb_direction_t.btt;
    }
}

private ShapingDirection fromHbDirection(hb_direction_t direction)
{
    switch (direction)
    {
        case hb_direction_t.rtl: return ShapingDirection.rightToLeft;
        case hb_direction_t.ttb: return ShapingDirection.topToBottom;
        case hb_direction_t.btt: return ShapingDirection.bottomToTop;
        default: return ShapingDirection.leftToRight;
    }
}

// ---------------------------------------------------------------------------
// Justification candidates (FTS11)
// ---------------------------------------------------------------------------

/// A justification mode a candidate measurement may request (FTS11).
enum JustificationMode : ubyte
{
    /// Shape with explicit feature settings: a real measurement.
    featureSettings,
    /// Insert extender glyphs: font does not choose or insert them.
    extenderInsertion,
    /// Insert kashidas: font does not choose or insert them.
    kashidaInsertion,
}

/**
Measures one justification candidate (FTS11): for `featureSettings`,
the exact contextual shaped run of `request` under its feature
settings. The insertion modes are the engine capabilities font does
not have: `unsupportedCapability`, never a manufactured advance.
*/
FontResult!ShapeInfo measureJustificationCandidate(ref Shaper shaper,
    in ShapeRequest request, JustificationMode mode, scope ShapedGlyph[] glyphs,
    scope SourceSpan[] spans, scope BoundarySafety[] boundaries, scope char[] languageOut)
{
    if (mode != JustificationMode.featureSettings)
        return fontErr!ShapeInfo(FontError(FontErrorKind.unsupportedCapability));
    return shaper.shape(request, glyphs, spans, boundaries, languageOut);
}
