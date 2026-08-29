/// Procedural box-drawing. A font's box-drawing glyphs (`─ │ ┼ ╭ …`) are rendered
/// at the glyph's own metrics, so a vertical rule stops short of the cell edges
/// and the rules in adjacent rows/columns don't connect — tables and block-quote
/// gutters look dashed. Real terminals sidestep this by drawing the box glyphs
/// procedurally: each glyph is a set of arms (up/down/left/right) drawn from the
/// cell center to the cell edges, so neighbouring cells' arms meet exactly.
///
/// $(LREF boxSpec) is the pure arm/weight lookup (unit-tested); $(LREF drawBox)
/// fills the arms as rectangles through the atlas white texel (so they batch with
/// glyphs), returning `false` for a codepoint it doesn't cover so the caller can
/// fall back to the font glyph.
module sparkles.raylib_text.box;

import raylib;

import sparkles.raylib_text.font : LoadedFont;

private enum ubyte armUp = 1, armDown = 2, armLeft = 4, armRight = 8;

/// The arms of a box-drawing glyph and their stroke weight. `heavyH` thickens the
/// horizontal arms (left/right), `heavyV` the vertical arms (up/down) — a mixed
/// glyph like `┿` (heavy horizontal, light vertical) sets only `heavyH`.
struct BoxSpec
{
    ubyte arms;   /// OR of armUp/armDown/armLeft/armRight
    bool heavyH;  /// left/right arms are heavy
    bool heavyV;  /// up/down arms are heavy
    bool valid;   /// false → not a covered codepoint (caller draws the glyph)
}

