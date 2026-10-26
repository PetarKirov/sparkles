/**
Raster content for $(MREF sparkles,ui) (`IMG`): the opaque handle a widget
carries, the registry that owns the pixels, and the pixel→cell arithmetic that
lets an image lay out as an ordinary box.

$(B The toolkit does not decode, and does not draw.) It has no image format and
no device — `sparkles:ui` is GL-free, and a cell grid is a real target. What it
owns is the $(I addressing): a widget names an image by $(LREF ImageHandle),
the registry holds the decoded pixels under that handle, and a backend resolves
the handle when it paints. Three consequences, each of which is a requirement:

$(UL
    $(LI $(B The arena stays flat) (`IMG3`). A handle is eight bytes; the pixels
    live outside the widget tree, so a relayout re-reads a handle and never
    re-decodes a megabyte.)
    $(LI $(B Layout needs no registry) (`IMG2`). The widget carries the image's
    $(I pixel size) — which the view knows, having registered it — and layout
    converts that to cells through the measurer's cell metrics. So `layout` is
    still a pure function of the tree.)
    $(LI $(B A canvas that cannot draw rasters degrades visibly) (`IMG4`). The
    operation carries alt text for exactly that, and the degradation is in
    $(MREF sparkles,ui,interp,immediate) — one place, every backend.)
)
*/
module sparkles.ui.image;

import sparkles.base.pool.handle : Handle;
import sparkles.ui.geometry : Rect, Size;

/// The tag that keeps image handles apart from every other pool's.
struct ImageTag
{
}

/**
An image's identity: a slot in the registry that issued it and the slot's
generation when it was issued, as $(REF Handle, sparkles,base,pool,handle)
gives every pool.

Opaque on purpose: the toolkit never looks inside, and a backend uses it as a
cache key. `ImageHandle.init` is the null handle — its generation is 0, which
$(LREF ImageRegistry) never issues, so a default-constructed widget names no
image. A slot is reused after $(LREF ImageRegistry.remove), but under a new
generation: a handle to what was removed never resolves to what came next.
*/
alias ImageHandle = Handle!ImageTag;

/// How an image fills a destination rect that is not its own aspect ratio.
enum ImageFit : ubyte
{
    /// Stretch to the rect exactly, distorting the aspect ratio.
    fill,
    /// Scale to fit inside the rect, preserving aspect; letterboxed.
    contain,
    /// Scale to cover the rect, preserving aspect; overflow is clipped.
    cover,
}

/**
One registered image: decoded pixels, their extent, and the text that stands in
for them where they cannot be drawn.

$(B `rgba` is borrowed, not owned.) The registry is an index, not a heap: the
bytes belong to whoever decoded them and must outlive the registry. That is the
same bargain $(REF TextRun.text, sparkles,ui,canvas) makes, and it keeps this
module free of an allocator it would have to choose for everyone.
*/
struct ImageData
{
    /// Decoded pixels, 8-bit RGBA, row-major, `size.width * size.height * 4`
    /// bytes. May be empty for an image a backend loaded by itself and only
    /// registered the extent of.
    const(ubyte)[] rgba;

    /// The image's extent in device pixels.
    Size size;

    /// What a canvas that cannot draw rasters shows instead (`IMG4`).
    string alt;

    /// Bumped by $(LREF ImageRegistry.replace). A backend caching an upload
    /// under the handle compares this to know its texture is stale — which is
    /// why no backend state lives in the toolkit.
    uint generation;
}

/**
The image index (`IMG3`): handles in, $(LREF ImageData) out.

Lives beside the widget tree, never inside it. An application registers once —
at startup, or when a document loads — and the tree it rebuilds every frame
carries only handles.

$(B A stale handle never aliases) (the `IMG3` twin of `EFX14`): $(LREF remove)
frees the slot for the next $(LREF register), but bumps its generation first,
so a handle to the removed image resolves to nothing rather than to whatever
was registered next. Slots are reused, so a registry that images come and go
through (a terminal's kitty graphics) holds as many slots as it ever held live
images, not one per image it has seen. A slot whose generation would wrap is
retired instead of reused.
*/
struct ImageRegistry
{
    private ImageData[] _entries;
    private uint[] _generations; // per slot, ≥ 1
    private bool[] _live;
    private uint[] _free;        // freed slots, reused last-freed first
    private size_t _liveCount;

@safe:

    /// Registers `data`, returning the handle that addresses it.
    ImageHandle register(ImageData data) pure nothrow
    {
        uint i;
        if (_free.length)
        {
            i = _free[$ - 1];
            _free.length -= 1;
            _entries[i] = data;
        }
        else
        {
            i = cast(uint) _entries.length;
            _entries ~= data;
            _generations ~= 1;
            _live ~= false;
        }
        _live[i] = true;
        ++_liveCount;
        return ImageHandle(i, _generations[i]);
    }

    /// ditto
    ImageHandle register(const(ubyte)[] rgba, in Size size, string alt = null)
        pure nothrow
        => register(ImageData(rgba: rgba, size: size, alt: alt));

