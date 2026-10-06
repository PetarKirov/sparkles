/**
The CRT monitor, as an effect behind the `sparkles:ui-raylib` seam (`UIA7`,
`EFX21`).

Barrel curvature fitted to the screen, a mouse-directed tilt and magnifier,
scanlines and a roll bar, an RGB phosphor mask, chromatic aberration, bloom
and a vignette, plus reactions to the UI's structure (`EFX23`) — written once
for desktop GLSL 330 and Android ES 100, and run by the effect backend as a
four-pass tier-2 effect on the frame's root bracket.
*/
module sparkles.ui_raylib.crt;

import raylib;
import sparkles.base.term_control : PointerShape;
import sparkles.input.gesture : PointF;
public import sparkles.ui_raylib.crt_projection : CrtProjection, toShaderBox, UiRect;
import std.algorithm : map;
import std.array : array;

import sparkles.ui.canvas : DrawOp, OpKind, RuleEdge;
import sparkles.ui.effect : Degradation, EffectId, EffectParam, EffectRecord,
    EffectRegistry;
import sparkles.ui.frame_list : firstOfSlot, focusedExtent, FrameList,
    scrollbarThumbOf, textAt;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.state : ThumbGeometry;
import sparkles.ui.style : Slot;


/// UI structure context passed to the CRT shader to drive localized phosphor reactions.
struct CrtUiContext
{
    UiRect focusBox;
    UiRect hoverBox;
    UiRect selectBox;
    UiRect splitDivider;
    UiRect scrollbarThumb;
}

/**
The context, $(B harvested from what the frame emitted) (`EFX23`) — never
re-derived by the application.

Every rect comes out of `frame`, the one op stream the frame painted, by the
slot the paint site already gave it:

$(UL
    $(LI `focusBox` — the last focused group's painted extent: a modal over
        the panes, else the focused pane.)
    $(LI `selectBox` — the first `Slot.selection` operation inside the focused
        extent, else anywhere: the tree's selected row, or a text selection's
        first line.)
    $(LI `splitDivider` — the first `Slot.border` rule, as a 4 px band around
        the hairline it draws.)
    $(LI `hoverBox` — the topmost text run under `pointerCell`: what the
        pointer is over, as drawn.)
    $(LI `scrollbarThumb` — the thumb of the first `Slot.thumb` scrollbar,
        from the extents the operation carries, through the same formula the
        bar is painted with.)
)

What a frame did not emit stays empty, and the shader skips an empty rect.
*/
CrtUiContext crtUiContextOf(in FrameList frame, in Point pointerCell,
    int cellW, int cellH) @safe pure nothrow @nogc
{
    static UiRect px(in Rect r, int cw, int ch)
        => UiRect(cast(float)(r.x * cw), cast(float)(r.y * ch),
            cast(float)(r.width * cw), cast(float)(r.height * ch));

    CrtUiContext c;
    const ops = frame.ops;

    Rect focus;
    if (focusedExtent(frame, focus))
        c.focusBox = px(focus, cellW, cellH);

    Rect sel;
    if (firstOfSlot(ops, Slot.selection, sel, focus)
        || firstOfSlot(ops, Slot.selection, sel))
        c.selectBox = px(sel, cellW, cellH);

    foreach (ref const op; ops)
        if (op.kind == OpKind.rule && op.slot == Slot.border)
        {
            const r = op.rect;
            // A vertical divider's hairline is centred in its cell column.
            const cx = r.x * cellW + cellW / 2;
            c.splitDivider = UiRect(cast(float)(cx - 2), cast(float)(r.y * cellH),
                4.0f, cast(float)(r.height * cellH));
            break;
        }

    Rect hover;
    if (textAt(ops, pointerCell, hover))
        c.hoverBox = px(hover, cellW, cellH);

    Rect track;
    ThumbGeometry thumb;
    if (scrollbarThumbOf(ops, Slot.thumb, cellH, cellH, track, thumb))
        c.scrollbarThumb = UiRect(cast(float)(track.x * cellW),
            cast(float)(track.y * cellH + thumb.start),
            cast(float) cellW, cast(float) thumb.extent);
    return c;
}

