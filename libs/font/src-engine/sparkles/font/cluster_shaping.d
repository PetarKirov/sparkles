/**
Shaping one grapheme cluster, behind a narrow interface: an opaque shaper,
and glyphs with their advances and offsets already in pixels.

The module imports nothing at its top level, and its functions import the
engine only inside their bodies, which only the font library's own build
compiles. A consumer that names these functions therefore never analyses the
engine's modules in its own build. A renderer whose build holds ImportC
modules needs that: analysing the engine there made the frontend list a
`ModuleInfo` for an ImportC module, which never has one, and the link failed.
*/
module sparkles.font.cluster_shaping;

/// The most glyphs one call shapes a cluster to: `shapeCluster` writes at
/// most this many, and a cluster needing more is refused whole.
enum size_t maxClusterGlyphs = 64;

/// A shaper of one face, made by `openClusterShaper`.
struct ClusterShaper;

/// One glyph of a shaped cluster, in pixels at the size the caller named.
struct ClusterGlyph
{
    uint glyph;     /// the face's glyph id; 0 when the face has none
    double advance; /// pixels to the next glyph's pen
    double xOffset; /// pixels right of this glyph's pen
    double yOffset; /// pixels up from the baseline
}

/**
A shaper for `instance` (a `sparkles.font.Instance`, which must outlive
it), or null when the engine cannot shape — not linked, an incompatible
HarfBuzz, or no memory.
*/
ClusterShaper* openClusterShaper(const(void)* instance) @system nothrow @nogc
{
    import core.lifetime : emplace;
    import core.stdc.stdlib : malloc;
    import sparkles.font.errors : FontError;
    import sparkles.font.instance : Instance;
    import sparkles.font.shaping : Shaper;

    if (instance is null)
        return null;
    auto memory = () @trusted { return malloc(Shaper.sizeof); }();
    if (memory is null)
        return null;
    // The one place the type-erased instance is taken on trust.
    auto shaper = () @trusted {
        return emplace(cast(Shaper*) memory, *cast(const(Instance)*) instance);
    }();
    if (shaper.status != FontError.init)
    {
        closeClusterShaper(cast(ClusterShaper*) memory);
        return null;
    }
    return cast(ClusterShaper*) memory;
}

/**
Shapes the UTF-8 cluster `text` with `shaper` at `ppemNumerator /
ppemDenominator` pixels per em into `glyphs`: how many it wrote, or 0 when
shaping failed or `glyphs` is too short.
*/
size_t shapeCluster(ClusterShaper* shaper, scope const(char)[] text, ulong ppemNumerator,
    ulong ppemDenominator, scope ClusterGlyph[] glyphs) @system nothrow @nogc
{
    import sparkles.base.text.layout_units : I128, Rational, U128;
    import sparkles.font.shaping : SegmentProperties, ShapedGlyph, ShapeRequest, Shaper, SourceSpan;
    import sparkles.font.units : Ppem, toPixels;

    if (shaper is null || text.length == 0)
        return 0;
    const ppem = Ppem.fromRational(Rational(I128(U128(ppemNumerator, 0)), U128(ppemDenominator, 0)));
    if (ppem.hasError)
        return 0;
    ShapedGlyph[maxClusterGlyphs] shaped;
    SourceSpan[maxClusterGlyphs] spans;
    if (glyphs.length > shaped.length)
        glyphs = glyphs[0 .. shaped.length];
    const result = (cast(Shaper*) shaper).shape(ShapeRequest(text, 0, text.length, SegmentProperties.init,
        false, null, true, true), shaped[0 .. glyphs.length], spans[], null, null);
    if (result.hasError)
        return 0;
    foreach (i, g; shaped[0 .. result.value.glyphCount])
        glyphs[i] = ClusterGlyph(g.glyphId, toPixels(g.xAdvance, ppem.value), toPixels(g.xOffset, ppem.value),
            toPixels(g.yOffset, ppem.value));
    return result.value.glyphCount;
}

/// Destroys a shaper `openClusterShaper` made; null is ignored.
void closeClusterShaper(ClusterShaper* shaper) @system nothrow @nogc
{
    import core.stdc.stdlib : free;
    import sparkles.font.shaping : Shaper;

    if (shaper is null)
        return;
    () @trusted {
        (cast(Shaper*) shaper).__xdtor();
        free(shaper);
    }();
}
