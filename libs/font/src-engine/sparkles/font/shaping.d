/**
Shaping with HarfBuzz, in the `engine` configuration
(`docs/specs/font/SPEC.md` § 12, FTA4, FTA8, FTS1–FTS11).

A `Shaper` owns the HarfBuzz objects of one instance: a blob borrowing
the face's bytes, a face, a font at the instance's normalized
coordinates exactly as stored (FTS3; no renormalization), and a sub-font
whose horizontal advances are the library's own (FTS1). It borrows the
instance's bytes: it cannot outlive them in `@safe` code (FTS5).

The engine profile (FTS8) is the `pinnedEngine` manifest: the HarfBuzz
release and source revision, and the Unicode release of HarfBuzz's
internal tables. Creating a shaper compares the running HarfBuzz with
the manifest (`unsupportedEngine`) and base's Unicode release with the
engine's (`unsupportedUnicodeVersion`), so neither a system upgrade nor
a base upgrade silently changes the accepted profile. Every Unicode
callback HarfBuzz takes is supplied from base's tables; `sparkles:font-
oracle` checks them against HarfBuzz's own and the manifest's internal
tables against the pinned source.

`shape` shapes a run range of a borrowed source with the surrounding
source as context (FTS7). The source is validated and decoded by base:
HarfBuzz receives scalars with their absolute byte offsets as clusters,
and up to five scalars of context either side. Results are glyph IDs,
advances and offsets as `DesignValue`s (FTS1), source spans that
partition the run (FTS4) and per-span safety flags (FTS9). Errors
publish no output. Glyph, outline and shaping caches do not exist here
(FTA5): each call shapes afresh.
*/
module sparkles.font.shaping;

import sparkles.base.text.unicode_tables : bidiMirror, canonicalCombiningClass, canonicalComposition,
    canonicalMapping, canonicalMappingValue, generalCategory, GeneralCategory, script, Script,
    unicodeVersion;
import sparkles.base.text.utf : decodeToken, UtfMode, UtfStatus;
import sparkles.base.text.utf8 : indexOfInvalidUtf8;

import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontLimit, FontResult,
    fontErr, fontLimitValue, fontOk, limitError, Tag;
import sparkles.font.harfbuzz;
import sparkles.font.instance : Instance, InstanceSize;
import sparkles.font.metrics : advance, Measurement;
import sparkles.font.outlines : PointWorkspace;
import sparkles.font.vertical : verticalAdvance, verticalOrigin;

import sparkles.base.unique : makeUnique, Unique;
import std.experimental.allocator.mallocator : Mallocator;
import sparkles.font.units : DesignValue, designSubunits;

/**
The accepted shaping-engine profile (FTS8): the HarfBuzz release and
source revision, and the Unicode release its internal tables were
generated from.
*/
struct EngineManifest
{
    /// `hb_version_string()` of the accepted engine.
    string harfBuzzVersion;
    /// The source revision the release was built from.
    string harfBuzzRevision;
    /**
    The Unicode release of HarfBuzz's internal tables that the callbacks do
    not replace: Arabic joining, Indic and USE categories, emoji, the UCD
    fallback, and the hand-coded default ignorables (checked by shaping).
    */
    string unicodeVersion;
}

/// The engine profile `sparkles:font` accepts (FTS8): HarfBuzz 14.6.0, Unicode 18.0.0.
enum EngineManifest pinnedEngine = EngineManifest("14.6.0",
    "c7a7457b7385f33178e8cf87615ca077a810bbe7", "18.0.0");

/**
Whether an engine reporting `runningVersion`, with base at
`baseUnicodeVersion`, is the accepted profile `manifest` (FTS8):
`unsupportedEngine` for any other HarfBuzz, `unsupportedUnicodeVersion`
when base's Unicode release is not the engine's; `FontError.init`
otherwise. The engine check comes first: a different engine's tables
are unknown.
*/
FontError checkEngineProfile(in EngineManifest manifest, scope const(char)[] runningVersion,
    scope const(char)[] baseUnicodeVersion) @safe pure nothrow @nogc
{
    if (runningVersion != manifest.harfBuzzVersion)
        return FontError(FontErrorKind.unsupportedEngine);
    if (baseUnicodeVersion != manifest.unicodeVersion)
        return FontError(FontErrorKind.unsupportedUnicodeVersion);
    return FontError.init;
}

///
@("shaping.checkEngineProfile.rejects")
@safe pure nothrow @nogc
unittest
{
    assert(checkEngineProfile(pinnedEngine, "14.6.0", "18.0.0") == FontError.init);
    assert(checkEngineProfile(pinnedEngine, "13.2.1", "18.0.0").kind == FontErrorKind.unsupportedEngine);
    assert(checkEngineProfile(pinnedEngine, "15.0.0", "17.0.0").kind == FontErrorKind.unsupportedEngine);
    assert(checkEngineProfile(pinnedEngine, "14.6.0", "17.0.0").kind
        == FontErrorKind.unsupportedUnicodeVersion);
    assert(checkEngineProfile(pinnedEngine, "14.6.0", "19.0.0").kind
        == FontErrorKind.unsupportedUnicodeVersion);
}