@("uiRaylib.crt.uiContextIsHarvestedFromTheFrame")
@safe nothrow unittest
{
    import sparkles.ui.canvas : fillRectOp, RecordingCanvas, ruleOp, Scrollbar,
        textRunOp;

    // A tree pane and a focused document pane, a divider between them, a
    // scrolled document bar — emitted the way a paint site does.
    RecordingCanvas c;
    FrameList f;
    f.beginGroup(focused: false);
    f.emit(c, fillRectOp(Rect(0, 3, 20, 1), Slot.selection)); // tree's row
    f.emit(c, textRunOp(Rect(1, 5, 8, 1), "apps.d"));
    f.endGroup();
    f.emit(c, ruleOp(Rect(20, 0, 1, 30), RuleEdge.centerX, Slot.border));
    f.beginGroup(focused: true);
    f.emit(c, fillRectOp(Rect(21, 1, 59, 29)));
    f.emit(c, fillRectOp(Rect(30, 8, 12, 1), Slot.selection)); // text selection
    f.emit(c, DrawOp(Scrollbar(rect: Rect(79, 1, 1, 29), content: 290,
        viewport: 29, offset: 0, edge: RuleEdge.right, slot: Slot.thumb)));
    f.endGroup();

    const ctx = crtUiContextOf(f, Point(3, 5), 10, 20);
    assert(ctx.focusBox == UiRect(210, 20, 590, 580), "the focused pane, as painted");
    assert(ctx.selectBox == UiRect(300, 160, 120, 20),
        "the selection inside the focused pane wins over the tree's");
    assert(ctx.splitDivider == UiRect(203, 0, 4, 600), "centred on the hairline");
    assert(ctx.hoverBox == UiRect(10, 100, 80, 20), "the text under the pointer");
    // 29 rows of 20 px, a tenth visible, at the top: 58 px from the top.
    assert(ctx.scrollbarThumb == UiRect(790, 20, 10, 58));

    // Nothing emitted, nothing harvested.
    FrameList empty;
    const none = crtUiContextOf(empty, Point(0, 0), 10, 20);
    assert(none.focusBox.empty && none.hoverBox.empty && none.scrollbarThumb.empty);
}

/// Every value the CRT's passes read, in the order `writeParams` sets them.
private static immutable string[] crtParamNames = [
    "mouse", "mouseTilt", "mouseMagnify", "cursorShape", "uCurvature",
    "uScanlines", "uMask", "uChromaAberration", "uVignette", "uFlicker",
    "uBrightness", "uLensRadius", "uLensPower", "uBloomIntensity",
    "uBloomThreshold", "uBloomRadius", "uUiReactive", "uFocusHalo",
    "uHoverGlow", "uSelectionBloom", "uDividerTension", "uFocusRect",
    "uHoverRect", "uSelectRect", "uSplitDivider", "uScrollbarThumb",
];

// The shader's cursor code (`CRT6`): which sprite `renderCursor` draws.
private float cursorShapeCode(PointerShape s) @safe pure nothrow @nogc
{
    switch (s) with (PointerShape)
    {
        case text:     return 1.0f;
        case pointer:  return 2.0f;
        case ewResize: return 3.0f;
        default:       return 0.0f;
    }
}

/**
The CRT's parameters — the tube's shape, its knobs and the pointer — and the
effect it is drawn as.

It owns no GPU object. The CRT is a tier-2 effect ($(LREF effectRecord)): an
application registers it, brackets the root of its frame with the id, and
calls $(LREF writeParams) each frame; the effect backend runs the passes like
any other effect's (`EFX21`). What stays here is what the CPU needs too — the
projection that maps a pointer through the curved glass for input
(`PTR2`) — and the values the shader reads.
*/
struct CrtEffect
{
    private CrtProjection proj_;
    private PointerShape shape_ = PointerShape.default_;
    private bool systemPointer_;

