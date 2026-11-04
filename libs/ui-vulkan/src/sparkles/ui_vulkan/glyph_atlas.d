/**
The canvas's interim glyph cache (decision `UVX12`): glyphs drawn by
`sparkles:font`'s rasterizers, packed into pages, and handed to the canvas
region by region to upload.

Two sheets of pages: coverage, one byte a texel, for outline glyphs the
shading tints with the text's colour; and colour, premultiplied RGBA, for a
glyph's colour form — `COLR` layers or a `CBDT`/`sbix` bitmap — which draws
in its own colours.

`sparkles:font`'s own glyph cache (its startup slice S3) replaces this under
the same key — face, exact ppem, glyph and rasterizer — so the canvas keeps
its upload path and only the source moves. Until then the canvas owns this
one cache, and nothing else draws glyph pixels.

Everything here is CPU work with no device in sight, so it is tested
without a driver; the canvas uploads what `takeDirty` reports.
*/
module sparkles.ui_vulkan.glyph_atlas;

import sparkles.font : Colour, ColourGlyph, ColourRegion, ColourSource, ColourWorkspace, colourMeasure,
    Face, FlattenPolicy, FontErrorKind, FontLimit, Instance, LightHints, OutlinePoint, OutlineSegment,
    OverlapMode, Ppem, RasterRegion, RasterWorkspace, rasterizeColourGlyph, prepareRaster, Tag;
import sparkles.ui_vulkan.raster_batch : RasterBatch, RasterRequest;

/// What became of a glyph the atlas was asked for.
enum AtlasOutcome : ubyte
{
    placed,   /// in a page: draw it from `AtlasGlyph`
    blank,    /// the glyph has no outline (a space): draw nothing, count nothing
    refused,  /// the rasterizer refused it; remembered, so not retried every frame
    full,     /// every page of its sheet is full; the atlas starts over on the next frame
    noColour, /// asked for its colour form, it has none: draw its outline instead
}

/// Where a placed glyph sits in its page, and where it sits from the pen.
struct AtlasGlyph
{
    uint page;          /// 0-based page index in its sheet
    bool colour;        /// in the colour sheet: premultiplied RGBA, drawn in its own colours
    int x, y;           /// its box's top-left texel in the page
    int width, height;  /// its box, in texels
    int bearingX;       /// pixels from the pen to the box's left edge
    int bearingY;       /// pixels from the baseline up to the box's top edge
}

/// A region of a page written since it was last taken, to upload.
struct DirtyRegion
{
    bool colour;        /// in the colour sheet, four bytes a texel
    uint page;          ///
    bool whole;         /// the page has never been uploaded: upload all of it
    int x, y, width, height; ///
}

/// The cache key: which face, at which exact size, which glyph, and for a
/// colour form the foreground its layers may be drawn in.
struct GlyphKey
{
    uint face;  /// the canvas's face serial; a new face is a new serial
    ulong ppemNumerator, ppemDenominator; /// `Ppem` exactly (`FTM10`)
    uint glyph; ///
    bool colour; /// the colour form, or the outline
    bool hinted; /// the outline light-hinted, or as designed
    uint foreground; /// for the colour form: the foreground as RGBA bytes
    // Effective normalized coordinates, in face axis order. Explicit defaults,
    // reordered inputs and clamped user values therefore share entries.
    short[64] coordinates;
    ushort coordinateCount;
}

private GlyphKey withCoordinates(GlyphKey key, in Instance inst) @safe pure nothrow @nogc
{
    key.coordinateCount = cast(ushort) inst.coords.length;
    key.coordinates[0 .. inst.coords.length] = inst.coords[];
    return key;
}

/// Whether `face` has a colour form for any glyph: `COLR` layers or a bitmap strike.
bool hasColourGlyphs(in Face face) @safe pure nothrow @nogc
    => face.has(Tag("COLR")) || face.has(Tag("CBDT")) || face.has(Tag("sbix"));

/// The atlas. Not copyable: it owns its pages.
struct GlyphAtlas
{
    /// A page's side, in texels.
    enum uint pageSize = 1024;
    /// The most pages a sheet holds: 1 MiB each of coverage, 4 MiB of colour.
    enum uint maxPages = 4;
    /// Texels left between glyphs, so nearest sampling never reads a neighbour.
    enum int padding = 1;

