/**
The canvas's batcher: the toolkit's drawing operations in, quad records and
draw runs out, with no device in sight.

A $(LREF Painter) satisfies `isCanvas` with every optional method (`UVK1`).
Each operation becomes the $(REF Instance, sparkles,ui_vulkan,shading)s it
needs, appended in the order the operations arrive, so a later operation is
always drawn over an earlier one (`UVK5`). The records are grouped into
$(LREF DrawRun)s: a run ends only where the scissor or a bound image changes,
never by reordering. Pixels come from `sparkles:ui`'s pixel geometry
(`UVK10`), cells map to pixels as `UVK8` says, and clips and shifts are
resolved to a scissor per run (`UVK13`, `UVK14`).

What the canvas cannot draw it counts in a $(LREF FrameReport) instead of
approximating (`UVK16`): until glyphs arrive (plan slice V3) every text
operation draws nothing and counts as `glyphMiss`, and an interface run
counts as `missingFace` too (`UVK17`).

The Vulkan canvas wraps a painter and records its output at `endFrame`;
keeping the two apart is what lets the operation-to-record mapping be tested
without a driver.
*/
module sparkles.ui_vulkan.painter;

import std.traits : EnumMembers;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.base.text.grapheme : byGraphemeCluster, ClusterMeasure, emojiPresentation, visibleWidth;
import sparkles.base.text.utf : convertPrefix, UtfMode;
import sparkles.base.text.width : codepointWidth;
import sparkles.shaders : v4, vec4;
import sparkles.ui.canvas : isCanvas, LineStyle, RuleEdge, Scrollbar;
import sparkles.ui.effect : EffectId;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.image : fitRect, ImageFit, ImageHandle;
import sparkles.ui.interp.immediate : paintImagePlaceholder;
import sparkles.ui.pixel_geometry : arrowTriangle, borderRects, centredSpan, ClipEntry,
    cornerRadiusPx, densityPx, lineRects, roundedBorderPx, ruleRect, ScissorBox,
    scissorBoxOfStack, scrollbarMinExtentPx, scrollbarRail, shadowRect, shiftPx;
import sparkles.ui.style : FontRole, Visual;
import sparkles.ui_vulkan.shading : Instance, QuadKind;
import sparkles.ui_vulkan.text_rendering : TextRendering;

/// Why an operation was drawn differently from its specification (`UVK16`).
enum Degradation : ubyte
{
    effect,          /// an effect bracket drew its contents unaffected (`UVK15`)
    missingFace,     /// a text run's font role had no face (`UVK17`)
    glyphMiss,       /// a glyph was not available in time (`UVK22`)
    unshapedCluster, /// a cluster needing shaping drew its first codepoint (`UVK19`)
    noGlyph,         /// neither the cell font nor a fallback face has a glyph for a codepoint (`UVX12`)
    imageDeferred,   /// an image waited for a later frame's upload budget (`UVK25`)
    imageTooLarge,   /// an image exceeded the device's largest image (`UVK25`)
    srgbBlending,    /// the target is sRGB: partial coverage blends in linear light (`UVK7`)
}

/// One frame's degradation report: a count per cause, and whether the frame
/// asks for another to complete what it skipped.
struct FrameReport
{
    uint[EnumMembers!Degradation.length] counts; /// indexed by `Degradation`
    bool anotherFrame; ///

@safe pure nothrow @nogc:

    /// The count for `d`.
    uint opIndex(Degradation d) const => counts[d];

    /// Counts one more operation drawn differently for `d`.
    void count(Degradation d)
    {
        ++counts[d];
    }

    /// Whether the frame was drawn exactly as specified.
    bool empty() const
    {
        foreach (c; counts)
            if (c)
                return false;
        return !anotherFrame;
    }
}

/// How the frame's cells map to its pixels (`UVK3`, `UVK8`).
struct FrameMetrics
{
    int cellW = 1;     /// one cell's width, in pixels
    int cellH = 1;     /// one cell's height, in pixels
    int originX;       /// the pixel of cell column 0
    int originY;       /// the pixel of cell row 0
    float density = 1; /// device pixels per CSS pixel
}

/// The images a draw run binds: an atlas page of each kind and an image,
/// each by its holder's number; 0 is the placeholder the holder binds for
/// none.
struct BoundImages
{
    uint coveragePage; ///
    uint colourPage;   ///
    uint image;        ///
}

/// Records drawn with one call: a range of the frame's instances under one
/// scissor and one set of bound images.
struct DrawRun
{
    uint first;          /// the first instance
    uint count;          /// how many
    ScissorBox scissor;  /// in target pixels
    BoundImages images;  ///
}

/// What became of an image a painter asked for.
enum ImageOutcome : ubyte
{
    drawn,    /// resident, or uploaded this frame: draw it from `slot`
    missing,  /// no pixels under the handle: the placeholder, uncounted (`IMG4`)
    tooLarge, /// larger than the device's largest image (`UVK25`)
    deferred, /// over this frame's upload budget; it uploads in a later one (`UVK25`)
}

/**
Whether `S` resolves images for a painter: `resolve(handle, slot, size)`
reports what became of the image and, when it is drawn, the number its
draw runs bind it by and its size in pixels.
*/
enum bool isImageSource(S) = is(typeof((ref S s, ImageHandle h) {
    uint slot;
    Size size;
    ImageOutcome o = s.resolve(h, slot, size);
}));


/// What became of a glyph a painter asked for.
enum GlyphOutcome : ubyte
{
    drawn,   /// in an atlas page: draw it from the `GlyphQuad`
    blank,   /// no ink (a space): nothing to draw, nothing to count
    noGlyph, /// no face has a glyph for the codepoint (`noGlyph`)
    refused, /// the rasterizer refused it (`glyphMiss`)
    full,    /// the atlas is full this frame; it starts over (`glyphMiss`, another frame)
}

/// A glyph drawn from an atlas page: where its texels are, and where its box
/// sits from the pen and the baseline.
struct GlyphQuad
{
    uint page;             /// the page, numbered from 1 as draw runs bind it
    bool colour;           /// a colour page's premultiplied RGBA, drawn in its own colours
    vec4 texRect;          /// its texels' (u0, v0, u1, v1) in the page
    int width, height;     /// its box, in pixels
    int bearingX;          /// pixels from the pen to the box's left edge
    int bearingY;          /// pixels from the baseline up to the box's top edge
    /// For one glyph of a shaped cluster: pixels from the cluster's pen to
    /// this glyph's, and up from the baseline (its shaped offset).
    int dx, dy;
}

/// The cell font's vertical metrics, in pixels from a cell's top.
struct TextMetrics
{
    bool present;          /// a cell font is bound; without one, text misses
    int ascent;            /// the baseline
    int underlineY;        /// the underline's top
    int underlineHeight;   /// its thickness
    int strikeY;           /// the strikethrough's top
}

/// Which of the cell font's faces a run draws in, from its bold and italic bits.
enum FaceStyle : ubyte
{
    regular,    ///
    bold,       ///
    italic,     ///
    boldItalic, ///
}

