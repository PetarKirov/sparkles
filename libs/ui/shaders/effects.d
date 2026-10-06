/**
The GPU half of the built-in effects: one `@fragment` entry point per effect,
each a thin wrapper around the transform in `sparkles.ui.effect_shaders`.

Device-only, and outside `sparkles:ui`'s source paths on purpose: only
`shader-compile` ever compiles this module, with LDC's Vulkan target (which
predefines `LDC_DCompute`), and what it produces is the GLSL under
`generated/` that `sparkles.ui.effect` string-imports. An ordinary build never
sees it — its `Sampler2D.sample` names a SPIR-V intrinsic no CPU has.

The interface is raylib's: `fragTexCoord`/`fragColor` are the varyings its
default vertex shader emits, `texture0` the sampler it binds, `finalColor`
the output. `uExtentCells` and the per-effect uniforms are what
`ui_raylib.effect_gpu` uploads at composite time.
*/
@compute(CompileFor.deviceOnly)
module effects;

import sparkles.shaders;
static import sparkles.ui.effect_shaders;
import sparkles.ui.crt_shaders : crtCurve, crtLens, crtLensDistance, crtLensRim;

/**
The tier-0 bracket (`EFX8` on the GPU): sample the rendered subtree, floor
the texture coordinate to the cell — the very `at` the terminal hands the
same function — and run the transform on the texel's colour, keeping its
alpha.
*/
private vec4 tier0(alias transform)(vec2 fragTexCoord, vec4 fragColor,
    Sampler2D texture0, vec2 uExtentCells) @safe pure nothrow @nogc
{
    const texel = texture0.sample(fragTexCoord) * fragColor;
    const at = floor(fragTexCoord * uExtentCells);
    return v4(transform(at, uExtentCells, texel.xyz), texel.w);
}

/// ditto
@fragment vec4 scanlines(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.scanlines)(fragTexCoord, fragColor, texture0, uExtentCells);

/// ditto
@fragment vec4 phosphor(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.phosphor)(fragTexCoord, fragColor, texture0, uExtentCells);

/// ditto
@fragment vec4 dim(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.dim)(fragTexCoord, fragColor, texture0, uExtentCells);

/// ditto
@fragment vec4 spectrum(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.spectrum)(fragTexCoord, fragColor, texture0, uExtentCells);

/**
The tier-1 bracket (`EFX11`): sample at the warped position. Outside `[0, 1]`
is off the subtree, not a clamped edge — a barrel distortion that smeared its
border pixels outward would be hiding the shape it exists to show.
Transparent is the honest answer and composites over whatever the bracket
sits on.
*/
@fragment vec4 curvature(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform float uAmount)
{
    const uv = sparkles.ui.effect_shaders.curvature(fragTexCoord, uAmount);
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f)
        return v4(0.0f);
    return texture0.sample(uv) * fragColor;
}

// ── bloom: four passes (tier 2) ─────────────────────────────────────────────
// Extract the bright part at half size, blur it horizontally, then vertically,
// then add it back over the bracket. `ui_raylib.effect_gpu` chains them: each
// pass draws the previous one's image as `texture0`, and the composite also
// reads the blurred glow as `texture1`. `uResolution` is the size of the image
// a pass writes.

/// ditto
@fragment vec4 bloomExtract(@input vec2 fragTexCoord, Sampler2D texture0,
    @uniform float uBloomThreshold)
    => v4(sparkles.ui.effect_shaders.bloomBright(texture0.sample(fragTexCoord).xyz,
        uBloomThreshold), 1.0f);

