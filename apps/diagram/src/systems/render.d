/**
The render systems (`RND1`–`RND5`, `GRD7`, `DIA5`): free functions that turn a
$(MREF world) + $(MREF camera) into a flat $(REF DrawOp, sparkles,ui,canvas)
stream.

Three streams, one buffer, append order is z-order (`RND1`):

$(LIST
    * $(B board) — grid, culled nodes, orthogonal connectors, group outlines,
        marquee/create previews
    * $(B minimap) — every live entity (no cull — `RND2`) and the camera frustum
    * $(B chrome) — toolbar, status, context menu
)

Colours are slots resolved against the frame's palette (`RND5`); the page fill
is the host's, not ours. The steady-state path is `@safe pure nothrow @nogc`
(`DIA5`): columns and the op buffer are fixed, labels are borrowed, and a
unittest compiles the whole frame under the attribute.

Connectors (`RND3`) are orthogonal box-drawing routes — never the canvas
`line` primitive — so arms connect across cells on both targets.
*/
module systems.render;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.base.text.grapheme : byGraphemeCluster, visibleWidth;
import sparkles.base.text.writers : writeInteger;
import sparkles.base.unique : makeUnique;
import sparkles.ui.arena : FrameArena;
import sparkles.ui.canvas : DrawOp, OpKind, RuleEdge;
import sparkles.ui.cmd_buffer : CmdBufferT;
import sparkles.ui.components.grid_backdrop : appendGridBackdrop, GridView;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.style : ColorScheme, defaultTwoslashPalette, Palette,
    resolveSlot, Slot, Visual;

import camera : Camera, contentBounds, minimapDivisor, minimapFrustum,
    worldToMinimap;
import systems.input : boardArea,
    menuItemCount, menuItemLabel, menuItemRect, menuPanel, MenuItem,
    minimapPanel, statusRows, toolButton, toolbarArea, toolbarRows;
import world : Capture, Entity, GroupId, liveBounds, noEntity, Tool, World,
    entityCap;

/// Inline capacity of the frame's op buffer. A few thousand ops covers a dense
/// board at terminal size without spilling to the heap; the `@nogc` frame
/// path asserts it stays under.
enum size_t frameOpCap = 16_384;

/**
Ops the BOARD may not spend (`RND1`).

The ceiling used to be one number every emitter checked against the whole
buffer, which made the chrome the thing that lost. A dotted backdrop costs one
op per lattice $(I intersection) where a lined one costs a rule per row and
column, so switching minor marks to `dots` multiplied the board's cost by two
orders of magnitude: the grid alone reached the ceiling, and the toolbar, the
status row and the minimap — emitted afterwards, and all small — then emitted
NOTHING. A board with no chrome at all, from one enum change.

Two things were wrong, and both are fixed here. The ceiling itself was sized
for a lined grid: one dot per screen cell is the honest cost of graph paper,
so a surface of 16k cells needs 16k ops and 4,096 could not draw a 100×45
terminal. And the ceiling was shared, so the unbounded half of the frame could
spend the bounded half's share. Now the board draws inside a budget and the
chrome's is reserved: the board is the part that can be arbitrarily dense, the
chrome is the part that says what the board is doing, and the second is never
what the first costs you.
*/
enum size_t chromeOpReserve = 512;
/// ditto
enum size_t boardOpBudget = frameOpCap - chromeOpReserve;

/// How many of those the buffer holds inline before it reaches for the heap.
/// Deliberately not `frameOpCap`: the two used to be one number, which put
/// every operation of a full frame in the buffer's own storage — 2.6 MB of it,
/// back when an operation was 656 bytes. A warm start is all this needs to be.
enum size_t frameOpInline = 64;

/// The frame buffer type — one reuse per component (`RND1`, `DIA5`).
alias FrameOps = CmdBufferT!(FrameArena!(), frameOpInline);

/**
Emits the whole frame into `ops`: board, then minimap, then chrome.

`ops` is cleared first so a retained buffer from the previous frame never
leaks. Colours come from `pal` + the page pair — the app names slots only.
*/
void systemRender(ref const World w, ref const Camera cam, in Size viewport,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    ops.reset();
    const board = boardArea(viewport);
    if (!board.empty)
    {
        renderBoard(w, cam, board, pal, pageFg, pageBg, ops);
        if (w.minimapVisible)
            renderMinimap(w, cam, viewport, board, pal, pageFg, pageBg, ops);
    }
    renderChrome(w, cam, viewport, pal, pageFg, pageBg, ops);
    if (w.menuOpen)
        renderMenu(w, viewport, pal, pageFg, pageBg, ops);
    // The settings pane is NOT painted here (`SET8`): it is a widget tree, so
    // it needs `Builder`/`layout`, which allocate — and this function is the
    // `@nogc` steady-state frame (`DIA5`). `DiagramApp.paint` appends it to
    // the same buffer afterwards, on the frames it actually shows, exactly as
    // the key guide does.
}