    private
    {
        Sheet[2] sheets_ = [Sheet(1), Sheet(4)]; // coverage, colour
        Entry[GlyphKey] entries_;
        bool overflowed_;
        Storage storage_;
        enum maxPreparedGlyphs = 128;
        RasterBatch!maxPreparedGlyphs rasterBatch_;
        RasterRequest[maxPreparedGlyphs] preparedRequests_;
        GlyphKey[maxPreparedGlyphs] preparedKeys_;
        uint[GlyphKey] queued_;
        size_t preparedCount_;
    }

    @disable this(this);

    /// How many glyphs are cached, placed or not.
    size_t length() const @safe pure nothrow @nogc => entries_.length;
    /// How many pages the coverage sheet, or the colour one, holds.
    size_t pageCount(bool colour = false) const @safe pure nothrow @nogc => sheets_[colour].pages.length;
    /// The texels of page `i`, row-major, `pageSize` wide: one byte each, or
    /// four (premultiplied RGBA) in the colour sheet.
    const(ubyte)[] page(size_t i, bool colour = false) const @safe pure nothrow @nogc
        => sheets_[colour].pages[i];

    /// Starts collection of this frame's unique coverage misses.
    void beginPreparation() @safe nothrow
    {
        preparedCount_ = 0;
        queued_ = null;
    }

    /// Queues a miss without atlas writes. Inputs stay alive until finish.
    void prepare(Instance inst, uint face, uint glyph, Ppem ppem,
        const(LightHints)* hints = null) @safe
    {
        const key = withCoordinates(GlyphKey(face: face, ppemNumerator: ppem.numerator,
            ppemDenominator: ppem.denominator, glyph: glyph, hinted: hints !is null), inst);
        if ((key in entries_) !is null || (key in queued_) !is null || preparedCount_ == maxPreparedGlyphs)
            return;
        const i = preparedCount_++;
        preparedKeys_[i] = key;
        preparedRequests_[i] = RasterRequest(inst, glyph, ppem,
            hints is null ? LightHints.init : *hints, hints !is null);
        queued_[key] = cast(uint)i;
    }

    /// Joins the bounded batch, then places tiles on the caller.
    /// Unsupported/oversized jobs retain the ordinary synchronous path.
    void finishPreparation(uint workers = 2) @system nothrow
    {
        rasterBatch_.run(preparedRequests_[0 .. preparedCount_], workers);
        foreach (i; 0 .. preparedCount_)
        {
            const tile = &rasterBatch_.tile(i);
            if (!tile.ready) continue;
            const key = preparedKeys_[i];
            const m = tile.metrics;
            AtlasGlyph g;
            if (m.empty || m.width <= 0 || m.height <= 0)
            {
                cast(void) remember(key, AtlasOutcome.blank, g);
                continue;
            }
            uint page;
            int x, y;
            if (overflowed_ || !sheets_[0].place(m.width, m.height, page, x, y))
            {
                overflowed_ = true;
                break;
            }
            foreach (row; 0 .. m.height)
                sheets_[0].pages[page][size_t(y + row) * pageSize + x .. size_t(y + row) * pageSize + x + m.width]
                    = tile.pixels[][size_t(row) * m.width .. size_t(row + 1) * m.width];
            sheets_[0].markDirty(page, x, y, m.width, m.height);
            g = AtlasGlyph(page, false, x, y, m.width, m.height, m.bearingX, m.bearingY);
            entries_[key] = Entry(AtlasOutcome.placed, g);
        }
        beginPreparation();
    }

    /// Joins worker threads before font bytes or the renderer are released.
    void stopPreparation() @safe nothrow { rasterBatch_.stop(); }

