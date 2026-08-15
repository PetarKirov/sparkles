/**
The input system (`IXN1`–`IXN6`): free functions over $(MREF world) and
$(MREF camera).

Every behaviour the pointer or keyboard can provoke is one of these functions
mutating a $(LREF World) (and its camera). The component's `handle` is a thin
adapter that builds an $(LREF InputView) from the host and calls
$(LREF systemInput) — so a scripted test asserts on $(B one) struct, and no
system keeps a little state of its own (`WLD4`, `DIA6`).

$(B Capture owns the drag.) The toolkit's $(REF CaptureState, sparkles,ui,state)
is the arbitration; $(LREF World.capture) is the same fact in the board's
vocabulary. A press that starts a create / marquee / move / pan / minimap scrub
captures, every subsequent motion and the release go to that owner wherever the
pointer strays, and the release frees both (`IXN1`).

$(B Grid settings) sits above the context menu (`GRD9` / `IXN1`): **Grid…**
opens it, 1/2/3 and arrows pick a fixture, Esc closes it — first step of the
dismissal chain (`IXN6`).

$(B Context menu) sits above every other layer (`IXN1` / `IXN5`): RMB opens it,
a click on an item runs it, a click outside or Esc closes it — first step of
the dismissal chain (`IXN6`).
*/
module systems.input;

import sparkles.input : Event, Gesture, GestureEvent, InputCapabilities, isDismiss,
    Key, KeyAction, KeyEvent, match, Mods, PointerAction, PointerButton,
    PointerEvent, WheelEvent;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.state : CaptureState;
import sparkles.ui_app.backend : Backend;

import camera : Camera, contentBounds, fitContent, scaleBase, minimapDivisor,
    minimapToWorld;
import sparkles.ui.components.grid_backdrop : GridPreset;

import world : Capture, Entity, liveBounds, noEntity, Tool, World;

/// Toolkit capture ids — one per $(LREF Capture) owner, non-zero (`STM11`).
enum size_t capCreate = 1;
enum size_t capMarquee = 2;
enum size_t capMove = 3;
enum size_t capPan = 4;
enum size_t capMinimap = 5;

/// Wheel / pinch notch as a percent of the current magnification (`CAM2`).
enum int zoomInRatio = 110;
/// ditto — ×0.91, the inverse of a 10% step, integer-truncated.
enum int zoomOutRatio = 91;

/// Keyboard pan step, in screen cells (`IXN3`).
enum int panStepCells = 2;

/// Chrome sizes shared with the render systems (`RND1`): one toolbar row, one
/// status row, a fixed minimap panel in the board's bottom-right.
enum int toolbarRows = 1;
/// ditto
enum int statusRows = 1;
/// ditto
enum int minimapWidth = 20;
/// ditto
enum int minimapHeight = 10;

/**
What the input system needs of the surface for one event — everything that is
not the world or the camera.

Built once per event by the component from the host, so the free functions
never name a host and a pure test can hand them a literal.
*/
struct InputView
{
    Size viewport;                 /// surface size, in cells
    InputCapabilities capabilities; /// key-release, pointer precision, …
    Backend backend;               /// gui vs tui: which zoom path the wheel takes
    /**
    Natural cell size in pixels. Zero means pointer positions are already in
    cells (terminal, or a recorder that never opted into pixels). Non-zero is
    the GUI board's path: positions arrive in device pixels (`HST18`) and
    $(LREF Camera.pixelToCell) turns them into board cells at the drawn size.
    */
    int naturalCellW;
    /// ditto
    int naturalCellH;
}

/// The board area — everything below the toolbar and above the status row.
Rect boardArea(in Size viewport) @safe pure nothrow @nogc
{
    const h = viewport.height - toolbarRows - statusRows;
    return Rect(0, toolbarRows, viewport.width, h > 0 ? h : 0);
}

/// The minimap panel, bottom-right of the board (empty when the board is too
/// small to host it).
Rect minimapPanel(in Size viewport) @safe pure nothrow @nogc
{
    const board = boardArea(viewport);
    if (board.width < minimapWidth + 1 || board.height < minimapHeight + 1)
        return Rect.init;
    return Rect(
        board.x + board.width - minimapWidth,
        board.y + board.height - minimapHeight,
        minimapWidth, minimapHeight);
}

/// The toolbar strip across the top.
Rect toolbarArea(in Size viewport) @safe pure nothrow @nogc
    => Rect(0, 0, viewport.width, toolbarRows);

/// Tool chip hit rects inside the toolbar: select, rect, connect — three
/// three-cell buttons with a one-cell gap, so a click picks a tool without a
/// keyboard (`IXN1` / `IXN2`).
Rect toolButton(Tool t, in Size viewport) @safe pure nothrow @nogc
{
    const bar = toolbarArea(viewport);
    if (bar.empty)
        return Rect.init;
    const idx = cast(int) t; // select=0, rect=1, connect=2
    return Rect(bar.x + 1 + idx * 4, bar.y, 3, 1);
}

/// Context-menu entries (`IXN5`), top to bottom.
enum MenuItem : ubyte
{
    group,
    ungroup,
    label,
    connect,
    delete_,
    grid,
}

/// ditto
enum size_t menuItemCount = MenuItem.max + 1;
/// Width of the menu panel in cells.
enum int menuWidth = 12;
/// One row per item.
enum int menuRowH = 1;

/// The menu's screen-space panel, or empty when closed.
Rect menuPanel(ref const World w) @safe pure nothrow @nogc
{
    if (!w.menuOpen)
        return Rect.init;
    return Rect(w.menuAt.x, w.menuAt.y, menuWidth, cast(int) menuItemCount * menuRowH);
}

/// Hit rect for one menu item, or empty when the menu is closed.
Rect menuItemRect(ref const World w, MenuItem item) @safe pure nothrow @nogc
{
    if (!w.menuOpen)
        return Rect.init;
    return Rect(w.menuAt.x, w.menuAt.y + cast(int) item * menuRowH, menuWidth, menuRowH);
}

/// Label text for a menu item (for render + tests).
string menuItemLabel(MenuItem item) @safe pure nothrow @nogc
{
    final switch (item)
    {
        case MenuItem.group: return "Group";
        case MenuItem.ungroup: return "Ungroup";
        case MenuItem.label: return "Label…";
        case MenuItem.connect: return "Connect";
        case MenuItem.delete_: return "Delete";
        case MenuItem.grid: return "Grid…";
    }
}