/// The face `v` asks for.
FaceStyle faceStyleOf(in Visual v) @safe pure nothrow @nogc
    => faceStyle((v.styleBits & TextAttr.bold.bits) != 0, (v.styleBits & TextAttr.italic.bits) != 0);

/// ditto, from the two flags
FaceStyle faceStyle(bool bold, bool italic) @safe pure nothrow @nogc
    => bold ? (italic ? FaceStyle.boldItalic : FaceStyle.bold)
        : italic ? FaceStyle.italic : FaceStyle.regular;

/// A glyph a painter asks for: a cluster's first codepoint, the face style its
/// run asks for, whether the cluster presents as an emoji, and the text's colour
/// (straight RGBA), which colour layers drawn in the foreground take.
struct GlyphRequest
{
    dchar cp;           ///
    FaceStyle style;    ///
    bool emoji;         /// the cluster presents as an emoji: an emoji face first
    vec4 colour = v4(1, 1, 1, 1); ///
    /// What is under the text, straight RGBA, `w` 1 when the painter knows it:
    /// coverage glyphs composite against it (`Compositing`).
    vec4 background = v4(0, 0, 0, 0);
    /// The cells the cluster takes, in pixels: a colour glyph larger than them
    /// is drawn smaller to fit, as the raylib arm fits it. 0 fits nothing.
    int fitWidth, fitHeight;
}

/// The most glyphs one cluster is drawn as: the font seam's cap
/// (`sparkles.font.cluster_shaping.maxClusterGlyphs`), which the canvas
/// asserts against where both are visible.
enum size_t maxClusterQuads = 64;

/// A cluster a painter asks a glyph source to shape (T3): its codepoints and
/// what a `GlyphRequest` carries for its first.
struct ClusterRequest
{
    const(uint)[] cps;  ///
    GlyphRequest first; /// style, presentation, colours and cells, as for one glyph
}

/**
Whether `S` shapes clusters: `resolveCluster(request, quads, count)` writes
the cluster's glyphs, each placed from the cluster's pen, into `quads`.
`drawn` with none written is a cluster with no ink; any other outcome leaves
the painter to draw the first codepoint, unshaped.
*/
enum bool shapesClusters(S) = is(typeof((ref S s) {
    GlyphQuad[4] q;
    size_t n;
    GlyphOutcome o = s.resolveCluster(ClusterRequest.init, q[], n);
}));

/**
Whether `S` supplies glyphs too: `resolveGlyph(request, quad)` for a
codepoint in the cell font's face of that style or a fallback face, and
`textMetrics` for where it sits in a cell. A source without them draws no
text (every run counts `glyphMiss`).
*/
enum bool isGlyphSource(S) = is(typeof((ref S s) {
    GlyphQuad q;
    GlyphOutcome o = s.resolveGlyph(GlyphRequest(dchar('a')), q);
    TextMetrics m = s.textMetrics;
}));

/// An image source with no images: every image is the placeholder.
struct NoImages
{
    /// Always `missing`.
    ImageOutcome resolve(ImageHandle, out uint, out Size) const @safe pure nothrow @nogc
        => ImageOutcome.missing;
}

static assert(isImageSource!NoImages);

/// A colour and an 8-bit alpha as the shading's straight RGBA.
vec4 rgba(RgbColor c, ubyte a) @safe pure nothrow @nogc
    => v4(c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, a / 255.0f);