    private float scanlines_ = 0.12f;
    private float mask_ = 1.0f;
    private float chromaticAberration_ = 0.0025f;
    private float vignette_ = 0.12f;
    private float flicker_ = 0.007f;
    private float brightness_ = 1.05f;
    private float bloomIntensity_ = 0.35f;
    private float bloomThreshold_ = 0.65f;
    private float bloomRadius_ = 2.0f;

    private bool uiReactive_ = true;
    private float focusHalo_ = 1.0f;
    private float hoverGlow_ = 1.0f;
    private float selectionBloom_ = 1.0f;
    private float dividerTension_ = 1.0f;
    private CrtUiContext uiContext_;

    @disable this(this);

    /// Whether the CRT effect is active.
    bool enabled() const @safe pure nothrow @nogc => proj_.enabled;

    /// ditto
    void enabled(bool on) @safe pure nothrow @nogc { proj_.enabled = on; }

    /// Toggles the CRT effect on or off.
    void toggle() @safe pure nothrow @nogc { proj_.enabled = !proj_.enabled; }

    /// Whether mouse-directed 3D asteroid curvature tilt is enabled.
    bool tilt() const @safe pure nothrow @nogc => proj_.tilt;

    /// ditto
    void tilt(bool on) @safe pure nothrow @nogc { proj_.tilt = on; }

    /// Whether mouse magnification lens distortion is enabled.
    bool magnify() const @safe pure nothrow @nogc => proj_.magnify;

    /// ditto
    void magnify(bool on) @safe pure nothrow @nogc { proj_.magnify = on; }

    /// The active pointer shape rendered by the CRT shader.
    PointerShape pointerShape() const @safe pure nothrow @nogc => shape_;

    /// ditto
    void pointerShape(PointerShape s) @safe pure nothrow @nogc { shape_ = s; }

    /**
    Whether the window system's own pointer is left visible instead of being
    hidden in favour of the in-shader cursor (`PTR1`).

    Set, `begin` stops hiding the compositor cursor and `end` stops drawing the
    software one, so the pointer is a flat sprite $(B on) the glass rather than
    one drawn inside the tube. The host is then responsible for translating
    input out of screen space — see $(LREF mapPointerToUi).
    */
    bool systemPointer() const @safe pure nothrow @nogc => systemPointer_;

    /**
    Whether this pass renders a pointer itself, and so wants the window system
    to stop drawing one (`PTR1`).

    A $(B declaration), not an action. Whether a cursor is on screen is the
    window's state, and a pass that is disabled, reconfigured or destroyed
    between frames should not have to remember to hand it back — so the host
    reads this and calls $(REF Window.pointerVisible, sparkles,ui_raylib,window).
    */
    bool drawsOwnPointer() const @safe pure nothrow @nogc
        => proj_.enabled && !systemPointer_;


    /// ditto
    void systemPointer(bool on) @safe pure nothrow @nogc { systemPointer_ = on; }

    /// Screen curvature amount (0 for flat monitor).
    float curvature() const @safe pure nothrow @nogc => proj_.curvature;

    /// ditto
    void curvature(float v) @safe pure nothrow @nogc { proj_.curvature = v; }

    /// Scanline darkening intensity (0 to disable).
    float scanlines() const @safe pure nothrow @nogc => scanlines_;

    /// ditto
    void scanlines(float v) @safe pure nothrow @nogc { scanlines_ = v; }

    /// RGB phosphor triad mask intensity (0 to 1).
    float mask() const @safe pure nothrow @nogc => mask_;

    /// ditto
    void mask(float v) @safe pure nothrow @nogc { mask_ = v; }