/// Settings-panel size (`GRD9`).
enum int gridSettingsWidth = 22;
/// title + 3 presets
enum int gridSettingsRows = 4;

/// Screen-space rect of the grid settings panel, or empty when closed.
Rect gridSettingsPanel(ref const World w, in Size viewport)
    @safe pure nothrow @nogc
{
    if (!w.gridSettingsOpen)
        return Rect.init;
    int x = 2;
    int y = toolbarRows + 1;
    if (x + gridSettingsWidth > viewport.width)
        x = viewport.width > gridSettingsWidth
            ? viewport.width - gridSettingsWidth : 0;
    if (y + gridSettingsRows > viewport.height)
        y = viewport.height > gridSettingsRows
            ? viewport.height - gridSettingsRows : 0;
    return Rect(x, y, gridSettingsWidth, gridSettingsRows);
}

/// Hit rect for one preset row (0..2), or empty when closed.
Rect gridSettingsRow(ref const World w, in Size viewport, ubyte row)
    @safe pure nothrow @nogc
{
    const panel = gridSettingsPanel(w, viewport);
    if (panel.empty || row >= 3)
        return Rect.init;
    return Rect(panel.x, panel.y + 1 + row, panel.width, 1);
}

/// Toolkit capture id for a board capture owner, or `0` for none.
size_t captureIdOf(Capture c) @safe pure nothrow @nogc
{
    final switch (c)
    {
        case Capture.none: return 0;
        case Capture.create: return capCreate;
        case Capture.marquee: return capMarquee;
        case Capture.move: return capMove;
        case Capture.pan: return capPan;
        case Capture.minimapScrub: return capMinimap;
    }
}

/**
Drives one event into the board.

Returns `true` when the run should end (`q`, the dismissal chain's tail, or
end-of-input). The caller is the only place that knows how to quit a host.
*/
bool systemInput(ref World w, ref Camera cam, ref CaptureState cap, in Event e,
    in InputView view) @safe pure nothrow @nogc
{
    return e.match!(
        (in KeyEvent k) => onKey(w, cam, cap, k, view),
        (in PointerEvent p) { onPointer(w, cam, cap, p, view); return false; },
        (in WheelEvent wh) { onWheel(w, cam, wh, view); return false; },
        (in GestureEvent g) { onGesture(w, cam, g, view); return false; },
        (in _) => false,
    );
}

// ── keys (`IXN2`–`IXN4`, dismissal) ─────────────────────────────────────────

private bool onKey(ref World w, ref Camera cam, ref CaptureState cap,
    in KeyEvent k, in InputView view) @safe pure nothrow @nogc
{
    // Space release only when the target reports it — otherwise Space is a
    // sticky arm (see `World.spaceDown`).
    if (k.action == KeyAction.release)
    {
        if (view.capabilities.keyRelease && isSpace(k))
            w.spaceDown = false;
        return false;
    }

    // Label edit captures the keyboard (`IXN5`): printable types, backspace
    // erases, Enter commits, Esc cancels. Nothing else runs until it ends.
    if (w.isEditing)
        return onEditKey(w, k);

    // Grid settings captures 1/2/3 and arrows while open (`GRD9`).
    if (w.gridSettingsOpen && onGridSettingsKey(w, k))
        return false;

    // Tool switch cancels a pending connect half and any open drag.
    if (k.key == Key.char_)
    {
        if (k.ch == 'v' || k.ch == 'V')
        {
            setTool(w, cap, Tool.select);
            return false;
        }
        if (k.ch == 'r' || k.ch == 'R')
        {
            setTool(w, cap, Tool.rect);
            return false;
        }
        if (k.ch == 'c' || k.ch == 'C')
        {
            setTool(w, cap, Tool.connect);
            return false;
        }
        if (k.ch == 'q' || k.ch == 'Q')
            return true;
        if (k.ch == 'm' || k.ch == 'M')
        {
            w.minimapVisible = !w.minimapVisible;
            return false;
        }
        if (k.ch == 'f' || k.ch == 'F')
        {
            fitAll(w, cam, view.viewport);
            return false;
        }
        if (k.ch == '0')
        {
            cam.resetZoom();
            return false;
        }
        if (k.ch == '+' || k.ch == '=')
        {
            cam.zoomAt(1, boardPivot(view.viewport));
            return false;
        }
        if (k.ch == '-' || k.ch == '_')
        {
            cam.zoomAt(-1, boardPivot(view.viewport));
            return false;
        }
        // WASD pan — one step per press/repeat, never a held-key continuous
        // move, so a terminal without releases can pan too (`IXN3`).
        if (k.ch == 'w' || k.ch == 'W')
        {
            cam.panBy(0, panStepCells);
            return false;
        }
        if (k.ch == 's' || k.ch == 'S')
        {
            cam.panBy(0, -panStepCells);
            return false;
        }
        if (k.ch == 'a' || k.ch == 'A')
        {
            cam.panBy(panStepCells, 0);
            return false;
        }
        if (k.ch == 'd' || k.ch == 'D')
        {
            cam.panBy(-panStepCells, 0);
            return false;
        }
        if (k.ch == 'g' || k.ch == 'G')
        {
            cast(void) w.groupSelection();
            return false;
        }
        if (k.ch == 'u' || k.ch == 'U')
        {
            w.ungroupSelection();
            return false;
        }
        if (isSpace(k))
        {
            // Hold where releases exist; sticky toggle where they do not.
            if (view.capabilities.keyRelease)
                w.spaceDown = true;
            else
                w.spaceDown = !w.spaceDown;
            return false;
        }
    }

    if (k.key == Key.delete_ || k.key == Key.backspace)
    {
        if (w.selectionCount > 0)
            w.deleteSelection();
        return false;
    }

    if (k.key == Key.up)
    {
        cam.panBy(0, panStepCells);
        return false;
    }
    if (k.key == Key.down)
    {
        cam.panBy(0, -panStepCells);
        return false;
    }
    if (k.key == Key.left)
    {
        cam.panBy(panStepCells, 0);
        return false;
    }
    if (k.key == Key.right)
    {
        cam.panBy(-panStepCells, 0);
        return false;
    }

    if (isDismiss(k))
        return dismiss(w, cap);

    return false;
}