// ── board (`RND2`, `RND4`) ──────────────────────────────────────────────────

private void renderBoard(ref const World w, ref const Camera cam, in Rect board,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    // Clip everything board-local so a node straddling the chrome is cut, not
    // painted over the toolbar.
    pushClip(ops, board);
    scope (exit) popClip(ops);

    const boardSize = Size(board.width, board.height);
    const vis = cam.visibleWorldRect(boardSize);

    GridView gv = {
        screen: board,
        world: vis,
        origin: cam.origin,
        worldPerCell: cam.worldPerCell,
        cellsPerWorld: cam.cellsPerWorld,
    };
    // The backdrop gets what the board has, minus what the rest of the board
    // still needs; it drops a layer whole rather than half-drawing one.
    appendGridBackdrop(ops, w.gridConfig, gv, pal, pageFg, pageBg,
        boardOpBudget > ops.length ? boardOpBudget - ops.length : 0);

    // Connectors under nodes so a box covers the stub that enters it (`RND3`).
    renderConnectors(w, cam, board, vis, pal, pageFg, pageBg, ops);

    // z-order: collect culled live entities, sort ascending, paint.
    Entity[entityCap] order = void;
    size_t n;
    foreach (e; 0 .. w.highWater)
    {
        if (!w.alive(cast(Entity) e))
            continue;
        if (w.bounds[e].intersection(vis).empty)
            continue; // `RND2`: off-camera emits nothing to the board
        if (n < order.length)
            order[n++] = cast(Entity) e;
    }
    sortByZ(w, order[0 .. n]);

    const surfaceVis = resolveSlot(pal, Slot.surface, pageFg, pageBg);
    const borderVis = resolveSlot(pal, Slot.border, pageFg, pageBg);
    const selectVis = resolveSlot(pal, Slot.selection, pageFg, pageBg);
    const accentVis = resolveSlot(pal, Slot.chromeAccent, pageFg, pageBg);
    const codeVis = resolveSlot(pal, Slot.code, pageFg, pageBg);
    const caretVis = resolveSlot(pal, Slot.caret, pageFg, pageBg);

    foreach (e; order[0 .. n])
    {
        // Same budget as the backdrop, for the same reason: a board dense
        // with entities must not be able to cost the reader their chrome.
        if (ops.length >= boardOpBudget)
            break;
        const r = worldRectToSurface(cam, w.bounds[e], board);
        if (r.empty)
            continue;
        // Selection tint under the body so the border still reads.
        if (w.selected(e))
            fill(ops, r, Slot.selection, withBg(selectVis, true));
        fill(ops, r, Slot.surface, withBg(surfaceVis, true));
        outline(ops, r, w.selected(e) ? Slot.chromeAccent : Slot.border,
            w.selected(e) ? accentVis : borderVis);
        // Labels: owned textRun (DrawOp copies the bytes). While editing,
        // show the draft from the edit buffer.
        const editing = w.editing == e;
        const lab = editing
            ? w.editBuf[0 .. w.editLen]
            : w.label[e][0 .. w.labelLen[e]];
        if (lab.length && r.height >= 1 && r.width >= 1)
            textAt(ops, Point(r.x, r.y), lab, Slot.code, codeVis, r.width);
        if (editing && r.height >= 1)
        {
            // Caret after the draft (clamped inside the box), by cell width.
            int cx = r.x + cast(int) visibleWidth(lab);
            if (cx >= r.right)
                cx = r.right - 1;
            if (cx < r.x)
                cx = r.x;
            glyphAt(ops, Point(cx, r.y), '|', Slot.caret, caretVis);
        }
    }

    renderGroupOutlines(w, cam, board, vis, pal, pageFg, pageBg, ops);

    // In-progress drag previews (`RND4`).
    if (w.capture == Capture.marquee || w.capture == Capture.create)
    {
        const r = worldRectToSurface(cam, w.dragRect, board);
        if (!r.empty)
            outline(ops, r, Slot.selection, selectVis);
    }

    // Pending connect half: a faint accent on the source node.
    if (w.connectFrom != noEntity && w.alive(w.connectFrom))
    {
        const r = worldRectToSurface(cam, w.bounds[w.connectFrom], board);
        if (!r.empty)
            outline(ops, r, Slot.chromeAccent, accentVis);
    }
}

// ── connectors (`RND3`) ─────────────────────────────────────────────────────

