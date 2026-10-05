/// The GL draw primitives: `drawGrapheme` (one cluster from the atlas, the
/// terminal's per-cell primitive), `drawSolid` (a fill routed through the atlas
/// white texel so the grid batches), and `drawText` (a whole styled run with
/// grapheme font routing, the hue per-run primitive). Need an active GL
/// context; rendering is validated by the apps' goldens.
module sparkles.raylib_text.draw;

import raylib;

import sparkles.raylib_text.font : LoadedFont, glyphIndexFor;
import sparkles.raylib_text.font_set : FontSet;
import sparkles.raylib_text.style : TextStyle;
import sparkles.raylib_text.box : drawBox;
import sparkles.base.term_color : RgbColor;

/**
Draw atlas glyphs belonging to one complete grapheme at `(x, y)`.
This is a fallback, not a shaper: callers first use `FontSet.drawCluster` for
complete clusters, emoji and uncached glyphs. Atlas members share the cluster
origin and never manufacture a per-scalar advance. The caller owns cell layout
and backgrounds; complex placement requires the native shaping path.
*/
void drawGrapheme(ref LoadedFont lf, scope const(uint)[] cps,
    float x, float y, int fontSize, Color tint) @system nothrow @nogc
{
    const font = lf.font;
    const float scale = font.baseSize > 0 ? cast(float) fontSize / font.baseSize : 1.0f;

    foreach (cp; cps)
    {
        const idx = glyphIndexFor(lf, cast(int) cp);
        const Rectangle rec = font.recs[idx];

        // Whitespace and other zero-area glyphs draw nothing.
        if (rec.width > 0 && rec.height > 0)
        {
            // Sample the glyph's EXACT atlas rectangle. raylib's own
            // DrawTextCodepoint expands the source rect by `glyphPadding` on
            // every side — a margin that helps only when bilinear-scaling the
            // atlas to a different size. This pipeline always rasterizes the
            // atlas at the render size (`FontSet` reloads on every size change,
            // so `scale` is 1), and the expansion instead samples whatever sits
            // in the atlas gap: a neighbouring glyph that overflows its row's
            // nominal height (raylib packs rows only `fontSize + 2*padding`
            // tall) bleeds a stray "tail" into this glyph. The set of affected
            // glyphs shifts with the atlas packing, so the artifact changes with
            // font size. Sampling `rec` verbatim removes it (nothing of the
            // glyph lives outside its own rect).
            const Rectangle src = Rectangle(rec.x, rec.y, rec.width, rec.height);
            const Rectangle dst = Rectangle(
                x + font.glyphs[idx].offsetX * scale,
                y + font.glyphs[idx].offsetY * scale,
                rec.width * scale,
                rec.height * scale);
            DrawTexturePro(font.texture, src, dst, Vector2(0, 0), 0.0f, tint);
        }
    }
}

/**
Draw a solid-color rectangle. When `white` has a known white atlas texel, the
rect is drawn as a textured quad from that atlas so it shares the glyph texture —
backgrounds, underlines, the cursor, and glyphs all sampling one texture lets
raylib batch the whole grid instead of flushing on a texture switch every cell.
Falls back to `DrawRectangle` when no white texel is available.
*/
void drawSolid(ref LoadedFont white, int x, int y, int w, int h, Color c) @system nothrow @nogc
{
    if (white.hasWhite)
        DrawTexturePro(white.font.texture, white.whiteSrc,
            Rectangle(cast(float) x, cast(float) y, cast(float) w, cast(float) h),
            Vector2(0, 0), 0.0f, c);
    else
        DrawRectangle(x, y, w, h, c);
}

/**
Draw a whole styled run at `(x, y)` on a fixed monospace grid. Owned grapheme
segmentation and terminal-cell geometry determine each complete source span and
its occupied columns. Each cluster is routed to its preferred face and shaped
as a unit; single atlas glyphs retain codepoint-map / styled-face / fallback
routing. Underline and strikethrough span the occupied cells, not scalar count.
ANSI escapes and zero-cell clusters do not draw or advance. Draws no background.
The caller flushes on-demand requests with `FontSet.flushPending` after
`EndDrawing`, then repaints when it returns true.
*/
/**
Draws `str` in the toolkit's colour type, opaque.

So a consumer need not name the backend's `Color` just to draw a string —
that import was the last raylib symbol `apps/hue` needed (`UIA7`). A caller
that genuinely wants alpha uses the `Color` overload below.
*/
void drawText(ref FontSet fonts, scope const(char)[] str, float x, float y,
    TextStyle style, RgbColor fg) @system
    => drawText(fonts, str, x, y, style, Color(fg.r, fg.g, fg.b, 255));

/// ditto
void drawText(ref FontSet fonts, scope const(char)[] str, float x, float y,
    TextStyle style, Color fg) @system
{
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.base.text.grapheme : byGraphemeCluster;
    import sparkles.base.text.tokens : byUtfToken;
    import sparkles.base.text.utf : UtfMode;

    if (str.length == 0)
        return;

    const bold = style.has(TextStyle.bold);
    const italic = style.has(TextStyle.italic);
    const size = fonts.size();
    const cellW = fonts.cellW();
    const cellH = fonts.cellH();

    size_t col;
    UniqueBuffer!(uint, 32) decoded;
    foreach (cluster; byGraphemeCluster(str))
    {
        if (cluster.isEscape || cluster.width == 0)
            continue;
        const gxCol = x + col * cellW;
        const spanPixels = cluster.width * cellW;
        col += cluster.width;

        // Procedural box glyphs fill their cell and connect across neighbours.
        // A cluster with marks must reach the shaper intact, not lose its tail.
        if (cluster.codepoints == 1
            && drawBox(fonts.whiteFace, cast(uint) cluster.first,
                gxCol, y, spanPixels, cellH, fg))
            continue;

        const uint[1] one = [cast(uint) cluster.first];
        const(uint)[] cps = one[];
        if (cluster.codepoints != 1)
        {
            decoded.clear(releaseStorage: false);
            decoded.reserve(cluster.codepoints);
            foreach (token; byUtfToken(cluster.slice, UtfMode.replacement))
                decoded ~= cast(uint) token.scalar;
            cps = decoded[];
        }
        if (fonts.drawCluster(cps, bold, italic, gxCol, y, spanPixels, cellH, fg))
            continue;

        // A missing italic face renders upright; no synthetic slant or shift.
        // Shaping failure retains the complete cluster in the atlas fallback.
        bool fakeBold, fakeItalic;
        auto face = fonts.resolveFace(cast(int) cluster.first,
            bold, italic, fakeBold, fakeItalic);
        drawGrapheme(*face, cps, gxCol, y, size, fg);
        if (fakeBold)
            drawGrapheme(*face, cps, gxCol + 1, y, size, fg);
    }

    if (style.has(TextStyle.underline) || style.has(TextStyle.strikethrough))
    {
        const wpx = col * cellW;
        if (style.has(TextStyle.underline))
            drawSolid(fonts.whiteFace, cast(int) x, cast(int)(y + fonts.cellH() - 2),
                cast(int) wpx, 1, fg);
        if (style.has(TextStyle.strikethrough))
            drawSolid(fonts.whiteFace, cast(int) x, cast(int)(y + fonts.cellH() / 2),
                cast(int) wpx, 1, fg);
    }
}
