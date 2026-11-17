/**
Pointer positions measured in cells, for an application that asked for pixels.

An application that sets `RunConfig.pointerUnit = PointerUnit.pixels`
(`HST18`) still lays its widget tree out in cells, so every pointer event is
converted back before a hit test. $(LREF pointerCells) reads, once per event,
the three host facts that conversion needs — the cell size, whether the
pointer can hover, and so the touch slop — into a $(LREF PointerCells) value.
*/
module sparkles.ui_app.pointer_cells;

import sparkles.input : Point, PointerEvent;
import sparkles.ui_app.backend : Backend;

/// One host's pointer geometry: the pixel size of a cell, and whether the pointer is a finger.
struct PointerCells
{
    /// The pixels per cell; 1×1 where the host reports cells.
    int cellWidth = 1, cellHeight = 1;
    /// The pointer cannot hover: presses are touches, a drag pans and a short one taps.
    bool touch;

    /// The travel, in pixels, under which a touch is still a tap: a quarter of the larger cell side, plus one.
    int slop() const @safe pure nothrow @nogc
        => (cellWidth > cellHeight ? cellWidth : cellHeight) / 4 + 1;

    /// The cell holding pixel `at`.
    Point cell(Point at) const @safe pure nothrow @nogc
        => Point(at.x / cellWidth, at.y / cellHeight);

    /// The fractional column of pixel column `x`, for a hit test between cell edges.
    float column(int x) const @safe pure nothrow @nogc => x / cast(float) cellWidth;

    /// The fractional row of pixel row `y`.
    float row(int y) const @safe pure nothrow @nogc => y / cast(float) cellHeight;

    /// `event` with its position in cells.
    PointerEvent inCells(in PointerEvent event) const @safe pure nothrow @nogc
    {
        PointerEvent cells = event;
        cells.pos = cell(event.pos);
        return cells;
    }
}

/**
The pointer geometry of `host`. A host with a pixel cell size
(`cellWidth`/`cellHeight`) on the GPU backend contributes it; any other host
reports cells. A host with `capabilities` reports touch when its pointer
cannot hover. Non-positive sizes clamp to one pixel.
*/
PointerCells pointerCells(H)(ref H host)
{
    PointerCells cells;
    static if (__traits(hasMember, H, "cellWidth") && __traits(hasMember, H, "cellHeight"))
    {
        bool pixels = true;
        static if (__traits(hasMember, H, "backend")) pixels = host.backend == Backend.gui;
        if (pixels)
        {
            cells.cellWidth = host.cellWidth;
            cells.cellHeight = host.cellHeight;
        }
    }
    if (cells.cellWidth < 1) cells.cellWidth = 1;
    if (cells.cellHeight < 1) cells.cellHeight = 1;
    static if (__traits(hasMember, H, "capabilities")) cells.touch = !host.capabilities.hover;
    return cells;
}

/// A window's pixels become cells; the slop scales with the cell.
@("ui_app.pointerCells.window")
@safe pure nothrow @nogc unittest
{
    import sparkles.input : InputCapabilities, PointerAction;
    static struct Host
    {
        Backend backend = Backend.gui;
        int cellWidth = 10, cellHeight = 20;
        InputCapabilities capabilities;
    }
    Host host;
    host.capabilities.hover = false;
    const cells = pointerCells(host);
    assert(cells.touch && cells.slop == 6);
    assert(cells.cell(Point(25, 45)) == Point(2, 2));
    assert(cells.column(25) == 2.5f && cells.row(50) == 2.5f);
    const moved = cells.inCells(PointerEvent(PointerAction.press, pos: Point(99, 19)));
    assert(moved.pos == Point(9, 0) && moved.action == PointerAction.press);
}

/// A terminal, or a host without a cell size, already reports cells.
@("ui_app.pointerCells.cellsHost")
@safe pure nothrow @nogc unittest
{
    static struct Terminal
    {
        Backend backend = Backend.tui;
        int cellWidth = 10, cellHeight = 20;
    }
    static struct Bare {}
    Terminal terminal;
    Bare bare;
    const PointerCells[2] hosts = [pointerCells(terminal), pointerCells(bare)];
    foreach (cells; hosts)
    {
        assert(!cells.touch && cells.slop == 1);
        assert(cells.cell(Point(7, 3)) == Point(7, 3));
    }
    static struct Broken
    {
        int cellWidth, cellHeight = -4;
    }
    Broken broken;
    const cells = pointerCells(broken);
    assert(cells.cellWidth == 1 && cells.cellHeight == 1);
}