    /**
    Glyph `glyph` of `inst` at `ppem`, from the cache or rasterized now into
    a coverage page. `face` is the caller's serial for `inst`'s face: glyphs
    of different faces never share entries. With `hints`, the outline is
    light-hinted first, and cached apart from its unhinted self.
    */
    AtlasOutcome get(in Instance inst, uint face, uint glyph, Ppem ppem, out AtlasGlyph g,
        const(LightHints)* hints = null) @safe
    {
        const key = withCoordinates(GlyphKey(face: face, ppemNumerator: ppem.numerator, ppemDenominator: ppem.denominator,
            glyph: glyph, hinted: hints !is null), inst);
        if (auto e = key in entries_)
        {
            g = e.glyph;
            return e.outcome;
        }
        if (overflowed_)
            return AtlasOutcome.full;
        auto measured = measure(inst, glyph, ppem, hints);
        if (measured.hasError)
            return remember(key, AtlasOutcome.refused, g);
        const m = measured.value.metrics;
        if (m.empty || m.width <= 0 || m.height <= 0)
            return remember(key, AtlasOutcome.blank, g);
        if (!fitsPage(m.width, m.height))
            return remember(key, AtlasOutcome.refused, g);
        uint page;
        int x, y;
        if (!sheets_[0].place(m.width, m.height, page, x, y))
        {
            overflowed_ = true;
            return AtlasOutcome.full;
        }
        auto region = RasterRegion(sheets_[0].pages[page][size_t(y) * pageSize + x .. $], pageSize,
            m.width, m.height);
        auto ws = storage_.workspace;
        auto drawn = measured.value.rasterize(region, ws, FlattenPolicy.standard);
        if (drawn.hasError)
            return remember(key, AtlasOutcome.refused, g);
        sheets_[0].markDirty(page, x, y, m.width, m.height);
        g = AtlasGlyph(page, false, x, y, m.width, m.height, drawn.value.bearingX, drawn.value.bearingY);
        entries_[key] = Entry(AtlasOutcome.placed, g);
        return AtlasOutcome.placed;
    }

    /**
    The colour form of glyph `glyph` — its `COLR` layers in palette 0, with
    `foreground` for the layers that ask for it, or its bitmap scaled to
    `ppem` — from the cache or drawn now into a colour page. `noColour` when
    the glyph has none, which the caller draws through `get`.
    */
    AtlasOutcome getColour(in Instance inst, uint face, uint glyph, Ppem ppem, Colour foreground,
        out AtlasGlyph g) @safe
    {
        const key = withCoordinates(GlyphKey(face: face, ppemNumerator: ppem.numerator, ppemDenominator: ppem.denominator,
            glyph: glyph, colour: true, foreground: !inst.face.has(Tag("COLR")) ? 0
                : (uint(foreground.red) << 24) | (uint(foreground.green) << 16)
                | (uint(foreground.blue) << 8) | foreground.alpha), inst);
        if (auto e = key in entries_)
        {
            g = e.glyph;
            return e.outcome;
        }
        if (overflowed_)
            return AtlasOutcome.full;
        auto measured = measureColour(inst, glyph, ppem);
        if (measured.hasError)
            return remember(key, AtlasOutcome.refused, g);
        const m = measured.value;
        if (m.source == ColourSource.none)
            return remember(key, AtlasOutcome.noColour, g);
        if (m.empty)
            return remember(key, AtlasOutcome.blank, g);
        if (!fitsPage(m.width, m.height))
            return remember(key, AtlasOutcome.refused, g);
        uint page;
        int x, y;
        if (!sheets_[1].place(m.width, m.height, page, x, y))
        {
            overflowed_ = true;
            return AtlasOutcome.full;
        }
        auto region = ColourRegion(sheets_[1].pages[page][(size_t(y) * pageSize + x) * 4 .. $],
            pageSize * 4, m.width, m.height);
        auto drawn = rasterizeColourGlyph(inst, glyph, ppem, 0, foreground, region, storage_.colourWorkspace);
        if (drawn.hasError)
            return remember(key, AtlasOutcome.refused, g);
        sheets_[1].markDirty(page, x, y, m.width, m.height);
        g = AtlasGlyph(page, true, x, y, m.width, m.height, drawn.value.bearingX, drawn.value.bearingY);
        entries_[key] = Entry(AtlasOutcome.placed, g);
        return AtlasOutcome.placed;
    }

    /**
    Whether the atlas ran out of pages this frame. The canvas then calls
    `reset` before the next one: glyphs of a long run are re-rasterized as
    they are drawn again, rather than the cache growing without bound.
    */
    bool overflowed() const @safe pure nothrow @nogc => overflowed_;

    /// Forgets every glyph and clears the pages, which upload whole again.
    void reset() @safe pure nothrow
    {
        entries_ = null;
        foreach (ref s; sheets_)
            s.reset();
        overflowed_ = false;
    }