    /**
    Replaces the image `h` addresses, bumping its generation so a backend
    knows to re-upload. The handle stays valid and the extent may change.
    */
    void replace(ImageHandle h, ImageData data) pure nothrow @nogc
    {
        if (auto e = slotOf(h))
        {
            const gen = e.generation;
            *e = data;
            e.generation = gen + 1;
        }
    }

    /**
    Forgets `h`'s image and frees its slot for the next `register`, under a
    new generation: `h` and every copy of it resolve to nothing from here on.
    A stale or null `h` changes nothing.
    */
    void remove(ImageHandle h) pure nothrow
    {
        if (slotOf(h) is null)
            return;
        const i = h.index;
        _entries[i] = ImageData.init;
        _live[i] = false;
        --_liveCount;
        if (_generations[i] == uint.max)
            return; // retired: a wrapped generation could alias an old handle
        ++_generations[i];
        _free ~= i;
    }

    /// The image `h` addresses, or `null` for a null, stale or removed handle.
    const(ImageData)* lookup(ImageHandle h) const pure nothrow @nogc return
    {
        if (!h.valid || h.index >= _entries.length || !_live[h.index]
            || _generations[h.index] != h.generation)
            return null;
        return &_entries[h.index];
    }

    /// The registered extent of `h`, or `Size.init`.
    Size sizeOf(ImageHandle h) const pure nothrow @nogc
    {
        const e = lookup(h);
        return e is null ? Size.init : e.size;
    }

    /// How many images are registered now.
    size_t length() const pure nothrow @nogc => _liveCount;

    /// How many slots the registry holds, live or free: the most images it
    /// has held at once, plus any retired slots.
    size_t slotCount() const pure nothrow @nogc => _entries.length;

    private ImageData* slotOf(ImageHandle h) pure nothrow @nogc return
        => lookup(h) is null ? null : &_entries[h.index];
}

/**
The device size of one cell, in pixels — the fallback for a measurer that does
not report its own.

A cell grid has no pixels at all, and a GUI canvas knows its font's metrics; in
between sits every headless consumer, which needs $(I some) number to turn an
image's extent into cells. This is that number, and it is declared rather than
guessed at each call site: roughly a 14 px monospace cell, the shape the
toolkit's own defaults produce.
*/
enum Size defaultCellPixels = Size(8, 16);

/**
`tm`'s cell metrics, or $(LREF defaultCellPixels).

An optional measurer primitive, discovered by presence the way the canvas seam
discovers `pushClip`: a measurer that knows its device reports
`Size cellPixels()`, and one that does not costs nothing.
*/
Size cellPixelsOf(TM)(ref TM tm)
{
    static if (__traits(compiles, { Size s = tm.cellPixels(); }))
    {
        const s = tm.cellPixels();
        return s.width > 0 && s.height > 0 ? s : defaultCellPixels;
    }
    else
        return defaultCellPixels;
}

/**
An image's intrinsic extent in whole cells (`IMG2`).

Rounds $(B up): a picture 9 px wide in an 8 px cell occupies two cells, because
reserving one would crop it. A non-empty image never measures zero — an image
smaller than a cell still gets the cell it needs to be seen in.
*/
Size imageCells(in Size pixels, in Size cell) @safe pure nothrow @nogc
{
    if (pixels.width <= 0 || pixels.height <= 0
        || cell.width <= 0 || cell.height <= 0)
        return Size(0, 0);
    return Size(
        (pixels.width + cell.width - 1) / cell.width,
        (pixels.height + cell.height - 1) / cell.height);
}

/**
Where the image lands inside `dest` under `fit`, in the same units as `dest`.

$(LREF ImageFit.fill) is `dest` itself; $(LREF ImageFit.contain) is the largest
aspect-correct rect inside it, centred; $(LREF ImageFit.cover) is the smallest
that covers it, centred and overflowing — a caller clips, exactly as it would
clip anything else.

Shared arithmetic rather than each backend's own, because "contain" disagreeing
between the window and the terminal is the sort of difference nothing catches.
*/
Rect fitRect(in Rect dest, in Size pixels, ImageFit fit)
    @safe pure nothrow @nogc
{
    if (fit == ImageFit.fill || pixels.width <= 0 || pixels.height <= 0
        || dest.width <= 0 || dest.height <= 0)
        return dest;

    // Compare aspect ratios by cross-multiplying, so this stays integer.
    const wide = cast(long) pixels.width * dest.height
        > cast(long) dest.width * pixels.height;
    // `contain` matches the tighter axis; `cover` the looser one.
    const matchWidth = fit == ImageFit.contain ? wide : !wide;

    int w = dest.width, h = dest.height;
    if (matchWidth)
        h = cast(int)((cast(long) dest.width * pixels.height) / pixels.width);
    else
        w = cast(int)((cast(long) dest.height * pixels.width) / pixels.height);
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    return Rect(dest.x + (dest.width - w) / 2, dest.y + (dest.height - h) / 2,
        w, h);
}

