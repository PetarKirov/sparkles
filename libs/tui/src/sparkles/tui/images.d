/++
Images over the cell grid, by the kitty graphics protocol (`IMG5`).

A $(REF Screen, sparkles,tui,render) diffs cells; an image is not a cell. So
the images of a frame travel beside the grid as a list of
$(LREF ImagePlacement)s, and $(LREF KittyImages) diffs $(I that) list the way
the screen diffs cells: pixels are transmitted once per image and generation,
a placement is emitted only when it is new or has moved, and one that is gone
is deleted. A steady frame with an image on it writes no graphics bytes at
all.

Every command carries `q=2`, so the terminal never answers — a reply would
arrive on the input stream as bytes the key decoder does not know. Placements
do not move the cursor (`C=1`), so the diff's cursor bookkeeping is untouched.

The protocol: $(LINK https://sw.kovidgoyal.net/kitty/graphics-protocol/).
+/
module sparkles.tui.images;

import std.range.primitives : put;

import sparkles.base.term_control : writeCursorTo;
import sparkles.base.text.base_codecs : encodeBase64;
import sparkles.base.text.writers : writeInteger;

/**
One image drawn over the grid this frame: which pixels, and which cells.

The pixels are $(B borrowed) for the frame — the caller's registry owns them —
and identified by `image` and `generation`, so they are sent again only when
either changes. The picture is scaled to exactly `cols`×`rows` cells, shifted
by `offsetX`/`offsetY` pixels inside its first cell, after cropping the
source to `crop` (all zero: the whole picture) — which is how a caller
expresses `contain` and `cover`.
*/
struct ImagePlacement
{
    uint image;              /// the caller's stable id for these pixels (non-zero)
    uint generation;         /// bumped when the pixels under `image` change
    const(ubyte)[] rgba;     /// 8-bit RGBA, row-major, `width * height * 4` bytes
    ushort width, height;    /// the pixels' extent
    ushort x, y;             /// the top-left cell
    ushort cols, rows;       /// the cells the picture is scaled to
    ushort offsetX, offsetY; /// pixel offset inside the first cell
    ushort cropX, cropY, cropW, cropH; /// source rectangle, all zero for the whole

    // Everything a placement command says — two placements equal here draw
    // the same thing in the same place.
    private bool samePlace(in ImagePlacement o) const @safe pure nothrow @nogc
        => x == o.x && y == o.y && cols == o.cols && rows == o.rows
            && offsetX == o.offsetX && offsetY == o.offsetY && cropX == o.cropX
            && cropY == o.cropY && cropW == o.cropW && cropH == o.cropH;
}

/**
The terminal's side of the images: what it holds from earlier frames. One per
output surface, beside the $(REF Screen, sparkles,tui,render).
*/
struct KittyImages
{
    private
    {
        static struct Placed
        {
            ImagePlacement where; // pixels not retained: only the geometry
            uint placement;       // kitty's `p`: occurrence of this image, from 1
        }
        static struct Sent
        {
            uint image;
            uint generation;
        }
        Placed[] _placed;        // last frame's placements
        Sent[] _sent;            // what the terminal holds: a frame has few images
    }

    // The generation (plus one) the terminal holds for `image`, `0` for none.
    private uint heldGeneration(uint image) const @safe pure nothrow @nogc
    {
        foreach (ref e; _sent)
            if (e.image == image)
                return e.generation;
        return 0;
    }

    private void hold(uint image, uint generation) @safe pure nothrow
    {
        foreach (ref e; _sent)
            if (e.image == image)
            {
                e.generation = generation;
                return;
            }
        _sent ~= Sent(image, generation);
    }

    /**
    Brings the terminal's images to `frame`: transmits pixels it does not
    hold, places what is new or moved, deletes what is gone. `repaint` re-places
    everything — after a full repaint or a resize the cells under a placement
    may have been rewritten.

    Written after the frame's cells, so a picture lands over the cells it
    covers. Nothing here moves the terminal's cursor.
    */
    void update(Writer)(ref Writer w, in ImagePlacement[] frame, bool repaint = false)
    {
        Placed[] next;
        next.reserve(frame.length);
        uint[] resent; // images transmitted this frame
        foreach (ref f; frame)
        {
            if (f.image == 0 || f.rgba.length < cast(size_t) f.width * f.height * 4
                || f.cols == 0 || f.rows == 0)
                continue;
            uint occurrence = 1;
            foreach (ref n; next)
                if (n.where.image == f.image)
                    ++occurrence;

            // New pixels replace the image, and with it every placement the
            // terminal had for it — so this frame's are all placed afresh,
            // the image's later occurrences included.
            if (heldGeneration(f.image) != f.generation + 1)
            {
                transmit(w, f);
                hold(f.image, f.generation + 1);
                resent ~= f.image;
            }
            bool fresh;
            foreach (id; resent)
                fresh |= id == f.image;
            const previous = find(f.image, occurrence);
            if (fresh || repaint || previous is null || !previous.where.samePlace(f))
                place(w, f, occurrence);
            next ~= Placed(f, occurrence);
        }
        foreach (ref p; _placed)
            if (!containsKey(next, p.where.image, p.placement)
                && heldGeneration(p.where.image) != 0)
                remove(w, p.where.image, p.placement);
        _placed = next;
    }

    /**
    Deletes every image this surface transmitted, pixels included — what a
    session does on the way out, so the terminal does not keep them.
    */
    void clear(Writer)(ref Writer w)
    {
        foreach (ref e; _sent)
        {
            put(w, "\x1b_Ga=d,d=I,i=");
            writeInteger(w, e.image);
            put(w, ",q=2\x1b\\");
        }
        _sent = null;
        _placed = null;
    }

    private const(Placed)* find(uint image, uint placement) const @safe pure nothrow @nogc
    {
        foreach (ref p; _placed)
            if (p.where.image == image && p.placement == placement)
                return &p;
        return null;
    }

    private static bool containsKey(in Placed[] list, uint image, uint placement)
        @safe pure nothrow @nogc
    {
        foreach (ref p; list)
            if (p.where.image == image && p.placement == placement)
                return true;
        return false;
    }
}

// The pixels, in chunks of at most 4096 base64 characters: 3072 bytes each,
// so every chunk but the last is whole groups with no padding.
private void transmit(Writer)(ref Writer w, in ImagePlacement f)
{
    enum chunk = 3072;
    const data = f.rgba[0 .. cast(size_t) f.width * f.height * 4];
    for (size_t at = 0; at < data.length; at += chunk)
    {
        const end = at + chunk < data.length ? at + chunk : data.length;
        const last = end == data.length;
        if (at == 0)
        {
            put(w, "\x1b_Ga=t,f=32,s=");
            writeInteger(w, f.width);
            put(w, ",v=");
            writeInteger(w, f.height);
            put(w, ",i=");
            writeInteger(w, f.image);
            put(w, ",q=2,m=");
        }
        else
            put(w, "\x1b_Gq=2,m=");
        put(w, last ? '0' : '1');
        put(w, ';');
        encodeBase64(w, data[at .. end]);
        put(w, "\x1b\\");
    }
}

private void place(Writer)(ref Writer w, in ImagePlacement f, uint placement)
{
    writeCursorTo(w, cast(uint)(f.y + 1), cast(uint)(f.x + 1));
    put(w, "\x1b_Ga=p,i=");
    writeInteger(w, f.image);
    put(w, ",p=");
    writeInteger(w, placement);
    put(w, ",c=");
    writeInteger(w, f.cols);
    put(w, ",r=");
    writeInteger(w, f.rows);
    if (f.offsetX)
    {
        put(w, ",X=");
        writeInteger(w, f.offsetX);
    }
    if (f.offsetY)
    {
        put(w, ",Y=");
        writeInteger(w, f.offsetY);
    }
    if (f.cropW && f.cropH)
    {
        put(w, ",x=");
        writeInteger(w, f.cropX);
        put(w, ",y=");
        writeInteger(w, f.cropY);
        put(w, ",w=");
        writeInteger(w, f.cropW);
        put(w, ",h=");
        writeInteger(w, f.cropH);
    }
    put(w, ",C=1,q=2\x1b\\");
}

private void remove(Writer)(ref Writer w, uint image, uint placement)
{
    put(w, "\x1b_Ga=d,d=i,i=");
    writeInteger(w, image);
    put(w, ",p=");
    writeInteger(w, placement);
    put(w, ",q=2\x1b\\");
}

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.algorithm.searching : canFind, count;

    private static immutable ubyte[8] twoPixels = [255, 0, 0, 255, 0, 0, 255, 255];

    private ImagePlacement at(ushort x, ushort y, uint generation = 0) @safe pure nothrow
        => ImagePlacement(image: 7, generation: generation, rgba: twoPixels[],
            width: 1, height: 2, x: x, y: y, cols: 4, rows: 2);

    // A `SharedBuffer`, as the render tests use: the cursor writer puts
    // `const(char)[]` sequences an immutable-element appender refuses.
    private string frame(ref KittyImages k, in ImagePlacement[] f, bool repaint = false) @safe
    {
        import sparkles.base.buffer : SharedBuffer;

        SharedBuffer!(char, 256) w;
        k.update(w, f, repaint);
        return w[].idup;
    }
}

