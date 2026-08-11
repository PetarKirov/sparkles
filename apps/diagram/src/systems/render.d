/**
The render systems (`RND1`–`RND2`, `RND4`–`RND5`, `DIA5`): free functions that
turn a $(MREF world) + $(MREF camera) into a flat $(REF DrawOp, sparkles,ui,canvas)
stream.

Three streams, one buffer, append order is z-order (`RND1`):

$(LIST
    * $(B board) — grid, culled nodes, group outlines, marquee/create previews
    * $(B minimap) — every live entity (no cull — `RND2`) and the camera frustum
    * $(B chrome) — toolbar and status
)

Colours are slots resolved against the frame's palette (`RND5`); the page fill
is the host's, not ours. The steady-state path is `@safe pure nothrow @nogc`
(`DIA5`): columns and the op buffer are fixed, labels are borrowed, and a
unittest compiles the whole frame under the attribute.

Connectors (`RND3`) land with Series 2 — this module draws nodes and chrome.
*/
module systems.render;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.base.text.writers : writeInteger;
import sparkles.ui.canvas : DrawOp, OpKind, RuleEdge;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.style : ColorScheme, defaultTwoslashPalette, Palette,
    resolveSlot, Slot, Visual;

import camera : Camera, contentBounds, minimapDivisor, minimapFrustum,
    worldToMinimap;
import systems.input : boardArea, minimapPanel, statusRows, toolButton,
    toolbarArea, toolbarRows;
import world : Capture, Entity, GroupId, liveBounds, noEntity, Tool, World,
    entityCap;

/// Inline capacity of the frame's op buffer. A few thousand ops covers a dense
/// board at terminal size without spilling to the heap; the `@nogc` frame
/// path asserts it stays under.
enum size_t frameOpCap = 4096;

/// The frame buffer type — one reuse per component (`RND1`, `DIA5`).
alias FrameOps = SmallBuffer!(DrawOp, frameOpCap);

