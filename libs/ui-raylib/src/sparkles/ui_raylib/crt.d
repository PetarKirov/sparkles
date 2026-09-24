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
import sparkles.ui.glsl_dialect : activePrologue;
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

// The prologues moved to `sparkles.ui.glsl_dialect` when a second shader needed
// them: the effect compiler builds fragment shaders the same way, and a
// per-shader copy of the dual-dialect trick is the duplication this file
// already removed once.

/// The CRT shader's uniform block — shared, so a new uniform is declared once.
private enum crtUniforms = q{
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 resolution;
uniform float time;
uniform vec2 mouse;
uniform float mouseTilt;
uniform float mouseMagnify;
uniform float cursorShape;
uniform float uCurvature;
uniform float uScanlines;
uniform float uMask;
uniform float uChromaAberration;
uniform float uVignette;
uniform float uFlicker;
uniform float uBrightness;
uniform float uLensRadius;
uniform float uLensPower;

uniform sampler2D texture1;
uniform float uBloomIntensity;

uniform float uUiReactive;
uniform float uFocusHalo;
uniform float uHoverGlow;
uniform float uSelectionBloom;
uniform float uDividerTension;
uniform vec4 uFocusRect;
uniform vec4 uHoverRect;
uniform vec4 uSelectRect;
uniform vec4 uSplitDivider;
uniform vec4 uScrollbarThumb;

};