/**
Orthogonal box-drawing route from `from` to `to` (`RND3`).

Elbow at `(to.centre.x, from.centre.y)`: horizontal, then vertical. Drawn with
`─│╭╮╰╯` plus an arrowhead on the last step — never the canvas `line`
primitive — so arms connect across cells through the GPU backend's procedural
box drawing.
*/
private void renderConnectors(ref const World w, ref const Camera cam,
    in Rect board, in Rect vis, in Palette pal, in RgbColor pageFg,
    in RgbColor pageBg, ref FrameOps ops) @safe pure nothrow @nogc
{
    const accent = resolveSlot(pal, Slot.chromeAccent, pageFg, pageBg);
    foreach (i; 0 .. w.edgeCount)
    {
        const a = w.edgeFrom(i);
        const b = w.edgeTo(i);
        if (!w.alive(a) || !w.alive(b))
            continue;
        if (w.bounds[a].intersection(vis).empty
            && w.bounds[b].intersection(vis).empty)
            continue;
        drawOrthoEdge(cam, board, w.bounds[a], w.bounds[b], accent, ops);
    }
}

private void drawOrthoEdge(ref const Camera cam, in Rect board,
    in Rect from, in Rect to, in Visual vis, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    const Point ac = Point(from.x + from.width / 2, from.y + from.height / 2);
    const Point bc = Point(to.x + to.width / 2, to.y + to.height / 2);
    const Point mid = Point(bc.x, ac.y);

    paintH(cam, board, ac.x, mid.x, ac.y, from, to, vis, ops);
    paintV(cam, board, mid.y, bc.y, mid.x, from, to, vis, ops,
        mid.x > ac.x ? 1 : (mid.x < ac.x ? -1 : 0),
        mid.x != ac.x && mid.y != bc.y);

    Point tip = bc;
    if (bc.y != mid.y)
        tip = Point(bc.x, bc.y > mid.y ? bc.y - 1 : bc.y + 1);
    else if (bc.x != mid.x)
        tip = Point(bc.x > mid.x ? bc.x - 1 : bc.x + 1, bc.y);
    if (!from.contains(tip) && !to.contains(tip))
    {
        dchar head = '▶';
        if (bc.y > mid.y) head = '▼';
        else if (bc.y < mid.y) head = '▲';
        else if (bc.x < ac.x) head = '◀';
        putWorldGlyph(cam, board, tip, head, vis, ops);
    }
}

private void paintH(ref const Camera cam, in Rect board, int x0, int x1, int y,
    in Rect skipA, in Rect skipB, in Visual vis, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    if (x0 == x1)
        return;
    const step = x1 > x0 ? 1 : -1;
    int x = x0 + step;
    enum int maxSteps = 512;
    foreach (_; 0 .. maxSteps)
    {
        const p = Point(x, y);
        if (!skipA.contains(p) && !skipB.contains(p))
            putWorldGlyph(cam, board, p, '─', vis, ops);
        if (x == x1)
            break;
        x += step;
    }
}

private void paintV(ref const Camera cam, in Rect board, int y0, int y1, int x,
    in Rect skipA, in Rect skipB, in Visual vis, ref FrameOps ops,
    int elbowFromDx, bool hasElbow) @safe pure nothrow @nogc
{
    if (y0 == y1)
        return;
    const step = y1 > y0 ? 1 : -1;
    if (hasElbow)
    {
        const p = Point(x, y0);
        if (!skipA.contains(p) && !skipB.contains(p))
        {
            dchar corner = '│';
            if (elbowFromDx > 0 && step > 0) corner = '╮';
            else if (elbowFromDx > 0 && step < 0) corner = '╯';
            else if (elbowFromDx < 0 && step > 0) corner = '╭';
            else if (elbowFromDx < 0 && step < 0) corner = '╰';
            putWorldGlyph(cam, board, p, corner, vis, ops);
        }
    }
    int y = y0 + step;
    enum int maxSteps = 512;
    foreach (_; 0 .. maxSteps)
    {
        const p = Point(x, y);
        if (!skipA.contains(p) && !skipB.contains(p))
            putWorldGlyph(cam, board, p, '│', vis, ops);
        if (y == y1)
            break;
        y += step;
    }
}

private void putWorldGlyph(ref const Camera cam, in Rect board, in Point world,
    dchar g, in Visual vis, ref FrameOps ops) @safe pure nothrow @nogc
{
    const s = cam.worldToScreen(world);
    glyphAt(ops, Point(board.x + s.x, board.y + s.y), g, Slot.chromeAccent, vis);
}