    /// Chromatic aberration color fringing.
    float chromaticAberration() const @safe pure nothrow @nogc => chromaticAberration_;

    /// ditto
    void chromaticAberration(float v) @safe pure nothrow @nogc { chromaticAberration_ = v; }

    /// Vignette edge and corner darkening.
    float vignette() const @safe pure nothrow @nogc => vignette_;

    /// ditto
    void vignette(float v) @safe pure nothrow @nogc { vignette_ = v; }

    /// Phosphor decay flicker and roll bar intensity.
    float flicker() const @safe pure nothrow @nogc => flicker_;

    /// ditto
    void flicker(float v) @safe pure nothrow @nogc { flicker_ = v; }

    /// Gamma brightness boost factor.
    float brightness() const @safe pure nothrow @nogc => brightness_;

    /// ditto
    void brightness(float v) @safe pure nothrow @nogc { brightness_ = v; }

    /// Mouse magnification lens radius.
    float lensRadius() const @safe pure nothrow @nogc => proj_.lensRadius;

    /// ditto
    void lensRadius(float v) @safe pure nothrow @nogc { proj_.lensRadius = v; }

    /// Mouse magnification zoom power factor.
    float lensPower() const @safe pure nothrow @nogc => proj_.lensPower;

    /// ditto
    void lensPower(float v) @safe pure nothrow @nogc { proj_.lensPower = v; }

    /// Bloom strength: how much of the blurred bright pass is added back
    /// (`CRT3`). Zero disables the passes entirely, not merely their result.
    float bloomIntensity() const @safe pure nothrow @nogc => bloomIntensity_;

    /// ditto
    void bloomIntensity(float v) @safe pure nothrow @nogc { bloomIntensity_ = v; }

    /// Luminance above which a pixel blooms.
    float bloomThreshold() const @safe pure nothrow @nogc => bloomThreshold_;

    /// ditto
    void bloomThreshold(float v) @safe pure nothrow @nogc { bloomThreshold_ = v; }

    /// Gaussian tap spacing, in half-resolution texels.
    float bloomRadius() const @safe pure nothrow @nogc => bloomRadius_;

    /// ditto
    void bloomRadius(float v) @safe pure nothrow @nogc { bloomRadius_ = v; }

    /// Whether CRT reacts to UI structure (focus, hover, selection, dividers).
    bool uiReactive() const @safe pure nothrow @nogc => uiReactive_;

    /// ditto
    void uiReactive(bool on) @safe pure nothrow @nogc { uiReactive_ = on; }

    /// Intensity of focused container cathode border halo.
    float focusHalo() const @safe pure nothrow @nogc => focusHalo_;

    /// ditto
    void focusHalo(float v) @safe pure nothrow @nogc { focusHalo_ = v; }

    /// Intensity of interactive hover phosphor excitation.
    float hoverGlow() const @safe pure nothrow @nogc => hoverGlow_;

    /// ditto
    void hoverGlow(float v) @safe pure nothrow @nogc { hoverGlow_ = v; }

    /// Intensity of selection phosphor bloom and beam overdrive.
    float selectionBloom() const @safe pure nothrow @nogc => selectionBloom_;

    /// ditto
    void selectionBloom(float v) @safe pure nothrow @nogc { selectionBloom_ = v; }

    /// Intensity of dock divider cathode seam and tension.
    float dividerTension() const @safe pure nothrow @nogc => dividerTension_;

    /// ditto
    void dividerTension(float v) @safe pure nothrow @nogc { dividerTension_ = v; }

    /// Sets the active UI structure context for the current frame.
    void setUiContext(in CrtUiContext ctx) @safe pure nothrow @nogc { uiContext_ = ctx; }

    /// ditto
    const(CrtUiContext) uiContext() const @safe pure nothrow @nogc => uiContext_;