/// Keys while a label edit is open (`IXN5`).
private bool onEditKey(ref World w, in KeyEvent k) @safe pure nothrow @nogc
{
    if (k.key == Key.enter)
    {
        w.editCommit();
        return false;
    }
    if (isDismiss(k))
    {
        w.editCancel();
        return false; // cancel edit, do not climb the rest of the chain yet
    }
    if (k.key == Key.backspace)
    {
        w.editErase();
        return false;
    }
    if (k.key == Key.char_)
        w.editType(k.ch);
    return false;
}

/**
Esc dismissal chain (`IXN6`): settings → menu → label edit → pending connect →
capture → selection → quit. `q` bypasses the chain and quits directly.
*/
private bool dismiss(ref World w, ref CaptureState cap) @safe pure nothrow @nogc
{
    if (w.gridSettingsOpen)
    {
        w.gridSettingsOpen = false;
        return false;
    }
    if (w.menuOpen)
    {
        closeMenu(w);
        return false;
    }
    if (w.isEditing)
    {
        w.editCancel();
        return false;
    }
    if (w.connectFrom != noEntity)
    {
        w.connectFrom = noEntity;
        return false;
    }
    if (w.capture != Capture.none)
    {
        cancelCapture(w, cap);
        return false;
    }
    if (w.selectionCount > 0)
    {
        w.clearSelection();
        return false;
    }
    return true; // quit
}

private void setTool(ref World w, ref CaptureState cap, Tool t)
    @safe pure nothrow @nogc
{
    cancelCapture(w, cap);
    w.connectFrom = noEntity;
    closeMenu(w);
    w.tool = t;
}

private void closeMenu(ref World w) @safe pure nothrow @nogc
{
    w.menuOpen = false;
}

private void openMenu(ref World w, in Point screen) @safe pure nothrow @nogc
{
    w.menuOpen = true;
    w.menuAt = screen;
}

// ── pointer (`IXN1`–`IXN3`) ─────────────────────────────────────────────────

private void onPointer(ref World w, ref Camera cam, ref CaptureState cap,
    in PointerEvent p, in InputView view) @safe pure nothrow @nogc
{
    // A capture owner holds the drag to the end, wherever the pointer goes.
    if (w.capture != Capture.none)
    {
        driveCapture(w, cam, cap, p, view);
        return;
    }

    if (p.action == PointerAction.leave)
    {
        w.hovered = noEntity;
        return;
    }

    // Hover tracking on bare motion (no button).
    if (p.action == PointerAction.move ||
        (p.action == PointerAction.drag && p.button == PointerButton.none))
    {
        const world = pointerToWorld(cam, p.pos, view);
        w.hovered = w.pick(world);
        return;
    }

    if (p.action == PointerAction.press)
        pressFree(w, cam, cap, p, view);
    else if (p.action == PointerAction.release)
    {
        // A release with no capture is a no-op for the board; chrome may
        // still have used it, but nothing is armed here.
    }
}

private void pressFree(ref World w, ref Camera cam, ref CaptureState cap,
    in PointerEvent p, in InputView view) @safe pure nothrow @nogc
{
    // Layered hit order, topmost first (`IXN1`): settings → menu → toolbar →
    // minimap → board.
    if (hitGridSettings(w, p, view))
        return;
    if (hitMenu(w, cam, cap, p, view))
        return;
    // RMB opens the context menu on the board (after the menu itself has had
    // a chance to consume the click when already open).
    if (p.button == PointerButton.right && p.action == PointerAction.press)
    {
        openContextMenu(w, cam, p, view);
        return;
    }
    if (hitToolbar(w, cap, p, view))
        return;
    if (w.minimapVisible && hitMinimap(w, cam, cap, p, view))
        return;
    hitBoard(w, cam, cap, p, view);
}

/// `true` when the event was about the menu (open or closed by the click).
private bool hitMenu(ref World w, ref Camera cam, ref CaptureState cap,
    in PointerEvent p, in InputView view) @safe pure nothrow @nogc
{
    if (!w.menuOpen)
        return false;
    const cell = surfaceCell(p.pos, view);
    const panel = menuPanel(w);
    if (p.action != PointerAction.press)
        return true; // swallow motion over an open menu

    if (!panel.contains(cell))
    {
        // Click outside: dismiss, then let the same press fall through only
        // for non-right buttons so a left click both closes and acts. RMB
        // reopens at the new place via the caller.
        closeMenu(w);
        return p.button == PointerButton.right;
    }

    if (p.button != PointerButton.left)
        return true;

    foreach (i; 0 .. menuItemCount)
    {
        const item = cast(MenuItem) i;
        if (menuItemRect(w, item).contains(cell))
        {
            runMenuItem(w, cam, cap, item, view);
            closeMenu(w);
            return true;
        }
    }
    closeMenu(w);
    return true;
}

private void openContextMenu(ref World w, ref Camera cam, in PointerEvent p,
    in InputView view) @safe pure nothrow @nogc
{
    const cell = surfaceCell(p.pos, view);
    const board = boardArea(view.viewport);
    if (board.contains(cell))
    {
        const local = Point(cell.x - board.x, cell.y - board.y);
        const world = cam.screenToWorld(local);
        const hit = w.pick(world);
        if (hit != noEntity && !w.selected(hit))
            w.selectOnly(hit);
    }
    // Clamp so the panel stays on-screen.
    int x = cell.x;
    int y = cell.y;
    if (x + menuWidth > view.viewport.width)
        x = view.viewport.width - menuWidth;
    if (y + cast(int) menuItemCount * menuRowH > view.viewport.height)
        y = view.viewport.height - cast(int) menuItemCount * menuRowH;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    openMenu(w, Point(x, y));
}

private void runMenuItem(ref World w, ref Camera, ref CaptureState cap,
    MenuItem item, in InputView) @safe pure nothrow @nogc
{
    final switch (item)
    {
        case MenuItem.group:
            cast(void) w.groupSelection();
            return;
        case MenuItem.ungroup:
            w.ungroupSelection();
            return;
        case MenuItem.label:
            if (w.selectionCount >= 1)
                w.beginEdit(w.selection[0]);
            return;
        case MenuItem.connect:
            setTool(w, cap, Tool.connect);
            if (w.selectionCount >= 1)
                w.connectFrom = w.selection[0];
            return;
        case MenuItem.delete_:
            w.deleteSelection();
            return;
        case MenuItem.grid:
            w.gridSettingsOpen = true;
            return;
    }
}

