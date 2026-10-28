/**
The terminal's painter on raylib (`isTerminalPainter`): cells, glyphs and
decorations through `sparkles:raylib-text`'s face set and its white atlas
texel, kitty images as raylib textures, a pane's placement as a scissor and
a pushed translation. Exactly the calls the renderer made before it went
through a painter, so the raylib terminal draws the same pixels.
*/
module sparkles.terminal_view.raylib_painter;

import raylib : BeginScissorMode, Color, DrawRectangleLines, DrawTextEx, DrawTexturePro,
    EndScissorMode, Image, ImageFormat, LoadImageFromMemory, LoadTextureFromImage,
    MeasureTextEx, PixelFormat, Rectangle, SetTextureFilter, SetTextureWrap, Texture2D, TextureFilter,
    TextureWrap, UnloadImage, UnloadTexture, UpdateTextureRec, Vector2;
import raylib.rlgl : rlDrawRenderBatchActive, rlPopMatrix, rlPushMatrix, rlTranslatef;

import sparkles.base.text.cstring : toTempStringz;
import sparkles.ghostty.c;
import sparkles.raylib_text : FontSet, LoadedFont, drawGrapheme, drawSolid;
import sparkles.terminal_view.painter;

/// The raylib painter over a window's face set, at the terminal's font size.
struct RaylibPainter
{
    FontSet* fonts; /// borrowed: the window session owns it
    int fontSize;   /// the size glyphs fall back to and labels are drawn at

    @system nothrow @nogc:

    void fill(int x, int y, int w, int h, Rgba c)
    {
        drawSolid(fonts.whiteFace, x, y, w, h, rl(c));
    }

    void outline(int x, int y, int w, int h, Rgba c)
    {
        DrawRectangleLines(x, y, w, h, rl(c));
    }

    // The face set shapes the cluster; a codepoint it cannot shape draws
    // from the face that covers it, emboldened by a second pass a pixel
    // over when the face has no bold.
    void cluster(scope const(uint)[] cps, bool bold, bool italic, int x, int y, int w, int h,
        Rgba ink, Rgba)
    {
        const tint = rl(ink);
        if (fonts.drawCluster(cps, bold, italic, cast(float) x, cast(float) y, w, h, tint))
            return;
        bool fakeBold, fakeItalic;
        LoadedFont* face = fonts.resolveFace(cps[0], bold, italic, fakeBold, fakeItalic);
        drawGrapheme(*face, cps, cast(float) x, cast(float) y, fontSize, tint);
        if (fakeBold)
            drawGrapheme(*face, cps, cast(float)(x + 1), cast(float) y, fontSize, tint);
    }

    float[2] labelSize(scope const(char)[] text)
    {
        const z = text.toTempStringz;
        const size = MeasureTextEx(fonts.primaryFont(), z.ptr, fontSize, 0);
        return [size.x, size.y];
    }

    void label(scope const(char)[] text, float x, float y, Rgba c)
    {
        const z = text.toTempStringz;
        DrawTextEx(fonts.primaryFont(), z.ptr, Vector2(x, y), fontSize, 0, rl(c));
    }

    void clip(int x, int y, int w, int h)
    {
        BeginScissorMode(x, y, w, h);
    }

    void unclip()
    {
        EndScissorMode();
    }

    void pushOffset(float dx, float dy)
    {
        rlPushMatrix();
        rlTranslatef(dx, dy, 0);
    }

    void popOffset()
    {
        rlPopMatrix();
    }

    TextureId createTexture(in ImagePixels image) => RaylibTextures().createTexture(image);
    void updateTextureRows(TextureId t, in ImagePixels image, size_t first, size_t count)
        => RaylibTextures().updateTextureRows(t, image, first, count);
    void releaseTexture(TextureId t) => RaylibTextures().releaseTexture(t);
    void drawTexture(TextureId t, in ImageRect source, in ImageRect destination)
        => RaylibTextures().drawTexture(t, source, destination);
}

static assert(isTerminalPainter!RaylibPainter);

/**
Kitty images as raylib textures, with no fonts: what releasing a terminal's
images needs when there is nothing to paint (`TerminalView.close`).
*/
struct RaylibTextures
{
    @system nothrow @nogc:

    TextureId createTexture(in ImagePixels image)
    {
        Image source = {
            data: cast(void*) image.pixels.ptr,
            width: cast(int) image.width,
            height: cast(int) image.height,
            mipmaps: 1,
            format: formatOf(image.layout),
        };
        auto texture = LoadTextureFromImage(source);
        if (texture.id == 0)
            return TextureId.init;
        SetTextureFilter(texture, TextureFilter.TEXTURE_FILTER_BILINEAR);
        // Clamped, as the Vulkan canvas samples images: OpenGL's default
        // wrap repeats, which blended each edge with the opposite one.
        SetTextureWrap(texture, TextureWrap.TEXTURE_WRAP_CLAMP);
        return TextureId(texture.id, image.width, image.height, image.layout);
    }

    void updateTextureRows(TextureId t, in ImagePixels image, size_t first, size_t count)
    {
        // An earlier placement in this very layer, or another pane, can still
        // read the texture from raylib's CPU-side batch.
        rlDrawRenderBatchActive();
        const rowBytes = cast(size_t) image.width * channels(image.layout);
        UpdateTextureRec(textureOf(t), Rectangle(0, first, image.width, count),
            image.pixels.ptr + first * rowBytes);
    }

    void releaseTexture(TextureId t)
    {
        rlDrawRenderBatchActive();
        UnloadTexture(textureOf(t));
    }

    void drawTexture(TextureId t, in ImageRect source, in ImageRect destination)
    {
        DrawTexturePro(textureOf(t),
            Rectangle(source.x, source.y, source.width, source.height),
            Rectangle(destination.x, destination.y, destination.width, destination.height),
            Vector2(0, 0), 0, Color(255, 255, 255, 255));
    }
}

static assert(isTextureSink!RaylibTextures);

private Color rl(Rgba c) @safe pure nothrow @nogc
    => Color(c.r, c.g, c.b, c.a);

private int formatOf(PixelLayout layout) @safe pure nothrow @nogc
{
    final switch (layout)
    {
        case PixelLayout.gray:
            return PixelFormat.PIXELFORMAT_UNCOMPRESSED_GRAYSCALE;
        case PixelLayout.grayAlpha:
            return PixelFormat.PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA;
        case PixelLayout.rgb:
            return PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8;
        case PixelLayout.rgba:
            return PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;
    }
}

private Texture2D textureOf(TextureId t) @safe pure nothrow @nogc
    => Texture2D(t.value, cast(int) t.width, cast(int) t.height, 1, formatOf(t.layout));