/**
The batcher. `begin` starts a frame for a target of `target` pixels; the
canvas methods append records; `instances` and `runs` are the frame's.
Not copyable: it owns its buffers.
*/
struct Painter(Images)
if (isImageSource!Images)
{
    /// Where image draws are resolved: the source itself, or a pointer to
    /// one, which may be null for none.
    Images images;

    /// How coverage glyphs composite (`Compositing`), and their contrast.
    TextRendering textRendering;

    // The source behind `images`, and whether it supplies glyphs too
    // (`isGlyphSource`).
    static if (is(Images == U*, U))
        private alias GlyphSource = U;
    else
        private alias GlyphSource = Images;
    private enum bool drawsText = isGlyphSource!GlyphSource;

    /// The shortest a scrollbar's thumb is drawn, in device pixels (`SCV13`).
    int minThumbPx = scrollbarMinExtentPx;

    /// The frame's degradation report so far.
    FrameReport report;

    private static struct ShiftEntry
    {
        int x;
        int y;
        bool pixel; // true: a device-pixel offset; false: a cell shift
    }

    private FrameMetrics m_;
    private Size target_;
    private UniqueBuffer!Instance instances_;
    private UniqueBuffer!DrawRun runs_;
    private UniqueBuffer!ClipEntry clips_;
    private UniqueBuffer!ShiftEntry shifts_;
    private int shiftX_, shiftY_;
    private ScissorBox scissor_;
    private bool clipped_; // nothing survives the clip stack
    private bool hasPixelClip_;
    private ScissorBox pixelClip_;

    @disable this(this);

    /// Starts a frame: no records, no clip, no shift, an empty report.
    void begin(Size target, in FrameMetrics metrics)
    {
        m_ = metrics;
        target_ = target;
        instances_.clear();
        runs_.clear();
        clips_.clear();
        shifts_.clear();
        shiftX_ = shiftY_ = 0;
        hasPixelClip_ = false;
        report = FrameReport.init;
        updateScissor();
    }

    /// The frame's records, in drawing order.
    const(Instance)[] instances() const return => instances_[];

    /// The frame's draw runs, in drawing order.
    const(DrawRun)[] runs() const return => runs_[];

    /// The frame's metrics.
    ref const(FrameMetrics) metrics() const return => m_;

    // -------------------------------------------------------------------
    // The canvas concept
    // -------------------------------------------------------------------

    /**
    A box: its shadow behind it, its background, its border and its popup
    arrow, each only where the visual asks for it — the reference canvas's
    order. A plain fill is one solid record over exactly its pixels (`UVK9`).
    */
    void fillRect(in Rect r, in Visual visual)
    {
        const v = densityScaled(visual);
        int x = px(r.x), w = r.width * m_.cellW;
        centredSpan(x, w, v.drawWidth);
        int y = py(r.y), h = r.height * m_.cellH;
        centredSpan(y, h, v.drawHeight);
        const box = Rect(x, y, w, h);

        if (v.shadow.any)
        {
            const s = v.shadow;
            const sr = shadowRect(box, s);
            if (v.borderRadius > 0)
                rounded(sr, cornerRadiusPx(v.borderRadius, sr.width, sr.height),
                    rgba(s.color, s.alpha), v4(0), 0);
            else
                solid(sr, rgba(s.color, s.alpha));
        }

        const fill = v.hasBg ? rgba(v.bg, v.bgAlpha) : v4(0);
        const edge = v.border.any ? rgba(v.border.color, v.border.alpha) : v4(0);
        if (v.borderRadius > 0)
        {
            // Background and outline in one record: the ring lies outside
            // the box, so drawing it over the fill is all the order there is.
            if (v.hasBg || v.border.any)
                rounded(box, cornerRadiusPx(v.borderRadius, w, h), fill, edge,
                    v.border.any ? roundedBorderPx(v.border.width, m_.density) : 0);
        }
        else
        {
            if (v.hasBg)
                solid(box, fill);
            if (v.border.any)
                borderRects(box, v.border.width, v.border.style, m_.cellW, m_.cellH,
                    (Rect e) { solid(e, edge); });
        }

        if (v.arrow)
        {
            const t = arrowTriangle(x, y, v.arrowOffset, m_.cellW, m_.cellH);
            emit(record(v4(t.left[0], t.apex[1], t.right[0] - t.left[0], t.left[1] - t.apex[1]),
                fill, edge, v4(QuadKind.arrow, 0, 0, 1)));
        }
    }

    /**
    A cell text run from cell `at`: each grapheme cluster takes the cells its
    display width gives and draws its first codepoint's glyph from the cell
    font (`UVK19`, `UVK21`); a cluster of several codepoints counts as
    `unshapedCluster` until the font library shapes. Underline and
    strikethrough are rules at the cell font's positions. Without a glyph
    source, the run draws nothing and counts as `glyphMiss`.
    */
    void textRun(in Point at, scope const(char)[] text, in Visual v)
    {
        cellText(px(at.x), py(at.y), text, v);
    }

    /// ditto — an interface run has no face of its own here, so it also
    /// counts as `missingFace` and falls back to the cell font (`UVK17`),
    /// centred in the rows it was given, as an interface face is: a touch
    /// target's label sits in the middle of its several rows.
    void textRunIn(in Rect r, scope const(char)[] text, in Visual v)
    {
        if (text.length && (v.fontRole == FontRole.ui || v.fontRole == FontRole.uiMono
                || v.fontRole == FontRole.docs))
            report.count(Degradation.missingFace);
        const dy = r.height > 1 ? (r.height - 1) * m_.cellH / 2 : 0;
        cellText(px(r.x), py(r.y) + dy, text, v);
    }

    /// One glyph at cell `at`, in the cell font.
    void glyph(in Point at, dchar g, in Visual v)
    {
        static if (drawsText)
        {
            if (!textReady)
                return report.count(Degradation.glyphMiss);
            uint[1] cps = [g];
            clusterAt(px(at.x), py(at.y), cps[], faceStyleOf(v), rgba(v.fg, v.fgAlpha), backgroundOf(v),
                (codepointWidth(g) > 1 ? 2 : 1) * m_.cellW, m_.cellH);
        }
        else if (g != ' ')
            report.count(Degradation.glyphMiss);
    }

    /**
    A cluster in device pixels, for a painter that lays out its own cells
    (the terminal): `cps` drawn in the box at (`x`, `y`) `w` × `h`, its glyph
    on the box's baseline. Offsets apply; clips are the caller's.
    */
    void clusterPx(scope const(uint)[] cps, bool bold, bool italic, int x, int y, int w, int h,
        vec4 colour, vec4 background = v4(0, 0, 0, 0))
    {
        if (!cps.length)
            return;
        static if (drawsText)
        {
            if (!textReady)
                return report.count(Degradation.glyphMiss);
            clusterAt(m_.originX + shiftX_ + x, m_.originY + shiftY_ + y, cps, faceStyle(bold, italic),
                colour, background, w, h);
        }
        else
            report.count(Degradation.glyphMiss);
    }

    /// A label in device pixels from (`x`, `y`), one cell per cluster.
    void labelPx(scope const(char)[] text, int x, int y, vec4 colour, vec4 background = v4(0, 0, 0, 0))
    {
        static if (drawsText)
        {
            if (!textReady)
                return report.count(Degradation.glyphMiss);
            int pen = m_.originX + shiftX_ + x;
            foreach (c; byGraphemeCluster(text))
            {
                if (c.isEscape)
                    continue;
                textCluster(pen, m_.originY + shiftY_ + y, c, FaceStyle.regular, colour, background);
                pen += (c.width > 0 ? c.width : 1) * m_.cellW;
            }
        }
        else if (text.length)
            report.count(Degradation.glyphMiss);
    }

    /// The label's size in device pixels, as `labelPx` lays it out.
    int[2] labelSizePx(scope const(char)[] text) const
    {
        int cells;
        foreach (c; byGraphemeCluster(text))
            if (!c.isEscape)
                cells += c.width > 0 ? c.width : 1;
        return [cells * m_.cellW, m_.cellH];
    }

    // A run of cells from the pixel (`x`, `y`) of its first cell's top-left.
    private void cellText(int x, int y, scope const(char)[] text, in Visual v)
    {
        if (!text.length)
            return;
        static if (drawsText)
        {
            if (!textReady)
                return report.count(Degradation.glyphMiss);
            const colour = rgba(v.fg, v.fgAlpha);
            const style = faceStyleOf(v);
            const background = backgroundOf(v);
            int cells;
            foreach (c; byGraphemeCluster(text))
            {
                if (c.isEscape)
                    continue;
                textCluster(x + cells * m_.cellW, y, c, style, colour, background);
                cells += c.width > 0 ? c.width : 0;
            }
            const metrics = images.textMetrics;
            if (v.underline != UnderlineStyle.none)
                solid(Rect(x, y + metrics.underlineY, cells * m_.cellW, metrics.underlineHeight),
                    colour);
            if (v.styleBits & TextAttr.strikethrough.bits)
                solid(Rect(x, y + metrics.strikeY, cells * m_.cellW, metrics.underlineHeight),
                    colour);
        }
        else
            report.count(Degradation.glyphMiss);
    }

    static if (drawsText)
    {
        // Whether the source has a cell font to draw with.
        private bool textReady()
        {
            static if (is(Images == U*, U))
                if (images is null)
                    return false;
            return images.textMetrics.present;
        }

        // A cluster of text at its cell's top-left.
        private void textCluster(int penX, int top, in ClusterMeasure c, FaceStyle style, vec4 colour,
            vec4 background)
        {
            dchar[16] cps; // a longer cluster draws its first glyph all the same
            const decoded = convertPrefix(c.slice, cps[], UtfMode.replacement);
            clusterAt(penX, top, cast(const(uint)[]) cps[0 .. decoded.written], style, colour, background,
                (c.width > 0 ? c.width : 1) * m_.cellW, m_.cellH);
        }

        /*
        A cluster's glyphs. A single codepoint, or one with only variation
        selectors (which pick a face, not glyphs), draws its glyph, from an
        emoji face first when the cluster presents as one. A cluster that
        needs shaping — a combining mark, a joiner sequence, a flag, a keycap —
        is shaped by a source that shapes, when the text rendering asks for
        it; otherwise it draws its first codepoint's glyph and counts as
        `unshapedCluster` (`UVK19`).
        */
        private void clusterAt(int penX, int top, scope const(uint)[] cps, FaceStyle style, vec4 colour,
            vec4 background, int boxW, int boxH)
        {
            if (!cps.length)
                return;
            const request = GlyphRequest(cast(dchar) cps[0], style, emojiPresentation(cps), colour,
                background, boxW, boxH);
            bool needsShaping;
            foreach (cp; cps[1 .. $])
                needsShaping |= cp != 0xFE0E && cp != 0xFE0F;
            if (!needsShaping)
                return glyphAt(penX, top, boxH, request);
            static if (shapesClusters!GlyphSource)
                if (textRendering.shaping && shapedAt(penX, top, boxH, ClusterRequest(cps, request)))
                    return;
            report.count(Degradation.unshapedCluster);
            glyphAt(penX, top, boxH, request);
        }

        // One glyph with its pen at `penX` in cells whose top is `top` and
        // height `boxH`, its bitmap's origin on whole pixels (`UVK21`): a
        // coverage glyph tinted with the text's colour on the baseline, or a
        // colour glyph in its own colours, centred in the cells' height as the
        // raylib arm centres it.
        // One drawn glyph: a coverage glyph on the baseline, tinted with the
        // text's colour and composited against its background, or a colour
        // glyph in its own colours centred in the cells' height; a shaped
        // glyph moved by its offsets.
        private void emitQuad(int penX, int top, int boxH, in GlyphQuad q, in GlyphRequest request)
        {
            const y = q.colour ? top + (boxH - q.height) / 2 - q.dy
                : top + images.textMetrics.ascent - q.bearingY - q.dy;
            const box = v4(penX + q.dx + q.bearingX, y, q.width, q.height);
            if (q.colour)
                emit(record(box, request.colour, v4(0), v4(QuadKind.colourGlyph, 0, 0, 0), q.texRect),
                    BoundImages(colourPage: q.page));
            else
                emit(record(box, request.colour, request.background, v4(QuadKind.coverageGlyph,
                    textRendering.compositing, textRendering.contrast, 0), q.texRect),
                    BoundImages(coveragePage: q.page));
        }

        // A cluster shaped by the source: true when it drew (or had no ink),
        // false to draw it unshaped.
        private bool shapedAt(int penX, int top, int boxH, in ClusterRequest r)
        {
            static if (shapesClusters!GlyphSource)
            {
                GlyphQuad[maxClusterQuads] quads;
                size_t n;
                if (images.resolveCluster(r, quads[], n) != GlyphOutcome.drawn)
                    return false;
                foreach (ref q; quads[0 .. n])
                    emitQuad(penX, top, boxH, q, r.first);
                return true;
            }
            else
                return false;
        }

        private void glyphAt(int penX, int top, int boxH, in GlyphRequest request)
        {
            GlyphQuad q;
            final switch (images.resolveGlyph(request, q))
            {
                case GlyphOutcome.drawn:
                    emitQuad(penX, top, boxH, q, request);
                    break;
                case GlyphOutcome.blank:
                    break;
                case GlyphOutcome.noGlyph:
                    report.count(Degradation.noGlyph);
                    break;
                case GlyphOutcome.refused:
                    report.count(Degradation.glyphMiss);
                    break;
                case GlyphOutcome.full:
                    report.count(Degradation.glyphMiss);
                    report.anotherFrame = true;
                    break;
            }
        }
    }

    /// A line's pixels, from `lineRects`.
    void line(in Point from, in Point to, in Visual v, LineStyle style)
    {
        const c = rgba(v.fg, v.fgAlpha);
        lineRects(px(from.x), py(from.y), px(to.x), style == LineStyle.wavy, m_.cellH,
            (Rect r) { solid(r, c); });
    }

    /// A one-pixel rule along `edge` of `rect` (`UIA2`).
    void rule(in Rect rect, RuleEdge edge, in Visual v)
    {
        solid(ruleRect(pixelsOf(rect), edge), rgba(v.fg, v.fgAlpha));
    }

    /// A scrollbar's rail and thumb, from `scrollbarRail`; a bar that owns
    /// its rule shows that rule while idle.
    void scrollbar(in Scrollbar op)
    {
        const r = scrollbarRail(op, m_.cellW, m_.cellH, m_.originX + shiftX_,
            m_.originY + shiftY_, minThumbPx);
        if (!r.live)
            return;
        if (op.trackLit)
            solid(r.track, rgba(op.trackColor, cast(ubyte)(op.trackAlpha * op.fadePercent / 100)));
        else if (op.paintsIdleTrack)
            solid(ruleRect(pixelsOf(op.rect), op.edge), rgba(op.trackColor, op.trackAlpha));
        solid(r.thumb, rgba(op.fg, cast(ubyte)(op.fgAlpha * op.fadePercent / 100)));
    }

    /**
    The image `handle` placed in `r` by `fitRect`, clipped to `r` for
    `cover`, its texels times the foreground alpha (`UVK24`). An image the
    source cannot draw is the placeholder every canvas draws (`IMG4`),
    counted when it was too large or deferred (`UVK25`).
    */
    void image(in Rect r, ImageHandle handle, ImageFit fit, scope const(char)[] alt,
        in Visual v)
    {
        uint slot;
        Size size;
        static if (is(Images == U*, U))
            const outcome = images is null ? ImageOutcome.missing : images.resolve(handle, slot, size);
        else
            const outcome = images.resolve(handle, slot, size);
        if (outcome != ImageOutcome.drawn)
        {
            if (outcome == ImageOutcome.tooLarge)
                report.count(Degradation.imageTooLarge);
            else if (outcome == ImageOutcome.deferred)
            {
                report.count(Degradation.imageDeferred);
                report.anotherFrame = true;
            }
            paintImagePlaceholder(this, r, alt, v);
            return;
        }
        const placed = fitRect(pixelsOf(r), size, fit);
        const clipped = fit == ImageFit.cover;
        if (clipped)
            pushClip(r);
        emit(record(v4(placed.x, placed.y, placed.width, placed.height),
            v4(1, 1, 1, v.fgAlpha / 255.0f), v4(0), v4(QuadKind.image, 0, 0, 0), v4(0, 0, 1, 1)),
            BoundImages(image: slot));
        if (clipped)
            popClip();
    }

    /// Clips what follows to `r` intersected with every enclosing clip,
    /// where `r` lies under the shifts open now (`UVK13`).
    void pushClip(in Rect r)
    {
        clips_.put(ClipEntry(r, shiftX_, shiftY_));
        updateScissor();
    }

    /// ditto
    void popClip()
    {
        if (clips_.length)
            clips_.popBack();
        updateScissor();
    }

    /// Moves what follows by `dx` and `dy` cells, each rounded to whole
    /// pixels half away from zero (`UVK14`).
    void pushShift(float dx, float dy)
    {
        const x = shiftPx(dx, m_.cellW), y = shiftPx(dy, m_.cellH);
        shifts_.put(ShiftEntry(x, y, false));
        shiftX_ += x;
        shiftY_ += y;
    }

    /// ditto — removes the nearest enclosing cell shift, even under a
    /// pixel offset: the entries above it keep their contribution, so a
    /// crossed pop cannot unbalance the stack for the rest of the frame.
    void popShift()
    {
        popKind(false);
    }

    private void popKind(bool pixel)
    {
        auto all = shifts_[];
        foreach_reverse (i, ref e; all)
            if (e.pixel == pixel)
            {
                shiftX_ -= e.x;
                shiftY_ -= e.y;
                foreach (j; i + 1 .. all.length)
                    all[j - 1] = all[j];
                shifts_.popBack();
                return;
            }
    }

    // -------------------------------------------------------------------
    // Pixel space, for a painter that already works in device pixels
    // (the terminal). Reuses the instance batcher; does not scale by cells.
    // -------------------------------------------------------------------

    /// A solid rectangle in device pixels, blended over what is there.
    /// `(x, y)` is relative to the frame origin plus any open pixel offset.
    void fillPx(int x, int y, int w, int h, vec4 colour)
    {
        solid(Rect(m_.originX + shiftX_ + x, m_.originY + shiftY_ + y, w, h), colour);
    }

    /// A rounded rectangle in device pixels, filled; `radius` pixels at each
    /// corner, half the shorter side making a circle or a pill.
    void roundedPx(int x, int y, int w, int h, float radius, vec4 colour)
    {
        if (colour.array[3] > 0)
            rounded(Rect(m_.originX + shiftX_ + x, m_.originY + shiftY_ + y, w, h), radius,
                colour, v4(0), 0);
    }

    /// The rectangle's one-pixel border, inside the box, corners drawn once.
    void outlinePx(int x, int y, int w, int h, vec4 colour)
    {
        if (w <= 0 || h <= 0)
            return;
        fillPx(x, y, w, 1, colour);
        if (h > 1)
            fillPx(x, y + h - 1, w, 1, colour);
        if (h > 2 && w > 0)
        {
            fillPx(x, y + 1, 1, h - 2, colour);
            if (w > 1)
                fillPx(x + w - 1, y + 1, 1, h - 2, colour);
        }
    }

    /// Replaces the pixel clip. Coordinates are target pixels, not moved by
    /// a later offset — a pane's scissor stays put while its content shifts.
    void clipPx(int x, int y, int w, int h)
    {
        pixelClip_ = ScissorBox(m_.originX + x, m_.originY + y, w, h);
        hasPixelClip_ = true;
        updateScissor();
    }

    /// ditto
    void unclipPx()
    {
        hasPixelClip_ = false;
        updateScissor();
    }

    /// Moves what follows by `dx` and `dy` device pixels. Nests with
    /// `pushShift`.
    void pushOffsetPx(int dx, int dy)
    {
        shifts_.put(ShiftEntry(dx, dy, true));
        shiftX_ += dx;
        shiftY_ += dy;
    }

    /// ditto — removes the nearest enclosing pixel offset, even under a
    /// cell shift (see `popShift`).
    void popOffsetPx()
    {
        popKind(true);
    }

    /**
    An image quad in device pixels. `slot` is the bound image number;
    `(sx, sy, sw, sh)` is the source rectangle in the image's pixels,
    `imgW` × `imgH` the image's size. `tint.w` is the alpha.
    */
    void imageQuadPx(uint slot, int x, int y, int w, int h,
        int sx, int sy, int sw, int sh, int imgW, int imgH, vec4 tint)
    {
        if (w <= 0 || h <= 0 || imgW <= 0 || imgH <= 0 || slot == 0)
            return;
        const u0 = sx / cast(float) imgW, v0 = sy / cast(float) imgH;
        const u1 = (sx + sw) / cast(float) imgW, v1 = (sy + sh) / cast(float) imgH;
        emit(record(v4(m_.originX + shiftX_ + x, m_.originY + shiftY_ + y, w, h),
            tint, v4(0), v4(QuadKind.image, 0, 0, 0), v4(u0, v0, u1, v1)),
            BoundImages(image: slot));
    }

    /**
    An image the source resolves, drawn in device pixels from a source
    sub-rectangle. A handle that is not resident counts the same way
    `image` does and draws nothing.
    */
    void imageSourcePx(ImageHandle handle, int x, int y, int w, int h,
        int sx, int sy, int sw, int sh)
    {
        uint slot;
        Size size;
        static if (is(Images == U*, U))
            const outcome = images is null ? ImageOutcome.missing : images.resolve(handle, slot, size);
        else
            const outcome = images.resolve(handle, slot, size);
        if (outcome != ImageOutcome.drawn)
        {
            if (outcome == ImageOutcome.tooLarge)
                report.count(Degradation.imageTooLarge);
            else if (outcome == ImageOutcome.deferred)
            {
                report.count(Degradation.imageDeferred);
                report.anotherFrame = true;
            }
            return;
        }
        imageQuadPx(slot, x, y, w, h, sx, sy, sw, sh, size.width, size.height, v4(1, 1, 1, 1));
    }

    /// An effect bracket draws its contents unaffected and counts once
    /// (`UVK15`).
    void pushEffect(in Rect r, EffectId id)
    {
        report.count(Degradation.effect);
    }

    /// ditto
    void popEffect()
    {
    }

    /// A run's extent in cells, as layout measured it.
    Size measure(scope const(char)[] text) const => Size(cast(int) visibleWidth(text), 1);

    // -------------------------------------------------------------------

    private int px(int cx) const => m_.originX + shiftX_ + cx * m_.cellW;
    private int py(int cy) const => m_.originY + shiftY_ + cy * m_.cellH;

    private Rect pixelsOf(in Rect r) const
        => Rect(px(r.x), py(r.y), r.width * m_.cellW, r.height * m_.cellH);

    private Visual densityScaled(in Visual v) const
    {
        Visual s = v;
        if (m_.density == 1)
            return s;
        s.borderRadius = densityPx(v.borderRadius, m_.density);
        s.shadow.dx = densityPx(v.shadow.dx, m_.density);
        s.shadow.dy = densityPx(v.shadow.dy, m_.density);
        s.shadow.blur = densityPx(v.shadow.blur, m_.density);
        s.drawHeight = densityPx(v.drawHeight, m_.density);
        s.drawWidth = densityPx(v.drawWidth, m_.density);
        return s;
    }

    private void updateScissor()
    {
        if (!clips_.length)
        {
            scissor_ = ScissorBox(0, 0, target_.width, target_.height);
            clipped_ = target_.width <= 0 || target_.height <= 0;
        }
        else
            clipped_ = !scissorBoxOfStack(clips_[], m_.originX, m_.originY, m_.cellW, m_.cellH,
                target_.width, target_.height, scissor_);
        if (hasPixelClip_ && !clipped_)
            clipped_ = !intersectScissor(scissor_, pixelClip_);
    }

    private static bool intersectScissor(ref ScissorBox box, in ScissorBox clip)
        @safe pure nothrow @nogc
    {
        const x0 = box.x > clip.x ? box.x : clip.x;
        const y0 = box.y > clip.y ? box.y : clip.y;
        const x1 = box.x + box.w < clip.x + clip.w ? box.x + box.w : clip.x + clip.w;
        const y1 = box.y + box.h < clip.y + clip.h ? box.y + box.h : clip.y + clip.h;
        if (x1 <= x0 || y1 <= y0)
            return false;
        box = ScissorBox(x0, y0, x1 - x0, y1 - y0);
        return true;
    }

    private void solid(in Rect r, vec4 colour)
    {
        if (!r.empty && colour.array[3] > 0)
            emit(record(v4(r.x, r.y, r.width, r.height), colour, v4(0),
                v4(QuadKind.solid, 0, 0, 0)));
    }

    private void rounded(in Rect r, float radius, vec4 fill, vec4 edge, float thickness)
    {
        if (!r.empty)
            emit(record(v4(r.x, r.y, r.width, r.height), fill, edge,
                v4(QuadKind.roundedBox, radius, thickness, thickness + 1)));
    }

    // Every field given: a vector left out of a literal starts as NaN.
    private static Instance record(vec4 box, vec4 fill, vec4 edge, vec4 shape,
        vec4 texRect = v4(0))
    {
        Instance i;
        i.box = box;
        i.fill = fill;
        i.edge = edge;
        i.shape = shape;
        i.texRect = texRect;
        return i;
    }

    // Appends `i`, starting a run where the scissor or the images change.
    private void emit(in Instance i, BoundImages bound = BoundImages.init)
    {
        if (clipped_)
            return;
        auto all = runs_[];
        if (!all.length || all[$ - 1].scissor != scissor_ || all[$ - 1].images != bound)
            runs_.put(DrawRun(cast(uint) instances_.length, 0, scissor_, bound));
        instances_.put(i);
        ++runs_[][$ - 1].count;
    }
}