private bool onGridSettingsKey(ref World w, in KeyEvent k) @safe pure nothrow @nogc
{
    if (k.key == Key.char_)
    {
        if (k.ch == '1')
        {
            w.applyGridPreset(GridPreset.defaultLines);
            return true;
        }
        if (k.ch == '2')
        {
            w.applyGridPreset(GridPreset.stripeBands);
            return true;
        }
        if (k.ch == '3')
        {
            w.applyGridPreset(GridPreset.dotPaper);
            return true;
        }
    }
    if (k.key == Key.up)
    {
        if (w.gridPresetIndex > 0)
            w.gridPresetIndex--;
        else
            w.gridPresetIndex = 2;
        w.applyGridPreset(cast(GridPreset) w.gridPresetIndex);
        return true;
    }
    if (k.key == Key.down)
    {
        w.gridPresetIndex = cast(ubyte) ((w.gridPresetIndex + 1) % 3);
        w.applyGridPreset(cast(GridPreset) w.gridPresetIndex);
        return true;
    }
    if (k.key == Key.enter)
    {
        w.applyGridPreset(cast(GridPreset) (w.gridPresetIndex % 3));
        w.gridSettingsOpen = false;
        return true;
    }
    return false;
}

private bool hitGridSettings(ref World w, in PointerEvent p, in InputView view)
    @safe pure nothrow @nogc
{
    if (!w.gridSettingsOpen)
        return false;
    const cell = surfaceCell(p.pos, view);
    const panel = gridSettingsPanel(w, view.viewport);
    if (p.action != PointerAction.press)
        return true;
    if (!panel.contains(cell))
    {
        w.gridSettingsOpen = false;
        return p.button == PointerButton.right;
    }
    if (p.button != PointerButton.left)
        return true;
    foreach (ubyte i; 0 .. 3)
    {
        if (gridSettingsRow(w, view.viewport, i).contains(cell))
        {
            w.applyGridPreset(cast(GridPreset) i);
            return true;
        }
    }
    return true;
}

private bool hitToolbar(ref World w, ref CaptureState cap, in PointerEvent p,
    in InputView view) @safe pure nothrow @nogc
{
    // Toolbar is in surface cells, not board cells — convert via the surface
    // only (no camera).
    const cell = surfaceCell(p.pos, view);
    if (!toolbarArea(view.viewport).contains(cell))
        return false;

    if (p.button != PointerButton.left)
        return true; // consume, do not fall through to the board

    foreach (t; [Tool.select, Tool.rect, Tool.connect])
        if (toolButton(t, view.viewport).contains(cell))
        {
            setTool(w, cap, t);
            return true;
        }
    return true;
}

private bool hitMinimap(ref World w, ref Camera cam, ref CaptureState cap,
    in PointerEvent p, in InputView view) @safe pure nothrow @nogc
{
    const cell = surfaceCell(p.pos, view);
    const panel = minimapPanel(view.viewport);
    if (panel.empty || !panel.contains(cell))
        return false;

    // Middle button still pans the board even over the minimap — the minimap
    // is an overview, not a modal.
    if (p.button == PointerButton.middle ||
        (p.button == PointerButton.left && w.spaceDown))
    {
        beginCapture(w, cap, Capture.pan, cell);
        return true;
    }

    if (p.button != PointerButton.left)
        return true;

    scrubMinimapTo(w, cam, cell, view);
    beginCapture(w, cap, Capture.minimapScrub, cell);
    return true;
}

private void hitBoard(ref World w, ref Camera cam, ref CaptureState cap,
    in PointerEvent p, in InputView view) @safe pure nothrow @nogc
{
    const screen = surfaceCell(p.pos, view);
    const board = boardArea(view.viewport);
    // A press outside the board (status row, …) is ignored.
    if (!board.contains(screen) && p.button != PointerButton.middle)
        return;

    const local = Point(screen.x - board.x, screen.y - board.y);
    const world = cam.screenToWorld(local);

    // Pan: middle-drag, or Space+LMB (`IXN3`).
    if (p.button == PointerButton.middle ||
        (p.button == PointerButton.left && w.spaceDown))
    {
        beginCapture(w, cap, Capture.pan, screen);
        return;
    }

    if (p.button != PointerButton.left)
        return;

    final switch (w.tool)
    {
        case Tool.rect:
            w.dragStart = world;
            w.dragNow = world;
            beginCapture(w, cap, Capture.create, world);
            return;

        case Tool.connect:
            const hit = w.pick(world);
            if (hit == noEntity)
            {
                w.connectFrom = noEntity;
                return;
            }
            if (w.connectFrom == noEntity)
            {
                w.connectFrom = hit;
                w.selectOnly(hit);
                return;
            }
            if (hit != w.connectFrom)
                cast(void) w.connect(w.connectFrom, hit);
            w.connectFrom = noEntity;
            return;

        case Tool.select:
            const hit = w.pick(world);
            w.hovered = hit;
            if (hit == noEntity)
            {
                if (!p.mods.shift)
                    w.clearSelection();
                w.dragStart = world;
                w.dragNow = world;
                beginCapture(w, cap, Capture.marquee, world);
                return;
            }
            if (p.mods.shift)
            {
                w.toggleSelect(hit);
                return;
            }
            if (!w.selected(hit))
                w.selectOnly(hit);
            w.dragStart = world;
            w.dragNow = world;
            beginCapture(w, cap, Capture.move, world);
            return;
    }
}