    /**
    Hands each page region written since the last call to `upload`, and
    forgets a region only when `upload` took it (returned `true`): a
    staging failure leaves the region dirty for the next frame instead of
    marking texels uploaded that never reached the device.
    */
    void takeDirty(scope bool delegate(in DirtyRegion) @system upload) @system
    {
        foreach (ref s; sheets_)
            s.takeDirty(upload);
    }

    /**
    Says no page is on the device after all — a frame whose staged uploads
    were discarded — so every page uploads whole again. Texels and cache
    entries stand; only the upload bookkeeping starts over.
    */
    void markUnstaged() @safe pure nothrow
    {
        foreach (ref s; sheets_)
            s.markUnstaged();
    }

    private:

    struct Entry
    {
        AtlasOutcome outcome;
        AtlasGlyph glyph;
    }

    AtlasOutcome remember(in GlyphKey key, AtlasOutcome outcome, out AtlasGlyph g)
        @safe pure nothrow
    {
        entries_[key] = Entry(outcome);
        return outcome;
    }

    // Whether a glyph of this size could ever sit in a page, however empty.
    static bool fitsPage(int w, int h) @safe pure nothrow @nogc
        => w + padding <= pageSize && h + padding <= pageSize;

    // The glyph's size, growing the workspace when the outline needs more.
    auto measure(in Instance inst, uint glyph, Ppem ppem, const(LightHints)* hints) return @safe
    {
        foreach (attempt; 0 .. 6)
        {
            auto ws = storage_.workspace;
            auto r = prepareRaster(inst, glyph, ppem, ws, OverlapMode.perGlyphFlag, hints);
            if (r.hasError && r.error.kind == FontErrorKind.limitExceeded
                && r.error.limit == FontLimit.callerStorage)
            {
                storage_.grow();
                continue;
            }
            if (r.hasValue)
                storage_.reserve(r.value.metrics.accumulationNeeded, r.value.metrics.supersampleNeeded);
            return r;
        }
        auto ws = storage_.workspace;
        return prepareRaster(inst, glyph, ppem, ws, OverlapMode.perGlyphFlag, hints);
    }

    // The colour form's size, the storage drawing it needs made ready.
    auto measureColour(in Instance inst, uint glyph, Ppem ppem) @safe
    {
        foreach (attempt; 0 .. 6)
        {
            auto r = colourMeasure(inst, glyph, ppem, storage_.colourWorkspace);
            if (r.hasError && r.error.kind == FontErrorKind.limitExceeded
                && r.error.limit == FontLimit.callerStorage)
            {
                storage_.grow();
                continue;
            }
            if (r.hasValue)
                storage_.reserveColour(r.value);
            return r;
        }
        return colourMeasure(inst, glyph, ppem, storage_.colourWorkspace);
    }
}

// One kind of page: their texels, the shelves packed into each, and what is
// left to upload.
private struct Sheet
{
    uint bytesPerTexel;
    ubyte[][] pages;
    Shelf[][] shelves;
    DirtyRegion[] dirty;
    bool[] uploaded;

    // A row of a page, filled left to right.
    static struct Shelf
    {
        int y, height, x;
    }

    bool colour() const @safe pure nothrow @nogc => bytesPerTexel == 4;

    // First shelf that fits, else a new shelf, else a new page.
    bool place(int w, int h, out uint page, out int x, out int y) @safe pure nothrow
    {
        enum size = GlyphAtlas.pageSize;
        const pw = w + GlyphAtlas.padding, ph = h + GlyphAtlas.padding;
        if (pw > size || ph > size)
            return false;
        foreach (p, ref rows; shelves)
        {
            foreach (ref s; rows)
                if (s.height >= ph && s.height <= ph + ph / 2 && s.x + pw <= size)
                {
                    page = cast(uint) p;
                    x = s.x;
                    y = s.y;
                    s.x += pw;
                    return true;
                }
            const top = rows.length ? rows[$ - 1].y + rows[$ - 1].height : 0;
            if (top + ph <= size)
            {
                rows ~= Shelf(top, ph, pw);
                page = cast(uint) p;
                x = 0;
                y = top;
                return true;
            }
        }
        if (pages.length == GlyphAtlas.maxPages)
            return false;
        pages ~= new ubyte[size_t(size) * size * bytesPerTexel];
        shelves ~= [Shelf(0, ph, pw)];
        dirty ~= DirtyRegion(colour, cast(uint)(pages.length - 1), true, 0, 0, 0, 0);
        uploaded ~= false;
        page = cast(uint)(pages.length - 1);
        x = y = 0;
        return true;
    }