/**
The arm set + weight for a box-drawing codepoint, covering the light/heavy solid
frame, rounded corners, and BOTH mixed-weight header-rule families the table
renderer emits: heavy-horizontal/light-vertical (`┝ ┯ ┿ ┍`, a header row) and its
mirror, heavy-vertical/light-horizontal (`┠ ┰ ╂ ┎`, a frozen/stub column).

Dashed, doubled (`═ ║ ╔`), and diagonal (`╱ ╲`) forms are intentionally left
uncovered (`valid == false`) — they fall back to the font glyph. So are the
per-ARM mixed forms (`┞ ╃ ╈` — one arm of an axis heavy, the other light):
`BoxSpec` weights a whole axis, and no renderer here emits them.
*/
BoxSpec boxSpec(uint cp) @safe pure nothrow @nogc
{
    static BoxSpec s(ubyte arms, bool hH = false, bool hV = false)
        => BoxSpec(arms, hH, hV, true);

    switch (cp)
    {
    // Light lines, corners, tees, cross.
    case 0x2500: return s(armLeft | armRight);                    // ─
    case 0x2502: return s(armUp | armDown);                       // │
    case 0x250C: return s(armDown | armRight);                    // ┌
    case 0x2510: return s(armDown | armLeft);                     // ┐
    case 0x2514: return s(armUp | armRight);                      // └
    case 0x2518: return s(armUp | armLeft);                       // ┘
    case 0x251C: return s(armUp | armDown | armRight);            // ├
    case 0x2524: return s(armUp | armDown | armLeft);            // ┤
    case 0x252C: return s(armDown | armLeft | armRight);         // ┬
    case 0x2534: return s(armUp | armLeft | armRight);           // ┴
    case 0x253C: return s(armUp | armDown | armLeft | armRight); // ┼
    // Rounded corners (approximated as square — the arms still connect).
    case 0x256D: return s(armDown | armRight);                   // ╭
    case 0x256E: return s(armDown | armLeft);                    // ╮
    case 0x256F: return s(armUp | armLeft);                      // ╯
    case 0x2570: return s(armUp | armRight);                     // ╰
    // Heavy solid frame.
    case 0x2501: return s(armLeft | armRight, true, false);                    // ━
    case 0x2503: return s(armUp | armDown, false, true);                       // ┃
    case 0x250F: return s(armDown | armRight, true, true);                     // ┏
    case 0x2513: return s(armDown | armLeft, true, true);                      // ┓
    case 0x2517: return s(armUp | armRight, true, true);                       // ┗
    case 0x251B: return s(armUp | armLeft, true, true);                        // ┛
    case 0x2523: return s(armUp | armDown | armRight, true, true);             // ┣
    case 0x252B: return s(armUp | armDown | armLeft, true, true);              // ┫
    case 0x2533: return s(armDown | armLeft | armRight, true, true);           // ┳
    case 0x253B: return s(armUp | armLeft | armRight, true, true);             // ┻
    case 0x254B: return s(armUp | armDown | armLeft | armRight, true, true);   // ╋
    // Header-ROW rule: heavy horizontal, light vertical (`┝━━┿━━┥`).
    case 0x251D: return s(armUp | armDown | armRight, true, false);            // ┝
    case 0x2525: return s(armUp | armDown | armLeft, true, false);             // ┥
    case 0x252F: return s(armDown | armLeft | armRight, true, false);         // ┯
    case 0x2537: return s(armUp | armLeft | armRight, true, false);           // ┷
    case 0x253F: return s(armUp | armDown | armLeft | armRight, true, false); // ┿
    case 0x250D: return s(armDown | armRight, true, false);                   // ┍
    case 0x2511: return s(armDown | armLeft, true, false);                    // ┑
    case 0x2515: return s(armUp | armRight, true, false);                     // ┕
    case 0x2519: return s(armUp | armLeft, true, false);                      // ┙
    // Header/stub COLUMN rule: the mirror — heavy vertical, light horizontal
    // (`┰ ┃ ╂ ┸`). A frozen column's boundary is drawn from this family, and
    // without it the whole set fell through to the font: the rule rendered as
    // a stack of disconnected stubs while the row rule beside it connected.
    case 0x2520: return s(armUp | armDown | armRight, false, true);            // ┠
    case 0x2528: return s(armUp | armDown | armLeft, false, true);             // ┨
    case 0x2530: return s(armDown | armLeft | armRight, false, true);         // ┰
    case 0x2538: return s(armUp | armLeft | armRight, false, true);           // ┸
    case 0x2542: return s(armUp | armDown | armLeft | armRight, false, true); // ╂
    case 0x250E: return s(armDown | armRight, false, true);                   // ┎
    case 0x2512: return s(armDown | armLeft, false, true);                    // ┒
    case 0x2516: return s(armUp | armRight, false, true);                     // ┖
    case 0x251A: return s(armUp | armLeft, false, true);                      // ┚
    // Heavy half-lines used as title decorations (`╼ title ╾`).
    case 0x257C: return s(armLeft | armRight, true, false);                    // ╼
    case 0x257E: return s(armLeft | armRight, true, false);                    // ╾
    default: return BoxSpec.init; // valid == false
    }
}

/**
Draw the box-drawing glyph `cp` filling the cell at `(fx, fy)` sized
`cellW × cellH`: each arm is a rectangle from the cell centre to the cell edge, so
the same glyph in the neighbouring cell meets it exactly. Rectangles are filled
through the atlas white texel (via `white`) so they batch with the glyph draws.
Returns `false` (drawing nothing) for a codepoint `boxSpec` doesn't cover, so the
caller falls back to `drawGrapheme`. Needs an active GL context.
*/
bool drawBox(ref LoadedFont white, uint cp, float fx, float fy,
    int cellW, int cellH, Color tint) @system nothrow @nogc
{
    const spec = boxSpec(cp);
    if (!spec.valid)
        return false;

    const int x = cast(int) fx, y = cast(int) fy;
    const int minDim = cellW < cellH ? cellW : cellH;
    int tLight = minDim / 14;
    if (tLight < 1)
        tLight = 1;
    const int tHeavy = tLight < 1 ? 2 : tLight * 2;
    const int tV = spec.heavyV ? tHeavy : tLight; // vertical-arm width
    const int tH = spec.heavyH ? tHeavy : tLight; // horizontal-arm height
    const int cx = x + cellW / 2, cy = y + cellH / 2;
    const int vx = cx - tV / 2; // left edge of a vertical arm
    const int hy = cy - tH / 2; // top edge of a horizontal arm

    // Arms overlap the centre by half a stroke so junctions have no hole.
    if (spec.arms & armUp)
        fill(white, vx, y, tV, (cy + tH / 2) - y, tint);
    if (spec.arms & armDown)
        fill(white, vx, hy, tV, (y + cellH) - hy, tint);
    if (spec.arms & armLeft)
        fill(white, x, hy, (cx + tV / 2) - x, tH, tint);
    if (spec.arms & armRight)
        fill(white, vx, hy, (x + cellW) - vx, tH, tint);
    return true;
}