static assert(isCanvas!(Painter!NoImages));

// `UVK1`: every optional method, so the interpreter hands it every operation.
static assert(__traits(hasMember, Painter!NoImages, "textRunIn")
    && __traits(hasMember, Painter!NoImages, "rule")
    && __traits(hasMember, Painter!NoImages, "scrollbar")
    && __traits(hasMember, Painter!NoImages, "image")
    && __traits(hasMember, Painter!NoImages, "pushClip") && __traits(hasMember, Painter!NoImages, "popClip")
    && __traits(hasMember, Painter!NoImages, "pushShift") && __traits(hasMember, Painter!NoImages, "popShift")
    && __traits(hasMember, Painter!NoImages, "pushEffect") && __traits(hasMember, Painter!NoImages, "popEffect"));

version (unittest)
{
    import sparkles.ui.style : BorderStyle, BoxBorder, Shadow;
    import sparkles.ui.geometry : Insets;

    // An image source of two images: 1 is resident, 2 is too large, 3 is
    // over the budget.
    private struct TwoImages
    {
        ImageOutcome resolve(ImageHandle h, out uint slot, out Size size) const
            @safe pure nothrow @nogc
        {
            if (h.index == 1)
            {
                slot = 7;
                size = Size(40, 20);
                return ImageOutcome.drawn;
            }
            return h.index == 2 ? ImageOutcome.tooLarge
                : h.index == 3 ? ImageOutcome.deferred : ImageOutcome.missing;
        }
    }

    private enum FrameMetrics metrics10x20 = FrameMetrics(cellW: 10, cellH: 20, originX: 5, originY: 3);

    private bool boxIs(in Instance i, int x, int y, int w, int h) @safe pure nothrow @nogc
        => i.box.array == [cast(float) x, y, w, h];
}

