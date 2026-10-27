/**
The canvas's interim glyph cache (decision `UVX12`): coverage glyphs drawn by
`sparkles:font`'s rasterizer, packed into single-channel pages, and handed to
the canvas region by region to upload.

`sparkles:font`'s own glyph cache (its startup slice S3) replaces this under
the same key — face, exact ppem, glyph and rasterizer — so the canvas keeps
its upload path and only the source moves. Until then the canvas owns this
one cache, and nothing else draws glyph pixels.

Everything here is CPU work with no device in sight, so it is tested
without a driver; the canvas uploads what `takeDirty` reports.
*/
module sparkles.ui_vulkan.glyph_atlas;

import sparkles.font : FontErrorKind, FontLimit, Instance, OutlinePoint, OutlineSegment, Ppem,
    RasterGlyph, RasterRegion, RasterWorkspace, rasterizeGlyph, rasterMeasure;

/// What became of a glyph the atlas was asked for.
enum AtlasOutcome : ubyte
{
    placed,  /// in a page: draw it from `AtlasGlyph`
    blank,   /// the glyph has no outline (a space): draw nothing, count nothing
    refused, /// the rasterizer refused it; remembered, so not retried every frame
    full,    /// every page is full; the atlas starts over on the next frame
}

/// Where a placed glyph sits in its page, and where it sits from the pen.
struct AtlasGlyph
{
    uint page;          /// 0-based page index
    int x, y;           /// its box's top-left texel in the page
    int width, height;  /// its box, in texels
    int bearingX;       /// pixels from the pen to the box's left edge
    int bearingY;       /// pixels from the baseline up to the box's top edge
}

/// A region of a page written since it was last taken, to upload.
struct DirtyRegion
{
    uint page;          ///
    bool whole;         /// the page has never been uploaded: upload all of it
    int x, y, width, height; ///
}

/// The cache key: which face, at which exact size, which glyph.
struct GlyphKey
{
    uint face;  /// the canvas's face serial; a new face is a new serial
    ulong ppemNumerator, ppemDenominator; /// `Ppem` exactly (`FTM10`)
    uint glyph; ///
}

/// The atlas. Not copyable: it owns its pages.
struct GlyphAtlas
{
    /// A page's side, in texels.
    enum uint pageSize = 1024;
    /// The most pages it holds, 1 MiB each.
    enum uint maxPages = 4;
    /// Texels left between glyphs, so nearest sampling never reads a neighbour.
    enum int padding = 1;

    private
    {
        ubyte[][] pages_;
        Shelf[][] shelves_;
        DirtyRegion[] dirty_;
        bool[] uploaded_;
        Entry[GlyphKey] entries_;
        bool overflowed_;
        Storage storage_;
    }

    @disable this(this);

    /// How many glyphs are cached, placed or refused.
    size_t length() const @safe pure nothrow @nogc => entries_.length;
    /// How many pages exist.
    size_t pageCount() const @safe pure nothrow @nogc => pages_.length;
    /// The texels of page `i`, row-major, `pageSize` wide.
    const(ubyte)[] page(size_t i) const @safe pure nothrow @nogc => pages_[i];

    /**
    Glyph `glyph` of `inst` at `ppem`, from the cache or rasterized now into
    a page. `face` is the caller's serial for `inst`'s face: glyphs of
    different faces never share entries.
    */
    AtlasOutcome get(in Instance inst, uint face, uint glyph, Ppem ppem, out AtlasGlyph g)
        @safe
    {
        const key = GlyphKey(face, ppem.numerator, ppem.denominator, glyph);
        if (auto e = key in entries_)
        {
            g = e.glyph;
            return e.outcome;
        }
        if (overflowed_)
            return AtlasOutcome.full;
        auto measured = measure(inst, glyph, ppem);
        if (measured.hasError)
            return remember(key, AtlasOutcome.refused, g);
        const m = measured.value;
        if (m.empty || m.width <= 0 || m.height <= 0)
            return remember(key, AtlasOutcome.blank, g);
        uint page;
        int x, y;
        if (!place(m.width, m.height, page, x, y))
        {
            overflowed_ = true;
            return AtlasOutcome.full;
        }
        auto region = RasterRegion(pages_[page][size_t(y) * pageSize + x .. $], pageSize,
            m.width, m.height);
        auto ws = storage_.workspace;
        auto drawn = rasterizeGlyph(inst, glyph, ppem, region, ws);
        if (drawn.hasError)
            return remember(key, AtlasOutcome.refused, g);
        markDirty(page, x, y, m.width, m.height);
        g = AtlasGlyph(page, x, y, m.width, m.height, drawn.value.bearingX, drawn.value.bearingY);
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
        foreach (i, ref p; pages_)
        {
            p[] = 0;
            shelves_[i] = null;
            uploaded_[i] = false;
            dirty_[i] = DirtyRegion(cast(uint) i, true, 0, 0, pageSize, pageSize);
        }
        overflowed_ = false;
    }

    /// Hands each page region written since the last call to `upload`,
    /// once, and forgets it.
    void takeDirty(scope void delegate(in DirtyRegion) @system upload) @system
    {
        foreach (i, ref d; dirty_)
        {
            if (d.width <= 0)
                continue;
            if (!uploaded_[i])
                d = DirtyRegion(cast(uint) i, true, 0, 0, pageSize, pageSize);
            upload(d);
            uploaded_[i] = true;
            d = DirtyRegion(cast(uint) i, false, 0, 0, 0, 0);
        }
    }