/**
A nine-tap Gaussian along `dir`, `uBloomRadius` output pixels per tap. Each
tap is weighted and added on its own, in the order the hand-written pass
used, so the float rounding matches it.
*/
private vec3 bloomBlur(Sampler2D texture0, vec2 uv, vec2 dir, vec2 uResolution,
    float uBloomRadius) @safe pure nothrow @nogc
{
    enum float w0 = 0.2270270270f, w1 = 0.1945945946f, w2 = 0.1216216216f,
        w3 = 0.0540540541f, w4 = 0.0162162162f;
    const s = dir * uBloomRadius / uResolution;
    vec3 sum = texture0.sample(uv).xyz * w0;
    sum = sum + texture0.sample(uv + s * 1.0f).xyz * w1;
    sum = sum + texture0.sample(uv - s * 1.0f).xyz * w1;
    sum = sum + texture0.sample(uv + s * 2.0f).xyz * w2;
    sum = sum + texture0.sample(uv - s * 2.0f).xyz * w2;
    sum = sum + texture0.sample(uv + s * 3.0f).xyz * w3;
    sum = sum + texture0.sample(uv - s * 3.0f).xyz * w3;
    sum = sum + texture0.sample(uv + s * 4.0f).xyz * w4;
    sum = sum + texture0.sample(uv - s * 4.0f).xyz * w4;
    return sum;
}

/// ditto
@fragment vec4 bloomBlurH(@input vec2 fragTexCoord, Sampler2D texture0,
    @uniform vec2 uResolution, @uniform float uBloomRadius)
    => v4(bloomBlur(texture0, fragTexCoord, v2(1.0f, 0.0f), uResolution, uBloomRadius), 1.0f);

/// ditto
@fragment vec4 bloomBlurV(@input vec2 fragTexCoord, Sampler2D texture0,
    @uniform vec2 uResolution, @uniform float uBloomRadius)
    => v4(bloomBlur(texture0, fragTexCoord, v2(0.0f, 1.0f), uResolution, uBloomRadius), 1.0f);

/// ditto — `texture0` is the bracket, `texture1` the blurred glow.
@fragment vec4 bloomComposite(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, Sampler2D texture1, @uniform vec4 colDiffuse,
    @uniform float uBloomIntensity)
    => sparkles.ui.effect_shaders.bloomOver(
        texture0.sample(fragTexCoord) * colDiffuse * fragColor,
        texture1.sample(fragTexCoord).xyz * uBloomIntensity);

// ── the CRT's tube (tier 2) ─────────────────────────────────────────────────
// The composite pass of `sparkles.ui_raylib.crt.CrtEffect` (`EFX21`), after
// bloom's first three passes. It bends and magnifies the bracket with the
// geometry in `sparkles.ui.crt_shaders` — the functions the CPU's pointer maps
// call — then adds the glow, lights the UI elements the frame list names, draws
// the software cursor, and finishes with the beam. Every uniform but
// `uResolution` and `uTime` is an `EffectParam` the CRT writes each frame
// (`crtParamNames`), which is why their names are not this module's to change.
//
// Here rather than in a module of its own: the freshness stamp records the
// unit's modules, and a new one goes unseen until another input changes
// (`SHB4`, deferred), so a checkout with generated shaders would keep its stale
// set and fail to find this one's.

/// Signed distance from `p` to a box of half-extents `b` centred on the origin.
private float sdBox(vec2 p, vec2 b) @safe pure nothrow @nogc
{
    const d = abs(p) - b;
    return length(max(d, v2(0.0f))) + min(max(d.x, d.y), 0.0f);
}

