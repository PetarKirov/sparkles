/**
The CRT's geometry, with no GPU in it (`CRT8`, `CRT10`, `PTR2`).

Everything about $(I where) a screen pixel reads from — the tube's curvature,
its fit to the screen, the magnifier lens, and the two maps that answer for a
pointer — separated from $(REF CrtEffect, sparkles,ui_raylib,crt), which also
owns GLSL text, a render texture, twenty-five uniform locations and the
compositor cursor.

The split earns its keep twice. It is the whole of what the shader's `curve()`
must agree with, so the correspondence has one address instead of being spread
through a struct that cannot be constructed without a GL context; and it is
`@safe pure nothrow @nogc`, so the maps are testable as arithmetic rather than
through a `@system` wrapper that works by luck of field ordering.

$(B This is one half of a pair.) The other half is the GLSL `curve()` in
$(MREF sparkles,ui_raylib,crt), and nothing the compiler can see enforces that
they agree — see $(LREF CrtProjection.curveStep).
*/
module sparkles.ui_raylib.crt_projection;

import sparkles.input.gesture : PointF;

/**
The tube's shape and the two questions asked of it.

Parameters are plain fields: a projection is a value, copied freely, and every
one of them is something the settings pane can move while the frame runs.
*/
struct CrtProjection
{
    /// Whether the warp applies at all. Off, both maps are the identity.
    bool enabled;

    /// Bend the apex toward the pointer rather than the screen's middle.
    bool tilt;

    /// Apply the magnifier lens.
    bool magnify;

    /// Barrel amount; `0` is a flat screen and a 1:1 blit.
    float curvature = 0.08f;

    /// Lens radius, as a fraction of the screen's shorter axis.
    float lensRadius = 0.18f;

    /// Lens zoom power.
    float lensPower = 0.45f;

    /// The pointer, in UI pixels: the apex the tilt bends around and the point
    /// the lens is centred on. Both distortions are defined relative to it,
    /// which is what makes $(LREF mapPointerToUi) self-referential.
    PointF pointer;

    /**
    The curvature step alone, in normalized y-flipped coordinates.

    $(B The twin of the shader's `curve()`), and the reason that function and
    this one must be read together: one runs on the GPU and one on the CPU, so
    no compiler, linker or test can see that they agree. Two bugs of exactly
    that shape are in this file's history — a lens applied in the wrong space,
    and a screen fit hardcoded to one curvature — and both were found by eye.

    `mx`/`my` are the apex the tilt bends around, ignored when tilt is off.
    */
    void curveStep(float nx, float ny, float mx, float my,
        out float uvX, out float uvY) const @safe pure nothrow @nogc
    {
        const apexX = tilt ? mx : 0.5f;
        const apexY = tilt ? my : 0.5f;
        const k = tilt ? curvature * 0.625f : curvature;
        const ccX = nx - apexX;
        const ccY = ny - apexY;
        const dist = ccX * ccX + ccY * ccY;
        // `CRT10`: seat the texture's edge midpoints on the screen's edges. The
        // bend pushes a point at radius r out by (1 + k*r*r), so an edge
        // midpoint — at r = 1/2 — lands at (1 + k/4); the reciprocal puts it
        // back. Exact for a centred apex, which is the model it is stated for.
        const fit = 1.0f / (1.0f + k * 0.25f);
        uvX = (nx + ccX * (dist * k) - 0.5f) * fit + 0.5f;
        uvY = (ny + ccY * (dist * k) - 0.5f) * fit + 0.5f;
    }