    private:

    struct Entry
    {
        AtlasOutcome outcome;
        AtlasGlyph glyph;
    }

    // A row of a page, filled left to right.
    struct Shelf
    {
        int y, height, x;
    }

    AtlasOutcome remember(in GlyphKey key, AtlasOutcome outcome, out AtlasGlyph g)
        @safe pure nothrow
    {
        entries_[key] = Entry(outcome);
        return outcome;
    }

    // The glyph's size, growing the workspace when the outline needs more.
    auto measure(in Instance inst, uint glyph, Ppem ppem) @safe
    {
        foreach (attempt; 0 .. 6)
        {
            auto ws = storage_.workspace;
            auto r = rasterMeasure(inst, glyph, ppem, ws);
            if (r.hasError && r.error.kind == FontErrorKind.limitExceeded
                && r.error.limit == FontLimit.callerStorage)
            {
                storage_.grow();
                continue;
            }
            if (r.hasValue)
                storage_.reserve(r.value.accumulationNeeded, r.value.supersampleNeeded);
            return r;
        }
        auto ws = storage_.workspace;
        return rasterMeasure(inst, glyph, ppem, ws);
    }

    // First shelf that fits, else a new shelf, else a new page.
    bool place(int w, int h, out uint page, out int x, out int y) @safe pure nothrow
    {
        const pw = w + padding, ph = h + padding;
        if (pw > pageSize || ph > pageSize)
            return false;
        foreach (p, ref shelves; shelves_)
        {
            foreach (ref s; shelves)
                if (s.height >= ph && s.height <= ph + ph / 2 && s.x + pw <= pageSize)
                {
                    page = cast(uint) p;
                    x = s.x;
                    y = s.y;
                    s.x += pw;
                    return true;
                }
            const top = shelves.length ? shelves[$ - 1].y + shelves[$ - 1].height : 0;
            if (top + ph <= pageSize)
            {
                shelves ~= Shelf(top, ph, pw);
                page = cast(uint) p;
                x = 0;
                y = top;
                return true;
            }
        }
        if (pages_.length == maxPages)
            return false;
        pages_ ~= new ubyte[pageSize * pageSize];
        shelves_ ~= [Shelf(0, ph, pw)];
        dirty_ ~= DirtyRegion(cast(uint)(pages_.length - 1), true, 0, 0, 0, 0);
        uploaded_ ~= false;
        page = cast(uint)(pages_.length - 1);
        x = y = 0;
        return true;
    }

    void markDirty(uint page, int x, int y, int w, int h) @safe pure nothrow @nogc
    {
        auto d = &dirty_[page];
        if (d.width <= 0)
        {
            *d = DirtyRegion(page, false, x, y, w, h);
            return;
        }
        const x1 = d.x + d.width > x + w ? d.x + d.width : x + w;
        const y1 = d.y + d.height > y + h ? d.y + d.height : y + h;
        d.x = d.x < x ? d.x : x;
        d.y = d.y < y ? d.y : y;
        d.width = x1 - d.x;
        d.height = y1 - d.y;
    }
}

// The rasterizer's caller-owned arrays, sized for ordinary glyphs and grown
// when an outline needs more.
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

    RasterWorkspace workspace() return @safe pure nothrow
    {
        if (!points.length)
            grow();
        return RasterWorkspace(segments, points, onCurve, contourEnds, accumulation, supersample,
            pointNumbers, deltaX, deltaY, referenced);
    }

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
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: the bundled DejaVu Sans Mono, rasterized by `sparkles:font`.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.font : charMap, Face, instance, InstanceSize, openFace;

    private const(ubyte)[] dejaVu() @system
    {
        import std.file : exists, read;
        import std.path : buildPath;
        import std.process : environment;

        const dir = environment.get("SPARKLES_FONTS_PATH");
        assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
        const path = dir.buildPath("DejaVuSansMono.ttf");
        assert(path.exists, path ~ " is missing");
        return cast(const(ubyte)[]) read(path);
    }

    private struct Fixture
    {
        const(ubyte)[] bytes;
        Face face;
        Instance inst;
        Ppem ppem;

        static Fixture at(uint px) @system
        {
            Fixture f;
            f.bytes = dejaVu();
            f.face = openFace(f.bytes).value;
            f.ppem = Ppem.fromInteger(px).value;
            f.inst = f.face.instance(InstanceSize.pixels(f.ppem), null).value;
            return f;
        }

        uint glyph(dchar c) @system => charMap(face).value.glyph(c);
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

@("ui_vulkan.glyph_atlas.dirtyRegionsCoverWhatWasWrittenOnce")
@system unittest
{
    auto f = Fixture.at(18);
    GlyphAtlas atlas;
    AtlasGlyph a, b;
    cast(void) atlas.get(f.inst, 1, f.glyph('a'), f.ppem, a);
    DirtyRegion[] taken;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; });
    assert(taken.length == 1 && taken[0].whole, "a page's first upload is the whole page");
    taken = null;
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; });
    assert(taken.length == 0, "and nothing more until something is written");
    cast(void) atlas.get(f.inst, 1, f.glyph('b'), f.ppem, b);
    atlas.takeDirty((in DirtyRegion d) { taken ~= d; });
    assert(taken.length == 1 && !taken[0].whole);
    assert(taken[0].x <= b.x && taken[0].y <= b.y
        && taken[0].x + taken[0].width >= b.x + b.width
        && taken[0].y + taken[0].height >= b.y + b.height, "the patch covers the new glyph");
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