private void driveCapture(ref World w, ref Camera cam, ref CaptureState cap,
    in PointerEvent p, in InputView view) @safe pure nothrow @nogc
{
    const id = captureIdOf(w.capture);
    if (!cap.ownedBy(id) && !cap.isFree)
        return; // another owner somehow — do not interfere

    final switch (w.capture)
    {
        case Capture.none:
            return;

        case Capture.create:
            if (p.action == PointerAction.drag || p.action == PointerAction.move
                || p.action == PointerAction.press)
            {
                w.dragNow = pointerToWorld(cam, p.pos, view);
            }
            else if (p.action == PointerAction.release)
            {
                w.dragNow = pointerToWorld(cam, p.pos, view);
                const r = w.dragRect;
                // A real box: refuse the degenerate empty that a cancel would
                // leave. One cell is enough to pick and move later.
                if (r.width > 0 && r.height > 0)
                {
                    const e = w.spawn(r);
                    if (e != noEntity)
                        w.selectOnly(e);
                }
                endCapture(w, cap);
            }
            return;

        case Capture.marquee:
            if (p.action == PointerAction.drag || p.action == PointerAction.move
                || p.action == PointerAction.press)
            {
                w.dragNow = pointerToWorld(cam, p.pos, view);
            }
            else if (p.action == PointerAction.release)
            {
                w.dragNow = pointerToWorld(cam, p.pos, view);
                w.selectWithin(w.dragRect);
                endCapture(w, cap);
            }
            return;

        case Capture.move:
            if (p.action == PointerAction.drag || p.action == PointerAction.move
                || p.action == PointerAction.press)
            {
                const now = pointerToWorld(cam, p.pos, view);
                w.moveSelectionBy(now.x - w.dragNow.x, now.y - w.dragNow.y);
                w.dragNow = now;
            }
            else if (p.action == PointerAction.release)
            {
                // Sticky Space on a no-release target disarms with the pan;
                // for move it stays so the next drag can still pan if armed.
                endCapture(w, cap);
            }
            return;

        case Capture.pan:
            if (p.action == PointerAction.drag || p.action == PointerAction.move
                || p.action == PointerAction.press)
            {
                const now = surfaceCell(p.pos, view);
                cam.panBy(now.x - w.dragNow.x, now.y - w.dragNow.y);
                w.dragNow = now;
            }
            else if (p.action == PointerAction.release)
            {
                endCapture(w, cap);
                // One-shot Space arm on targets without releases: a completed
                // pan spends the arm so the next LMB is a normal click again.
                if (!view.capabilities.keyRelease)
                    w.spaceDown = false;
            }
            return;

        case Capture.minimapScrub:
            if (p.action == PointerAction.drag || p.action == PointerAction.move
                || p.action == PointerAction.press)
            {
                scrubMinimapTo(w, cam, surfaceCell(p.pos, view), view);
                w.dragNow = surfaceCell(p.pos, view);
            }
            else if (p.action == PointerAction.release)
                endCapture(w, cap);
            return;
    }
}

private void beginCapture(ref World w, ref CaptureState cap, Capture c, in Point at)
    @safe pure nothrow @nogc
{
    const id = captureIdOf(c);
    if (!cap.available(id))
        return;
    cap = cap.capturedBy(id);
    w.capture = c;
    w.dragStart = at;
    w.dragNow = at;
}

private void endCapture(ref World w, ref CaptureState cap) @safe pure nothrow @nogc
{
    cap = cap.released();
    w.capture = Capture.none;
}

private void cancelCapture(ref World w, ref CaptureState cap) @safe pure nothrow @nogc
{
    // Create/marquee cancel drops the in-progress rect without committing.
    endCapture(w, cap);
}

// ── wheel + pinch (`IXN4`) ──────────────────────────────────────────────────

private void onWheel(ref World w, ref Camera cam, in WheelEvent wh,
    in InputView view) @safe pure nothrow @nogc
{
    // Scroll up (negative dy) zooms in — the map convention, not the document
    // one. Horizontal notches are ignored: a board has no horizontal zoom.
    if (wh.dy == 0)
        return;
    const pivot = boardLocalCell(surfaceCell(wh.pos, view), view.viewport);
    if (view.backend == Backend.gui)
    {
        // Continuous: one ratio step per notch sign. A multi-line wheel event
        // is still one gesture step — the producer already folded notches.
        const ratio = wh.dy < 0 ? zoomInRatio : zoomOutRatio;
        cast(void) cam.zoomByRatio(ratio, pivot);
    }
    else
    {
        // Terminal: octaves only — a cell cannot express the mantissa.
        cam.zoomAt(wh.dy < 0 ? 1 : -1, pivot);
    }
}

private void onGesture(ref World w, ref Camera cam, in GestureEvent g,
    in InputView view) @safe pure nothrow @nogc
{
    if (g.gesture != Gesture.pinch)
        return;
    // `scale` is a ratio around 1.0; convert to the integer percent
    // `zoomByRatio` takes. A 1.0 is a no-op; clamp the absurd.
    int ratio = cast(int)(g.scale * scaleBase + 0.5f);
    if (ratio < 1)
        ratio = 1;
    if (ratio > 400)
        ratio = 400;
    const pivot = boardLocalCell(surfaceCell(g.pos, view), view.viewport);
    if (view.backend == Backend.gui)
        cast(void) cam.zoomByRatio(ratio, pivot);
    else
    {
        // A terminal still receives pinch only if some producer synthesised
        // one; step by the sign of the ratio around 1.
        if (ratio > scaleBase)
            cam.zoomAt(1, pivot);
        else if (ratio < scaleBase)
            cam.zoomAt(-1, pivot);
    }
}

// ── minimap scrub + fit ─────────────────────────────────────────────────────

private void scrubMinimapTo(ref World w, ref Camera cam, in Point screenCell,
    in InputView view) @safe pure nothrow @nogc
{
    const panel = minimapPanel(view.viewport);
    if (panel.empty)
        return;
    const local = Point(screenCell.x - panel.x, screenCell.y - panel.y);

    Rect[64] buf = void;
    // Prefer a small stack buffer; fall back to measuring via high-water when
    // the board is denser than the buffer (still correct, just truncated fit).
    const n = liveBounds(w, buf[]);
    const content = contentBounds(buf[0 .. n]);
    if (content.empty)
        return;
    const board = boardArea(view.viewport);
    const d = minimapDivisor(content, Size(panel.width, panel.height));
    const world = minimapToWorld(local, content, d);
    cam.lookAt(world, Size(board.width, board.height));
}

private void fitAll(ref World w, ref Camera cam, in Size viewport)
    @safe pure nothrow @nogc
{
    Rect[64] buf = void;
    const n = liveBounds(w, buf[]);
    const content = contentBounds(buf[0 .. n]);
    const board = boardArea(viewport);
    fitContent(cam, content, Size(board.width, board.height));
}

// ── coordinate helpers ──────────────────────────────────────────────────────