    /**
    The UI point the $(B OS pointer) at a screen position is sitting on — what
    `appearance.pointer.mode = system` routes input through (`PTR2`).

    Magnification is deliberately $(B not) applied. The lens is centred on the
    pointer's own UI position and leaves that point fixed, so for the pointer
    itself the lens cancels exactly; running it here would instead measure the
    displacement from the $(I previous) frame's centre. Tilt does not cancel —
    its apex is that same position — so it is resolved by iterating the map to
    its fixed point, which converges in a couple of steps at any curvature the
    settings allow.
    */
    PointF mapPointerToUi(float screenX, float screenY, int screenW, int screenH)
        const @safe pure nothrow @nogc
    {
        if (!enabled || screenW <= 0 || screenH <= 0)
            return PointF(screenX, screenY);

        const nx = screenX / cast(float) screenW;
        const ny = (cast(float) screenH - screenY) / cast(float) screenH;

        const mx = pointer.x / cast(float) screenW;
        const my = (cast(float) screenH - pointer.y) / cast(float) screenH;

        float uvX, uvY;
        curveStep(nx, ny, mx, my, uvX, uvY);
        if (tilt)
            foreach (_; 0 .. 3)
                curveStep(nx, ny, uvX, uvY, uvX, uvY);

        return PointF(uvX * cast(float) screenW, (1.0f - uvY) * cast(float) screenH);
    }

    /**
    The UI point $(B displayed) at a screen pixel — the whole pipeline, lens
    included.

    A different question from $(LREF mapPointerToUi), which is why both exist:
    this one asks what the viewer sees at a pixel, so the magnifier counts;
    that one asks what the pointer is over, where the magnifier cancels.
    */
    PointF mapScreenToUi(float screenX, float screenY, int screenW, int screenH)
        const @safe pure nothrow @nogc
    {
        if (!enabled || screenW <= 0 || screenH <= 0)
            return PointF(screenX, screenY);

        const nx = screenX / cast(float) screenW;
        const ny = (cast(float) screenH - screenY) / cast(float) screenH;

        const mx = pointer.x / cast(float) screenW;
        const my = (cast(float) screenH - pointer.y) / cast(float) screenH;

        const aspect = cast(float) screenW / cast(float) screenH;

        float uvX, uvY;
        curveStep(nx, ny, mx, my, uvX, uvY);

        // The lens in TEXTURE space, after curvature — the same order the
        // shader applies it in, so this stays its exact inverse-free twin.
        // Applying it before curvature made the two disagree (`CRT8`).
        if (magnify)
        {
            import std.math : sqrt, pow;

            const dx = (uvX - mx) * aspect;
            const dy = uvY - my;
            const dist = cast(float) sqrt(dx * dx + dy * dy);
            if (dist < lensRadius)
            {
                const normDist = dist / lensRadius;
                const z = cast(float) sqrt(1.0f - normDist * normDist);
                const factor = 1.0f - lensPower * cast(float) pow(z, 1.4f);
                uvX = mx + (uvX - mx) * factor;
                uvY = my + (uvY - my) * factor;
            }
        }

        return PointF(uvX * cast(float) screenW, (1.0f - uvY) * cast(float) screenH);
    }
}

/// Axis-aligned rectangle representing a UI element in surface points.
///
/// Not $(REF Rect, sparkles,ui,geometry), deliberately: that one is integer
/// $(B cells) and this is float $(B points), so the two are not
/// interchangeable and silently reusing the name would be worse than having
/// two.
struct UiRect
{
    float x = 0;
    float y = 0;
    float w = 0;
    float h = 0;

    bool empty() const @safe pure nothrow @nogc => w <= 0 || h <= 0;
}

/**
Converts a $(LREF UiRect) in surface points to the shader's `[cx, cy, hw, hh]`
in normalized UV, where `uv.y = 1` is the top of the window.
*/
float[4] toShaderBox(in UiRect r, float screenW, float screenH)
    @safe pure nothrow @nogc
{
    if (r.w <= 0 || r.h <= 0 || screenW <= 0 || screenH <= 0)
        return [0.0f, 0.0f, 0.0f, 0.0f];
    return [
        (r.x + r.w * 0.5f) / screenW,
        1.0f - (r.y + r.h * 0.5f) / screenH,
        (r.w * 0.5f) / screenW,
        (r.h * 0.5f) / screenH,
    ];
}