private void renderGroupOutlines(ref const World w, ref const Camera cam,
    in Rect board, in Rect vis, in Palette pal, in RgbColor pageFg,
    in RgbColor pageBg, ref FrameOps ops) @safe pure nothrow @nogc
{
    const accent = resolveSlot(pal, Slot.info, pageFg, pageBg);
    // Walk groups by first-seen member; a second pass would need a set. With
    // a flat id column this is one scan that stamps each group once.
    GroupId[64] seen = void;
    size_t seenN;
    foreach (e; 0 .. w.highWater)
    {
        if (!w.alive(cast(Entity) e))
            continue;
        const g = w.group[e];
        if (g == 0)
            continue;
        bool already;
        foreach (i; 0 .. seenN)
            if (seen[i] == g)
            {
                already = true;
                break;
            }
        if (already)
            continue;
        if (seenN < seen.length)
            seen[seenN++] = g;

        // Bounds of every member, including off-camera ones that still
        // contribute to the outline (a group half-off-screen should show its
        // edge, not a clipped lie).
        int x0 = int.max, y0 = int.max, x1 = int.min, y1 = int.min;
        bool any;
        foreach (o; 0 .. w.highWater)
        {
            if (!w.alive(cast(Entity) o) || w.group[o] != g)
                continue;
            const b = w.bounds[o];
            any = true;
            if (b.x < x0) x0 = b.x;
            if (b.y < y0) y0 = b.y;
            if (b.right > x1) x1 = b.right;
            if (b.bottom > y1) y1 = b.bottom;
        }
        if (!any)
            continue;
        const world = Rect(x0 - 1, y0 - 1, (x1 - x0) + 2, (y1 - y0) + 2);
        if (world.intersection(vis).empty)
            continue;
        const r = worldRectToSurface(cam, world, board);
        if (!r.empty)
            outline(ops, r, Slot.info, accent);
    }
}

// ── minimap (`RND2`) ────────────────────────────────────────────────────────

private void renderMinimap(ref const World w, ref const Camera cam,
    in Size viewport, in Rect board, in Palette pal, in RgbColor pageFg,
    in RgbColor pageBg, ref FrameOps ops) @safe pure nothrow @nogc
{
    const panel = minimapPanel(viewport);
    if (panel.empty)
        return;

    const surface = resolveSlot(pal, Slot.surface, pageFg, pageBg);
    const border = resolveSlot(pal, Slot.border, pageFg, pageBg);
    const accent = resolveSlot(pal, Slot.chromeAccent, pageFg, pageBg);
    const code = resolveSlot(pal, Slot.code, pageFg, pageBg);

    fill(ops, panel, Slot.surface, withBg(surface, true));
    outline(ops, panel, Slot.border, border);

    Rect[64] buf = void;
    const n = liveBounds(w, buf[]);
    const content = contentBounds(buf[0 .. n]);
    if (content.empty)
        return;

    const d = minimapDivisor(content, Size(panel.width, panel.height));

    // Every live entity — the board may have culled them (`RND2`).
    foreach (e; 0 .. w.highWater)
    {
        if (ops.length >= boardOpBudget)
            break; // the chrome's share is not the minimap's to spend either
        if (!w.alive(cast(Entity) e))
            continue;
        const b = w.bounds[e];
        const tl = worldToMinimap(b.origin, content, d);
        const br = worldToMinimap(Point(b.right, b.bottom), content, d);
        int rw = br.x - tl.x;
        int rh = br.y - tl.y;
        if (rw < 1) rw = 1;
        if (rh < 1) rh = 1;
        const r = Rect(panel.x + tl.x, panel.y + tl.y, rw, rh)
            .intersection(panel);
        if (!r.empty)
            fill(ops, r, Slot.code, withBg(code, true));
    }

    const fr = minimapFrustum(cam, Size(board.width, board.height), content, d);
    const frSurf = Rect(panel.x + fr.x, panel.y + fr.y, fr.width, fr.height)
        .intersection(panel);
    if (!frSurf.empty)
        outline(ops, frSurf, Slot.chromeAccent, accent);
}

// ── chrome ──────────────────────────────────────────────────────────────────