/// Pointer position → surface cell (toolbar / minimap / board share this grid).
private Point surfaceCell(in Point pos, in InputView view) @safe pure nothrow @nogc
{
    if (view.naturalCellW > 0 && view.naturalCellH > 0)
    {
        // Pixel mode: the surface is a cell grid of the natural (chrome) size.
        // The board's drawn cell size only applies inside the board, via
        // `pointerToWorld`.
        return Point(
            divFloorPx(pos.x, view.naturalCellW),
            divFloorPx(pos.y, view.naturalCellH));
    }
    return pos;
}

/// Surface cell → board-local cell (origin at the board's top-left).
private Point boardLocalCell(in Point surface, in Size viewport)
    @safe pure nothrow @nogc
{
    const board = boardArea(viewport);
    return Point(surface.x - board.x, surface.y - board.y);
}

/// Pointer position → world cell under the board camera.
private Point pointerToWorld(in Camera cam, in Point pos, in InputView view)
    @safe pure nothrow @nogc
{
    const board = boardArea(view.viewport);
    if (view.naturalCellW > 0 && view.naturalCellH > 0)
    {
        // Board cells are drawn at the mantissa-scaled size; chrome is not.
        const cW = cam.cellPixels(view.naturalCellW);
        const cH = cam.cellPixels(view.naturalCellH);
        const originPx = Point(board.x * view.naturalCellW, board.y * view.naturalCellH);
        const local = cam.pixelToCell(pos, originPx, cW, cH);
        return cam.screenToWorld(local);
    }
    const screen = surfaceCell(pos, view);
    return cam.screenToWorld(boardLocalCell(screen, view.viewport));
}

private Point boardPivot(in Size viewport) @safe pure nothrow @nogc
{
    const board = boardArea(viewport);
    return Point(board.width / 2, board.height / 2);
}

private bool isSpace(in KeyEvent k) @safe pure nothrow @nogc
    => k.key == Key.char_ && k.ch == ' ';

private int divFloorPx(int a, int b) @safe pure nothrow @nogc
{
    if (b <= 0)
        return a;
    const q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

// ---------------------------------------------------------------------------
// Pure tests — no host, no frame. Scripted sessions live on the component.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : charEvent, keyEvent, Point;

    private InputView tuiView(int w = 80, int h = 24) @safe pure nothrow @nogc
        => InputView(Size(w, h), InputCapabilities.init, Backend.tui);

    private InputView guiView(int w = 80, int h = 24) @safe pure nothrow @nogc
        => InputView(Size(w, h), InputCapabilities(keyRelease: true), Backend.gui);

    private Event pressAt(int x, int y, PointerButton b = PointerButton.left,
        Mods m = Mods.init) @safe pure nothrow @nogc
        => Event(PointerEvent(action: PointerAction.press, button: b,
            pos: Point(x, y), mods: m));

    private Event dragAt(int x, int y, PointerButton b = PointerButton.left)
        @safe pure nothrow @nogc
        => Event(PointerEvent(action: PointerAction.drag, button: b,
            pos: Point(x, y)));

    private Event releaseAt(int x, int y, PointerButton b = PointerButton.left)
        @safe pure nothrow @nogc
        => Event(PointerEvent(action: PointerAction.release, button: b,
            pos: Point(x, y)));

    private void drive(ref World w, ref Camera cam, ref CaptureState cap,
        in InputView view, in Event[] script) @safe pure nothrow @nogc
    {
        foreach (e; script)
            cast(void) systemInput(w, cam, cap, e, view);
    }
}

@("diagram.input.toolsSwitchOnKeys")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();

    assert(w.tool == Tool.select);
    cast(void) systemInput(w, cam, cap, charEvent('r'), view);
    assert(w.tool == Tool.rect);
    cast(void) systemInput(w, cam, cap, charEvent('c'), view);
    assert(w.tool == Tool.connect);
    cast(void) systemInput(w, cam, cap, charEvent('v'), view);
    assert(w.tool == Tool.select);
}

@("diagram.input.rectToolCreatesOnDrag")
@safe pure nothrow @nogc
unittest
{
    // `IXN2`: drag out a box; the new entity is selected.
    World w;
    Camera cam;
    CaptureState cap;
    auto view = tuiView();
    cast(void) systemInput(w, cam, cap, charEvent('r'), view);

    // Board starts at y = toolbarRows. World (0,0) is screen (0, 1) at zoom 0.
    drive(w, cam, cap, view, [
        pressAt(2, 1 + 2),
        dragAt(8, 1 + 6),
        releaseAt(8, 1 + 6),
    ]);

    assert(w.capture == Capture.none && cap.isFree);
    assert(w.count == 1);
    assert(w.bounds[0] == Rect(2, 2, 7, 5), "drag rect is inclusive");
    assert(w.selectionCount == 1 && w.selected(0));
}

@("diagram.input.selectClickAndShiftToggleAndMarquee")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    const a = w.spawn(Rect(2, 2, 4, 2));
    const b = w.spawn(Rect(10, 2, 4, 2));
    const c = w.spawn(Rect(2, 10, 4, 2));

    // Click selects only.
    drive(w, cam, cap, view, [pressAt(3, 1 + 3), releaseAt(3, 1 + 3)]);
    assert(w.selectionCount == 1 && w.selected(a));

    // Shift-click toggles another in.
    drive(w, cam, cap, view, [
        pressAt(11, 1 + 3, PointerButton.left, Mods(shift: true)),
        releaseAt(11, 1 + 3, PointerButton.left),
    ]);
    assert(w.selectionCount == 2 && w.selected(b));

    // Marquee over a and c (clear first by plain click on empty? marquee on
    // empty with no shift clears then selects within).
    drive(w, cam, cap, view, [
        pressAt(1, 1 + 1),
        dragAt(8, 1 + 14),
        releaseAt(8, 1 + 14),
    ]);
    assert(w.selected(a) && w.selected(c) && !w.selected(b));
}

@("diagram.input.moveDragsTheSelection")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    const e = w.spawn(Rect(4, 4, 3, 2));
    w.selectOnly(e);

    drive(w, cam, cap, view, [
        pressAt(5, 1 + 5),
        dragAt(9, 1 + 8),
        releaseAt(9, 1 + 8),
    ]);
    assert(w.bounds[e] == Rect(8, 7, 3, 2));
    assert(w.capture == Capture.none);
}