@("ui_raylib.crt_projection.identityWhenDisabled")
@safe pure nothrow @nogc
unittest
{
    CrtProjection p;
    p.curvature = 0.5f;
    assert(p.mapScreenToUi(123, 456, 800, 600) == PointF(123, 456));
    assert(p.mapPointerToUi(123, 456, 800, 600) == PointF(123, 456));

    // A degenerate screen is the identity too, rather than a division.
    p.enabled = true;
    assert(p.mapScreenToUi(1, 2, 0, 0) == PointF(1, 2));
}

@("ui_raylib.crt_projection.toShaderBox")
@safe pure nothrow @nogc
unittest
{
    assert(UiRect().empty);
    assert(toShaderBox(UiRect(), 800, 600) == [0.0f, 0.0f, 0.0f, 0.0f]);

    const b = toShaderBox(UiRect(100, 50, 200, 100), 800, 600);
    assert(b[0] == 200.0f / 800);          // centre x
    assert(b[1] == 1.0f - 100.0f / 600);   // centre y, flipped
    assert(b[2] == 100.0f / 800);          // half width
    assert(b[3] == 50.0f / 600);           // half height
}
/**
The magnifier lens is centred on the software cursor (`CRT6`).

The shader draws the cursor at the fragment whose $(I final) `uv` equals the
mouse's UI position, and applies the lens to that same `uv` — which leaves that
point fixed. So the screen point that resolves to the mouse must be the one the
lens is built around, whether magnification is on or off.

Applying the lens before curvature instead centred it on the screen point the
mouse had not yet been displaced from, and the pointer drifted out of the circle
the further it travelled from the middle of the screen.
*/
@("ui_raylib.crt_projection.magnifierLensIsCentredOnTheCursor")
@safe pure nothrow @nogc
unittest
{
    import std.math : abs;

    enum int w = 800, h = 600;

    CrtProjection crt;
    crt.enabled = true;
    crt.curvature = 0.25f;  // well past the default, so a drift is visible
    crt.lensRadius = 0.22f;
    crt.lensPower = 0.55f;

    // Off-centre in both axes: the bug is invisible at the screen's middle.
    const mouse = PointF(624, 168);

    static float miss(in PointF got, in PointF want)
    {
        const dx = got.x - want.x, dy = got.y - want.y;
        return abs(dx) > abs(dy) ? abs(dx) : abs(dy);
    }

    foreach (tilt; [false, true])
    {
        crt.tilt = tilt;
        crt.pointer = mouse;

        // Find the screen point that renders the mouse's own UI pixel: a
        // coarse sweep, then a refinement around the best cell.
        crt.magnify = false;
        auto best = PointF(mouse.x, mouse.y);
        float bestMiss = float.max;
        for (float y = 0; y < h; y += 2)
            for (float x = 0; x < w; x += 2)
            {
                const d = miss(crt.mapScreenToUi(x, y, w, h), mouse);
                if (d < bestMiss) { bestMiss = d; best = PointF(x, y); }
            }
        for (float dy = -2; dy <= 2; dy += 0.125f)
            for (float dx = -2; dx <= 2; dx += 0.125f)
            {
                const p = PointF(best.x + dx, best.y + dy);
                const d = miss(crt.mapScreenToUi(p.x, p.y, w, h), mouse);
                if (d < bestMiss) { bestMiss = d; best = p; }
            }
        assert(bestMiss < 0.5f, "no screen point renders the mouse's UI pixel");

        // Curvature really does displace the cursor — otherwise the assertion
        // below would hold for the broken ordering too.
        assert(miss(best, mouse) > 4.0f);

        // Turning the lens on must not move that point: the cursor sits at the
        // centre of the circle.
        crt.magnify = true;
        assert(miss(crt.mapScreenToUi(best.x, best.y, w, h), mouse) < 0.5f);
    }
}