    /**
    The pointer position last presented through $(LREF end), in UI pixels —
    the point both the lens and the software cursor are centred on.
    */
    PointF pointerPos() const @safe pure nothrow @nogc => proj_.pointer;

    /// ditto
    void pointerPos(PointF p) @safe pure nothrow @nogc { proj_.pointer = p; }

    /// The geometry alone — the tube's shape, with no GPU in it. Everything
    /// the tube's shader also computes (`sparkles.ui.crt_shaders`) lives there.
    ref const(CrtProjection) projection() const return @safe pure nothrow @nogc
        => proj_;

    /// ditto — the two maps, forwarded so existing call sites are unchanged.
    PointF mapPointerToUi(float screenX, float screenY, int screenW, int screenH)
        const @safe pure nothrow @nogc
        => proj_.mapPointerToUi(screenX, screenY, screenW, screenH);

    /// ditto
    PointF mapScreenToUi(float screenX, float screenY, int screenW, int screenH)
        const @safe pure nothrow @nogc
        => proj_.mapScreenToUi(screenX, screenY, screenW, screenH);

    /**
    The CRT as an effect record (`EFX21`): a tier-2 effect in four passes —
    `bloom`'s bright-pass and two blurs at half size, then the tube itself,
    drawing the bracket (`from: 0`) with the blurred glow as `texture1`.

    Register it once and bracket the ROOT of the frame with the id: the CRT is
    then one more effect in the pipeline, not a pass the application wraps
    around it. The values it reads each frame are $(LREF writeParams)'s.
    */
    static EffectRecord effectRecord() @safe pure nothrow
    {
        import sparkles.ui.effect : bloomPasses, crtTubeGlsl, EffectImpl,
            EffectPass, EffectTier, glslBackend;

        EffectPass[] passes = bloomPasses()[0 .. 3];
        passes ~= EffectPass(crtTubeGlsl, from: 0, inputs: [3]);
        return EffectRecord(
            name: "crt",
            tier: EffectTier.layer,
            // A terminal has no tube: the frame paints as it is.
            degradation: Degradation.unaffected,
            impls: [EffectImpl(glslBackend, passes: passes)],
            params: crtParamNames.map!(n => EffectParam(n)).array,
        );
    }

    /**
    Writes this frame's values into `id`'s record — every knob, the pointer
    and the UI context — in place, with no allocation (`EffectRegistry.setParam`).

    `mouseX`/`mouseY` are the pointer in UI pixels; the shader wants Y up, as
    it always did. The clock is not here: the host supplies `uTime` to every
    effect, and pins it for a capture (`DBG1`).
    */
    void writeParams(ref EffectRegistry reg, EffectId id, int screenW,
        int screenH, float mouseX, float mouseY) @safe pure nothrow
    {
        proj_.pointer = PointF(mouseX, mouseY);
        void f(string n, float v) { reg.setParam(id, n, [v, 0, 0, 0], 1); }
        void box(string n, in UiRect r)
        {
            reg.setParam(id, n, toShaderBox(r, screenW, screenH), 4);
        }

        reg.setParam(id, "mouse", [mouseX, screenH - mouseY, 0, 0], 2);
        f("mouseTilt", proj_.tilt ? 1 : 0);
        f("mouseMagnify", proj_.magnify ? 1 : 0);
        f("cursorShape", systemPointer_ ? -1.0f : cursorShapeCode(shape_));
        f("uCurvature", proj_.curvature);
        f("uScanlines", scanlines_);
        f("uMask", mask_);
        f("uChromaAberration", chromaticAberration_);
        f("uVignette", vignette_);
        f("uFlicker", flicker_);
        f("uBrightness", brightness_);
        f("uLensRadius", proj_.lensRadius);
        f("uLensPower", proj_.lensPower);
        f("uBloomIntensity", bloomIntensity_);
        f("uBloomThreshold", bloomThreshold_);
        f("uBloomRadius", bloomRadius_);
        f("uUiReactive", uiReactive_ ? 1 : 0);
        f("uFocusHalo", focusHalo_);
        f("uHoverGlow", hoverGlow_);
        f("uSelectionBloom", selectionBloom_);
        f("uDividerTension", dividerTension_);
        box("uFocusRect", uiContext_.focusBox);
        box("uHoverRect", uiContext_.hoverBox);
        box("uSelectRect", uiContext_.selectBox);
        box("uSplitDivider", uiContext_.splitDivider);
        box("uScrollbarThumb", uiContext_.scrollbarThumb);
    }
}