private void renderChrome(ref const World w, ref const Camera cam,
    in Size viewport, in Palette pal, in RgbColor pageFg, in RgbColor pageBg,
    ref FrameOps ops) @safe pure nothrow @nogc
{
    const chrome = resolveSlot(pal, Slot.chrome, pageFg, pageBg);
    const accent = resolveSlot(pal, Slot.chromeAccent, pageFg, pageBg);
    const muted = resolveSlot(pal, Slot.muted, pageFg, pageBg);

    const bar = toolbarArea(viewport);
    if (!bar.empty)
    {
        fill(ops, bar, Slot.chrome, withBg(chrome, true));
        // Tool chips: one glyph each, accent when active.
        static immutable dchar[3] glyphs = ['v', 'r', 'c'];
        static immutable Tool[3] tools = [Tool.select, Tool.rect, Tool.connect];
        foreach (i, t; tools)
        {
            const btn = toolButton(t, viewport);
            if (btn.empty)
                continue;
            const active = w.tool == t;
            if (active)
                fill(ops, btn, Slot.chromeAccent, withBg(accent, true));
            glyphAt(ops, btn.origin, glyphs[i], active ? Slot.chromeAccent : Slot.chrome,
                active ? accent : chrome);
        }
    }

    // Status row: tool · zoom · sel N · count
    if (viewport.height >= toolbarRows + statusRows)
    {
        const status = Rect(0, viewport.height - statusRows, viewport.width, statusRows);
        fill(ops, status, Slot.chrome, withBg(chrome, true));

        // Fixed scratch — drawn this frame only; the paint phase replays
        // immediately, so the slice need not outlive the frame.
        char[96] buf = void;
        size_t n;
        void put(scope const(char)[] s) @safe pure nothrow @nogc
        {
            const take = s.length < buf.length - n ? s.length : buf.length - n;
            buf[n .. n + take] = s[0 .. take];
            n += take;
        }
        void putInt(int v) @safe pure nothrow @nogc
        {
            // writeInteger needs an output range; a tiny local sink.
            struct Sink
            {
                char[] dest;
                size_t* len;
                void put(char c) @safe pure nothrow @nogc
                {
                    if (*len < dest.length)
                        dest[(*len)++] = c;
                }
                void put(scope const(char)[] s) @safe pure nothrow @nogc
                {
                    foreach (c; s)
                        put(c);
                }
            }
            auto sink = Sink(buf[], &n);
            if (v < 0)
            {
                sink.put('-');
                // Avoid negating int.min.
                writeInteger(sink, v == int.min ? cast(uint) int.max + 1 : cast(uint) -v);
            }
            else
                writeInteger(sink, cast(uint) v);
        }

        put(toolName(w.tool));
        put("  z");
        putInt(cam.zoom);
        if (cam.scalePercent != 100)
        {
            put(".");
            putInt(cam.scalePercent);
        }
        put("%  sel ");
        putInt(cast(int) w.selectionCount);
        put("  n ");
        putInt(cast(int) w.count);
        if (w.connectFrom != noEntity)
            put("  connecting…");

        // Owned textRun: setText copies buf into the op, so the stack
        // scratch need not outlive this function.
        textAt(ops, Point(status.x, status.y), buf[0 .. n], Slot.muted, muted,
            status.width);
    }
}

private string toolName(Tool t) @safe pure nothrow @nogc
{
    final switch (t)
    {
        case Tool.select: return "select";
        case Tool.rect: return "rect";
        case Tool.connect: return "connect";
    }
}

// ── context menu (`IXN5`) ───────────────────────────────────────────────────

private void renderMenu(ref const World w, in Size viewport, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    const panel = menuPanel(w);
    if (panel.empty)
        return;
    const surface = resolveSlot(pal, Slot.surface, pageFg, pageBg);
    const border = resolveSlot(pal, Slot.border, pageFg, pageBg);
    const code = resolveSlot(pal, Slot.code, pageFg, pageBg);
    fill(ops, panel, Slot.surface, withBg(surface, true));
    outline(ops, panel, Slot.border, border);
    foreach (i; 0 .. menuItemCount)
    {
        const item = cast(MenuItem) i;
        const row = menuItemRect(w, item);
        textAt(ops, Point(row.x + 1, row.y), menuItemLabel(item), Slot.code,
            code, row.width > 1 ? row.width - 1 : 0);
    }
}

// ── geometry ────────────────────────────────────────────────────────────────

/// World rectangle → surface rectangle in board space (board origin applied).
private Rect worldRectToSurface(ref const Camera cam, in Rect world, in Rect board)
    @safe pure nothrow @nogc
{
    const tl = cam.worldToScreen(world.origin);
    // Exclusive corner: the cell just past the entity.
    const br = cam.worldToScreen(Point(world.right, world.bottom));
    int w = br.x - tl.x;
    int h = br.y - tl.y;
    // Zoomed out a small entity can collapse to nothing — keep one cell so a
    // node is always pickable by eye.
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    return Rect(board.x + tl.x, board.y + tl.y, w, h);
}

private void sortByZ(ref const World w, scope Entity[] order)
    @safe pure nothrow @nogc
{
    // Insertion sort: n is the culled visible set, typically small.
    foreach (i; 1 .. order.length)
    {
        const key = order[i];
        const kz = w.zOrder[key];
        sizediff_t j = cast(sizediff_t) i - 1;
        while (j >= 0 && w.zOrder[order[j]] > kz)
        {
            order[j + 1] = order[j];
            --j;
        }
        order[j + 1] = key;
    }
}