/// The running engine against the pinned profile (FTS8).
struct EngineProfile
{
    /// The running HarfBuzz version string.
    const(char)[] harfBuzzVersion;
    /// Base's Unicode release.
    const(char)[] unicodeRelease;
    /// `FontError.init` when the running engine is the pinned profile.
    FontError status;

    /// Whether the running engine is the pinned profile.
    bool compatible() const @safe pure nothrow @nogc => status == FontError.init;
}

/// The running engine profile (FTS8), checked against `pinnedEngine`.
EngineProfile engineProfile() @safe nothrow @nogc
{
    const running = runningHarfBuzzVersion();
    return EngineProfile(running, unicodeVersion, checkEngineProfile(pinnedEngine, running, unicodeVersion));
}

private const(char)[] runningHarfBuzzVersion() @trusted nothrow @nogc
{
    import core.stdc.string : strlen;

    // A static string HarfBuzz owns.
    const v = hb_version_string();
    return v[0 .. strlen(v)];
}

// ---------------------------------------------------------------------------
// Shaper (FTS3, FTS5)
// ---------------------------------------------------------------------------

/**
The HarfBuzz objects of one instance (FTS5): created from the instance,
released when the shaper is destroyed. It borrows the instance's face
bytes and cannot outlive them in `@safe` code; it cannot be copied.

`Shaper(inst)` checks the engine profile first (FTS8): `status` is then
`unsupportedEngine` or `unsupportedUnicodeVersion` when the running
engine is not `pinnedEngine`, or `limitExceeded` naming `engineBuffer`
when an allocation failed, and `shape` returns that error. A
default-initialized `Shaper` shapes nothing: `unsupportedEngine`.

Building one allocates (FTB4): HarfBuzz's objects, and the callback state
the library's advances and origins read — a `PointWorkspace` of about
2.6 MiB among it — once, in a `Unique`. Shaping allocates only inside
HarfBuzz, whose buffer the run's length bounds.
*/
struct Shaper
{
    @safe nothrow @nogc:

    @disable this(this);

    private hb_blob_t* blob_;
    private hb_face_t* hbFace_;
    private hb_font_t* parent_;
    private hb_font_t* font_;
    private hb_font_funcs_t* fontFuncs_;
    private hb_unicode_funcs_t* unicodeFuncs_;
    // Heap-owned so that its address survives moves of the shaper.
    private Unique!(AdvanceState, Mallocator, false) advances_;
    private Instance instance_;
    private FontError status_ = FontError(FontErrorKind.unsupportedEngine);

    /// The HarfBuzz objects of `inst`, borrowing its bytes.
    this(return scope const Instance inst)
    {
        instance_ = inst;
        const profile = engineProfile();
        if (!profile.compatible)
        {
            status_ = profile.status;
            return;
        }
        const face = inst.face;
        const bytes = face.bytes;
        if (bytes.length > uint.max)
            return;
        blob_ = () @trusted {
            // Read-only: HarfBuzz borrows the bytes, which outlive the shaper.
            return hb_blob_create(cast(const(char)*) bytes.ptr, cast(uint) bytes.length,
                HB_MEMORY_MODE_READONLY, null, null);
        }();
        hbFace_ = () @trusted { return hb_face_create(blob_, face.index); }();
        parent_ = () @trusted { return hb_font_create(hbFace_); }();
        const scale = face.unitsPerEm * positionsPerUnit;
        int[64] coords;
        foreach (i, c; inst.coords)
            coords[i] = c;
        () @trusted {
            hb_font_set_scale(parent_, scale, scale);
            hb_font_set_var_coords_normalized(parent_, coords.ptr, cast(uint) inst.coords.length);
        }();

        // The one allocation of the library's side, made here at setup:
        // the advance callbacks decode phantom points into its workspace.
        advances_ = makeUnique!(AdvanceState, Mallocator, false)();
        if (advances_.empty)
        {
            status_ = limitError(FontLimit.engineBuffer, Tag.init, 0);
            return;
        }
        // The state lives as long as the shaper, which cannot outlive `inst`.
        () @trusted {
            advances_.get.instance = inst;
            advances_.get.parent = parent_;
        }();
        fontFuncs_ = () @trusted { return hb_font_funcs_create(); }();
        () @trusted {
            hb_font_funcs_set_glyph_h_advance_func(fontFuncs_, &advanceThunk, null, null);
            hb_font_funcs_set_glyph_v_advance_func(fontFuncs_, &verticalAdvanceThunk, null, null);
            hb_font_funcs_set_glyph_v_origin_func(fontFuncs_, &verticalOriginThunk, null, null);
            hb_font_funcs_make_immutable(fontFuncs_);
        }();
        // The sub-font inherits the scale and coordinates and defers every
        // function but the advances and the vertical origin to HarfBuzz's own.
        font_ = () @trusted { return hb_font_create_sub_font(parent_); }();
        () @trusted { hb_font_set_funcs(font_, fontFuncs_, advances_.ptr, null); }();

        unicodeFuncs_ = () @trusted { return hb_unicode_funcs_create(null); }();
        () @trusted {
            hb_unicode_funcs_set_general_category_func(unicodeFuncs_, &categoryThunk, null, null);
            hb_unicode_funcs_set_combining_class_func(unicodeFuncs_, &combiningClassThunk, null, null);
            hb_unicode_funcs_set_mirroring_func(unicodeFuncs_, &mirroringThunk, null, null);
            hb_unicode_funcs_set_script_func(unicodeFuncs_, &scriptThunk, null, null);
            hb_unicode_funcs_set_compose_func(unicodeFuncs_, &composeThunk, null, null);
            hb_unicode_funcs_set_decompose_func(unicodeFuncs_, &decomposeThunk, null, null);
            hb_unicode_funcs_make_immutable(unicodeFuncs_);
        }();
        status_ = FontError.init;
    }