    void markDirty(uint page, int x, int y, int w, int h) @safe pure nothrow @nogc
    {
        auto d = &dirty[page];
        if (d.width <= 0)
        {
            *d = DirtyRegion(colour, page, false, x, y, w, h);
            return;
        }
        const x1 = d.x + d.width > x + w ? d.x + d.width : x + w;
        const y1 = d.y + d.height > y + h ? d.y + d.height : y + h;
        d.x = d.x < x ? d.x : x;
        d.y = d.y < y ? d.y : y;
        d.width = x1 - d.x;
        d.height = y1 - d.y;
    }

    void reset() @safe pure nothrow
    {
        enum size = GlyphAtlas.pageSize;
        foreach (i, ref p; pages)
        {
            p[] = 0;
            shelves[i] = null;
            uploaded[i] = false;
            dirty[i] = DirtyRegion(colour, cast(uint) i, true, 0, 0, size, size);
        }
    }

    void takeDirty(scope bool delegate(in DirtyRegion) @system upload) @system
    {
        enum size = GlyphAtlas.pageSize;
        foreach (i, ref d; dirty)
        {
            if (d.width <= 0)
                continue;
            if (!uploaded[i])
                d = DirtyRegion(colour, cast(uint) i, true, 0, 0, size, size);
            if (!upload(d))
                continue; // not taken: still dirty, still not uploaded
            uploaded[i] = true;
            d = DirtyRegion(colour, cast(uint) i, false, 0, 0, 0, 0);
        }
    }

    void markUnstaged() @safe pure nothrow
    {
        enum size = GlyphAtlas.pageSize;
        foreach (i, ref d; dirty)
        {
            uploaded[i] = false;
            d = DirtyRegion(colour, cast(uint) i, true, 0, 0, size, size);
        }
    }
}

// The rasterizers' caller-owned arrays, sized for ordinary glyphs and grown
// when a glyph needs more.
private struct Storage
{
    OutlineSegment[] segments;
    OutlinePoint[] points;
    bool[] onCurve;
    ushort[] contourEnds;
    float[] accumulation;
    ubyte[] supersample;
    uint[] pointNumbers;
    int[] deltaX, deltaY;
    int[2][] referenced;
    ubyte[] coverage, inflated, image, zlib; // a colour form's

    RasterWorkspace workspace() return @safe pure nothrow
    {
        if (!points.length)
            grow();
        return RasterWorkspace(segments, points, onCurve, contourEnds, accumulation, supersample,
            pointNumbers, deltaX, deltaY, referenced);
    }

    ColourWorkspace colourWorkspace() return @safe pure nothrow
        => ColourWorkspace(workspace, coverage, inflated, image, zlib);

    void grow() @safe pure nothrow
    {
        const n = points.length ? points.length * 2 : 1024;
        segments.length = 2 * n;
        points.length = n;
        onCurve.length = n;
        contourEnds.length = n / 4;
        pointNumbers.length = n;
        deltaX.length = n;
        deltaY.length = n;
        referenced.length = n;
    }

    void reserve(size_t accumulationNeeded, size_t supersampleNeeded) @safe pure nothrow
    {
        if (accumulation.length < accumulationNeeded)
            accumulation.length = accumulationNeeded;
        if (supersample.length < supersampleNeeded)
            supersample.length = supersampleNeeded;
    }

