/**
Where an overlay's arrow goes (`docs/specs/ui/popup.md` `PLC10`, `PLC11`).

The arrow appears twice in the pipeline. Its clearance is an input to the
placement solve and its cell is an output of it (`OverlayGeometry.arrow`).
The side the solve resolved to then has to reach the canvases, which draw the
arrow on the edge that $(I faces) the anchor. Every canvas asks $(LREF arrowCell)
for the cell, so a cell grid, a pixel target and the HTML emitter cannot
disagree about it. Before this, the cell targets drew one cell further along
than the pixel ones, and no target kept the arrow inside its box.
*/
module sparkles.ui.overlay.arrow;

import sparkles.ui.overlay.place : Side;

@safe pure nothrow @nogc:

/// The arrow a box draws: the edge it pokes out of and the cell along it.
struct ArrowCell
{
    Side edge = Side.top; /// the box edge the arrow sits on
    int along;            /// the cell along that edge, from its start (left, or top)
    bool visible;         /// the edge holds an arrow clear of both corners
}

/**
The arrow on edge `edge` of a `width` × `height` cell box, `offset` cells from
the edge's start, kept off the two corners (`PLC10`). An edge shorter than
three cells has no cell between its corners, so the arrow is not drawn: a
clamp would put it on a corner, which is a different glyph, not an arrow.
*/
ArrowCell arrowCell(Side edge, int offset, int width, int height)
{
    const len = edge == Side.top || edge == Side.bottom ? width : height;
    if (len < 3)
        return ArrowCell(edge, 0, false);
    return ArrowCell(edge, offset < 1 ? 1 : offset > len - 2 ? len - 2 : offset, true);
}

/// The edge of an overlay that faces the anchor it was placed on `side` of:
/// below the anchor, the arrow is on its top edge.
Side facingEdge(Side side)
{
    final switch (side)
    {
        case Side.bottom: return Side.top;
        case Side.top: return Side.bottom;
        case Side.right: return Side.left;
        case Side.left: return Side.right;
    }
}

/// The box-drawing notch a cell target draws for an arrow on `edge`: the
/// border's line with a stub pointing out of the box.
dchar arrowNotch(Side edge)
{
    final switch (edge)
    {
        case Side.top: return '┴';
        case Side.bottom: return '┬';
        case Side.left: return '┤';
        case Side.right: return '├';
    }
}

/// The cell, in the box's coordinates (`x0`, `y0` the top-left corner, `x1`,
/// `y1` the bottom-right, inclusive), that $(LREF arrowNotch) goes in.
int[2] arrowNotchAt(in ArrowCell a, int x0, int y0, int x1, int y1)
{
    final switch (a.edge)
    {
        case Side.top: return [x0 + a.along, y0];
        case Side.bottom: return [x0 + a.along, y1];
        case Side.left: return [x0, y0 + a.along];
        case Side.right: return [x1, y0 + a.along];
    }
}

///
@("overlay.arrow.clampedOffTheCorners")
@safe pure nothrow @nogc
unittest
{
    assert(arrowCell(Side.top, 4, 10, 3) == ArrowCell(Side.top, 4, true));
    assert(arrowCell(Side.top, 0, 10, 3).along == 1, "never on the start corner");
    assert(arrowCell(Side.top, 40, 10, 3).along == 8, "never on the end corner");
    assert(arrowCell(Side.top, -5, 10, 3).along == 1, "a negative offset clamps too");
    assert(arrowCell(Side.left, 9, 40, 4).along == 2, "a side edge runs along the height");
    assert(!arrowCell(Side.bottom, 1, 2, 9).visible, "no cell between two corners");
    assert(arrowCell(Side.right, 1, 2, 3).visible);
}

///
@("overlay.arrow.facesTheAnchor")
@safe pure nothrow @nogc
unittest
{
    assert(facingEdge(Side.bottom) == Side.top);
    assert(facingEdge(Side.top) == Side.bottom);
    assert(facingEdge(Side.right) == Side.left);
    assert(facingEdge(Side.left) == Side.right);
    const a = arrowCell(Side.right, 1, 6, 4);
    assert(arrowNotchAt(a, 10, 20, 15, 23) == [15, 21] && arrowNotch(a.edge) == '├');
}