@("ui_vulkan.painter.aPlainFillIsOneSolidRecordOverItsPixels")
@safe pure nothrow @nogc
unittest
{
    Painter!NoImages p;
    p.begin(Size(200, 100), metrics10x20);
    p.fillRect(Rect(1, 2, 3, 1), Visual(bg: RgbColor(10, 20, 30), bgAlpha: 128, hasBg: true));
    assert(p.instances.length == 1 && p.runs.length == 1);
    const i = p.instances[0];
    assert(boxIs(i, 15, 43, 30, 20), "cell (1, 2) at origin (5, 3) of 10 × 20 cells");
    assert(i.shape.array[0] == QuadKind.solid);
    assert(i.fill.array == [10 / 255.0f, 20 / 255.0f, 30 / 255.0f, 128 / 255.0f]);
    assert(i.edge.array == [0, 0, 0, 0] && i.texRect.array == [0, 0, 0, 0]);
    assert(p.runs[0].scissor == ScissorBox(0, 0, 200, 100), "no clip: the whole target");

    p.fillRect(Rect(0, 0, 1, 1), Visual.init);
    assert(p.instances.length == 1, "nothing to paint, nothing recorded");
}

@("ui_vulkan.painter.pixelFillsDoNotScaleByCells")
@safe pure nothrow @nogc
unittest
{
    // `UVK35`: a pixel fill is the rectangle given, plus the frame origin
    // and any open pixel offset, not a cell rectangle.
    Painter!NoImages p;
    p.begin(Size(200, 100), metrics10x20);
    const c = rgba(RgbColor(10, 20, 30), 128);
    p.fillPx(4, 6, 3, 2, c);
    assert(p.instances.length == 1);
    assert(boxIs(p.instances[0], 9, 9, 3, 2), "origin (5, 3) plus (4, 6)");
    assert(p.instances[0].fill.array[3] == 128 / 255.0f);

    p.pushOffsetPx(10, 1);
    p.fillPx(0, 0, 1, 1, c);
    assert(boxIs(p.instances[1], 15, 4, 1, 1));
    p.popOffsetPx();

    p.outlinePx(4, 6, 5, 4, c);
    assert(p.instances.length == 6, "four border rects, corners once");

    p.clipPx(2, 2, 8, 6);
    p.fillPx(0, 0, 1, 1, c);
    assert(p.runs[$ - 1].scissor == ScissorBox(7, 5, 8, 6));
    p.unclipPx();
    p.fillPx(0, 0, 1, 1, c);
    assert(p.runs[$ - 1].scissor == ScissorBox(0, 0, 200, 100));

    p.imageQuadPx(3, 1, 2, 4, 5, 2, 1, 2, 2, 8, 4, v4(1, 1, 1, 1));
    const q = p.instances[$ - 1];
    assert(q.shape.array[0] == QuadKind.image);
    assert(q.texRect.array == [2 / 8.0f, 1 / 4.0f, 4 / 8.0f, 3 / 4.0f]);
    assert(p.runs[$ - 1].images.image == 3);
}

