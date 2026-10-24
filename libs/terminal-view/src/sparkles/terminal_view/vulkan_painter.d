/**
A terminal painter over a canvas that draws in device pixels (`UVX11`).

Glyphs and labels draw nothing and count a miss — the canvas's `glyph` and
`textRun` already do, and there is no atlas until the font slice. Kitty
images are handles in $(LREF VulkanImages); the canvas uploads them.
*/
module sparkles.terminal_view.vulkan_painter;

import sparkles.shaders : v4, vec4;
import sparkles.terminal_view.painter : ImagePixels, ImageRect, isTerminalPainter,
    PixelLayout, Rgba, TextureId;
import sparkles.terminal_view.vulkan_images : VulkanImages;
import sparkles.ui.geometry : Point;
import sparkles.ui.image : ImageHandle, ImageRegistry;
import sparkles.ui.style : Visual;

struct VulkanTerminalPainter(C)
{
    C* canvas;
    VulkanImages* images;
    int fontSize = 16;

    private const(ImageRegistry)* found_;
    private bool bound_;

    /// Binds the pane's image registry on the canvas, keeping the one it
    /// found for $(LREF unbind). Idempotent until then.
    void bind()
    {
        if (bound_ || canvas is null || images is null)
            return;
        found_ = canvas.boundImages;
        canvas.images(images.registryRef);
        bound_ = true;
    }

    /// Puts back the registry `bind` found, so what the embedder draws
    /// after the pane resolves against its own (`UVX11`).
    void unbind()
    {
        if (!bound_)
            return;
        canvas.images(found_);
        bound_ = false;
    }

    void fill(int x, int y, int w, int h, Rgba c)
    {
        canvas.fillPx(x, y, w, h, rgba(c));
    }

    void outline(int x, int y, int w, int h, Rgba c)
    {
        canvas.outlinePx(x, y, w, h, rgba(c));
    }

    void cluster(scope const(uint)[] cps, bool, bool, int, int, int, int, Rgba)
    {
        if (cps.length)
            canvas.glyph(Point.init, cast(dchar) cps[0], Visual.init);
    }

    void label(scope const(char)[] text, float, float, Rgba)
    {
        if (text.length)
            canvas.textRun(Point.init, text, Visual.init);
    }

    /// A placeholder until the font atlas (V3) measures text: a byte count
    /// times the font size, wide enough to lay a label out without overlap.
    float[2] labelSize(scope const(char)[] text) const @safe pure nothrow @nogc
        => [fontSize * text.length, fontSize];

    void clip(int x, int y, int w, int h)
    {
        canvas.clipPx(x, y, w, h);
    }

    void unclip()
    {
        canvas.unclipPx();
    }

    void pushOffset(float x, float y)
    {
        canvas.pushOffsetPx(cast(int) x, cast(int) y);
    }

    void popOffset()
    {
        canvas.popOffsetPx();
    }

    TextureId createTexture(in ImagePixels image)
        => images.createTexture(image);

    void updateTextureRows(TextureId t, in ImagePixels image, size_t first, size_t count)
    {
        images.updateTextureRows(t, image, first, count);
    }

    void releaseTexture(TextureId t)
    {
        images.releaseTexture(t);
    }

    void drawTexture(TextureId t, in ImageRect source, in ImageRect destination)
    {
        bind();
        canvas.imageSourcePx(ImageHandle(t.value),
            cast(int) destination.x, cast(int) destination.y,
            cast(int) destination.width, cast(int) destination.height,
            cast(int) source.x, cast(int) source.y,
            cast(int) source.width, cast(int) source.height);
    }
}

private vec4 rgba(Rgba c) @safe pure nothrow @nogc
    => v4(c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f);

private struct RecCanvas
{
    int glyphs;
    int texts;
    int quads;
    const(ImageRegistry)* bound;

    void fillPx(int, int, int, int, vec4) @safe pure nothrow @nogc {}
    void outlinePx(int, int, int, int, vec4) @safe pure nothrow @nogc {}
    void clipPx(int, int, int, int) @safe pure nothrow @nogc {}
    void unclipPx() @safe pure nothrow @nogc {}
    void pushOffsetPx(int, int) @safe pure nothrow @nogc {}
    void popOffsetPx() @safe pure nothrow @nogc {}
    void images(const(ImageRegistry)* r) @safe pure nothrow @nogc { bound = r; }
    const(ImageRegistry)* boundImages() const @safe pure nothrow @nogc => bound;
    void glyph(in Point, dchar, in Visual) @safe pure nothrow @nogc { ++glyphs; }
    void textRun(in Point, scope const(char)[], in Visual) @safe pure nothrow @nogc { ++texts; }
    void imageSourcePx(ImageHandle, int, int, int, int, int, int, int, int) @safe pure nothrow @nogc
    {
        ++quads;
    }
}

static assert(isTerminalPainter!(VulkanTerminalPainter!RecCanvas));

@("terminal_view.vulkan_painter.glyphsMissAndImagesAreHandles")
@system pure nothrow
unittest
{
    RecCanvas canvas;
    VulkanImages images;
    auto painter = VulkanTerminalPainter!RecCanvas(&canvas, &images, 16);
    painter.cluster([uint('A')], false, false, 0, 0, 8, 16, Rgba.init);
    painter.label("x", 0, 0, Rgba.init);
    assert(canvas.glyphs == 1 && canvas.texts == 1);

    immutable ubyte[4] px = [1, 2, 3, 4];
    const t = painter.createTexture(ImagePixels(1, 1, PixelLayout.rgba, px));
    painter.drawTexture(t, ImageRect(0, 0, 1, 1), ImageRect(4, 8, 1, 1));
    assert(canvas.quads == 1);
    assert(canvas.bound == images.registryRef);
}

@("terminal_view.vulkan_painter.unbindRestoresTheEmbeddersRegistry")
@system pure nothrow
unittest
{
    // `UVX11`: the pane binds its registry to draw a kitty image; what the
    // embedder draws afterwards resolves against the registry it bound.
    ImageRegistry embedders;
    RecCanvas canvas;
    canvas.bound = &embedders;
    VulkanImages images;
    auto painter = VulkanTerminalPainter!RecCanvas(&canvas, &images, 16);
    immutable ubyte[4] px = [1, 2, 3, 4];
    const t = painter.createTexture(ImagePixels(1, 1, PixelLayout.rgba, px));
    painter.drawTexture(t, ImageRect(0, 0, 1, 1), ImageRect(0, 0, 1, 1));
    painter.drawTexture(t, ImageRect(0, 0, 1, 1), ImageRect(1, 0, 1, 1));
    assert(canvas.bound == images.registryRef);
    painter.unbind();
    assert(canvas.bound is &embedders);
}