/// The CRT shader body, written once for both dialects.
private enum crtShaderBody = q{
float sdBox(vec2 p, vec2 b)
{
    vec2 d = abs(p) - b;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

vec2 curve(vec2 coord, vec2 m, float isTilt, vec2 res)
{
    // The apex the bend is centred on. With tilt it follows the mouse, so the
    // surface is flat directly under the pointer and the far side curves away;
    // with the mouse in a corner that corner straightens out.
    vec2 apex = (isTilt > 0.5) ? m : vec2(0.5);
    float k = (isTilt > 0.5) ? uCurvature * 0.625 : uCurvature;

    vec2 cc = coord - apex;
    float dist = dot(cc, cc);
    vec2 uv = coord + cc * (dist * k);

    // Fit the tube to the screen (`CRT10`). The bend pushes a point at radius r
    // out by (1 + k*r*r), so an edge midpoint — at r = 1/2 — lands at
    // (1 + k/4); scaling by the reciprocal puts it back exactly on the screen
    // edge, at ANY curvature, and leaves a flat screen (k = 0) a 1:1 blit.
    // The corners sit at a larger radius, still overhang, and are cut: that is
    // the rounded tube face, and the only part of the window left imageless.
    //
    // Exact with tilt off, which is the model the fit is stated for. An apex
    // that is not the centre deforms the four edges by different amounts, and
    // one scalar cannot seat all four at once.
    float fit = 1.0 / (1.0 + k * 0.25);
    return (uv - 0.5) * fit + 0.5;
}

vec4 renderCursor(vec2 p, float shape)
{
    if (shape > 0.5 && shape < 1.5)
    {
        // I-beam
        if (abs(p.x) > 5.0 || abs(p.y) > 9.0)
            return vec4(0.0);

        bool stem = (abs(p.x) <= 1.5 && abs(p.y) <= 7.5);
        bool topBar = (abs(p.x) <= 4.0 && p.y >= -8.0 && p.y <= -5.5);
        bool botBar = (abs(p.x) <= 4.0 && p.y >= 5.5 && p.y <= 8.0);

        bool stemFill = (abs(p.x) <= 0.5 && abs(p.y) <= 6.5);
        bool topFill = (abs(p.x) <= 3.0 && p.y >= -7.0 && p.y <= -6.5);
        bool botFill = (abs(p.x) <= 3.0 && p.y >= 6.5 && p.y <= 7.0);

        if (stemFill || topFill || botFill)
            return vec4(1.0, 1.0, 1.0, 1.0);
        if (stem || topBar || botBar)
            return vec4(0.0, 0.0, 0.0, 1.0);
        return vec4(0.0);
    }
    else if (shape > 2.5)
    {
        // EW-resize <->
        if (abs(p.x) > 9.5 || abs(p.y) > 5.5)
            return vec4(0.0);

        bool hLine = (abs(p.y) <= 1.5 && abs(p.x) <= 6.5);
        bool leftArrow = (p.x <= -2.5 && p.x >= -7.5 && abs(p.y) <= (-p.x - 2.5));
        bool rightArrow = (p.x >= 2.5 && p.x <= 7.5 && abs(p.y) <= (p.x - 2.5));

        bool hFill = (abs(p.y) <= 0.5 && abs(p.x) <= 5.5);
        bool lFill = (p.x <= -3.0 && p.x >= -6.5 && abs(p.y) <= (-p.x - 3.5));
        bool rFill = (p.x >= 3.0 && p.x <= 6.5 && abs(p.y) <= (p.x - 3.5));

        if (hFill || lFill || rFill)
            return vec4(1.0, 1.0, 1.0, 1.0);
        if (hLine || leftArrow || rightArrow)
            return vec4(0.0, 0.0, 0.0, 1.0);
        return vec4(0.0);
    }
    else
    {
        // Default Arrow
        if (p.x < -0.5 || p.x > 13.5 || p.y < -0.5 || p.y > 19.5)
            return vec4(0.0);

        bool inHead = (p.x >= 0.0 && p.y >= 0.0 && p.y <= 14.5 && p.x <= p.y && (p.y - p.x * 0.35) <= 12.0);
        bool inStem = (p.x >= 3.0 && p.x <= 7.5 && p.y >= 9.0 && p.y <= 17.5);

        bool inHeadFill = (p.x >= 1.0 && p.y >= 1.5 && p.y <= 13.0 && p.x <= (p.y - 0.5) && (p.y - p.x * 0.35) <= 10.5);
        bool inStemFill = (p.x >= 4.0 && p.x <= 6.5 && p.y >= 10.0 && p.y <= 16.5);

        if (inHeadFill || inStemFill)
            return vec4(1.0, 1.0, 1.0, 1.0);
        if (inHead || inStem)
            return vec4(0.0, 0.0, 0.0, 1.0);

        return vec4(0.0);
    }
}

void main()
{
    vec2 uv = fragTexCoord;
    float lensRim = 0.0;

    vec2 m = mouse / resolution;
    uv = curve(uv, m, mouseTilt, resolution);

    // The lens is applied in TEXTURE space, after curvature, so that its centre
    // is the very point the software cursor is drawn at (`CRT6`): the cursor
    // lands where the final `uv` equals the mouse's UI position, and
    // `uv = m + delta * factor` leaves exactly that point fixed. Centring the
    // lens in screen space instead put it wherever curvature had *not* yet
    // displaced the pointer, so the two drifted apart the further the mouse
    // travelled from the middle of the screen.
    if (mouseMagnify > 0.5)
    {
        float aspect = resolution.x / resolution.y;
        vec2 delta = uv - m;
        vec2 aspectDelta = vec2(delta.x * aspect, delta.y);
        float dist = length(aspectDelta);
        float radius = uLensRadius;

        if (dist < radius)
        {
            float normDist = dist / radius;
            float z = sqrt(max(0.0, 1.0 - normDist * normDist));
            float factor = 1.0 - uLensPower * pow(z, 1.4);
            uv = m + delta * factor;
            lensRim = smoothstep(0.90, 0.97, normDist) * smoothstep(1.0, 0.97, normDist);
        }
    }

    // Subtle horizontal sync micro-jitter
    float jitter = sin(uv.y * 120.0 + time * 30.0) * 0.00025;
    uv.x += jitter;

    // Vector from mouse tip to fragment in texture space (UI pixels).
    // A negative cursorShape means the window system is drawing the pointer
    // itself (`PTR1`) and the shader must not draw a second one.
    vec4 cursorCol = vec4(0.0);
    if (cursorShape >= 0.0 && uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0)
    {
        vec2 uiPixelPos = vec2(uv.x * resolution.x, uv.y * resolution.y);
        vec2 cursorDelta = vec2(uiPixelPos.x - mouse.x, mouse.y - uiPixelPos.y);
        cursorCol = renderCursor(cursorDelta, cursorShape);
    }

    vec3 col = vec3(0.0);
    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0)
    {
        vec2 cornerSmooth = smoothstep(vec2(0.0), vec2(0.012), uv) *
                            smoothstep(vec2(0.0), vec2(0.012), vec2(1.0) - uv);
        float corner = cornerSmooth.x * cornerSmooth.y;

        vec2 cc = uv - 0.5;
        float caStrength = uChromaAberration + (uChromaAberration * 0.2) * sin(time * 3.0);
        if (lensRim > 0.0)
            caStrength += 0.002 * lensRim;

        vec2 ca = cc * caStrength;
        float r = SAMPLE(texture0, uv + ca).r;
        float g = SAMPLE(texture0, uv).g;
        float b = SAMPLE(texture0, uv - ca).b;
        col = vec3(r, g, b);

        col += vec3(0.12) * lensRim;

        // `CRT3`: the separable-blurred bright pass, added back. Sampled at the
        // SAME warped `uv` as the content, so the glow curves with the tube
        // instead of floating flat above it.
        if (uBloomIntensity > 0.0)
            col += SAMPLE(texture1, uv).rgb * uBloomIntensity;

        col *= corner;

        if (uUiReactive > 0.5)
        {
            // 1. Focus Box Cathode Border Halation & Beam Sharpening
            if (uFocusRect.z > 0.0 && uFocusHalo > 0.0)
            {
                vec2 p = (uv - uFocusRect.xy) * resolution;
                vec2 b = uFocusRect.zw * resolution;
                float dist = sdBox(p, b);

                if (dist > -3.0 && dist < 14.0)
                {
                    float pulse = 0.85 + 0.15 * sin(time * 3.5);
                    float halo = exp(-abs(dist) * 0.28) * uFocusHalo * 0.22 * pulse;
                    col += vec3(0.25, 0.55, 0.85) * halo;
                }

                if (dist <= 0.0)
                {
                    col = mix(col, col * 1.03 + vec3(0.01), 0.5);
                }
            }

            // 2. Hover Box Phosphor Excitation
            if (uHoverRect.z > 0.0 && uHoverGlow > 0.0)
            {
                vec2 p = (uv - uHoverRect.xy) * resolution;
                vec2 b = uHoverRect.zw * resolution;
                float dist = sdBox(p, b);

                if (dist <= 10.0)
                {
                    float surge = exp(-max(dist, 0.0) * 0.35) * (dist < 0.0 ? 0.14 : 0.07) * uHoverGlow;
                    col += col * surge + vec3(0.02, 0.03, 0.04) * surge;

                    float edge = exp(-abs(dist) * 0.5) * uHoverGlow * 0.12;
                    col.r += edge * 0.04;
                    col.b += edge * 0.06;
                }
            }

            // 3. Selection Phosphor Overdrive & Horizontal Bloom
            if (uSelectRect.z > 0.0 && uSelectionBloom > 0.0)
            {
                vec2 p = (uv - uSelectRect.xy) * resolution;
                vec2 b = uSelectRect.zw * resolution;
                float dist = sdBox(p, b);

                if (dist <= 0.0)
                {
                    col += col * (0.16 * uSelectionBloom);
                }
                else if (abs(p.y) <= b.y && dist < 10.0)
                {
                    float hBleed = exp(-dist * 0.35) * 0.10 * uSelectionBloom;
                    col += col * hBleed;
                }
            }

            // 4. Dock Split Divider ("Cathode Seam & Tension")
            if (uSplitDivider.z > 0.0 && uDividerTension > 0.0)
            {
                vec2 p = (uv - uSplitDivider.xy) * resolution;
                vec2 b = uSplitDivider.zw * resolution;
                float dist = sdBox(p, b);

                if (abs(dist) < 2.5)
                {
                    float seam = (1.0 - abs(dist) / 2.5) * 0.12 * uDividerTension;
                    col *= (1.0 - seam);
                }
                else if (dist >= 0.0 && dist < 6.0)
                {
                    float halo = exp(-dist * 0.55) * 0.05 * uDividerTension;
                    col += vec3(0.02, 0.04, 0.06) * halo;
                }
            }

            // 5. Scrollbar Thumb Flare
            if (uScrollbarThumb.z > 0.0)
            {
                vec2 p = (uv - uScrollbarThumb.xy) * resolution;
                vec2 b = uScrollbarThumb.zw * resolution;
                float dist = sdBox(p, b);

                if (dist <= 4.0)
                {
                    float flare = exp(-max(dist, 0.0) * 0.6) * 0.08;
                    col += col * flare + vec3(0.03) * flare;
                }
            }
        }
    }

    // Composite shader-rendered cursor
    if (cursorCol.a > 0.0)
        col = mix(col, cursorCol.rgb, cursorCol.a);

    // Scanlines
    float scanline = sin(fragTexCoord.y * resolution.y * 3.14159265);
    col *= (1.0 - uScanlines) + uScanlines * (scanline * scanline);

    // Vertical roll hum bar
    float roll = 0.5 + 0.5 * sin(fragTexCoord.y * 5.0 - time * 2.2);
    col *= (1.0 - uFlicker * 5.7) + (uFlicker * 5.7) * roll;

    // Phosphor decay flicker
    float flicker = (1.0 - uFlicker) + uFlicker * sin(time * 70.0);
    col *= flicker;

    // RGB phosphor triad mask
    float pixelX = floor(fragTexCoord.x * resolution.x);
    float subpixel = mod(pixelX, 3.0);
    vec3 triad = vec3(0.88);
    if (subpixel < 1.0) triad = vec3(1.05, 0.88, 0.88);
    else if (subpixel < 2.0) triad = vec3(0.88, 1.05, 0.88);
    else triad = vec3(0.88, 0.88, 1.05);
    col *= mix(vec3(1.0), triad, uMask);

    // Vignette
    if (uVignette > 0.001)
    {
        float vig = 16.0 * fragTexCoord.x * fragTexCoord.y * (1.0 - fragTexCoord.x) * (1.0 - fragTexCoord.y);
        vig = clamp(pow(vig, uVignette), 0.0, 1.0);
        col *= vig;
    }

    // Gamma / contrast boost
    col = pow(col, vec3(0.95)) * uBrightness;

    OUT_COLOR = vec4(col, 1.0) * fragColor * colDiffuse;
}
};

/**
The CRT's composite pass, as the effect backend runs it.

The body predates the effect pipeline and reads `resolution` and `time`; the
backend supplies those to every pass as `uResolution` and `uTime`, so two
defines rename them rather than the body being rewritten around new names.
`texture1` is the blurred bright pass — image 3 of the chain.
*/
private enum crtFragmentShader = activePrologue
    ~ "#define resolution uResolution\n#define time uTime\n"
    ~ crtUniforms ~ crtShaderBody;

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
    /// the shader's `curve()` must agree with lives there, not here.
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
        import sparkles.ui.effect : bloomPasses, EffectImpl, EffectPass,
            EffectTier, glslBackend;

        EffectPass[] passes = bloomPasses()[0 .. 3];
        passes ~= EffectPass(crtFragmentShader, from: 0, inputs: [3]);
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
    // The backend supplies the clock and the size; the body keeps its names.
    assert(impl.passes[3].source.canFind("#define time uTime"));
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