@("ui_raylib.crt.isATier2EffectOnTheRoot")
@safe unittest
{
    import std.algorithm : canFind;
    import sparkles.ui.effect : EffectTier, glslBackend;

    // `EFX21`: the CRT is a record like any other — bloom's three passes,
    // then the tube compositing the bracket with the glow as `texture1`.
    auto rec = CrtEffect.effectRecord();
    assert(rec.tier == EffectTier.layer && !rec.honouredByCells);
    const impl = rec.implFor(glslBackend);
    assert(impl.passes.length == 4);
    assert(impl.passes[0].from == 0 && impl.passes[0].downscale == 2);
    assert(impl.passes[3].from == 0 && impl.passes[3].inputs == [3]);
    // The tube is generated from `shaders/effects.d` (`EFX25`) and reads the clock
    // and the size the backend supplies to every pass.
    assert(impl.passes[3].source.canFind("entry point `crtTube`"));
    assert(impl.passes[3].source.canFind("uTime") && impl.passes[3].source.canFind("uResolution"));
    // Every parameter is read by some pass (the threshold and radius by
    // bloom's, the rest by the tube's) — one no pass declares is a knob that
    // silently does nothing.
    foreach (name; crtParamNames)
    {
        bool read;
        foreach (ref pass; impl.passes)
            read = read || pass.source.canFind(name);
        assert(read, name);
    }

    // `writeParams` updates in place: the list does not grow frame on frame.
    EffectRegistry reg;
    const id = reg.register(rec);
    CrtEffect crt;
    crt.curvature = 0.3f;
    crt.setUiContext(CrtUiContext(focusBox: UiRect(100, 50, 200, 100)));
    crt.writeParams(reg, id, 800, 600, 400, 100);
    const n = reg.lookup(id).params.length;
    crt.writeParams(reg, id, 800, 600, 410, 110);
    assert(reg.lookup(id).params.length == n && n == crtParamNames.length);

    float[4] valueOf(string name)
    {
        foreach (ref p; reg.lookup(id).params)
            if (p.name == name)
                return p.value;
        assert(false, name);
    }
    assert(valueOf("uCurvature")[0] == 0.3f);
    assert(valueOf("mouse")[0 .. 2] == [410.0f, 490.0f], "Y up, as the shader wants");
    assert(valueOf("uFocusRect") == toShaderBox(UiRect(100, 50, 200, 100), 800, 600));
    assert(crt.pointerPos == PointF(410, 110), "the projection sees the pointer too");
}