@("diagram.input.moveDoesNotDoubleMoveAGroup")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    const a = w.spawn(Rect(0, 0, 2, 2));
    const b = w.spawn(Rect(4, 0, 2, 2));
    w.select(a);
    w.select(b);
    assert(w.groupSelection() != 0);

    // Press on a, drag by (+3, 0). Both must move by 3, not 6.
    drive(w, cam, cap, view, [
        pressAt(1, 1 + 1),
        dragAt(4, 1 + 1),
        releaseAt(4, 1 + 1),
    ]);
    assert(w.bounds[a] == Rect(3, 0, 2, 2));
    assert(w.bounds[b] == Rect(7, 0, 2, 2));
}

@("diagram.input.connectCompletesAnEdgeAndEscCancels")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    cast(void) systemInput(w, cam, cap, charEvent('c'), view);
    const a = w.spawn(Rect(2, 2, 3, 2));
    const b = w.spawn(Rect(12, 2, 3, 2));

    // First click arms, Esc cancels.
    drive(w, cam, cap, view, [pressAt(3, 1 + 3), releaseAt(3, 1 + 3)]);
    assert(w.connectFrom == a);
    assert(!systemInput(w, cam, cap, keyEvent(Key.escape), view));
    assert(w.connectFrom == noEntity);

    // Full connect.
    drive(w, cam, cap, view, [
        pressAt(3, 1 + 3), releaseAt(3, 1 + 3),
        pressAt(13, 1 + 3), releaseAt(13, 1 + 3),
    ]);
    assert(w.edgeCount == 1);
    assert(w.edgeFrom(0) == a && w.edgeTo(0) == b);
    assert(w.connectFrom == noEntity);
}

@("diagram.input.middleDragAndSpaceLmbPan")
@safe pure nothrow @nogc
unittest
{
    // `IXN3`: middle-drag and Space+LMB both pan; WASD/arrows step.
    World w;
    Camera cam;
    CaptureState cap;
    auto view = guiView(); // key releases available

    drive(w, cam, cap, view, [
        pressAt(20, 10, PointerButton.middle),
        dragAt(10, 10, PointerButton.middle),
        releaseAt(10, 10, PointerButton.middle),
    ]);
    assert(cam.origin.x == 10, "middle-drag pans by the screen delta");

    cam.origin = Point.init;
    cast(void) systemInput(w, cam, cap, charEvent(' '), view);
    assert(w.spaceDown);
    drive(w, cam, cap, view, [
        pressAt(20, 12),
        dragAt(20, 4),
        releaseAt(20, 4),
    ]);
    assert(cam.origin.y == 8);
    // Release Space.
    auto up = charEvent(' ');
    // charEvent defaults to press; build a release.
    import sparkles.input : KeyEvent;
    cast(void) systemInput(w, cam, cap,
        Event(KeyEvent(Key.char_, ' ', Mods.init, KeyAction.release)), view);
    assert(!w.spaceDown);

    // Keyboard pan steps, identical on both targets. `d` looks right, so
    // the origin advances; left looks left, and they cancel.
    cam.origin = Point.init;
    cast(void) systemInput(w, cam, cap, charEvent('d'), view);
    assert(cam.origin.x == panStepCells);
    cast(void) systemInput(w, cam, cap, keyEvent(Key.left), view);
    assert(cam.origin.x == 0);
}

@("diagram.input.spaceIsStickyWithoutKeyRelease")
@safe pure nothrow @nogc
unittest
{
    // Terminal route: Space toggles the arm; a completed pan spends it.
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView(); // keyRelease = false

    cast(void) systemInput(w, cam, cap, charEvent(' '), view);
    assert(w.spaceDown);
    drive(w, cam, cap, view, [
        pressAt(20, 12),
        dragAt(10, 12),
        releaseAt(10, 12),
    ]);
    assert(cam.origin.x == 10);
    assert(!w.spaceDown, "the pan spent the sticky arm");
}

@("diagram.input.wheelZoomsTowardPointer")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const pivotScreen = Point(30, 1 + 10);
    const board = boardArea(Size(80, 24));
    const pivot = Point(pivotScreen.x - board.x, pivotScreen.y - board.y);

    // Terminal: octave step, pivot stable.
    auto tui = tuiView();
    const before = cam.screenToWorld(pivot);
    cast(void) systemInput(w, cam, cap,
        Event(WheelEvent(dy: -3, pos: pivotScreen)), tui);
    assert(cam.zoom == 1);
    assert(cam.screenToWorld(pivot) == before);

    // GUI: ratio step moves the mantissa first.
    cam = Camera.init;
    auto gui = guiView();
    cast(void) systemInput(w, cam, cap,
        Event(WheelEvent(dy: -3, pos: pivotScreen)), gui);
    assert(cam.zoom == 0 && cam.scalePercent == zoomInRatio);
}

@("diagram.input.keyboardZoomAndResetAndMinimapToggle")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();

    cast(void) systemInput(w, cam, cap, charEvent('+'), view);
    assert(cam.zoom == 1);
    cast(void) systemInput(w, cam, cap, charEvent('-'), view);
    assert(cam.zoom == 0);
    cam.scalePercent = 150;
    cam.zoom = 2;
    cast(void) systemInput(w, cam, cap, charEvent('0'), view);
    assert(cam.zoom == 0 && cam.scalePercent == scaleBase);

    assert(w.minimapVisible);
    cast(void) systemInput(w, cam, cap, charEvent('m'), view);
    assert(!w.minimapVisible);
}

@("diagram.input.fitAllFramesContent")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    cast(void) w.spawn(Rect(0, 0, 4, 4));
    cast(void) w.spawn(Rect(100, 50, 4, 4));

    cast(void) systemInput(w, cam, cap, charEvent('f'), view);
    const board = boardArea(view.viewport);
    const vis = cam.visibleWorldRect(Size(board.width, board.height));
    assert(vis.width >= 104 && vis.height >= 54, "content fits with padding");
}