@("tui.images.transmitOncePlaceOnceThenNothing")
@safe unittest
{
    KittyImages k;
    const first = frame(k, [at(2, 3)]);
    // The pixels, then the placement at the image's cell — `CUP` is 1-based.
    assert(first.canFind("\x1b_Ga=t,f=32,s=1,v=2,i=7,q=2,m=0;/wAA/wAA//8=\x1b\\"));
    assert(first.canFind("\x1b[4;3H\x1b_Ga=p,i=7,p=1,c=4,r=2,C=1,q=2\x1b\\"));
    // The same frame again costs nothing.
    assert(frame(k, [at(2, 3)]) == "");
}

@("tui.images.movedIsReplacedGoneIsDeleted")
@safe unittest
{
    KittyImages k;
    cast(void) frame(k, [at(0, 0)]);
    // Moved: placed again under the same `p`, which replaces it; the pixels
    // are not sent again.
    const moved = frame(k, [at(5, 1)]);
    assert(!moved.canFind("a=t") && moved.canFind("\x1b[2;6H\x1b_Ga=p,i=7,p=1,"));
    // Gone: deleted, keeping the pixels for a later frame.
    assert(frame(k, []) == "\x1b_Ga=d,d=i,i=7,p=1,q=2\x1b\\");
    // Back: placed without retransmitting.
    const back = frame(k, [at(5, 1)]);
    assert(!back.canFind("a=t") && back.canFind("a=p"));
}