    void reserveColour(in ColourGlyph m) @safe pure nothrow
    {
        reserve(m.accumulationNeeded, m.supersampleNeeded);
        static void atLeast(ref ubyte[] a, size_t n) @safe pure nothrow
        {
            if (a.length < n)
                a.length = n;
        }
        atLeast(coverage, m.coverageNeeded);
        atLeast(inflated, m.inflatedNeeded);
        atLeast(image, m.imageNeeded);
        atLeast(zlib, m.zlibNeeded);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: the bundled DejaVu Sans Mono, rasterized by `sparkles:font`.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.font : charMap, Face, instance, InstanceSize, openFace;

    private const(ubyte)[] dejaVu() @system => bundled("DejaVuSansMono.ttf");

    private const(ubyte)[] bundled(string name) @system
    {
        import std.file : exists, read;
        import std.path : buildPath;
        import std.process : environment;

        const dir = environment.get("SPARKLES_FONTS_PATH");
        assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
        const path = dir.buildPath(name);
        assert(path.exists, path ~ " is missing");
        return cast(const(ubyte)[]) read(path);
    }

    private struct Fixture
    {
        const(ubyte)[] bytes;
        Face face;
        Instance inst;
        Ppem ppem;

        static Fixture at(uint px, string name = "DejaVuSansMono.ttf") @system
        {
            Fixture f;
            f.bytes = bundled(name);
            f.face = openFace(f.bytes).value;
            f.ppem = Ppem.fromInteger(px).value;
            f.inst = f.face.instance(InstanceSize.pixels(f.ppem), null).value;
            return f;
        }

        uint glyph(dchar c) @system => charMap(face).value.glyph(c);
    }
}

/// Parallel tiles preserve exact pixels, metrics and blank results across
/// variation coordinates and worker counts; duplicate misses queue only once.
@("ui_vulkan.glyph_atlas.parallelTilesMatchSerial")
@system unittest
{
    import sparkles.font : UserCoordinate;

    foreach (workers; 1 .. 5)
        foreach (weight; [100, 900])
            foreach (size; [17, 40])
            {
                auto f = Fixture.at(size, "NotoSans.ttf");
                f.inst = f.face.instance(InstanceSize.pixels(f.ppem),
                    [UserCoordinate(Tag("wght"), weight << 16)]).value;
                auto serial = new GlyphAtlas, parallel = new GlyphAtlas;
                parallel.beginPreparation();
                foreach (_; 0 .. 3)
                    foreach (cp; ['A', 'g', 'W', ' ', 'é'])
                        parallel.prepare(f.inst, 1, f.glyph(cp), f.ppem);
                assert(parallel.preparedCount_ == 5);
                parallel.finishPreparation(workers);
                assert(parallel.length == 5);
                foreach (cp; ['A', 'g', 'W', ' ', 'é'])
                {
                    AtlasGlyph expected, actual;
                    assert(serial.get(f.inst, 1, f.glyph(cp), f.ppem, expected)
                        == parallel.get(f.inst, 1, f.glyph(cp), f.ppem, actual));
                    assert(expected == actual);
                }
                assert(serial.pageCount == parallel.pageCount);
                foreach (page; 0 .. serial.pageCount)
                    assert(serial.page(page) == parallel.page(page));
                parallel.stopPreparation();
            }
}

@("ui_vulkan.glyph_atlas.aGlyphIsRasterizedOnceAndCached")
@system unittest
{
    auto f = Fixture.at(18);
    GlyphAtlas atlas;
    AtlasGlyph a, again;
    assert(atlas.get(f.inst, 1, f.glyph('A'), f.ppem, a) == AtlasOutcome.placed);
    assert(a.width > 0 && a.height > 0 && a.bearingY > 0, "a capital stands on the baseline");
    ubyte ink;
    foreach (row; 0 .. a.height)
        foreach (col; 0 .. a.width)
            ink |= atlas.page(a.page)[(a.y + row) * GlyphAtlas.pageSize + a.x + col];
    assert(ink, "the box holds coverage");
    assert(atlas.get(f.inst, 1, f.glyph('A'), f.ppem, again) == AtlasOutcome.placed);
    assert(again == a && atlas.length == 1, "the second ask is the cache's");
}

@("ui_vulkan.glyph_atlas.aSpaceIsBlankAndNotPlaced")
@system unittest
{
    auto f = Fixture.at(18);
    GlyphAtlas atlas;
    AtlasGlyph g;
    assert(atlas.get(f.inst, 1, f.glyph(' '), f.ppem, g) == AtlasOutcome.blank);
    assert(atlas.pageCount == 0, "nothing was packed");
}

@("ui_vulkan.glyph_atlas.facesAndSizesNeverShareEntries")
@system unittest
{
    auto small = Fixture.at(12), large = Fixture.at(24);
    GlyphAtlas atlas;
    AtlasGlyph a, b, c;
    const gid = small.glyph('g');
    assert(atlas.get(small.inst, 1, gid, small.ppem, a) == AtlasOutcome.placed);
    assert(atlas.get(large.inst, 1, gid, large.ppem, b) == AtlasOutcome.placed);
    assert(atlas.get(small.inst, 2, gid, small.ppem, c) == AtlasOutcome.placed);
    assert(b.height > a.height, "24 ppem is its own, larger entry");
    assert(atlas.length == 3 && (a.x != c.x || a.y != c.y), "another face is another entry");
}

/// Effective variation coordinates separate glyphs, while defaults reuse them.
@("ui_vulkan.glyph_atlas.variationCoordinatesSeparateBothKinds")
@system unittest
{
    import sparkles.font : UserCoordinate;
    auto font = Fixture.at(24, "NotoSans.ttf");
    const light = instance(font.face, InstanceSize.pixels(font.ppem),
        [UserCoordinate(Tag("wght"), 100 << 16)]).value;
    const heavy = instance(font.face, InstanceSize.pixels(font.ppem),
        [UserCoordinate(Tag("wght"), 900 << 16)]).value;
    assert(light.coords != heavy.coords, "fixture must be variable");
    GlyphAtlas atlas;
    AtlasGlyph a, b;
    const glyph = font.glyph('M');
    assert(atlas.get(light, 1, glyph, font.ppem, a) == AtlasOutcome.placed);
    assert(atlas.get(heavy, 1, glyph, font.ppem, b) == AtlasOutcome.placed);
    assert(atlas.length == 2 && (a.x != b.x || a.y != b.y));
    assert(atlas.get(light, 1, glyph, font.ppem, a) == AtlasOutcome.placed);
    assert(atlas.length == 2);
    const white = Colour(255, 255, 255, 255);
    assert(atlas.getColour(light, 1, glyph, font.ppem, white, a) == AtlasOutcome.noColour);
    assert(atlas.getColour(heavy, 1, glyph, font.ppem, white, b) == AtlasOutcome.noColour);
    assert(atlas.length == 4, "colour lookups also retain each variation result separately");
}

@("ui_vulkan.glyph_atlas.dirtyRegionsCoverWhatWasWrittenOnce")
@system unittest
{
    auto f = Fixture.at(18);
    GlyphAtlas atlas;
    AtlasGlyph a, b;
    cast(void) atlas.get(f.inst, 1, f.glyph('a'), f.ppem, a);
    DirtyRegion[] taken;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1 && taken[0].whole, "a page's first upload is the whole page");
    taken = null;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 0, "and nothing more until something is written");
    cast(void) atlas.get(f.inst, 1, f.glyph('b'), f.ppem, b);
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1 && !taken[0].whole);
    assert(taken[0].x <= b.x && taken[0].y <= b.y
        && taken[0].x + taken[0].width >= b.x + b.width
        && taken[0].y + taken[0].height >= b.y + b.height, "the patch covers the new glyph");
}