@("ui_vulkan.painter.pixelAndCellShiftsDoNotStealEachOther")
@safe pure nothrow @nogc
unittest
{
    // A cell shift and a pixel offset share one stack. A crossed pop
    // takes the nearest entry of its own kind out from under the other:
    // the pixel offset keeps contributing until its own pop.
    Painter!NoImages p;
    p.begin(Size(200, 100), metrics10x20);
    const c = rgba(RgbColor(10, 20, 30), 128);
    p.pushShift(1, 0); // one 10 px cell
    p.pushOffsetPx(3, 0);
    p.popShift(); // crossed: removes the cell shift under the pixel offset
    p.fillPx(0, 0, 1, 1, c);
    assert(boxIs(p.instances[0], 8, 3, 1, 1), "origin 5 + pixel 3 only");
    p.popOffsetPx();
    p.fillPx(0, 0, 1, 1, c);
    assert(p.instances.length == 2);
    assert(boxIs(p.instances[1], 5, 3, 1, 1), "both popped: the origin only");
}

@("ui_vulkan.painter.runsBreakWhereTheImageChangesAndNeverReorder")
@safe pure nothrow @nogc
unittest
{
    // `UVK5`, canvas scenario 6's shape: image A, a fill, image A again. A
    // batcher that grouped by bound image would draw the fill last.
    Painter!TwoImages p;
    p.begin(Size(400, 300), metrics10x20);
    const v = Visual(bg: RgbColor(255, 0, 0), hasBg: true);
    p.image(Rect(0, 0, 4, 1), ImageHandle(1, 1), ImageFit.fill, "a", Visual.init);
    p.fillRect(Rect(1, 0, 4, 1), v);
    p.image(Rect(2, 0, 4, 1), ImageHandle(1, 1), ImageFit.fill, "a", Visual.init);
    assert(p.instances.length == 3 && p.runs.length == 3);
    assert(p.runs[0].images.image == 7 && p.runs[1].images.image == 0 && p.runs[2].images.image == 7);
    assert(p.instances[0].shape.array[0] == QuadKind.image);
    assert(p.instances[1].shape.array[0] == QuadKind.solid);
    assert(p.runs[2].first == 2 && p.runs[2].count == 1);

    // Two fills in a row share a run.
    p.fillRect(Rect(0, 1, 1, 1), v);
    p.fillRect(Rect(1, 1, 1, 1), v);
    assert(p.runs.length == 4 && p.runs[3].count == 2);
}