    ~this() scope @trusted
    {
        // Each handle was created by this shaper and is destroyed once.
        if (font_) hb_font_destroy(font_);
        if (parent_) hb_font_destroy(parent_);
        if (fontFuncs_) hb_font_funcs_destroy(fontFuncs_);
        if (unicodeFuncs_) hb_unicode_funcs_destroy(unicodeFuncs_);
        if (hbFace_) hb_face_destroy(hbFace_);
        if (blob_) hb_blob_destroy(blob_);
    }

    /// The instance this shaper shapes with.
    Instance instance() const return scope => instance_;

    /// `FontError.init` when the shaper is ready; otherwise why it is not.
    FontError status() const scope => status_;

    /**
    Shapes `request` (FTS7), writing glyphs to `glyphs`, source spans to
    `spans`, boundary safety to `boundaries` (empty, or at least as long
    as the spans), and the used language to `languageOut` (empty when
    not wanted). Nothing is written when the result is an error.

    Errors, before any output: `invalidEncoding` at the first invalid
    byte; `invalidRange` for an inverted or out-of-source run;
    `splitScalar` for a run edge inside a scalar; `invalidFeatureRange`
    for a feature range outside the run or splitting a scalar; `badValue`
    for explicit properties without a script; `limitExceeded` naming
    `shapingFeatures` past 512 features, `engineBuffer` when HarfBuzz
    cannot grow its buffer or the run spends its operation budget (the
    lookups left unapplied, so no partial run is returned as shaped), or
    `callerStorage` with the length a short output needs; an advance's own
    error.

    Cost: O(c) to validate and decode a source of `c` bytes; HarfBuzz's
    shaping, which allocates its buffer (at most max(65,536, 256 × n)
    glyphs for `n` scalars) and stops applying lookups silently after
    max(65,536, 4,096 × n) operations; O(g) to publish `g` glyphs.
    */
    FontResult!ShapeInfo shape(in ShapeRequest request, scope ShapedGlyph[] glyphs,
        scope SourceSpan[] spans, scope BoundarySafety[] boundaries, scope char[] languageOut) scope
    {
        if (status_ != FontError.init)
            return fontErr!ShapeInfo(status_);
        const invalid = validateRequest(request);
        if (invalid != FontError.init)
            return fontErr!ShapeInfo(invalid);
        if (request.features.length > fontLimitValue[FontLimit.shapingFeatures])
            return fontErr!ShapeInfo(limitError(FontLimit.shapingFeatures, Tag.init, 0));
        return runShape(this, request, glyphs, spans, boundaries, languageOut);
    }
}

/**
Shapes `source` with `inst` as a standalone convenience call (FTS1,
FTS2): direction, script and language are guessed and reported in the
result. Coordinated callers use a `Shaper` with explicit properties
instead (FTS8).
*/
FontResult!ShapeInfo shapeText(in Instance inst, scope const(char)[] source,
    scope ShapedGlyph[] glyphs, scope SourceSpan[] spans, scope BoundarySafety[] boundaries,
    scope char[] languageOut) @safe nothrow @nogc
{
    auto owned = Shaper(inst);
    auto request = ShapeRequest(source, 0, source.length, SegmentProperties.init, false);
    return owned.shape(request, glyphs, spans, boundaries, languageOut);
}

// ---------------------------------------------------------------------------
// The engine call
// ---------------------------------------------------------------------------