/**
The software cursor (`CRT6`) at offset `p` from its hotspot, in UI pixels
with y up: an I-beam (`shape` 1), a horizontal resize arrow (3), else the
arrow. White fill, black outline, transparent outside.
*/
private vec4 renderCursor(vec2 p, float shape) @safe pure nothrow @nogc
{
    // Masks combined with `&`/`|` and one select per shape, never an early
    // return or a short-circuit chain: the pinned SPIR-V backend emits
    // unstructured control flow for those here, which spirv-val rejects. The
    // masks are the hand-written shader's, unchanged; a fill wins over the
    // outline, and anything outside a shape's box is transparent.
    const ax = abs(p.x), ay = abs(p.y);
    const clear = v4(0.0f), white = v4(1.0f, 1.0f, 1.0f, 1.0f), black = v4(0.0f, 0.0f, 0.0f, 1.0f);

    // I-beam
    const ibBox = (ax <= 5.0f) & (ay <= 9.0f);
    const ibLine = ((ax <= 1.5f) & (ay <= 7.5f))
        | ((ax <= 4.0f) & (p.y >= -8.0f) & (p.y <= -5.5f))
        | ((ax <= 4.0f) & (p.y >= 5.5f) & (p.y <= 8.0f));
    const ibFill = ((ax <= 0.5f) & (ay <= 6.5f))
        | ((ax <= 3.0f) & (p.y >= -7.0f) & (p.y <= -6.5f))
        | ((ax <= 3.0f) & (p.y >= 6.5f) & (p.y <= 7.0f));
    const iBeam = !ibBox ? clear : ibFill ? white : ibLine ? black : clear;

    // EW-resize <->
    const ewBox = (ax <= 9.5f) & (ay <= 5.5f);
    const ewLine = ((ay <= 1.5f) & (ax <= 6.5f))
        | ((p.x <= -2.5f) & (p.x >= -7.5f) & (ay <= -p.x - 2.5f))
        | ((p.x >= 2.5f) & (p.x <= 7.5f) & (ay <= p.x - 2.5f));
    const ewFill = ((ay <= 0.5f) & (ax <= 5.5f))
        | ((p.x <= -3.0f) & (p.x >= -6.5f) & (ay <= -p.x - 3.5f))
        | ((p.x >= 3.0f) & (p.x <= 6.5f) & (ay <= p.x - 3.5f));
    const resize = !ewBox ? clear : ewFill ? white : ewLine ? black : clear;

    // The arrow.
    const arBox = (p.x >= -0.5f) & (p.x <= 13.5f) & (p.y >= -0.5f) & (p.y <= 19.5f);
    const arLine = ((p.x >= 0.0f) & (p.y >= 0.0f) & (p.y <= 14.5f) & (p.x <= p.y)
            & (p.y - p.x * 0.35f <= 12.0f))
        | ((p.x >= 3.0f) & (p.x <= 7.5f) & (p.y >= 9.0f) & (p.y <= 17.5f));
    const arFill = ((p.x >= 1.0f) & (p.y >= 1.5f) & (p.y <= 13.0f) & (p.x <= p.y - 0.5f)
            & (p.y - p.x * 0.35f <= 10.5f))
        | ((p.x >= 4.0f) & (p.x <= 6.5f) & (p.y >= 10.0f) & (p.y <= 16.5f));
    const arrow = !arBox ? clear : arFill ? white : arLine ? black : clear;

    return (shape > 0.5f) & (shape < 1.5f) ? iBeam : shape > 2.5f ? resize : arrow;
}