/**
Emits the whole frame into `ops`: board, then minimap, then chrome.

`ops` is cleared first so a retained buffer from the previous frame never
leaks. Colours come from `pal` + the page pair — the app names slots only.
*/
void systemRender(ref const World w, ref const Camera cam, in Size viewport,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    ops.length = 0;
    const board = boardArea(viewport);
    if (!board.empty)
    {
        renderBoard(w, cam, board, pal, pageFg, pageBg, ops);
        if (w.minimapVisible)
            renderMinimap(w, cam, viewport, board, pal, pageFg, pageBg, ops);
    }
    renderChrome(w, cam, viewport, pal, pageFg, pageBg, ops);
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

    renderGrid(cam, board, vis, pal, pageFg, pageBg, ops);

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

    foreach (e; order[0 .. n])
    {
        const r = worldRectToSurface(cam, w.bounds[e], board);
        if (r.empty)
            continue;
        // Selection tint under the body so the border still reads.
        if (w.selected(e))
            fill(ops, r, Slot.selection, withBg(selectVis, true));
        fill(ops, r, Slot.surface, withBg(surfaceVis, true));
        outline(ops, r, w.selected(e) ? Slot.chromeAccent : Slot.border,
            w.selected(e) ? accentVis : borderVis);
        // Labels: one glyph per cell. A `textRun` would borrow a slice of the
        // world's fixed slot, and dip1000 refuses to park that slice in the
        // op buffer from a `scope` method — glyphs carry the code point by
        // value and keep the frame `@safe`.
        if (w.labelLen[e] > 0 && r.height >= 1 && r.width >= 1)
        {
            const take = w.labelLen[e] < cast(ubyte) r.width
                ? w.labelLen[e] : cast(ubyte) r.width;
            foreach (i; 0 .. take)
                glyphAt(ops, Point(r.x + cast(int) i, r.y), w.label[e][i],
                    Slot.code, codeVis);
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
}

/// Zoom-aware faint grid (`RND4`). Step is one screen-cell of world, so the
/// lattice thins as the user zooms out and densifies only as far as a cell
/// can express when zoomed in. A major line every 8 minor steps gives a
/// coarser structure without a second density table.
private void renderGrid(ref const Camera cam, in Rect board, in Rect vis,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, ref FrameOps ops)
    @safe pure nothrow @nogc
{
    const muted = resolveSlot(pal, Slot.muted, pageFg, pageBg);
    const border = resolveSlot(pal, Slot.border, pageFg, pageBg);
    const step = cam.worldPerCell; // one screen cell of world
    const majorEvery = 8;

    // Align the first line to a multiple of `step` at or before vis.origin.
    int x0 = floorMultiple(vis.x, step);
    int y0 = floorMultiple(vis.y, step);

    // Verticals.
    int col = 0;
    for (int wx = x0; wx < vis.right; wx += step, ++col)
    {
        const sx = board.x + cam.worldToScreen(Point(wx, vis.y)).x;
        if (sx < board.x || sx >= board.right)
            continue;
        const major = col % majorEvery == 0
            || floorMultiple(wx, step * majorEvery) == wx;
        ruleV(ops, sx, board.y, board.height, major ? Slot.border : Slot.muted,
            major ? border : muted);
    }
    // Horizontals.
    int row = 0;
    for (int wy = y0; wy < vis.bottom; wy += step, ++row)
    {
        const sy = board.y + cam.worldToScreen(Point(vis.x, wy)).y;
        if (sy < board.y || sy >= board.bottom)
            continue;
        const major = row % majorEvery == 0
            || floorMultiple(wy, step * majorEvery) == wy;
        ruleH(ops, board.x, sy, board.width, major ? Slot.border : Slot.muted,
            major ? border : muted);
    }
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

        // Copy into a slot that outlives the local: DrawOp borrows. The
        // caller (paint) must keep `statusScratch` on the component. We emit
        // a glyph-only status when we cannot borrow — but DiagramApp passes
        // a persistent scratch via the overload below. Here we only emit
        // when the buffer is the ops' own concern: use per-cell glyphs for
        // the status so no borrow escapes.
        //
        // Prefer text when the host will paint in the same stack frame. The
        // component copies `buf` into its scratch before paint; for pure
        // tests that only inspect ops, text pointing at a dead stack is
        // fine as long as they read before return — they do not. So emit
        // glyphs for the status string, one cell each.
        foreach (i; 0 .. n)
        {
            if (cast(int) i >= status.width)
                break;
            glyphAt(ops, Point(status.x + cast(int) i, status.y), buf[i],
                Slot.muted, muted);
        }
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

private int floorMultiple(int v, int step) @safe pure nothrow @nogc
{
    if (step <= 0)
        return v;
    // Toward -∞, matching the camera.
    const q = v / step;
    const r = v % step;
    if (r != 0 && ((v < 0) != (step < 0)))
        return (q - 1) * step;
    return q * step;
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
    ops ~= DrawOp(kind: OpKind.fillRect, rect: r, slot: slot, visual: vis);
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
    ops ~= DrawOp(kind: OpKind.rule, rect: r, ruleEdge: edge, slot: slot,
        visual: vis);
}

private void ruleV(ref FrameOps ops, int x, int y, int h, Slot slot, in Visual vis)
    @safe pure nothrow @nogc
{
    if (h <= 0 || ops.length >= frameOpCap)
        return;
    ops ~= DrawOp(kind: OpKind.rule, rect: Rect(x, y, 1, h),
        ruleEdge: RuleEdge.left, slot: slot, visual: vis);
}

private void ruleH(ref FrameOps ops, int x, int y, int w, Slot slot, in Visual vis)
    @safe pure nothrow @nogc
{
    if (w <= 0 || ops.length >= frameOpCap)
        return;
    ops ~= DrawOp(kind: OpKind.rule, rect: Rect(x, y, w, 1),
        ruleEdge: RuleEdge.top, slot: slot, visual: vis);
}

/// `text` is borrowed into the op — the caller must keep it alive for the
/// frame (entity labels live in the world's fixed slots; that is enough).
private void glyphAt(ref FrameOps ops, in Point at, dchar g, Slot slot,
    in Visual vis) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops ~= DrawOp(kind: OpKind.glyph, rect: Rect(at.x, at.y, 1, 1),
        glyph: g, slot: slot, visual: vis);
}

private void pushClip(ref FrameOps ops, in Rect r) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops ~= DrawOp(kind: OpKind.pushClip, rect: r);
}

private void popClip(ref FrameOps ops) @safe pure nothrow @nogc
{
    if (ops.length >= frameOpCap)
        return;
    ops ~= DrawOp(kind: OpKind.popClip);
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
    World w;
    Camera cam;
    FrameOps ops;
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
    World w;
    Camera cam;
    // Camera at origin looking at a small viewport-worth of world.
    cam.origin = Point(0, 0);
    cam.zoom = 0;
    const near = w.spawn(Rect(2, 2, 3, 2));
    const far = w.spawn(Rect(500, 500, 3, 2));
    w.setLabel(near, "near");
    w.setLabel(far, "far");

    FrameOps ops;
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    // Board paints labels as glyphs; minimap paints only fills. "near" is
    // on-camera so its 'n' glyph appears on the board; "far" does not.
    size_t nearGlyphs, farGlyphs, entityFills;
    const panel = minimapPanel(Size(80, 24));
    const board = boardArea(Size(80, 24));
    foreach (ref op; ops[])
    {
        if (op.kind == OpKind.glyph && op.slot == Slot.code
            && board.contains(op.rect.origin))
        {
            if (op.glyph == 'n')
                ++nearGlyphs;
            if (op.glyph == 'f')
                ++farGlyphs;
        }
        if (op.kind == OpKind.fillRect && !panel.empty
            && panel.contains(op.rect.origin)
            && op.slot == Slot.code)
        {
            // Minimap entity fills use Slot.code.
            ++entityFills;
        }
    }
    assert(nearGlyphs >= 1, "on-camera node is labelled on the board");
    assert(farGlyphs == 0, "off-camera node emits no board glyphs");
    // Minimap shows both entities as fills (near + far ≥ 2).
    assert(entityFills >= 2, "minimap paints every live entity");
}

@("diagram.render.streamsAreBoardThenMinimapThenChrome")
@safe pure nothrow @nogc
unittest
{
    // `RND1`: z-order is append order. A chrome fill (toolbar y=0) must not
    // appear before the board's pushClip, and the minimap panel fill sits
    // between board content and the status row.
    World w;
    Camera cam;
    cast(void) w.spawn(Rect(1, 1, 2, 2));
    FrameOps ops;
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
    World w;
    Camera cam;
    cast(void) w.spawn(Rect(0, 0, 4, 2));
    w.selectOnly(0);
    FrameOps ops;
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
    World w;
    Camera cam;
    FrameOps ops;
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
    World w;
    Camera cam;
    const a = w.spawn(Rect(2, 2, 3, 2));
    const b = w.spawn(Rect(8, 2, 3, 2));
    w.select(a);
    w.select(b);
    assert(w.groupSelection() != 0);

    FrameOps ops;
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
    World w;
    Camera cam;
    w.tool = Tool.rect;
    FrameOps ops;
    systemRender(w, cam, Size(80, 24), testPal(), fg, bg, ops);

    const btn = toolButton(Tool.rect, Size(80, 24));
    bool found;
    foreach (ref op; ops[])
        if (op.kind == OpKind.fillRect && op.rect == btn
            && op.slot == Slot.chromeAccent)
            found = true;
    assert(found, "the active tool chip is accented");
}