private FontResult!ShapeInfo runShape(scope ref Shaper shaper, in ShapeRequest request,
    scope ShapedGlyph[] glyphs, scope SourceSpan[] spans, scope BoundarySafety[] boundaries,
    scope char[] languageOut) @safe nothrow @nogc
{
    auto buffer = () @trusted { return hb_buffer_create(); }();
    scope (exit) () @trusted { hb_buffer_destroy(buffer); }();
    uint flags = HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT | HB_BUFFER_FLAG_PRODUCE_SAFE_TO_INSERT_TATWEEL;
    if (request.beginningOfText)
        flags |= HB_BUFFER_FLAG_BOT;
    if (request.endOfText)
        flags |= HB_BUFFER_FLAG_EOT;
    () @trusted {
        hb_buffer_set_unicode_funcs(buffer, shaper.unicodeFuncs_);
        hb_buffer_set_cluster_level(buffer, hb_buffer_cluster_level_t.monotoneCharacters);
        hb_buffer_set_flags(buffer, flags);
    }();

    // Base decodes; HarfBuzz receives scalars and their byte offsets.
    const source = request.source;
    hb_codepoint_t[contextLength] before, after;
    const nBefore = contextScalars(source, 0, request.runStart, true, before[]);
    const nAfter = contextScalars(source, request.runEnd, source.length, false, after[]);
    // An empty buffer takes the scalars before `itemOffset` as pre-context.
    () @trusted { hb_buffer_add_codepoints(buffer, before.ptr, cast(int) nBefore, cast(uint) nBefore, 0); }();
    for (size_t at = request.runStart; at < request.runEnd;)
    {
        const d = decodeToken(source[at .. request.runEnd], UtfMode.strict, true, at);
        () @trusted { hb_buffer_add(buffer, d.token.scalar, cast(uint) at); }();
        at = d.token.end;
    }
    // A zero-length item after the text installs its post-context.
    () @trusted { hb_buffer_add_codepoints(buffer, after.ptr, cast(int) nAfter, 0, 0); }();
    if (!() @trusted { return hb_buffer_allocation_successful(buffer); }())
        return fontErr!ShapeInfo(limitError(FontLimit.engineBuffer, Tag.init, request.runStart));

    if (request.propertiesExplicit)
    {
        const language = request.properties.language;
        () @trusted {
            hb_buffer_set_direction(buffer, toHbDirection(request.properties.direction));
            hb_buffer_set_script(buffer, request.properties.script.value);
            if (language.length)
                hb_buffer_set_language(buffer, hb_language_from_string(language.ptr,
                    cast(int)(language.length < int.max ? language.length : int.max)));
        }();
    }
    else
        () @trusted { hb_buffer_guess_segment_properties(buffer); }();

    enum maxFeatures = fontLimitValue[FontLimit.shapingFeatures];
    hb_feature_t[maxFeatures] features;
    foreach (i, feature; request.features)
        features[i] = hb_feature_t(feature.tag.value, feature.value,
            feature.hasRange ? cast(uint) feature.start : 0,
            feature.hasRange ? cast(uint) feature.end : uint.max);
    const featureCount = cast(uint) request.features.length;
    () @trusted { shaper.advances_.get.error = FontError.init; }();
    const shaped = () @trusted {
        return hb_shape_full(shaper.font_, buffer, featureCount ? features.ptr : null, featureCount, null);
    }();
    if (!shaped || !() @trusted { return hb_buffer_allocation_successful(buffer); }())
        return fontErr!ShapeInfo(limitError(FontLimit.engineBuffer, Tag.init, request.runStart));
    const callbackError = () @trusted { return shaper.advances_.get.error; }();
    if (callbackError != FontError.init)
        return fontErr!ShapeInfo(callbackError);

    const infos = () @trusted {
        uint n;
        const p = hb_buffer_get_glyph_infos(buffer, &n);
        return p is null ? null : p[0 .. n];
    }();
    const positions = () @trusted {
        uint n;
        const p = hb_buffer_get_glyph_positions(buffer, &n);
        return p is null ? null : p[0 .. n];
    }();
    if (positions.length != infos.length)
        return fontErr!ShapeInfo(limitError(FontLimit.engineBuffer, Tag.init, request.runStart));
    const direction = fromHbDirection(() @trusted { return hb_buffer_get_direction(buffer); }());
    const script = Tag(() @trusted { return hb_buffer_get_script(buffer); }());
    const language = () @trusted {
        import core.stdc.string : strlen;

        // HarfBuzz interns languages for the process's lifetime.
        const l = hb_language_to_string(hb_buffer_get_language(buffer));
        return l is null ? null : l[0 .. strlen(l)];
    }();

    // Every check precedes the first write (FTS7).
    const layout = spanLayout(request, infos, isBackward(direction));
    if (layout.hasError)
        return fontErr!ShapeInfo(layout.error);
    const spanCount = layout.value;
    if (infos.length > glyphs.length)
        return fontErr!ShapeInfo(callerStorageError(infos.length));
    if (spanCount > spans.length)
        return fontErr!ShapeInfo(callerStorageError(spanCount));
    if (boundaries.length && spanCount > boundaries.length)
        return fontErr!ShapeInfo(callerStorageError(spanCount));
    if (languageOut.length && language.length > languageOut.length)
        return fontErr!ShapeInfo(callerStorageError(language.length));

    const upem = shaper.instance_.unitsPerEm;
    DesignValue design(int position) => DesignValue(position * rawPerPosition, upem);
    foreach (i, info; infos)
        glyphs[i] = ShapedGlyph(info.codepoint, info.cluster, design(positions[i].x_advance),
            design(positions[i].y_advance), design(positions[i].x_offset),
            design(positions[i].y_offset), info.mask & HB_GLYPH_FLAG_DEFINED);
    buildSpans(request, glyphs[0 .. infos.length], isBackward(direction), spans[0 .. spanCount]);
    if (boundaries.length)
        foreach (i; 0 .. spanCount)
            boundaries[i] = boundaryAt(request, glyphs[0 .. infos.length], spans[i]);

    ShapeInfo info;
    info.glyphCount = infos.length;
    info.spanCount = spanCount;
    info.direction = direction;
    info.script = script;
    info.beginningOfText = request.beginningOfText;
    info.endOfText = request.endOfText;
    info.directionGuessed = info.scriptGuessed = !request.propertiesExplicit;
    info.languageGuessed = !request.propertiesExplicit || request.properties.language.length == 0;
    info.size = shaper.instance_.size;
    if (languageOut.length)
    {
        languageOut[0 .. language.length] = language[];
        info.languageLength = language.length;
    }
    return fontOk(info);
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
    /// Apply a `JSTF` maximum record's own lookups: the engine cannot.
    maximumLookups,
}