@("ui.image.registry.aStaleHandleNeverAliasesTheSlotsNextImage")
@safe pure nothrow unittest
{
    ImageRegistry reg;
    assert(!ImageHandle.init.valid, "the default widget names no image");
    assert(reg.lookup(ImageHandle.init) is null);

    const a = reg.register(null, Size(32, 16), "a chart");
    const b = reg.register(null, Size(8, 8), "an icon");
    assert(a.valid && b.valid && a != b);
    assert(reg.sizeOf(a) == Size(32, 16));
    assert(reg.lookup(a).alt == "a chart");

    // Removing frees the slot for reuse, under a new generation: the next
    // registration takes `a`'s slot, and `a` itself resolves to nothing.
    reg.remove(a);
    assert(reg.sizeOf(a) == Size.init);
    const c = reg.register(null, Size(4, 4), "later");
    assert(c.index == a.index && c != a, "the slot is reused, the handle is not");
    assert(reg.sizeOf(c) == Size(4, 4));
    assert(reg.lookup(a) is null, "a stale handle does not see the slot's new image");
    reg.remove(a);
    assert(reg.sizeOf(c) == Size(4, 4), "removing through a stale handle changes nothing");

    // Replacing bumps the generation, which is how a backend's cached upload
    // learns it is stale without the toolkit knowing what an upload is.
    const gen = reg.lookup(b).generation;
    reg.replace(b, ImageData(size: Size(16, 16), alt: "an icon"));
    assert(reg.lookup(b).generation == gen + 1);
    assert(reg.sizeOf(b) == Size(16, 16));

    // A handle from beyond the end is not a crash.
    assert(reg.lookup(ImageHandle(9999, 1)) is null);
}

@("ui.image.registry.churnKeepsTheSlotCountBounded")
@safe pure nothrow unittest
{
    // A stream of images (a terminal's kitty graphics) holds as many slots
    // as it ever held live images, however many it has seen.
    ImageRegistry reg;
    const kept = reg.register(null, Size(1, 1), "kept");
    ImageHandle[3] shown;
    foreach (i; 0 .. 1000)
    {
        foreach (ref h; shown)
            h = reg.register(null, Size(2, 2), "shown");
        foreach (h; shown)
            reg.remove(h);
    }
    assert(reg.slotCount == 4, "one kept image plus three at a time");
    assert(reg.length == 1 && reg.sizeOf(kept) == Size(1, 1));
}

@("ui.image.cells.roundsUpAndNeverVanishes")
@safe pure nothrow @nogc unittest
{
    assert(imageCells(Size(16, 32), Size(8, 16)) == Size(2, 2));
    // Rounds up: one cell would crop the ninth column.
    assert(imageCells(Size(9, 17), Size(8, 16)) == Size(2, 2));
    // Smaller than a cell still gets the cell it needs to be seen in.
    assert(imageCells(Size(1, 1), Size(8, 16)) == Size(1, 1));
    assert(imageCells(Size(0, 0), Size(8, 16)) == Size(0, 0));
    assert(imageCells(Size(8, 16), Size(0, 0)) == Size(0, 0));
}

@("ui.image.fitRect.containAndCoverAgreeOnTheSquareCase")
@safe pure nothrow @nogc unittest
{
    const dest = Rect(10, 20, 40, 10);

    // `fill` is the rect itself, distortion and all.
    assert(fitRect(dest, Size(100, 100), ImageFit.fill) == dest);

    // A square in a wide rect: `contain` matches the short axis and centres.
    const c = fitRect(dest, Size(100, 100), ImageFit.contain);
    assert(c.width == 10 && c.height == 10);
    assert(c.x == 10 + (40 - 10) / 2 && c.y == 20);

    // `cover` matches the long one and overflows the short one symmetrically.
    const o = fitRect(dest, Size(100, 100), ImageFit.cover);
    assert(o.width == 40 && o.height == 40);
    assert(o.x == 10 && o.y == 20 + (10 - 40) / 2);

    // When the aspect ratios already agree, every fit is the rect.
    assert(fitRect(dest, Size(80, 20), ImageFit.contain) == dest);
    assert(fitRect(dest, Size(80, 20), ImageFit.cover) == dest);

    // Degenerate input degrades to the rect rather than dividing by zero.
    assert(fitRect(dest, Size(0, 5), ImageFit.contain) == dest);
    assert(fitRect(Rect(0, 0, 0, 0), Size(4, 4), ImageFit.cover) == Rect(0, 0, 0, 0));
}

@("ui.image.cellPixelsOf.discoversTheMetricByPresence")
@safe pure nothrow @nogc unittest
{
    static struct Blind {}
    static struct Knowing { Size cellPixels() const @safe pure nothrow @nogc => Size(9, 18); }
    static struct Lying { Size cellPixels() const @safe pure nothrow @nogc => Size(0, 0); }

    Blind blind;
    Knowing knowing;
    Lying lying;
    assert(cellPixelsOf(blind) == defaultCellPixels);
    assert(cellPixelsOf(knowing) == Size(9, 18));
    // A degenerate report is not a division hazard waiting to happen.
    assert(cellPixelsOf(lying) == defaultCellPixels);
}