@("ui_vulkan.glyph_atlas.anUploadNotTakenStaysDirty")
@system unittest
{
    auto f = Fixture.at(18);
    GlyphAtlas atlas;
    AtlasGlyph a, b;
    cast(void) atlas.get(f.inst, 1, f.glyph('a'), f.ppem, a);
    DirtyRegion[] taken;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return false; });
    assert(taken.length == 1, "the region was offered");
    taken = null;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1 && taken[0].whole,
        "not taken, it is offered again — still as a first, whole upload");
    taken = null;
    cast(void) atlas.get(f.inst, 1, f.glyph('b'), f.ppem, b);
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return false; });
    taken = null;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1 && !taken[0].whole
        && taken[0].x <= b.x && taken[0].y <= b.y,
        "a refused patch stays a patch, covering the same glyph");
}

@("ui_vulkan.glyph_atlas.markUnstagedUploadsWholePagesAgain")
@system unittest
{
    auto f = Fixture.at(18);
    GlyphAtlas atlas;
    AtlasGlyph a, again;
    cast(void) atlas.get(f.inst, 1, f.glyph('a'), f.ppem, a);
    DirtyRegion[] taken;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1);
    atlas.markUnstaged();
    taken = null;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1 && taken[0].whole, "the page uploads whole again");
    assert(atlas.get(f.inst, 1, f.glyph('a'), f.ppem, again) == AtlasOutcome.placed
        && again == a && atlas.length == 1, "but its glyphs are still cached");
}