/**
Measures one justification candidate (FTS11): for `featureSettings`,
the exact contextual shaped run of `request` under its feature
settings. The other modes are capabilities the pinned engine does not
have: `unsupportedCapability`, never a manufactured advance.
*/
FontResult!ShapeInfo measureJustificationCandidate(scope ref Shaper shaper,
    in ShapeRequest request, JustificationMode mode, scope ShapedGlyph[] glyphs,
    scope SourceSpan[] spans, scope BoundarySafety[] boundaries, scope char[] languageOut)
    @safe nothrow @nogc
{
    if (mode != JustificationMode.featureSettings)
        return fontErr!ShapeInfo(FontError(FontErrorKind.unsupportedCapability));
    return shaper.shape(request, glyphs, spans, boundaries, languageOut);
}

// ---------------------------------------------------------------------------
// Advances (FTS1)
// ---------------------------------------------------------------------------

/// HarfBuzz positions per font unit: the font's scale is `unitsPerEm` times this.
private enum int positionsPerUnit = 1_024;
/// `DesignValue.raw` steps per HarfBuzz position.
private enum long rawPerPosition = designSubunits / positionsPerUnit;

/**
What the advance and origin callbacks read: the instance, the HarfBuzz
font they defer to where the face defines no vertical metrics, the
workspace phantom points decode into, and the first error a callback
gave, which `shape` returns in place of the run.
*/
private struct AdvanceState
{
    Instance instance;
    hb_font_t* parent;
    FontError error;
    PointWorkspace points;
}

/// Records `error` unless an earlier one is kept.
private void keepFirst(AdvanceState* state, FontError error) @system nothrow @nogc
{
    if (state.error == FontError.init)
        state.error = error;
}

/// `raw` design steps as HarfBuzz positions, or `arithmeticExhausted` past `int`.
private bool toPosition(long raw, out hb_position_t position) @safe pure nothrow @nogc
{
    const p = toPositions(raw);
    if (p < -int.max || p > int.max)
        return false;
    position = cast(hb_position_t) p;
    return true;
}

/// `raw` design steps rounded to the nearest HarfBuzz position, ties away from zero.
private long toPositions(long raw) @safe pure nothrow @nogc
    => raw >= 0 ? (raw + rawPerPosition / 2) / rawPerPosition : -((-raw + rawPerPosition / 2) / rawPerPosition);

private extern (C) hb_position_t advanceThunk(hb_font_t*, void* fontData, hb_codepoint_t glyph, void*)
    @system nothrow @nogc
{
    auto state = cast(AdvanceState*) fontData;
    const a = advance(state.instance, glyph, state.points);
    if (a.hasError)
    {
        keepFirst(state, a.error);
        return 0;
    }
    hb_position_t p;
    if (!toPosition(a.value.design.raw, p))
        keepFirst(state, FontError(FontErrorKind.arithmeticExhausted));
    return p;
}

/**
The vertical advance (FTM20), negated as HarfBuzz's y grows up. A face
without `vhea` and `vmtx` has none, and HarfBuzz's synthesized advance —
its line height — stands in: the engine's fallback, not the font's.
*/
private extern (C) hb_position_t verticalAdvanceThunk(hb_font_t*, void* fontData,
    hb_codepoint_t glyph, void*) @system nothrow @nogc
{
    auto state = cast(AdvanceState*) fontData;
    const a = verticalAdvance(state.instance, glyph, state.points);
    if (a.hasError)
    {
        keepFirst(state, a.error);
        return 0;
    }
    if (!a.value.present)
        return hb_font_get_glyph_v_advance(state.parent, glyph);
    hb_position_t p;
    if (!toPosition(a.value.advance.design.raw, p))
        keepFirst(state, FontError(FontErrorKind.arithmeticExhausted));
    return -p;
}