// ── op emitters ─────────────────────────────────────────────────────────────

private void fill(ref FrameOps ops, in Rect r, Slot slot, in Visual vis)
    @safe pure nothrow @nogc
{
    if (r.empty || ops.length >= frameOpCap)
        return;
    ops.fillRect(r, slot, vis);
}

private void outline(ref FrameOps ops, in Rect r, Slot slot, in Visual vis)
    @safe pure nothrow @nogc
{
    if (r.empty)
        return;
    ruleEdge(ops, r, RuleEdge.top, slot, vis);
    ruleEdge(ops, r, RuleEdge.bottom, slot, vis);
    ruleEdge(ops, r, RuleEdge.left, slot, vis);
    ruleEdge(ops, r, RuleEdge.right, slot, vis);
}

private void ruleEdge(ref FrameOps ops, in Rect r, RuleEdge edge, Slot slot,
    in Visual vis) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops.rule(r, edge, slot, vis);
}

/// `text` is borrowed into the op — the caller must keep it alive for the
/// frame (entity labels live in the world's fixed slots; that is enough).
private void glyphAt(ref FrameOps ops, in Point at, dchar g, Slot slot,
    in Visual vis) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops.glyph(at, g, slot, vis);
}

/**
Emit `s` as one owned `textRun`, truncated to `maxCells` on a grapheme-cluster
boundary (ZWJ / CJK / combining marks advance by cluster width, not by byte).
*/
private void textAt(ref FrameOps ops, in Point at, scope const(char)[] s,
    Slot slot, in Visual vis, int maxCells) @safe pure nothrow @nogc
{
    if (s.length == 0 || maxCells <= 0 || ops.length >= frameOpCap)
        return;

    size_t byteEnd;
    int cells;
    size_t pos;
    foreach (c; s.byGraphemeCluster)
    {
        if (c.isEscape)
        {
            pos += c.slice.length;
            continue;
        }
        if (c.width <= 0)
        {
            // Zero-width cluster still consumes bytes (e.g. orphaned marks).
            pos += c.slice.length;
            byteEnd = pos;
            continue;
        }
        if (cells + c.width > maxCells)
            break;
        cells += c.width;
        pos += c.slice.length;
        byteEnd = pos;
    }
    if (cells <= 0 || byteEnd == 0)
        return;

    ops.textRun(Rect(at.x, at.y, cells, 1), s[0 .. byteEnd], slot, vis);
}

private void pushClip(ref FrameOps ops, in Rect r) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops.pushClip(r);
}

private void popClip(ref FrameOps ops) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops.popClip();
}

private Visual withBg(Visual v, bool on) @safe pure nothrow @nogc
{
    v.hasBg = on;
    return v;
}

// ---------------------------------------------------------------------------
// Tests (`RND1`–`RND2`, `RND4`–`RND5`, `DIA5`)
// ---------------------------------------------------------------------------

version (unittest)
{
    import world : Tool;

    private Palette testPal() @safe pure nothrow @nogc
        => defaultTwoslashPalette(ColorScheme.dark);

    private enum fg = RgbColor(0xcc, 0xcc, 0xcc);
    private enum bg = RgbColor(0x12, 0x12, 0x12);
}

@("diagram.render.frameIsNogc")
@safe pure nothrow @nogc
unittest
{
    // `DIA5`: the steady-state frame path compiles under the attribute.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    cast(void) w.spawn(Rect(0, 0, 4, 2));
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);
    assert(ops.length > 0);
    assert(ops.length < frameOpCap);
}

@("diagram.render.boardCullsOffCameraButMinimapDoesNot")
@safe pure nothrow @nogc
unittest
{
    // `RND2`: an entity outside the camera emits nothing to the board stream
    // and still appears on the minimap — asserted, not an optimisation note.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    // Camera at origin looking at a small viewport-worth of world.
    cam.origin = Point(0, 0);
    cam.zoom = 0;
    // Wide enough for a 4-letter label at zoom 0 (one cell per world cell).
    const near = w.spawn(Rect(2, 2, 8, 2));
    const far = w.spawn(Rect(500, 500, 8, 2));
    w.setLabel(near, "near");
    w.setLabel(far, "far");

    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    // Board paints labels as owned textRuns; minimap paints only fills.
    size_t nearRuns, farRuns, entityFills, codeTextRuns;
    const panel = minimapPanel(Size(80, 24));
    foreach (ref op; ops[])
    {
        if (op.kind == OpKind.textRun)
        {
            ++codeTextRuns;
            // Compare via a temporary slice copy of the owned buffer.
            const t = op.text;
            if (t == "near")
                ++nearRuns;
            if (t == "far")
                ++farRuns;
        }
        if (op.kind == OpKind.fillRect && !panel.empty
            && panel.contains(op.rect.origin)
            && op.slot == Slot.code)
        {
            // Minimap entity fills use Slot.code.
            ++entityFills;
        }
    }
    assert(nearRuns >= 1, "on-camera node is labelled on the board");
    assert(farRuns == 0, "off-camera node emits no board label");
    // Minimap shows both entities as fills (near + far ≥ 2).
    assert(entityFills >= 2, "minimap paints every live entity");
    assert(codeTextRuns >= 1, "at least the near label was a textRun");
}

