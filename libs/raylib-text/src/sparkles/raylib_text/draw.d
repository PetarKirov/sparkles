/// The GL draw primitives: `drawGrapheme` (one cluster from the atlas, the
/// terminal's per-cell primitive), `drawSolid` (a fill routed through the atlas
/// white texel so the grid batches), and `drawText` (a whole styled run with
/// per-codepoint font routing, the hue per-run primitive). Need an active GL
/// context, so this module has no unittests; validated by the apps' goldens.
module sparkles.raylib_text.draw;

import raylib;

import sparkles.raylib_text.font : LoadedFont, glyphIndexFor;
import sparkles.raylib_text.font_set : FontSet;
import sparkles.raylib_text.style : TextStyle;
import sparkles.raylib_text.box : drawBox;

/**
Draw a grapheme cluster (base codepoint plus any combining marks) at `(x, y)`,
glyph by glyph, via the face's O(log n) glyph-index map. A drop-in replacement
for raylib's `DrawTextEx` (spacing 0) that reproduces its placement/advance math
but avoids both `GetGlyphIndex`'s linear scan and `DrawTextEx`'s per-call UTF-8
re-decode. The caller owns layout and backgrounds.
*/
void drawGrapheme(ref LoadedFont lf, scope const(uint)[] cps,
    float x, float y, int fontSize, Color tint) @system nothrow @nogc
{
    const font = lf.font;
    const float scale = font.baseSize > 0 ? cast(float) fontSize / font.baseSize : 1.0f;
    const float pad = cast(float) font.glyphPadding;

    float ox = x;
    foreach (cp; cps)
    {
        const idx = glyphIndexFor(lf, cast(int) cp);
        const Rectangle rec = font.recs[idx];

        // Whitespace and other zero-area glyphs draw nothing; just advance.
        if (rec.width > 0 && rec.height > 0)
        {
            const Rectangle src = Rectangle(
                rec.x - pad, rec.y - pad, rec.width + 2 * pad, rec.height + 2 * pad);
            const Rectangle dst = Rectangle(
                ox + font.glyphs[idx].offsetX * scale - pad * scale,
                y + font.glyphs[idx].offsetY * scale - pad * scale,
                (rec.width + 2 * pad) * scale,
                (rec.height + 2 * pad) * scale);
            DrawTexturePro(font.texture, src, dst, Vector2(0, 0), 0.0f, tint);
        }

        const adv = font.glyphs[idx].advanceX;
        ox += adv == 0 ? rec.width * scale : adv * scale;
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
Draw a whole styled run at `(x, y)` on a fixed monospace grid: each codepoint is
routed to its own face (`FontSet.resolveFace` — codepoint-map / real bold-italic
face / fallback / on-demand), so a run mixing ASCII, icons, and CJK renders each
in the right font, and SGR italic uses a real cursive face rather than a slant.
Codepoints are placed one grid column apart (`FontSet.cellW`), matching
`columnWidth`; underline/strikethrough span the whole run. Draws no background.
The caller flushes on-demand requests with `FontSet.flushPending` after
`EndDrawing`.
*/
void drawText(ref FontSet fonts, scope const(char)[] str, float x, float y,
    TextStyle style, Color fg) @system
{
    import std.utf : decode;
    import std.typecons : Yes;

    if (str.length == 0)
        return;

    const bold = style.has(TextStyle.bold);
    const italic = style.has(TextStyle.italic);
    const size = fonts.size();
    const cellW = fonts.cellW();
    const cellH = fonts.cellH();

    int col;
    size_t i = 0;
    while (i < str.length)
    {
        const cp = cast(int) decode!(Yes.useReplacementDchar)(str, i);
        const gxCol = x + col * cellW;
        // Box-drawing glyphs are rendered procedurally so their arms fill the cell
        // and connect across neighbouring cells (fonts leave gaps); anything the
        // box table doesn't cover falls through to the font glyph.
        if (drawBox(fonts.whiteFace, cast(uint) cp, gxCol, y, cellW, cellH, fg))
        {
            ++col;
            continue;
        }
        bool fakeBold, fakeItalic;
        auto face = fonts.resolveFace(cp, bold, italic, fakeBold, fakeItalic);
        const gx = gxCol + (fakeItalic ? size / 6 : 0);
        const uint[1] one = [cast(uint) cp];
        drawGrapheme(*face, one[], gx, y, size, fg);
        if (fakeBold)
            drawGrapheme(*face, one[], gx + 1, y, size, fg);
        ++col;
    }

    if (style.has(TextStyle.underline) || style.has(TextStyle.strikethrough))
    {
        const wpx = col * cellW;
        if (style.has(TextStyle.underline))
            drawSolid(fonts.whiteFace, cast(int) x, cast(int)(y + fonts.cellH() - 2), wpx, 1, fg);
        if (style.has(TextStyle.strikethrough))
            drawSolid(fonts.whiteFace, cast(int) x, cast(int)(y + fonts.cellH() / 2), wpx, 1, fg);
    }
}