@("ui_vulkan.painter.clipsNestAndStayWhereTheyWerePushed")
@safe pure nothrow @nogc
unittest
{
    // `UVK13`/`UVK14`: a viewport clip, a half-row shift, a nested clip
    // inside it — the nested one moves with the content, the outer stays.
    Painter!NoImages p;
    p.begin(Size(800, 600), FrameMetrics(cellW: 10, cellH: 20));
    p.pushClip(Rect(0, 1, 30, 4));
    p.pushShift(0, -0.5f);
    p.pushClip(Rect(0, 2, 30, 2));
    p.fillRect(Rect(0, 0, 100, 100), Visual(hasBg: true, bgAlpha: 255));
    assert(p.runs[$ - 1].scissor == ScissorBox(0, 30, 300, 40));
    assert(boxIs(p.instances[$ - 1], 0, -10, 1000, 2000), "the fill moved by the shift");
    p.popClip();
    p.popShift();
    p.fillRect(Rect(0, 0, 1, 1), Visual(hasBg: true, bgAlpha: 255));
    assert(p.runs[$ - 1].scissor == ScissorBox(0, 20, 300, 80));
    assert(boxIs(p.instances[$ - 1], 0, 0, 10, 20));

    // A clip disjoint from its parent leaves nothing to draw.
    p.pushClip(Rect(40, 40, 2, 2));
    const before = p.instances.length;
    p.fillRect(Rect(40, 40, 2, 2), Visual(hasBg: true, bgAlpha: 255));
    assert(p.instances.length == before);
}

@("ui_vulkan.painter.shiftsRoundHalfAwayFromZeroAndAdd")
@safe pure nothrow @nogc
unittest
{
    // `UVK14`, canvas scenario 5: an odd cell width.
    Painter!NoImages p;
    p.begin(Size(100, 100), FrameMetrics(cellW: 9, cellH: 20));
    p.pushShift(0.5f, 0);
    p.pushShift(-0.5f, 0);
    p.pushShift(0.5f, 0);
    p.fillRect(Rect(1, 0, 1, 1), Visual(hasBg: true, bgAlpha: 255));
    assert(boxIs(p.instances[0], 9 + 5, 0, 9, 20), "+5 − 5 + 5");
}

@("ui_vulkan.painter.bordersAreTheSharedGeometrysPixels")
@safe pure nothrow @nogc
unittest
{
    // `UVK10`: the records of a dashed border are `borderRects`' rectangles.
    Painter!NoImages p;
    p.begin(Size(400, 300), metrics10x20);
    const border = BoxBorder(width: Insets.all(1), style: BorderStyle.dashed,
        color: RgbColor(1, 2, 3));
    p.fillRect(Rect(1, 1, 6, 3), Visual(border: border));
    Rect[64] want;
    size_t n;
    borderRects(Rect(15, 23, 60, 60), Insets.all(1), BorderStyle.dashed, 10, 20,
        (Rect r) { want[n++] = r; });
    assert(n > 4 && p.instances.length == n);
    foreach (k, r; want[0 .. n])
        assert(boxIs(p.instances[k], r.x, r.y, r.width, r.height));
}

@("ui_vulkan.painter.roundedBoxesAndShadows")
@safe pure nothrow @nogc
unittest
{
    Painter!NoImages p;
    p.begin(Size(400, 300), FrameMetrics(cellW: 10, cellH: 20, density: 2));
    const v = Visual(bg: RgbColor(9, 9, 9), hasBg: true, borderRadius: 6,
        border: BoxBorder(width: Insets.all(1), style: BorderStyle.solid),
        shadow: Shadow(dy: 2, blur: 3, alpha: 0x40));
    p.fillRect(Rect(1, 1, 6, 3), v);
    assert(p.instances.length == 2, "the shadow, then the box and its ring in one record");
    const shadow = p.instances[0], box = p.instances[1];
    // Density 2: dy 4, blur 6 — three pixels left, six wider, three longer.
    assert(boxIs(shadow, 7, 24, 66, 63) && shadow.shape.array[0] == QuadKind.roundedBox);
    assert(boxIs(box, 10, 20, 60, 60));
    assert(box.shape.array == [QuadKind.roundedBox, 12, 2, 3], "radius 12, a 2 px ring");
}

@("ui_vulkan.painter.textAndEffectsDegradeVisibly")
@safe pure nothrow @nogc
unittest
{
    // `UVK15`–`UVK17`, canvas scenario 14.
    Painter!NoImages p;
    p.begin(Size(400, 300), metrics10x20);
    p.pushEffect(Rect(0, 0, 4, 4), EffectId.init);
    p.fillRect(Rect(0, 0, 2, 2), Visual(hasBg: true, bgAlpha: 255));
    p.popEffect();
    assert(p.instances.length == 1, "the contents, unaffected");
    p.textRunIn(Rect(0, 0, 4, 1), "Logs", Visual(fontRole: FontRole.ui));
    p.textRunIn(Rect(0, 1, 4, 1), "code", Visual(fontRole: FontRole.code));
    p.glyph(Point(0, 2), 'x', Visual.init);
    assert(p.report[Degradation.effect] == 1);
    assert(p.report[Degradation.missingFace] == 1);
    assert(p.report[Degradation.glyphMiss] == 3);
    assert(p.instances.length == 1 && !p.report.anotherFrame);
}

