/**
The terminal's drawing seam: everything the per-cell renderer
(`paintFrame`) asks of a graphics backend, in pixels, with no backend's types
in it.

The renderer decides what to draw — which cells have a background, which
glyph a cell shows and in which colour, where the cursor and the decorations
go, which kitty image is placed where. A painter only draws: a solid
rectangle, a one-pixel outline, a grapheme cluster across a run of cells, a
short label, and textured rectangles for kitty images. It also owns the GPU
side of an image (create, update rows, release), so the image cache can
decide what is resident without knowing what a texture is.

`sparkles.terminal_view.raylib_painter` is the raylib implementation;
`RecordingPainter` records the calls, for tests that have no window.
*/
module sparkles.terminal_view.painter;

import sparkles.base.term_color : RgbColor;

/// A colour with coverage: what a fill, a glyph or an image tint is drawn in.
struct Rgba
{
    ubyte r, g, b;
    ubyte a = 255;

    /// An opaque `RgbColor`.
    static Rgba opaque(in RgbColor c) @safe pure nothrow @nogc
        => Rgba(c.r, c.g, c.b, 255);
}

/// A rectangle in (possibly fractional) pixels, for an image placement.
struct ImageRect
{
    float x = 0, y = 0, width = 0, height = 0;
}

/// How an image's pixels are laid out, row after row with no padding.
enum PixelLayout : ubyte
{
    gray,      /// one byte per pixel
    grayAlpha, /// two
    rgb,       /// three
    rgba,      /// four
}

/// Bytes per pixel of `layout`.
uint channels(PixelLayout layout) @safe pure nothrow @nogc
    => layout + 1;

/// A painter's image, `TextureId.init` (0) for none. It carries the image's
/// size and layout, which a backend may need to draw it.
struct TextureId
{
    uint value;          /// the backend's name for it
    uint width, height;  /// its size in pixels
    PixelLayout layout;  /// ditto, its pixels

    /// Whether this names an image.
    bool valid() const @safe pure nothrow @nogc => value != 0;
}

/// The pixels of an image a painter uploads: `height` rows of
/// `width * channels(layout)` bytes.
struct ImagePixels
{
    uint width;
    uint height;
    PixelLayout layout;
    const(ubyte)[] pixels;
}

/**
Whether `P` holds a terminal's images: creates a texture from pixels,
replaces a span of its rows, releases it, and draws a part of it into a
rectangle. Releasing must be safe while draws that read the texture are
still queued: the painter flushes them first.
*/
enum isTextureSink(P) = is(typeof((ref P p) {
    TextureId t = p.createTexture(ImagePixels.init);
    p.updateTextureRows(t, ImagePixels.init, 0, 1);
    p.releaseTexture(t);
    p.drawTexture(t, ImageRect.init, ImageRect.init);
}));

/**
The texture sink with no textures: it creates none, so nothing is ever drawn
or released through it. What an image cache is released with when no painter
ever drew from it — a headless terminal's.
*/
struct NoTextures
{
    TextureId createTexture(in ImagePixels) const @safe pure nothrow @nogc => TextureId.init;
    void updateTextureRows(TextureId, in ImagePixels, size_t, size_t) const @safe pure nothrow @nogc {}
    void releaseTexture(TextureId) const @safe pure nothrow @nogc {}
    void drawTexture(TextureId, in ImageRect, in ImageRect) const @safe pure nothrow @nogc {}
}

static assert(isTextureSink!NoTextures);

/**
Whether `P` can paint a terminal (`paintFrame`).

$(UL
$(LI `fill(x, y, w, h, colour)`: a solid rectangle, blended over what is
    there.)
$(LI `outline(x, y, w, h, colour)`: the rectangle's one-pixel border (the
    hollow cursor).)
$(LI `cluster(codepoints, bold, italic, x, y, w, h, ink)`: a grapheme
    cluster in a run of cells `w` × `h` pixels, at the cell's top-left
    corner.)
$(LI `labelSize(text)` and `label(text, x, y, colour)`: a line of text in
    the terminal's primary face, measured and drawn (the exit banner).)
$(LI `clip`/`unclip` and `pushOffset`/`popOffset`: where an embedded pane
    goes. A clip replaces the current one; offsets nest.)
$(LI the image operations of $(LREF isTextureSink).)
)
*/
enum isTerminalPainter(P) = isTextureSink!P && is(typeof((ref P p) {
    p.fill(0, 0, 1, 1, Rgba.init);
    p.outline(0, 0, 1, 1, Rgba.init);
    p.cluster((const(uint)[]).init, false, false, 0, 0, 1, 1, Rgba.init);
    float[2] size = p.labelSize((const(char)[]).init);
    p.label((const(char)[]).init, 0.0f, 0.0f, Rgba.init);
    p.clip(0, 0, 1, 1);
    p.unclip();
    p.pushOffset(0, 0);
    p.popOffset();
}));