// A single filled rectangle, routed through the atlas white texel when available
// so the box arms batch with the glyph texture instead of flushing per cell.
private void fill(ref LoadedFont white, int x, int y, int w, int h, Color c) @system nothrow @nogc
{
    if (w <= 0 || h <= 0)
        return;
    if (white.hasWhite)
        DrawTexturePro(white.font.texture, white.whiteSrc,
            Rectangle(x, y, w, h), Vector2(0, 0), 0.0f, c);
    else
        DrawRectangle(x, y, w, h, c);
}

@("raylib_text.box.boxSpec")
@safe pure nothrow @nogc
unittest
{
    // Light cross has all four arms, no heavy weight.
    const cross = boxSpec('┼');
    assert(cross.valid && cross.arms == (armUp | armDown | armLeft | armRight));
    assert(!cross.heavyH && !cross.heavyV);

    // Vertical rule: up+down only.
    assert(boxSpec('│').arms == (armUp | armDown));
    // Rounded top-left corner connects down+right like the square one.
    assert(boxSpec('╭').arms == boxSpec('┌').arms);
    // Header-rule cross: heavy horizontal, light vertical.
    const h = boxSpec('┿');
    assert(h.valid && h.heavyH && !h.heavyV);
    // Heavy vertical rule.
    assert(boxSpec('┃').heavyV && !boxSpec('┃').heavyH);
    // Uncovered forms fall back to the glyph.
    assert(!boxSpec('═').valid && !boxSpec('╱').valid && !boxSpec('A').valid);
}

@("raylib_text.box.coversEveryTableGlyph")
@safe pure nothrow @nogc
unittest
{
    // The regression this exists for: the heavy-VERTICAL family (a frozen or
    // stub column's boundary) was missing while its heavy-horizontal mirror
    // was covered, so a table drew one rule procedurally and the other from
    // the font — the column rule came out as disconnected stubs beside a
    // clean row rule. Every glyph `sparkles.ui`'s TableGlyphs can emit is
    // listed here; an emphasis set that grows a glyph this does not cover
    // fails here rather than in someone's screenshot.
    static immutable dchar[] emitted = [
        // The light frame.
        '╭', '╮', '╰', '╯', '─', '│', '┬', '┴', '├', '┤', '┼',
        '┌', '┐', '└', '┘',
        // Header ROW: heavy horizontal, light vertical.
        '━', '┯', '┷', '┝', '┥', '┿', '┍', '┑', '┕', '┙',
        // Header/stub COLUMN: heavy vertical, light horizontal.
        '┃', '┰', '┸', '┠', '┨', '╂', '┎', '┒', '┖', '┚',
        // Where the two cross: heavy both.
        '┳', '┻', '┣', '┫', '╋', '┏', '┓', '┗', '┛',
        // Title decorations.
        '╼', '╾',
    ];
    foreach (g; emitted)
    {
        const spec = boxSpec(g);
        assert(spec.valid, "a table glyph with no procedural arms");
        assert(spec.arms != 0, "a covered glyph must draw something");
    }

    // And the two families really are mirrors, not copies.
    assert(boxSpec('┿').heavyH && !boxSpec('┿').heavyV);
    assert(boxSpec('╂').heavyV && !boxSpec('╂').heavyH);
    assert(boxSpec('╋').heavyH && boxSpec('╋').heavyV);
}
