/**
The interface face's sizing rules (design-system `GLY10`), apart from any
renderer: how many steps the type scale has, how tall a step's line is, where
a run sits in the rows it was given, and how the steps shrink so the interface
face's x-height is the cell font's.

Raylib-free, so every arm that draws the interface face — the raylib arm's
$(REF UiFonts, sparkles,raylib_text,ui_font), the Vulkan arm's canvas — sizes
it by one rule.
*/
module sparkles.raylib_text.ui_sizing;

/// The number of steps on the type scale (`sparkles:ui`'s `TypeStep`).
enum uiTypeSteps = 4;

// `TypeStep.body`'s index: the step the cell font's x-height is matched at.
package enum TypeStepBody = 0;

/// The largest body glyph box, as a share of the cell font's size, when the
/// interface steps follow the cell font: the rest of the cell is the line's
/// leading.
enum float uiBodyOfCell = 0.85f;

/// The line height for a face drawn at `size`: the size plus a third, the
/// leading the mockups use (17 px titles on 22–24 px lines, 14 px body on 19).
int uiLineHeight(int size) @safe pure nothrow @nogc
    => size + (size + 2) / 3;

/// How far down a line of height `lineHeight` sits so it is centred in `rows`
/// cells of `cellH` — the cell rectangle the layout gave the run.
float uiCentreOffset(int lineHeight, int rows, int cellH) @safe pure nothrow @nogc
{
    const room = rows * cellH;
    return room > lineHeight ? (room - lineHeight) / 2.0f : 0.0f;
}

@("raylib_text.ui_sizing.metrics")
@safe pure nothrow @nogc
unittest
{
    assert(uiLineHeight(14) == 19 && uiLineHeight(17) == 23 && uiLineHeight(12) == 16);
    assert(uiCentreOffset(19, 1, 17) == 0, "a line taller than its cell starts at the top");
    assert(uiCentreOffset(23, 2, 17) == 5.5f);
    assert(uiCentreOffset(16, 1, 20) == 2);
}

/**
`sizes` (one per step, following the cell font) shrunk so the interface
face's x-height is the cell font's (`GLY10`): each step divided by
`xHeightRatio` — the interface face's x-height over the cell font's, each per
unit of size, at least 1 — and by at least $(LREF uiBodyOfCell)'s inverse, so a
body line keeps leading inside its cell instead of touching the rules and
boxes around it.
*/
int[uiTypeSteps] xHeightMatched(const int[uiTypeSteps] sizes, float xHeightRatio)
    @safe pure nothrow @nogc
{
    const xh = xHeightRatio < 1 ? 1.0f : xHeightRatio;
    const shrink = xh * uiBodyOfCell < 1 ? 1 / uiBodyOfCell : xh;
    int[uiTypeSteps] at;
    foreach (i, ref s; at)
    {
        const v = cast(int)(sizes[i] / shrink + 0.5f);
        s = v < 1 ? 1 : v;
    }
    return at;
}

///
@("raylib_text.ui_sizing.xHeightMatched")
@safe pure nothrow @nogc
unittest
{
    const int[uiTypeSteps] cell = [28, 24, 26, 34];
    // An equal x-height still leaves the body line its leading.
    assert(xHeightMatched(cell, 1.0f)[0] == 24, "28 × 0.85");
    // A face with a taller x-height shrinks by it.
    assert(xHeightMatched(cell, 1.25f)[0] == 22);
    // One with a smaller x-height never grows past the cell's share.
    assert(xHeightMatched(cell, 0.8f) == xHeightMatched(cell, 1.0f));
}