@("diagram.input.minimapScrubRecentres")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    cast(void) w.spawn(Rect(0, 0, 10, 10));
    cast(void) w.spawn(Rect(200, 100, 10, 10));

    const panel = minimapPanel(view.viewport);
    assert(!panel.empty);
    // Click near the bottom-right of the minimap — should look toward the
    // far content, not the origin.
    const at = Point(panel.x + panel.width - 2, panel.y + panel.height - 2);
    drive(w, cam, cap, view, [pressAt(at.x, at.y), releaseAt(at.x, at.y)]);
    assert(cam.origin.x > 0 || cam.origin.y > 0, "scrub moved the camera");
}

@("diagram.input.captureHoldsAcrossChrome")
@safe pure nothrow @nogc
unittest
{
    // `IXN1`: a create drag that wanders over the minimap still belongs to
    // create — the press owns the drag.
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    cast(void) systemInput(w, cam, cap, charEvent('r'), view);

    const panel = minimapPanel(view.viewport);
    drive(w, cam, cap, view, [
        pressAt(2, 1 + 2),
        dragAt(panel.x + 1, panel.y + 1),
        releaseAt(panel.x + 1, panel.y + 1),
    ]);
    assert(w.count == 1, "create committed, not a minimap scrub");
    assert(w.capture == Capture.none && cap.isFree);
}

@("diagram.input.dismissChainOrder")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    cast(void) w.spawn(Rect(2, 2, 2, 2));

    // Menu first (`IXN6`).
    drive(w, cam, cap, view, [
        Event(PointerEvent(action: PointerAction.press,
            button: PointerButton.right, pos: Point(3, 1 + 3))),
    ]);
    assert(w.menuOpen);
    assert(!systemInput(w, cam, cap, keyEvent(Key.escape), view));
    assert(!w.menuOpen);

    cast(void) systemInput(w, cam, cap, charEvent('c'), view);
    drive(w, cam, cap, view, [pressAt(2, 1 + 2), releaseAt(2, 1 + 2)]);
    assert(w.connectFrom != noEntity);

    // Cancel connect
    assert(!systemInput(w, cam, cap, keyEvent(Key.escape), view));
    assert(w.connectFrom == noEntity);

    // Arm a selection, then dismiss clears it before quitting.
    w.selectOnly(0);
    assert(!systemInput(w, cam, cap, keyEvent(Key.escape), view));
    assert(w.selectionCount == 0);

    // Empty board: Esc quits.
    assert(systemInput(w, cam, cap, keyEvent(Key.escape), view));
}

@("diagram.input.contextMenuDelete")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    const e = w.spawn(Rect(2, 2, 3, 2));
    w.selectOnly(e);

    // RMB opens; click Delete.
    drive(w, cam, cap, view, [
        Event(PointerEvent(action: PointerAction.press,
            button: PointerButton.right, pos: Point(3, 1 + 3))),
    ]);
    assert(w.menuOpen);
    const del = menuItemRect(w, MenuItem.delete_);
    drive(w, cam, cap, view, [
        pressAt(del.x + 1, del.y),
        releaseAt(del.x + 1, del.y),
    ]);
    assert(!w.menuOpen && !w.alive(e) && w.count == 0);
}

@("diagram.input.groupUngroupFromKeysAndMenu")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    const a = w.spawn(Rect(0, 0, 2, 2));
    const b = w.spawn(Rect(4, 0, 2, 2));
    w.select(a);
    w.select(b);
    cast(void) systemInput(w, cam, cap, charEvent('g'), view);
    assert(w.group[a] != 0 && w.group[a] == w.group[b]);
    cast(void) systemInput(w, cam, cap, charEvent('u'), view);
    assert(w.group[a] == 0 && w.group[b] == 0);
}

@("diagram.input.labelEditFromMenu")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();
    const e = w.spawn(Rect(2, 2, 8, 2));
    w.selectOnly(e);

    drive(w, cam, cap, view, [
        Event(PointerEvent(action: PointerAction.press,
            button: PointerButton.right, pos: Point(3, 1 + 3))),
    ]);
    const lab = menuItemRect(w, MenuItem.label);
    drive(w, cam, cap, view, [pressAt(lab.x + 1, lab.y)]);
    assert(w.isEditing && w.editing == e);

    cast(void) systemInput(w, cam, cap, charEvent('H'), view);
    cast(void) systemInput(w, cam, cap, charEvent('i'), view);
    cast(void) systemInput(w, cam, cap, keyEvent(Key.enter), view);
    assert(!w.isEditing && w.labelOf(e) == "Hi");
}

@("diagram.input.gridSettingsFromMenuAndKeys")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.components.grid_backdrop : MarkKind;

    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();

    drive(w, cam, cap, view, [
        Event(PointerEvent(action: PointerAction.press,
            button: PointerButton.right, pos: Point(3, 1 + 3))),
    ]);
    const item = menuItemRect(w, MenuItem.grid);
    drive(w, cam, cap, view, [pressAt(item.x + 1, item.y)]);
    assert(w.gridSettingsOpen);

    cast(void) systemInput(w, cam, cap, charEvent('3'), view);
    assert(w.gridConfig.minorStyle.markKind == MarkKind.dots);
    assert(w.gridPresetIndex == 2);

    cast(void) systemInput(w, cam, cap, keyEvent(Key.escape), view);
    assert(!w.gridSettingsOpen);
}

@("diagram.input.toolbarPicksTheTool")
@safe pure nothrow @nogc
unittest
{
    World w;
    Camera cam;
    CaptureState cap;
    const view = tuiView();

    const rectBtn = toolButton(Tool.rect, view.viewport);
    drive(w, cam, cap, view, [
        pressAt(rectBtn.x + 1, rectBtn.y),
        releaseAt(rectBtn.x + 1, rectBtn.y),
    ]);
    assert(w.tool == Tool.rect);
}

@("diagram.camera.fitContentAndLookAt")
@safe pure nothrow @nogc
unittest
{
    // Camera helpers added for `IXN4` — pure, so they live with the camera.
    auto cam = Camera(Point(0, 0), 0);
    const content = Rect(10, 10, 20, 10);
    fitContent(cam, content, Size(80, 24), 2);
    assert(cam.scalePercent == scaleBase);
    const vis = cam.visibleWorldRect(Size(80, 24));
    assert(vis.width >= content.width && vis.height >= content.height);

    cam.lookAt(Point(100, 50), Size(80, 24));
    const mid = cam.screenToWorld(Point(40, 12));
    assert(mid.x <= 100 && mid.x + cam.worldPerCell > 100 - cam.worldPerCell);
}