/**
The vertical origin (FTM21): x is half the horizontal advance, truncated
as HarfBuzz halves it; y is the library's origin. A face with neither
`VORG` nor `vmtx` with `glyf` has none, and HarfBuzz's synthesized y — the
glyph centred on the line — stands in: the engine's fallback.
*/
private extern (C) hb_bool_t verticalOriginThunk(hb_font_t*, void* fontData, hb_codepoint_t glyph,
    hb_position_t* x, hb_position_t* y, void*) @system nothrow @nogc
{
    auto state = cast(AdvanceState*) fontData;
    *x = *y = 0;
    const h = advance(state.instance, glyph, state.points);
    if (h.hasError)
    {
        keepFirst(state, h.error);
        return true;
    }
    hb_position_t half;
    if (!toPosition(h.value.design.raw, half))
        keepFirst(state, FontError(FontErrorKind.arithmeticExhausted));
    *x = half / 2;
    const o = verticalOrigin(state.instance, glyph, state.points);
    if (o.hasError)
    {
        keepFirst(state, o.error);
        return true;
    }
    if (!o.value.present)
    {
        hb_position_t ignored;
        hb_font_get_glyph_v_origin(state.parent, glyph, &ignored, y);
        return true;
    }
    if (!toPosition(o.value.y.design.raw, *y))
        keepFirst(state, FontError(FontErrorKind.arithmeticExhausted));
    return true;
}

// ---------------------------------------------------------------------------
// Values (pure from here on)
// ---------------------------------------------------------------------------

@safe pure nothrow @nogc:

/// A text direction for shaping (FTS2).
enum ShapingDirection : ubyte
{
    leftToRight,
    rightToLeft,
    topToBottom,
    bottomToTop,
}

/// Whether `direction` lays glyphs out against source order.
bool isBackward(ShapingDirection direction)
    => direction == ShapingDirection.rightToLeft || direction == ShapingDirection.bottomToTop;

/// Segment properties resolved by the caller (FTS2, FTS8).
struct SegmentProperties
{
    @safe pure nothrow @nogc:

    ShapingDirection direction;
    /// The script as an OpenType tag (`Latn`, `Arab`, …); required when explicit.
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

/**
One shaped glyph (FTS1). Advances and offsets are design values at the
instance's coordinates, multiples of 1/1,024 font unit;
`ShapeInfo.measured` gives their pixel and physical forms (FTM4, FTM6).
Offsets are from the glyph's pen position.
*/
struct ShapedGlyph
{
    @safe pure nothrow @nogc:

    uint glyphId;
    /// The source cluster: an absolute UTF-8 byte offset into the source.
    uint cluster;
    DesignValue xAdvance, yAdvance, xOffset, yOffset;
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
order and partition the run; a span with no glyphs has
`glyphStart == glyphEnd`.
*/
struct SourceSpan
{
    @safe pure nothrow @nogc:

    size_t start, end;
    size_t glyphStart, glyphEnd;
}

/**
Break/concat safety at the start of one source span (FTS9). `known` is
false at a run edge and for a span with no glyphs: nothing there is
reusable. The tatweel hint is known only when the span's glyphs agree.
*/
struct BoundarySafety
{
    @safe pure nothrow @nogc:

    /// The span start this boundary sits at.
    size_t offset;
    /// Whether the engine's flags determine the break/concat fields at all.
    bool known;
    /// The union of the span's glyphs' flags.
    bool unsafeToBreak, unsafeToConcat;
    /// Whether every glyph of the span allows a tatweel; meaningful when `tatweelKnown`.
    bool safeToInsertTatweel;
    /// Whether the span's glyphs agree on the tatweel hint.
    bool tatweelKnown;
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
    /// The size of the instance shaped with.
    InstanceSize size;