@("ui_vulkan.glyph_atlas.aFullAtlasSaysSoAndStartsOver")
@system unittest
{
    auto f = Fixture.at(900); // over 512 texels a side: one capital to a page
    GlyphAtlas atlas;
    AtlasGlyph g;
    AtlasOutcome last;
    foreach (dchar c; 'A' .. 'Z')
        last = atlas.get(f.inst, 1, f.glyph(c), f.ppem, g);
    assert(last == AtlasOutcome.full && atlas.overflowed);
    assert(atlas.pageCount == GlyphAtlas.maxPages, "bounded: no page beyond the limit");
    atlas.reset();
    assert(!atlas.overflowed && atlas.length == 0);
    assert(atlas.get(f.inst, 1, f.glyph('Z'), f.ppem, g) == AtlasOutcome.placed);
}

@("ui_vulkan.glyph_atlas.aGlyphLargerThanAPageIsRefusedNotFull")
@system unittest
{
    // At this size a capital is wider than a whole page: it can never be
    // placed, however empty the atlas is. That is a per-glyph refusal,
    // not a full atlas — `full` would reset every frame and retry it.
    auto huge = Fixture.at(1800);
    GlyphAtlas atlas;
    AtlasGlyph g;
    assert(atlas.get(huge.inst, 1, huge.glyph('A'), huge.ppem, g) == AtlasOutcome.refused);
    assert(!atlas.overflowed, "one oversized glyph does not fill the atlas");
    assert(atlas.get(huge.inst, 1, huge.glyph('A'), huge.ppem, g) == AtlasOutcome.refused,
        "and the refusal is remembered, not re-measured every frame");
    auto small = Fixture.at(18);
    assert(atlas.get(small.inst, 2, small.glyph('A'), small.ppem, g) == AtlasOutcome.placed,
        "ordinary glyphs still place after it");
}

@("ui_vulkan.glyph_atlas.anEmojiIsPlacedInColour")
@system unittest
{
    auto f = Fixture.at(32, "NotoColorEmoji.ttf");
    assert(hasColourGlyphs(f.face));
    GlyphAtlas atlas;
    AtlasGlyph g, again;
    const white = Colour(255, 255, 255, 255);
    assert(atlas.getColour(f.inst, 1, f.glyph('\U0001F600'), f.ppem, white, g) == AtlasOutcome.placed);
    assert(g.colour && g.width > 20 && g.height > 20, "a grinning face, at about the em");
    assert(atlas.pageCount(true) == 1 && atlas.pageCount == 0, "in the colour sheet only");
    bool opaque, coloured;
    foreach (row; 0 .. g.height)
        foreach (col; 0 .. g.width)
        {
            const at = ((g.y + row) * GlyphAtlas.pageSize + g.x + col) * 4;
            const px = atlas.page(g.page, true)[at .. at + 4];
            opaque |= px[3] == 255;
            coloured |= px[0] != px[2]; // yellow is not grey
            assert(px[0] <= px[3] && px[1] <= px[3] && px[2] <= px[3], "premultiplied");
        }
    assert(opaque && coloured);
    assert(atlas.getColour(f.inst, 1, f.glyph('\U0001F600'), f.ppem, white, again) == AtlasOutcome.placed
        && again == g && atlas.length == 1, "cached");
    DirtyRegion[] taken;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; return true; });
    assert(taken.length == 1 && taken[0].colour && taken[0].whole);
}

@("ui_vulkan.glyph_atlas.anOutlineFaceHasNoColourForm")
@system unittest
{
    auto f = Fixture.at(18);
    assert(!hasColourGlyphs(f.face));
    GlyphAtlas atlas;
    AtlasGlyph g;
    assert(atlas.getColour(f.inst, 1, f.glyph('A'), f.ppem, Colour(0, 0, 0, 255), g)
        == AtlasOutcome.noColour);
    assert(atlas.get(f.inst, 1, f.glyph('A'), f.ppem, g) == AtlasOutcome.placed && !g.colour,
        "its outline is the coverage sheet's");
    assert(atlas.pageCount(true) == 0);
}