/**
A painter that records instead of drawing — the renderer's oracle where
there is no window. Every call becomes one `Call`; images are numbered from
1 in the order they were created.
*/
struct RecordingPainter
{
    /// What a call was.
    enum Op : ubyte
    {
        fill, outline, cluster, label, clip, unclip, pushOffset, popOffset,
        createTexture, updateTextureRows, releaseTexture, drawTexture,
    }

    /// One recorded call; the fields a call does not use stay `init`.
    struct Call
    {
        Op op;
        int x, y, width, height;
        Rgba colour;
        uint[] codepoints;
        bool bold, italic;
        string text;
        TextureId texture;
        ImageRect source, destination;
    }

    Call[] calls;               /// every call, in order
    float labelWidth = 8;       /// a label's width per byte
    float labelHeight = 16;     /// a label's height
    private uint nextTexture;

    void fill(int x, int y, int w, int h, Rgba c) @safe pure nothrow
    {
        calls ~= Call(op: Op.fill, x: x, y: y, width: w, height: h, colour: c);
    }

    void outline(int x, int y, int w, int h, Rgba c) @safe pure nothrow
    {
        calls ~= Call(op: Op.outline, x: x, y: y, width: w, height: h, colour: c);
    }

    void cluster(scope const(uint)[] cps, bool bold, bool italic, int x, int y, int w, int h,
        Rgba ink) @safe pure nothrow
    {
        calls ~= Call(op: Op.cluster, x: x, y: y, width: w, height: h, colour: ink,
            codepoints: cps.dup, bold: bold, italic: italic);
    }

    float[2] labelSize(scope const(char)[] text) const @safe pure nothrow @nogc
        => [labelWidth * text.length, labelHeight];

    void label(scope const(char)[] text, float x, float y, Rgba c) @safe pure nothrow
    {
        calls ~= Call(op: Op.label, x: cast(int) x, y: cast(int) y, colour: c, text: text.idup);
    }

    void clip(int x, int y, int w, int h) @safe pure nothrow
    {
        calls ~= Call(op: Op.clip, x: x, y: y, width: w, height: h);
    }

    void unclip() @safe pure nothrow
    {
        calls ~= Call(op: Op.unclip);
    }

    void pushOffset(float dx, float dy) @safe pure nothrow
    {
        calls ~= Call(op: Op.pushOffset, x: cast(int) dx, y: cast(int) dy);
    }

    void popOffset() @safe pure nothrow
    {
        calls ~= Call(op: Op.popOffset);
    }

    TextureId createTexture(in ImagePixels image) @safe pure nothrow
    {
        const t = TextureId(++nextTexture, image.width, image.height, image.layout);
        calls ~= Call(op: Op.createTexture, width: image.width, height: image.height,
            texture: t);
        return t;
    }

    void updateTextureRows(TextureId t, in ImagePixels image, size_t first, size_t count)
        @safe pure nothrow
    {
        calls ~= Call(op: Op.updateTextureRows, y: cast(int) first, height: cast(int) count,
            texture: t);
    }

    void releaseTexture(TextureId t) @safe pure nothrow
    {
        calls ~= Call(op: Op.releaseTexture, texture: t);
    }

    void drawTexture(TextureId t, in ImageRect source, in ImageRect destination)
        @safe pure nothrow
    {
        calls ~= Call(op: Op.drawTexture, texture: t, source: source,
            destination: destination);
    }

    /// The calls of one kind, in order.
    Call[] only(Op op) @safe pure nothrow
    {
        Call[] r;
        foreach (c; calls)
            if (c.op == op)
                r ~= c;
        return r;
    }
}

static assert(isTerminalPainter!RecordingPainter);

///
@("terminal_view.painter.recordingPainterRecords")
@safe pure nothrow unittest
{
    RecordingPainter p;
    p.fill(1, 2, 3, 4, Rgba(5, 6, 7));
    const t = p.createTexture(ImagePixels(2, 2, PixelLayout.rgba, null));
    p.drawTexture(t, ImageRect(0, 0, 2, 2), ImageRect(10, 10, 20, 20));
    assert(p.calls.length == 3);
    assert(p.calls[0] == RecordingPainter.Call(op: RecordingPainter.Op.fill, x: 1, y: 2,
        width: 3, height: 4, colour: Rgba(5, 6, 7)));
    assert(t == TextureId(1, 2, 2, PixelLayout.rgba) && p.only(RecordingPainter.Op.drawTexture).length == 1);
    assert(channels(PixelLayout.gray) == 1 && channels(PixelLayout.rgba) == 4);
}