/**
The pointer map is the lens's fixed point and the tilt's (`PTR2`).

`mapPointerToUi` answers "which UI point is the OS pointer sitting on", and both
mouse-driven distortions are centred on that same answer — which is why neither
may be applied to it naively. The lens leaves its own centre alone, so it must
cancel exactly; the tilt's apex is that centre, so the map must be a fixed point
of itself. Testing those two properties is testing that the self-reference was
resolved rather than papered over with the previous frame's value.
*/
@("ui_raylib.crt_projection.mapPointerToUi.resolvesTheDistortionsCentredOnIt")
@safe pure nothrow @nogc
unittest
{
    import std.math : abs;

    enum int w = 1000, h = 720;
    enum PointF probe = PointF(820, 560);

    static float miss(in PointF a, in PointF b)
    {
        const dx = a.x - b.x, dy = a.y - b.y;
        return abs(dx) > abs(dy) ? abs(dx) : abs(dy);
    }

    CrtProjection crt;
    crt.enabled = true;
    crt.curvature = 0.25f;
    crt.lensRadius = 0.30f;
    crt.lensPower = 0.55f;
    crt.pointer = PointF(640, 300);

    // The lens cancels: magnifying does not move the point the pointer is on.
    crt.tilt = false;
    crt.magnify = false;
    const flat = crt.mapPointerToUi(probe.x, probe.y, w, h);
    crt.magnify = true;
    assert(miss(crt.mapPointerToUi(probe.x, probe.y, w, h), flat) < 0.01f);

    // It is a real warp, not a no-op that would satisfy the above vacuously.
    assert(miss(flat, probe) > 4.0f);

    // Tilt bends around the pointer, so the map must reproduce itself when its
    // own answer is fed back as that apex.
    crt.tilt = true;
    const tilted = crt.mapPointerToUi(probe.x, probe.y, w, h);
    crt.pointer = tilted;
    assert(miss(crt.mapPointerToUi(probe.x, probe.y, w, h), tilted) < 0.5f,
        "the tilt apex did not converge");

    // ...and it converges from a badly wrong starting point, too — the apex is
    // seeded with the previous frame's pointer, which after a jump is stale.
    crt.pointer = PointF(10, 700);
    assert(miss(crt.mapPointerToUi(probe.x, probe.y, w, h), tilted) < 1.0f);
}

/**
The tube is fitted to the screen at every curvature (`CRT10`).

The bend pushes a point at radius `r` out by `(1 + k·r²)`, so the midpoint of
each edge — at `r = ½` — lands at `(1 + k/4)`, and scaling by that reciprocal
seats it exactly on the screen edge. The old fixed `1.06` was a fit for one
curvature and no other: it left a 20 px band of nothing along every edge even
on a flat screen, and swallowed a third of the window at the top of the range.

The corners, at a larger radius, still overhang and are cut — that is the
rounded face of the tube, and it should be the only part of the window without
an image.
*/
@("ui_raylib.crt_projection.curve.seatsEachEdgeMidpointOnItsScreenEdge")
@safe pure nothrow @nogc
unittest
{
    import std.math : abs;

    enum int w = 1000, h = 720;

    CrtProjection crt;
    crt.enabled = true;
    crt.tilt = false; // the fit is stated for a centred apex

    foreach (curv; [0.0f, 0.08f, 0.25f, 0.5f, 1.0f])
    {
        crt.curvature = curv;

        // Each screen edge midpoint reads the corresponding texture edge.
        assert(abs(crt.mapScreenToUi(w / 2.0f, 0, w, h).y - 0) < 0.5f);
        assert(abs(crt.mapScreenToUi(w / 2.0f, h, w, h).y - h) < 0.5f);
        assert(abs(crt.mapScreenToUi(0, h / 2.0f, w, h).x - 0) < 0.5f);
        assert(abs(crt.mapScreenToUi(w, h / 2.0f, w, h).x - w) < 0.5f);

        // ...so there is no dead band anywhere along an edge's middle.
        assert(crt.mapScreenToUi(w / 2.0f, 0.5f, w, h).y >= 0);

        // A flat screen is a 1:1 blit: no curvature, and so nothing cut.
        const corner = crt.mapScreenToUi(0, 0, w, h);
        if (curv == 0)
            assert(corner.x >= 0 && corner.y >= 0, "a flat tube fills the window");
        else
            assert(corner.x < 0 || corner.y < 0, "a curved tube rounds its corners");
    }
}