@("diagram.render.streamsAreBoardThenMinimapThenChrome")
@safe pure nothrow @nogc
unittest
{
    // `RND1`: z-order is append order. A chrome fill (toolbar y=0) must not
    // appear before the board's pushClip, and the minimap panel fill sits
    // between board content and the status row.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    cast(void) w.spawn(Rect(1, 1, 2, 2));
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    size_t firstClip = size_t.max, firstMinimap = size_t.max, firstStatus = size_t.max;
    const panel = minimapPanel(Size(80, 24));
    foreach (i, ref op; ops[])
    {
        if (op.kind == OpKind.pushClip && firstClip == size_t.max)
            firstClip = i;
        if (op.kind == OpKind.fillRect && op.rect == panel && firstMinimap == size_t.max)
            firstMinimap = i;
        if (op.kind == OpKind.fillRect && op.rect.y == 23 && firstStatus == size_t.max)
            firstStatus = i;
    }
    assert(firstClip != size_t.max, "board opens a clip");
    assert(firstMinimap != size_t.max, "minimap panel was filled");
    assert(firstStatus != size_t.max, "status row was filled");
    assert(firstClip < firstMinimap, "board before minimap");
    assert(firstMinimap < firstStatus, "minimap before chrome status");
}

@("diagram.render.usesSlotsNeverRawRgbInSlotField")
@safe pure nothrow @nogc
unittest
{
    // `RND5`: every op names a Slot (or is a clip). The page is the host's.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    cast(void) w.spawn(Rect(0, 0, 4, 2));
    w.selectOnly(0);
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    foreach (ref op; ops[])
    {
        if (op.kind == OpKind.pushClip || op.kind == OpKind.popClip)
            continue;
        // Slot.inherit is the only "unset" and we never emit it for paint.
        assert(op.slot != Slot.inherit);
    }
}

@("diagram.render.marqueeAndCreatePreview")
@safe pure nothrow @nogc
unittest
{
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    w.capture = Capture.marquee;
    w.dragStart = Point(1, 1);
    w.dragNow = Point(10, 8);
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    size_t selectionRules;
    foreach (ref op; ops[])
        if (op.kind == OpKind.rule && op.slot == Slot.selection)
            ++selectionRules;
    assert(selectionRules >= 4, "marquee is an outlined rectangle");
}

@("diagram.render.groupOutline")
@safe pure nothrow @nogc
unittest
{
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    const a = w.spawn(Rect(2, 2, 3, 2));
    const b = w.spawn(Rect(8, 2, 3, 2));
    w.select(a);
    w.select(b);
    assert(w.groupSelection() != 0);

    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);
    size_t infoRules;
    foreach (ref op; ops[])
        if (op.kind == OpKind.rule && op.slot == Slot.info)
            ++infoRules;
    assert(infoRules >= 4, "a group gets an outline");
}

@("diagram.render.activeToolAccentOnToolbar")
@safe pure nothrow @nogc
unittest
{
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    w.tool = Tool.rect;
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    const btn = toolButton(Tool.rect, Size(80, 24));
    bool found;
    foreach (ref op; ops[])
        if (op.kind == OpKind.fillRect && op.rect == btn
            && op.slot == Slot.chromeAccent)
            found = true;
    assert(found, "the active tool chip is accented");
}

@("diagram.render.connectorsUseBoxDrawingNotLine")
@safe pure nothrow @nogc
unittest
{
    // `RND3`: edges are orthogonal glyph routes — no OpKind.line.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    const a = w.spawn(Rect(0, 0, 4, 2));
    const b = w.spawn(Rect(12, 6, 4, 2));
    assert(w.connect(a, b));
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    size_t lines, boxGlyphs;
    foreach (ref op; ops[])
    {
        if (op.kind == OpKind.line)
            ++lines;
        if (op.kind == OpKind.glyph)
        {
            const g = op.glyph;
            if (g == '─' || g == '│' || g == '╭' || g == '╮' || g == '╰'
                || g == '╯' || g == '▶' || g == '▼' || g == '▲' || g == '◀')
                ++boxGlyphs;
        }
    }
    assert(lines == 0, "connectors never use the line primitive");
    assert(boxGlyphs > 0, "connectors paint box-drawing glyphs");
}