    /// `value` with its pixel and physical conversions at the instance (FTM4, FTM6).
    Measurement measured(DesignValue value) const => Measurement(value, size);
}

// ---------------------------------------------------------------------------
// Unicode callbacks from base (FTS8)
// ---------------------------------------------------------------------------

/// The general category HarfBuzz receives for `cp`, from base.
hb_unicode_general_category_t engineGeneralCategory(dchar cp)
{
    alias C = hb_unicode_general_category_t;
    switch (generalCategory(cp))
    {
        case GeneralCategory.Cc: return C.control;
        case GeneralCategory.Cf: return C.format;
        case GeneralCategory.Co: return C.privateUse;
        case GeneralCategory.Cs: return C.surrogate;
        case GeneralCategory.Ll, GeneralCategory.LC: return C.lowercaseLetter;
        case GeneralCategory.Lm: return C.modifierLetter;
        case GeneralCategory.Lo, GeneralCategory.L: return C.otherLetter;
        case GeneralCategory.Lt: return C.titlecaseLetter;
        case GeneralCategory.Lu: return C.uppercaseLetter;
        case GeneralCategory.Mc: return C.spacingMark;
        case GeneralCategory.Me: return C.enclosingMark;
        case GeneralCategory.Mn, GeneralCategory.M: return C.nonSpacingMark;
        case GeneralCategory.Nd: return C.decimalNumber;
        case GeneralCategory.Nl: return C.letterNumber;
        case GeneralCategory.No, GeneralCategory.N: return C.otherNumber;
        case GeneralCategory.Pc: return C.connectPunctuation;
        case GeneralCategory.Pd: return C.dashPunctuation;
        case GeneralCategory.Pe: return C.closePunctuation;
        case GeneralCategory.Pf: return C.finalPunctuation;
        case GeneralCategory.Pi: return C.initialPunctuation;
        case GeneralCategory.Ps: return C.openPunctuation;
        case GeneralCategory.Po, GeneralCategory.P: return C.otherPunctuation;
        case GeneralCategory.Sc: return C.currencySymbol;
        case GeneralCategory.Sk: return C.modifierSymbol;
        case GeneralCategory.Sm: return C.mathSymbol;
        case GeneralCategory.So, GeneralCategory.S: return C.otherSymbol;
        case GeneralCategory.Zl: return C.lineSeparator;
        case GeneralCategory.Zp: return C.paragraphSeparator;
        case GeneralCategory.Zs, GeneralCategory.Z: return C.spaceSeparator;
        default: return C.unassigned;
    }
}

/// The canonical combining class HarfBuzz receives for `cp`, from base.
uint engineCombiningClass(dchar cp) => canonicalCombiningClass(cp);

/// The Bidi_Mirroring_Glyph HarfBuzz receives for `cp` (itself when none), from base.
dchar engineMirroring(dchar cp) => bidiMirror(cp);

/// The script HarfBuzz receives for `cp`, as its ISO 15924 tag, from base.
hb_tag_t engineScript(dchar cp)
{
    static immutable hb_tag_t[Script.max + 1] tags = () {
        hb_tag_t[Script.max + 1] t;
        static foreach (name; __traits(allMembers, Script))
            t[__traits(getMember, Script, name)] = Tag(name).value;
        return t;
    }();
    return tags[script(cp)];
}

/**
The primary composite of `a` + `b`, or 0 when they do not compose, from
base (whose `canonicalComposition` says "none" with `dchar.init`).
*/
dchar engineCompose(dchar a, dchar b)
{
    const c = canonicalComposition(a, b);
    return c == dchar.init ? 0 : c;
}

/**
One step of `cp`'s canonical decomposition, from base's
`canonicalMapping`: `[a, b]`, `[a, 0]` for a singleton, or `[0, 0]`
when `cp` does not decompose. This is the step HarfBuzz's decompose
callback expects, not the full decomposition.
*/
dchar[2] engineDecompose(dchar cp)
{
    const m = canonicalMapping(cp);
    dchar[2] parts = 0;
    foreach (i; 0 .. m.length)
        parts[i] = canonicalMappingValue(m.offset + i);
    return parts;
}

///
@("shaping.engineDecompose.singleStep")
unittest
{
    assert(engineDecompose(0x1E09) == [dchar(0xE7), 0x301]);
    assert(engineDecompose(0x212B) == [dchar(0xC5), 0]);
    assert(engineDecompose(0xAC01) == [dchar(0xAC00), 0x11A8]);
    assert(engineDecompose('a') == [dchar(0), 0]);
    assert(engineCompose(0xE7, 0x301) == 0x1E09);
    // U+0344 decomposes to these, but is excluded from composition.
    assert(engineCompose(0x308, 0x301) == 0 && engineCompose('a', 'b') == 0);
}

private extern (C) @system nothrow @nogc
{
    hb_unicode_general_category_t categoryThunk(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => engineGeneralCategory(cast(dchar) cp);

    uint combiningClassThunk(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => engineCombiningClass(cast(dchar) cp);

    hb_codepoint_t mirroringThunk(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => engineMirroring(cast(dchar) cp);

    hb_tag_t scriptThunk(hb_unicode_funcs_t*, hb_codepoint_t cp, void*)
        => engineScript(cast(dchar) cp);

    hb_bool_t composeThunk(hb_unicode_funcs_t*, hb_codepoint_t a, hb_codepoint_t b,
        hb_codepoint_t* ab, void*)
    {
        const c = engineCompose(cast(dchar) a, cast(dchar) b);
        if (c == 0)
            return 0;
        *ab = c;
        return 1;
    }

    hb_bool_t decomposeThunk(hb_unicode_funcs_t*, hb_codepoint_t ab, hb_codepoint_t* a,
        hb_codepoint_t* b, void*)
    {
        const parts = engineDecompose(cast(dchar) ab);
        if (parts[0] == 0)
            return 0;
        *a = parts[0];
        *b = parts[1];
        return 1;
    }
}

// ---------------------------------------------------------------------------
// Validation (FTS7)
// ---------------------------------------------------------------------------

private bool isBoundary(scope const(char)[] source, size_t at)
    => at == 0 || at == source.length || (cast(ubyte) source[at] & 0xC0) != 0x80;

package FontError validateRequest(in ShapeRequest request)
{
    const source = request.source;
    const invalidAt = indexOfInvalidUtf8(source);
    if (invalidAt != source.length)
        return FontError(FontErrorKind.invalidEncoding, Tag.init, invalidAt);
    if (request.runStart > request.runEnd)
        return FontError(FontErrorKind.invalidRange, Tag.init, request.runStart);
    if (request.runEnd > source.length)
        return FontError(FontErrorKind.invalidRange, Tag.init, request.runEnd);
    if (request.runEnd > uint.max)
        return limitError(FontLimit.engineBuffer, Tag.init, request.runEnd);
    if (!isBoundary(source, request.runStart))
        return FontError(FontErrorKind.splitScalar, Tag.init, request.runStart);
    if (!isBoundary(source, request.runEnd))
        return FontError(FontErrorKind.splitScalar, Tag.init, request.runEnd);
    foreach (feature; request.features)
    {
        if (!feature.hasRange)
            continue;
        if (feature.start > feature.end || feature.start < request.runStart
            || feature.end > request.runEnd || !isBoundary(source, feature.start))
            return FontError(FontErrorKind.invalidFeatureRange, feature.tag, feature.start);
        if (!isBoundary(source, feature.end))
            return FontError(FontErrorKind.invalidFeatureRange, feature.tag, feature.end);
    }
    if (request.propertiesExplicit && request.properties.script.isNone)
        return FontError(FontErrorKind.badValue);
    return FontError.init;
}

// ---------------------------------------------------------------------------
// Decoding (FTS7)
// ---------------------------------------------------------------------------

/// The scalars of `source[from .. to]` in source order: at most `out_.length`, from the end when `last`.
private size_t contextScalars(scope const(char)[] source, size_t from, size_t to, bool last,
    scope hb_codepoint_t[] out_)
{
    // Scalar starts, walking back from `to` when the last ones are wanted.
    size_t start = from;
    if (last)
    {
        size_t at = to, count;
        while (at > from && count < out_.length)
        {
            --at;
            while (at > from && !isBoundary(source, at))
                --at;
            ++count;
        }
        start = at;
    }
    size_t n;
    size_t at = start;
    while (at < to && n < out_.length)
    {
        const d = decodeToken(source[at .. to], UtfMode.strict, true, at);
        // The source was validated: every token decodes.
        out_[n++] = d.token.scalar;
        at = d.token.end;
    }
    return n;
}

private enum size_t contextLength = 5;

/**
The number of source spans the shaped `infos` give (FTS4), checking the
monotone-character contract: cluster starts in pen order ascend for a
forward run and descend for a backward one, within the run.
*/
private FontResult!size_t spanLayout(in ShapeRequest request, scope const(hb_glyph_info_t)[] infos,
    bool backward)
{
    if (infos.length == 0)
        return fontOk!size_t(request.runStart < request.runEnd ? 1 : 0);
    size_t distinct = 1;
    foreach (i, info; infos)
    {
        if (info.cluster < request.runStart || info.cluster >= request.runEnd)
            return fontErr!size_t(FontError(FontErrorKind.unsupportedEngine));
        if (i == 0)
            continue;
        const previous = infos[i - 1].cluster;
        if (backward ? info.cluster > previous : info.cluster < previous)
            return fontErr!size_t(FontError(FontErrorKind.unsupportedEngine));
        distinct += info.cluster != previous;
    }
    const first = backward ? infos[$ - 1].cluster : infos[0].cluster;
    return fontOk!size_t(distinct + (first > request.runStart));
}

/**
Fills `spans` from `glyphs`' monotone clusters (FTS4), in source order:
a leading glyphless span when the first cluster starts after the run,
then one span per distinct cluster start, each holding its contiguous
pen-order glyphs. Linear in the glyph count.
*/
private void buildSpans(in ShapeRequest request, scope const ShapedGlyph[] glyphs, bool backward,
    scope SourceSpan[] spans)
{
    if (glyphs.length == 0)
    {
        if (spans.length)
            spans[0] = SourceSpan(request.runStart, request.runEnd, 0, 0);
        return;
    }
    size_t written;
    // Source order visits pen order forwards, or backwards for RTL/BTT.
    size_t penAt(size_t k) => backward ? glyphs.length - 1 - k : k;
    const firstCluster = glyphs[penAt(0)].cluster;
    if (firstCluster > request.runStart)
        spans[written++] = SourceSpan(request.runStart, firstCluster, glyphs.length, glyphs.length);
    size_t k;
    while (k < glyphs.length)
    {
        const cluster = glyphs[penAt(k)].cluster;
        size_t j = k + 1;
        while (j < glyphs.length && glyphs[penAt(j)].cluster == cluster)
            ++j;
        // Pen-order indices of source positions k .. j.
        const a = penAt(k), b = penAt(j - 1);
        const lo = a < b ? a : b, hi = a < b ? b : a;
        const end = j < glyphs.length ? glyphs[penAt(j)].cluster : request.runEnd;
        spans[written++] = SourceSpan(cluster, end, lo, hi + 1);
        k = j;
    }
}

/// The safety view at `span`'s start (FTS9).
private BoundarySafety boundaryAt(in ShapeRequest request, scope const ShapedGlyph[] glyphs,
    in SourceSpan span)
{
    BoundarySafety b;
    b.offset = span.start;
    if (span.glyphStart == span.glyphEnd || span.start == request.runStart)
        return b;
    b.known = true;
    size_t tatweel;
    foreach (g; glyphs[span.glyphStart .. span.glyphEnd])
    {
        b.unsafeToBreak |= (g.flags & glyphFlagUnsafeToBreak) != 0;
        b.unsafeToConcat |= (g.flags & glyphFlagUnsafeToConcat) != 0;
        tatweel += (g.flags & glyphFlagSafeToInsertTatweel) != 0;
    }
    const count = span.glyphEnd - span.glyphStart;
    b.tatweelKnown = tatweel == 0 || tatweel == count;
    b.safeToInsertTatweel = tatweel == count;
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