/// The CRT's composite pass (`EFX21`).
@fragment vec4 crtTube(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, Sampler2D texture1, @uniform vec4 colDiffuse,
    @uniform vec2 uResolution, @uniform float uTime,
    @uniform vec2 mouse, @uniform float mouseTilt, @uniform float mouseMagnify,
    @uniform float cursorShape, @uniform float uCurvature, @uniform float uScanlines,
    @uniform float uMask, @uniform float uChromaAberration, @uniform float uVignette,
    @uniform float uFlicker, @uniform float uBrightness, @uniform float uLensRadius,
    @uniform float uLensPower, @uniform float uBloomIntensity,
    @uniform float uUiReactive, @uniform float uFocusHalo, @uniform float uHoverGlow,
    @uniform float uSelectionBloom, @uniform float uDividerTension,
    @uniform vec4 uFocusRect, @uniform vec4 uHoverRect, @uniform vec4 uSelectRect,
    @uniform vec4 uSplitDivider, @uniform vec4 uScrollbarThumb)
{
    const res = uResolution;
    const m = mouse / res;
    vec2 uv = crtCurve(fragTexCoord, m, mouseTilt, uCurvature);

    // The lens is applied in TEXTURE space, after curvature, so that its
    // centre is the very point the software cursor is drawn at (`CRT6`).
    float lensRim = 0.0f;
    if (mouseMagnify > 0.5f)
    {
        const aspect = res.x / res.y;
        lensRim = crtLensRim(crtLensDistance(uv, m, aspect, uLensRadius));
        uv = crtLens(uv, m, aspect, uLensRadius, uLensPower);
    }

    // Subtle horizontal sync micro-jitter.
    uv = v2(uv.x + sin(uv.y * 120.0f + uTime * 30.0f) * 0.00025f, uv.y);

    const onTube = uv.x >= 0.0f && uv.x <= 1.0f && uv.y >= 0.0f && uv.y <= 1.0f;

    // The vector from the cursor's hotspot to this fragment, in UI pixels. A
    // negative `cursorShape` means the window system draws the pointer itself
    // (`PTR1`) and the tube must not draw a second one.
    vec4 cursorCol = v4(0.0f);
    if (cursorShape >= 0.0f && onTube)
    {
        const ui = v2(uv.x * res.x, uv.y * res.y);
        cursorCol = renderCursor(v2(ui.x - mouse.x, mouse.y - ui.y), cursorShape);
    }

    vec3 col = v3(0.0f);
    if (onTube)
    {
        const corner = smoothstep(0.0f, 0.012f, uv.x) * smoothstep(0.0f, 0.012f, 1.0f - uv.x)
            * (smoothstep(0.0f, 0.012f, uv.y) * smoothstep(0.0f, 0.012f, 1.0f - uv.y));

        const cc = uv - v2(0.5f);
        float caStrength = uChromaAberration + uChromaAberration * 0.2f * sin(uTime * 3.0f);
        if (lensRim > 0.0f)
            caStrength = caStrength + 0.002f * lensRim;

        const ca = cc * caStrength;
        col = v3(texture0.sample(uv + ca).x, texture0.sample(uv).y,
            texture0.sample(uv - ca).z);

        col = col + v3(0.12f) * lensRim;

        // `CRT3`: the blurred bright pass, sampled at the SAME warped `uv` as
        // the content, so the glow curves with the tube.
        if (uBloomIntensity > 0.0f)
            col = col + texture1.sample(uv).xyz * uBloomIntensity;

        col = col * corner;

        if (uUiReactive > 0.5f)
        {
            // 1. Focus box: cathode halation around the border, a sharper beam inside.
            if (uFocusRect.z > 0.0f && uFocusHalo > 0.0f)
            {
                const dist = sdBox((uv - uFocusRect.xy) * res, v2(uFocusRect.z, uFocusRect.w) * res);
                if (dist > -3.0f && dist < 14.0f)
                {
                    const pulse = 0.85f + 0.15f * sin(uTime * 3.5f);
                    const halo = exp(-abs(dist) * 0.28f) * uFocusHalo * 0.22f * pulse;
                    col = col + v3(0.25f, 0.55f, 0.85f) * halo;
                }
                if (dist <= 0.0f)
                    col = mix(col, col * 1.03f + v3(0.01f), 0.5f);
            }

            // 2. Hover box: phosphor excitation.
            if (uHoverRect.z > 0.0f && uHoverGlow > 0.0f)
            {
                const dist = sdBox((uv - uHoverRect.xy) * res, v2(uHoverRect.z, uHoverRect.w) * res);
                if (dist <= 10.0f)
                {
                    const surge = exp(-max(dist, 0.0f) * 0.35f)
                        * (dist < 0.0f ? 0.14f : 0.07f) * uHoverGlow;
                    col = col + (col * surge + v3(0.02f, 0.03f, 0.04f) * surge);

                    const edge = exp(-abs(dist) * 0.5f) * uHoverGlow * 0.12f;
                    col = v3(col.x + edge * 0.04f, col.y, col.z + edge * 0.06f);
                }
            }

            // 3. Selection: phosphor overdrive inside, a horizontal bleed beside.
            if (uSelectRect.z > 0.0f && uSelectionBloom > 0.0f)
            {
                const p = (uv - uSelectRect.xy) * res;
                const b = v2(uSelectRect.z, uSelectRect.w) * res;
                const dist = sdBox(p, b);
                if (dist <= 0.0f)
                    col = col + col * (0.16f * uSelectionBloom);
                else if (abs(p.y) <= b.y && dist < 10.0f)
                    col = col + col * (exp(-dist * 0.35f) * 0.10f * uSelectionBloom);
            }

            // 4. Dock split divider: a cathode seam, and tension beside it.
            if (uSplitDivider.z > 0.0f && uDividerTension > 0.0f)
            {
                const dist = sdBox((uv - uSplitDivider.xy) * res,
                    v2(uSplitDivider.z, uSplitDivider.w) * res);
                // Two independent tests rather than `if … else if (a && b)`:
                // the pinned SPIR-V backend emits unstructured control flow
                // for that shape here, which spirv-val rejects.
                const seam = abs(dist) < 2.5f;
                const halo = !seam & (dist >= 0.0f) & (dist < 6.0f);
                if (seam)
                    col = col * (1.0f - (1.0f - abs(dist) / 2.5f) * 0.12f * uDividerTension);
                if (halo)
                    col = col + v3(0.02f, 0.04f, 0.06f) * (exp(-dist * 0.55f) * 0.05f * uDividerTension);
            }

            // 5. Scrollbar thumb flare.
            if (uScrollbarThumb.z > 0.0f)
            {
                const dist = sdBox((uv - uScrollbarThumb.xy) * res,
                    v2(uScrollbarThumb.z, uScrollbarThumb.w) * res);
                if (dist <= 4.0f)
                {
                    const flare = exp(-max(dist, 0.0f) * 0.6f) * 0.08f;
                    col = col + (col * flare + v3(0.03f) * flare);
                }
            }
        }
    }

    // The shader-drawn cursor, over everything the tube shows.
    if (cursorCol.w > 0.0f)
        col = mix(col, cursorCol.xyz, cursorCol.w);

    // Scanlines.
    const scanline = sin(fragTexCoord.y * res.y * 3.14159265f);
    col = col * ((1.0f - uScanlines) + uScanlines * (scanline * scanline));

    // The vertical roll hum bar.
    const roll = 0.5f + 0.5f * sin(fragTexCoord.y * 5.0f - uTime * 2.2f);
    col = col * ((1.0f - uFlicker * 5.7f) + uFlicker * 5.7f * roll);

    // Phosphor decay flicker.
    col = col * ((1.0f - uFlicker) + uFlicker * sin(uTime * 70.0f));

    // The RGB phosphor triad.
    const subpixel = mod(floor(fragTexCoord.x * res.x), 3.0f);
    const triad = subpixel < 1.0f ? v3(1.05f, 0.88f, 0.88f)
        : subpixel < 2.0f ? v3(0.88f, 1.05f, 0.88f)
        : v3(0.88f, 0.88f, 1.05f);
    col = col * mix(v3(1.0f), triad, uMask);

    // Vignette.
    if (uVignette > 0.001f)
    {
        const vig = 16.0f * fragTexCoord.x * fragTexCoord.y
            * (1.0f - fragTexCoord.x) * (1.0f - fragTexCoord.y);
        col = col * clamp(pow(vig, uVignette), 0.0f, 1.0f);
    }

    // Gamma and contrast.
    col = pow(col, v3(0.95f)) * uBrightness;

    return v4(col, 1.0f) * fragColor * colDiffuse;
}