@("diagram.render.menuPaintsWhenOpen")
@safe pure nothrow @nogc
unittest
{
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    w.menuOpen = true;
    w.menuAt = Point(10, 5);
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);
    const panel = menuPanel(w);
    bool found;
    foreach (ref op; ops[])
        if (op.kind == OpKind.fillRect && op.rect == panel && op.slot == Slot.surface)
            found = true;
    assert(found, "open menu paints a surface panel");
}

@("diagram.render.menuLabelIsWholeUtf8Run")
@safe pure nothrow @nogc
unittest
{
    // Regression: "Label…" must not be painted as three garbage glyphs
    // (UTF-8 code units). Owned textRun keeps the ellipsis intact.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Camera cam;
    w.menuOpen = true;
    w.menuAt = Point(10, 5);
    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    bool sawLabel;
    foreach (ref op; ops[])
        if (op.kind == OpKind.textRun && op.text == "Label…")
            sawLabel = true;
    assert(sawLabel, "menu item is one textRun containing U+2026");
}

@("diagram.render.aDenseBackdropNeverStarvesTheChrome")
@safe unittest
{
    import sparkles.ui.components.grid_backdrop : gridPreset, GridPreset;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    // Dotted graph paper emits one glyph per lattice INTERSECTION, so on a
    // large surface the backdrop alone runs to thousands of ops — where a
    // line lattice is one rule per row and column. The frame ceiling used to
    // be checked by every emitter against the whole buffer, so the backdrop
    // spent it and the toolbar, the status row and the minimap then emitted
    // NOTHING: a board with no chrome at all, which is what a reader saw the
    // moment they switched minor marks to dots.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    w.settings.grid = gridPreset(GridPreset.dotPaper);
    w.settings.grid.minorLattice.interval = 1;
    cast(void) w.spawn(Rect(2, 2, 8, 4));
    cast(void) w.spawn(Rect(20, 10, 6, 3));
    Camera cam;
    const pal = defaultTwoslashPalette(ColorScheme.dark);
    const viewport = Size(140, 48); // 6,720 board cells: past any sane ceiling

    auto opsOwner = makeUnique!FrameOps();
    ref FrameOps ops() => opsOwner.get();
    systemRender(w, cam, viewport, pal, RgbColor(0xcd, 0xd6, 0xf4),
        RgbColor(0x1e, 0x1e, 0x2e), ops);

    // The toolbar's tool buttons and the status row are the chrome that must
    // survive: they are O(1), and they are the only way to see the board's
    // state at all.
    // The board is clipped to `boardArea`, so an op on the toolbar row or the
    // status row can only have come from the chrome — no need to identify it
    // by content. The minimap IS inside the board, so that one is matched by
    // its exact panel rect instead of by overlap, which the backdrop's own
    // ops would otherwise satisfy.
    const toolbar = toolbarArea(viewport);
    const status = Rect(0, viewport.height - statusRows, viewport.width, statusRows);
    const mini = minimapPanel(viewport);
    bool sawToolbar, sawStatus, sawMinimap;
    size_t dots;
    foreach (ref op; ops[])
    {
        if (toolbar.contains(op.rect.origin))
            sawToolbar = true;
        if (status.contains(op.rect.origin))
            sawStatus = true;
        if (!mini.empty && op.kind == OpKind.fillRect && op.rect == mini)
            sawMinimap = true;
        if (op.kind == OpKind.glyph)
            ++dots;
    }
    assert(sawToolbar, "the toolbar survived a dense backdrop");
    assert(sawStatus, "…and so did the status row");
    assert(sawMinimap, "…and the minimap");
    // …and the backdrop the reader actually asked for is still THERE, at the
    // density they asked for. Reserving the chrome is only half the fix: the
    // first attempt kept the chrome by dropping the dense minor layer, which
    // means it kept the chrome by deleting the very feature that revealed the
    // bug — and a `sawDots` flag was happy, because the sparse MAJOR layer
    // still drew. So count them. A minor lattice at interval 1 is one mark
    // per board cell; anything near the major layer's own count (a sixteenth
    // of that) means the minor layer was dropped.
    const boardCells = cast(size_t)(viewport.width
        * (viewport.height - toolbarRows - statusRows));
    assert(dots > boardCells / 2,
        "the dots are drawn at full density, not sacrificed to make room");
}