@("tui.images.newPixelsAreSentAgainAndEveryPlacementRenewed")
@safe unittest
{
    KittyImages k;
    cast(void) frame(k, [at(0, 0), at(0, 4)]);
    // A new generation replaces the image in the terminal, which drops its
    // placements there — so both are placed again, and each keeps its `p`.
    const next = frame(k, [at(0, 0, 1), at(0, 4, 1)]);
    assert(next.count("a=t") == 1);
    assert(next.canFind("p=1,") && next.canFind("p=2,"));
    // A repaint re-places without retransmitting.
    const repainted = frame(k, [at(0, 0, 1), at(0, 4, 1)], true);
    assert(!repainted.canFind("a=t") && repainted.count("a=p") == 2);
}

@("tui.images.largePicturesAreChunked")
@safe unittest
{
    // 64×64 RGBA is 16384 bytes: six chunks of at most 4096 characters, only
    // the first carrying the keys and only the last saying `m=0`.
    auto px = new ubyte[](64 * 64 * 4);
    KittyImages k;
    const out_ = frame(k, [ImagePlacement(image: 1, rgba: px, width: 64, height: 64,
        cols: 8, rows: 4)]);
    assert(out_.count("\x1b_G") == 7); // six chunks and the placement
    assert(out_.count("m=1;") == 5 && out_.count("m=0;") == 1);
    assert(out_.count("s=64,v=64") == 1);
}

@("tui.images.clearFreesWhatWasSent")
@safe unittest
{
    import sparkles.base.buffer : SharedBuffer;

    KittyImages k;
    cast(void) frame(k, [at(0, 0)]);
    SharedBuffer!(char, 64) w;
    k.clear(w);
    assert(w[] == "\x1b_Ga=d,d=I,i=7,q=2\x1b\\");
    // Nothing held any more: the next frame transmits again.
    assert(frame(k, [at(0, 0)]).canFind("a=t"));
}

@("tui.images.malformedPlacementsAreSkipped")
@safe unittest
{
    KittyImages k;
    // No id, short pixels, or no cells: nothing a terminal could draw.
    auto noId = at(0, 0);
    noId.image = 0;
    auto shortPx = at(0, 0);
    shortPx.width = 9;
    auto noCells = at(0, 0);
    noCells.cols = 0;
    assert(frame(k, [noId, shortPx, noCells]) == "");
}