@("ui_raylib.crt.defaults")
@system
unittest
{
    CrtEffect crt;
    assert(!crt.enabled);
    assert(!crt.tilt);
    assert(!crt.magnify);
    assert(crt.pointerShape == PointerShape.default_);
    crt.enabled = true;
    crt.tilt = true;
    crt.magnify = true;
    crt.pointerShape = PointerShape.text;
    assert(crt.enabled);
    assert(crt.tilt);
    assert(crt.magnify);
    assert(crt.pointerShape == PointerShape.text);
    crt.toggle();
    assert(!crt.enabled);
    assert(crt.tilt);
    assert(crt.magnify);

    // Configurable CRT parameters
    assert(crt.curvature == 0.08f);
    assert(crt.scanlines == 0.12f);
    assert(crt.mask == 1.0f);
    assert(crt.chromaticAberration == 0.0025f);
    assert(crt.vignette == 0.12f);
    assert(crt.flicker == 0.007f);
    assert(crt.brightness == 1.05f);
    assert(crt.lensRadius == 0.18f);
    assert(crt.lensPower == 0.45f);

    crt.curvature = 0.15f;
    crt.scanlines = 0.25f;
    crt.mask = 0.50f;
    crt.chromaticAberration = 0.005f;
    crt.vignette = 0.20f;
    crt.flicker = 0.015f;
    crt.brightness = 1.20f;
    crt.lensRadius = 0.25f;
    crt.lensPower = 0.60f;

    assert(crt.curvature == 0.15f);
    assert(crt.scanlines == 0.25f);
    assert(crt.mask == 0.50f);
    assert(crt.chromaticAberration == 0.005f);
    assert(crt.vignette == 0.20f);
    assert(crt.flicker == 0.015f);
    assert(crt.brightness == 1.20f);
    assert(crt.lensRadius == 0.25f);
    assert(crt.lensPower == 0.60f);

    // mapScreenToUi pass-through when disabled
    auto pt = crt.mapScreenToUi(100, 200, 800, 600);
    assert(pt.x == 100 && pt.y == 200);

    // mapScreenToUi transformation when enabled
    crt.enabled = true;
    crt.tilt = false;
    auto ptCurved = crt.mapScreenToUi(400, 300, 800, 600);
    // Center maps back to center
    assert(ptCurved.x > 395 && ptCurved.x < 405);
    assert(ptCurved.y > 295 && ptCurved.y < 305);

    // UI reactivity defaults & settings
    assert(crt.uiReactive);
    assert(crt.focusHalo == 1.0f);
    assert(crt.hoverGlow == 1.0f);
    assert(crt.selectionBloom == 1.0f);
    assert(crt.dividerTension == 1.0f);

    crt.uiReactive = false;
    crt.focusHalo = 1.5f;
    crt.hoverGlow = 0.8f;
    crt.selectionBloom = 1.2f;
    crt.dividerTension = 0.5f;

    assert(!crt.uiReactive);
    assert(crt.focusHalo == 1.5f);
    assert(crt.hoverGlow == 0.8f);
    assert(crt.selectionBloom == 1.2f);
    assert(crt.dividerTension == 0.5f);

    // UiRect & toShaderBox
    UiRect rEmpty;
    assert(rEmpty.empty);
    auto bEmpty = toShaderBox(rEmpty, 800, 600);
    assert(bEmpty == [0.0f, 0.0f, 0.0f, 0.0f]);

    UiRect r = UiRect(100, 50, 200, 100);
    assert(!r.empty);
    auto b = toShaderBox(r, 800, 600);
    // cx = (100 + 100) / 800 = 0.25, cy = 1.0 - (50 + 50) / 600 = 500/600 ~ 0.8333
    // hw = 100 / 800 = 0.125, hh = 50 / 600 ~ 0.08333
    assert(b[0] == 0.25f);
    assert(b[2] == 0.125f);
    assert(b[1] > 0.83f && b[1] < 0.84f);
    assert(b[3] > 0.08f && b[3] < 0.09f);

    CrtUiContext ctx;
    ctx.focusBox = r;
    crt.setUiContext(ctx);
    assert(crt.uiContext.focusBox == r);
}



@("ui_raylib.crt.systemPointer.suppressesTheShaderCursor")
@system
unittest
{
    CrtEffect crt;
    assert(!crt.systemPointer, "hue draws its own cursor by default");
    crt.systemPointer = true;
    assert(crt.systemPointer);

    // Disabled, the map is the identity in either mode: with no warp on screen
    // the two spaces are the same one.
    crt.pointerShape = PointerShape.text;
    const p = crt.mapPointerToUi(123, 456, 800, 600);
    assert(p.x == 123 && p.y == 456);
}