@("ui_vulkan.painter.imagesPlaceAndDegrade")
@safe pure nothrow @nogc
unittest
{
    Painter!TwoImages p;
    p.begin(Size(400, 300), metrics10x20);

    // `UVK24`: `contain` letterboxes a 40 × 20 image into a 60 × 20 rect.
    p.image(Rect(0, 0, 6, 1), ImageHandle(1, 1), ImageFit.contain, null, Visual(fgAlpha: 128));
    assert(boxIs(p.instances[0], 15, 3, 40, 20));
    assert(p.instances[0].fill.array[3] == 128 / 255.0f);
    assert(p.instances[0].texRect.array == [0, 0, 1, 1]);

    // `cover` is clipped to its rect.
    p.image(Rect(0, 1, 1, 1), ImageHandle(1, 1), ImageFit.cover, null, Visual.init);
    assert(p.runs[$ - 1].scissor == ScissorBox(5, 23, 10, 20));

    // `UVK25`: too large and deferred draw the placeholder and count.
    const n = p.instances.length;
    const bg = Visual(bg: RgbColor(1, 1, 1), hasBg: true);
    p.image(Rect(0, 2, 6, 3), ImageHandle(2, 1), ImageFit.contain, "big", bg);
    p.image(Rect(0, 5, 6, 3), ImageHandle(3, 1), ImageFit.contain, "later", bg);
    assert(p.instances.length == n + 2, "each placeholder's box");
    assert(p.report[Degradation.imageTooLarge] == 1 && p.report[Degradation.imageDeferred] == 1);
    assert(p.report.anotherFrame, "a deferred image asks for the frame that uploads it");
}

version (unittest)
{
    // A glyph source whose every glyph is a 4 × 6 box with bearings (1, 5),
    // on page 2; `x` has no glyph; the face style chosen is recorded.
    private struct FakeGlyphs
    {
        FaceStyle lastStyle;

        ImageOutcome resolve(ImageHandle, out uint, out Size) const @safe pure nothrow @nogc
            => ImageOutcome.missing;

        bool lastEmoji;

        GlyphOutcome resolveGlyph(in GlyphRequest r, out GlyphQuad q) @safe pure nothrow @nogc
        {
            lastStyle = r.style;
            lastEmoji = r.emoji;
            if (r.cp == 'x')
                return GlyphOutcome.noGlyph;
            if (r.cp == ' ')
                return GlyphOutcome.blank;
            q = r.emoji ? GlyphQuad(3, true, v4(0, 0, 0.5f, 0.5f), 16, 16, 0, 14)
                : GlyphQuad(2, false, v4(0, 0, 0.25f, 0.25f), 4, 6, 1, 5);
            return GlyphOutcome.drawn;
        }

        TextMetrics textMetrics() const @safe pure nothrow @nogc
            => TextMetrics(present: true, ascent: 15, underlineY: 17, underlineHeight: 1,
                strikeY: 10);
    }
}

@("ui_vulkan.painter.aRunPlacesEachClusterInItsCells")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.term_style : TextAttr;

    // `UVK19`, `UVK21`: clusters advance by their display width; each glyph's
    // box sits at the pen plus its bearing, up from the cell's baseline.
    Painter!FakeGlyphs p;
    p.begin(Size(200, 100), metrics10x20); // origin (5, 3), 10 × 20 cells
    const v = Visual(fg: RgbColor(255, 255, 255), fgAlpha: 255);
    p.textRun(Point(1, 1), "a一b x", v);
    // 'a' at cell 1, the wide CJK at cells 2–3, 'b' at cell 4, ' ' blank, 'x' none.
    assert(p.instances.length == 3);
    assert(boxIs(p.instances[0], 5 + 10 + 1, 3 + 20 + 15 - 5, 4, 6));
    assert(boxIs(p.instances[1], 5 + 20 + 1, 3 + 20 + 15 - 5, 4, 6));
    assert(boxIs(p.instances[2], 5 + 40 + 1, 3 + 20 + 15 - 5, 4, 6), "the wide one took two cells");
    assert(p.instances[0].shape.array[0] == QuadKind.coverageGlyph);
    assert(p.runs[$ - 1].images.coveragePage == 2);
    assert(p.report[Degradation.noGlyph] == 1, "'x' has no glyph");

    Visual bold = v;
    bold.styleBits = TextAttr.bold.bits;
    bold.underline = UnderlineStyle.single;
    p.textRun(Point(0, 0), "ab", bold);
    assert(p.images.lastStyle == FaceStyle.bold, "the run's attributes pick the face");
    const underline = p.instances[$ - 1];
    assert(boxIs(underline, 5, 3 + 17, 20, 1), "the underline spans the run's cells");
}

@("ui_vulkan.painter.anInterfaceRunSitsInTheMiddleOfItsRows")
@safe pure nothrow @nogc
unittest
{
    // `UVK17`: a run in a rect several rows tall (a touch target's label)
    // draws in the cell font, centred in those rows, as an interface face is.
    Painter!FakeGlyphs p;
    p.begin(Size(200, 100), metrics10x20); // origin (5, 3), 10 × 20 cells
    const v = Visual(fg: RgbColor(255, 255, 255), fgAlpha: 255, fontRole: FontRole.ui);
    p.textRunIn(Rect(1, 0, 4, 1), "a", v);
    assert(boxIs(p.instances[$ - 1], 5 + 10 + 1, 3 + 15 - 5, 4, 6), "one row: as a run");
    p.textRunIn(Rect(1, 1, 4, 3), "a", v);
    assert(boxIs(p.instances[$ - 1], 5 + 10 + 1, 3 + 20 + 20 + 15 - 5, 4, 6),
        "three rows: in the middle one");
    p.textRunIn(Rect(1, 1, 4, 2), "a", v);
    assert(boxIs(p.instances[$ - 1], 5 + 10 + 1, 3 + 20 + 10 + 15 - 5, 4, 6),
        "two rows: half a row down");
    assert(p.report[Degradation.missingFace] == 3);
}

@("ui_vulkan.painter.anEmojiClusterDrawsInColour")
@safe pure nothrow @nogc
unittest
{
    Painter!FakeGlyphs p;
    p.begin(Size(200, 100), metrics10x20);
    const v = Visual(fg: RgbColor(255, 255, 255), fgAlpha: 255);
    p.textRun(Point(0, 0), "\u2764\uFE0F", v); // a heart asked for as an emoji
    assert(p.images.lastEmoji, "VS16 asks for the emoji face");
    assert(p.report[Degradation.unshapedCluster] == 0, "a variation selector needs no shaping");
    assert(p.instances.length == 1 && p.instances[0].shape.array[0] == QuadKind.colourGlyph);
    assert(p.runs[$ - 1].images.colourPage == 3 && p.runs[$ - 1].images.coveragePage == 0);
    p.textRun(Point(0, 0), "\u2764", v);
    assert(!p.images.lastEmoji, "the bare heart is text");
    p.textRun(Point(0, 0), "\U0001F469\u200D\U0001F4BB", v);
    assert(p.images.lastEmoji && p.report[Degradation.unshapedCluster] == 1,
        "a joiner sequence draws its first emoji and counts as unshaped");
}

@("ui_vulkan.painter.textWithoutAGlyphSourceCountsAMiss")
@safe pure nothrow @nogc
unittest
{
    Painter!NoImages p;
    p.begin(Size(200, 100), metrics10x20);
    p.textRun(Point(0, 0), "abc", Visual.init);
    assert(p.instances.length == 0 && p.report[Degradation.glyphMiss] == 1);
}

/// What is under text drawn with `v`: its background, when it paints one.
vec4 backgroundOf(in Visual v) @safe pure nothrow @nogc
    => v.hasBg && v.bgAlpha == 255 ? rgba(v.bg, 255) : v4(0, 0, 0, 0);
