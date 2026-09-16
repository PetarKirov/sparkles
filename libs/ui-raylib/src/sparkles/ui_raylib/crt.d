/**
CRT monitor shader effect behind the `sparkles:ui-raylib` seam (`UIA7`).

Encapsulates the post-processing render texture, GLSL shader compilation for
desktop (GLSL 330) and Android (GLSL 100 ES), barrel distortion curvature,
mouse-driven 3D asteroid curvature tilt, mouse magnification lens distortion,
animated scanlines and roll bars, RGB phosphor triad mask, chromatic aberration,
and vignette.
*/
module sparkles.ui_raylib.crt;

import raylib;
import sparkles.base.term_control : PointerShape;
import sparkles.input.gesture : PointF;

/// Axis-aligned rectangle representing a UI element in window pixel coordinates.
struct UiRect
{
    float x = 0;
    float y = 0;
    float w = 0;
    float h = 0;

    bool empty() const @safe pure nothrow @nogc => w <= 0 || h <= 0;
}

/// UI structure context passed to the CRT shader to drive localized phosphor reactions.
struct CrtUiContext
{
    UiRect focusBox;
    UiRect hoverBox;
    UiRect selectBox;
    UiRect splitDivider;
    UiRect scrollbarThumb;
}

version (Android)
{
    private enum crtFragmentShader = q{
#version 100
precision mediump float;

varying vec2 fragTexCoord;
varying vec4 fragColor;

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

float sdBox(vec2 p, vec2 b)
{
    vec2 d = abs(p) - b;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

vec2 curve(vec2 coord, vec2 m, float isTilt, vec2 res)
{
    if (isTilt > 0.5)
    {
        // When tilt is enabled, the apex of the curvature follows the mouse m.
        // Directly under the mouse (coord == m), curvature distortion is zero.
        // When m is at one of the four corners, that corner appears straightened out,
        // while the opposite side curves away.
        vec2 cc = coord - m;
        float dist = dot(cc, cc);
        vec2 uv = coord + cc * (dist * uCurvature * 0.625);
        return (uv - 0.5) * 1.06 + 0.5;
    }
    else
    {
        vec2 cc = coord - 0.5;
        float dist = dot(cc, cc);
        vec2 uv = coord + cc * (dist * uCurvature);
        return (uv - 0.5) * 1.06 + 0.5;
    }
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
        float r = texture2D(texture0, uv + ca).r;
        float g = texture2D(texture0, uv).g;
        float b = texture2D(texture0, uv - ca).b;
        col = vec3(r, g, b);

        col += vec3(0.12) * lensRim;
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

    gl_FragColor = vec4(col, 1.0) * fragColor * colDiffuse;
}
};
}
else
{
    private enum crtFragmentShader = q{
#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

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

out vec4 finalColor;

float sdBox(vec2 p, vec2 b)
{
    vec2 d = abs(p) - b;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

vec2 curve(vec2 coord, vec2 m, float isTilt, vec2 res)
{
    if (isTilt > 0.5)
    {
        // When tilt is enabled, the apex of the curvature follows the mouse m.
        // Directly under the mouse (coord == m), curvature distortion is zero.
        // When m is at one of the four corners, that corner appears straightened out,
        // while the opposite side curves away.
        vec2 cc = coord - m;
        float dist = dot(cc, cc);
        vec2 uv = coord + cc * (dist * uCurvature * 0.625);
        return (uv - 0.5) * 1.06 + 0.5;
    }
    else
    {
        vec2 cc = coord - 0.5;
        float dist = dot(cc, cc);
        vec2 uv = coord + cc * (dist * uCurvature);
        return (uv - 0.5) * 1.06 + 0.5;
    }
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
        float r = texture(texture0, uv + ca).r;
        float g = texture(texture0, uv).g;
        float b = texture(texture0, uv - ca).b;
        col = vec3(r, g, b);

        col += vec3(0.12) * lensRim;
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

    finalColor = vec4(col, 1.0) * fragColor * colDiffuse;
}
};
}

/**
Manages the CRT post-processing effect.

Allocates and owns an off-screen render texture matching the screen dimensions,
loads and applies the CRT post-processing shader during presentation, and
handles resizing and resource cleanup.
*/
struct CrtEffect
{
    private bool enabled_;
    private bool tilt_;
    private bool magnify_;
    private bool cursorHidden_;
    private PointerShape shape_ = PointerShape.default_;
    private bool systemPointer_;
    private float lastMouseX_ = 0;
    private float lastMouseY_ = 0;

    private float curvature_ = 0.08f;
    private float scanlines_ = 0.12f;
    private float mask_ = 1.0f;
    private float chromaticAberration_ = 0.0025f;
    private float vignette_ = 0.12f;
    private float flicker_ = 0.007f;
    private float brightness_ = 1.05f;
    private float lensRadius_ = 0.18f;
    private float lensPower_ = 0.45f;

    private bool shaderLoaded;
    private Shader shader;
    private RenderTexture2D target;
    private int resLoc = -1;
    private int timeLoc = -1;
    private int mouseLoc = -1;
    private int tiltLoc = -1;
    private int magnifyLoc = -1;
    private int cursorShapeLoc = -1;
    private int curvatureLoc = -1;
    private int scanlinesLoc = -1;
    private int maskLoc = -1;
    private int chromaLoc = -1;
    private int vignetteLoc = -1;
    private int flickerLoc = -1;
    private int brightnessLoc = -1;
    private int lensRadiusLoc = -1;
    private int lensPowerLoc = -1;

    private bool uiReactive_ = true;
    private float focusHalo_ = 1.0f;
    private float hoverGlow_ = 1.0f;
    private float selectionBloom_ = 1.0f;
    private float dividerTension_ = 1.0f;
    private CrtUiContext uiContext_;

    private int uiReactiveLoc = -1;
    private int focusHaloLoc = -1;
    private int hoverGlowLoc = -1;
    private int selectionBloomLoc = -1;
    private int dividerTensionLoc = -1;
    private int focusRectLoc = -1;
    private int hoverRectLoc = -1;
    private int selectRectLoc = -1;
    private int splitDividerLoc = -1;
    private int scrollbarThumbLoc = -1;

    @disable this(this);

    /// Whether the CRT effect is active.
    bool enabled() const @safe pure nothrow @nogc => enabled_;

    /// ditto
    void enabled(bool on) @safe pure nothrow @nogc { enabled_ = on; }

    /// Toggles the CRT effect on or off.
    void toggle() @safe pure nothrow @nogc { enabled_ = !enabled_; }

    /// Whether mouse-directed 3D asteroid curvature tilt is enabled.
    bool tilt() const @safe pure nothrow @nogc => tilt_;

    /// ditto
    void tilt(bool on) @safe pure nothrow @nogc { tilt_ = on; }

    /// Whether mouse magnification lens distortion is enabled.
    bool magnify() const @safe pure nothrow @nogc => magnify_;

    /// ditto
    void magnify(bool on) @safe pure nothrow @nogc { magnify_ = on; }

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

    /// ditto
    void systemPointer(bool on) @safe pure nothrow @nogc { systemPointer_ = on; }

    /// Screen curvature amount (0 for flat monitor).
    float curvature() const @safe pure nothrow @nogc => curvature_;

    /// ditto
    void curvature(float v) @safe pure nothrow @nogc { curvature_ = v; }

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
    float lensRadius() const @safe pure nothrow @nogc => lensRadius_;

    /// ditto
    void lensRadius(float v) @safe pure nothrow @nogc { lensRadius_ = v; }

    /// Mouse magnification zoom power factor.
    float lensPower() const @safe pure nothrow @nogc => lensPower_;

    /// ditto
    void lensPower(float v) @safe pure nothrow @nogc { lensPower_ = v; }

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
    Converts a $(LREF UiRect) in screen coordinates to shader `[cx, cy, hw, hh]` in normalized
    UV space where `uv.y = 1.0` is the top of the window.
    */
    static float[4] toShaderBox(in UiRect r, float screenW, float screenH) @safe pure nothrow @nogc
    {
        if (r.w <= 0 || r.h <= 0 || screenW <= 0 || screenH <= 0)
            return [0.0f, 0.0f, 0.0f, 0.0f];
        float cx = (r.x + r.w * 0.5f) / screenW;
        float cy = 1.0f - (r.y + r.h * 0.5f) / screenH;
        float hw = (r.w * 0.5f) / screenW;
        float hh = (r.h * 0.5f) / screenH;
        return [cx, cy, hw, hh];
    }

    /**
    The pointer position last presented through $(LREF end), in UI pixels —
    the point both the lens and the software cursor are centred on.
    */
    PointF pointerPos() const @safe pure nothrow @nogc
        => PointF(lastMouseX_, lastMouseY_);

    /// ditto
    void pointerPos(PointF p) @safe pure nothrow @nogc
    {
        lastMouseX_ = p.x;
        lastMouseY_ = p.y;
    }

    /**
    The curvature step alone, in normalized y-flipped coordinates: `curve()`
    from the shader, and nothing else. `mx`/`my` are the apex the tilt bends
    around, ignored when tilt is off.
    */
    private void curveStep(float nx, float ny, float mx, float my,
        out float uvX, out float uvY) const @safe pure nothrow @nogc
    {
        const apexX = tilt_ ? mx : 0.5f;
        const apexY = tilt_ ? my : 0.5f;
        const k = tilt_ ? curvature_ * 0.625f : curvature_;
        const ccX = nx - apexX;
        const ccY = ny - apexY;
        const dist = ccX * ccX + ccY * ccY;
        uvX = (nx + ccX * (dist * k) - 0.5f) * 1.06f + 0.5f;
        uvY = (ny + ccY * (dist * k) - 0.5f) * 1.06f + 0.5f;
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
        if (!enabled_ || screenW <= 0 || screenH <= 0)
            return PointF(screenX, screenY);

        const nx = screenX / cast(float) screenW;
        const ny = (cast(float) screenH - screenY) / cast(float) screenH;

        float mx = lastMouseX_ / cast(float) screenW;
        float my = (cast(float) screenH - lastMouseY_) / cast(float) screenH;

        float uvX, uvY;
        curveStep(nx, ny, mx, my, uvX, uvY);
        if (tilt_)
            foreach (_; 0 .. 3)
            {
                curveStep(nx, ny, uvX, uvY, uvX, uvY);
            }

        return PointF(uvX * cast(float) screenW, (1.0f - uvY) * cast(float) screenH);
    }

    /**
    Translates a screen device pixel coordinate to the corresponding unwarped UI
    pixel coordinate rendered under that screen location.
    */
    PointF mapScreenToUi(float screenX, float screenY, int screenW, int screenH) const @safe pure nothrow @nogc
    {
        if (!enabled_ || screenW <= 0 || screenH <= 0)
            return PointF(screenX, screenY);

        float nx = screenX / cast(float) screenW;
        float ny = (cast(float) screenH - screenY) / cast(float) screenH;

        float mx = lastMouseX_ / cast(float) screenW;
        float my = (cast(float) screenH - lastMouseY_) / cast(float) screenH;

        float aspect = cast(float) screenW / cast(float) screenH;

        float uvX, uvY;
        curveStep(nx, ny, mx, my, uvX, uvY);

        // Lens magnification around the mouse, in texture space — the same
        // order the shader applies it in, so this stays its exact inverse-free
        // twin. Applying it before curvature made the two disagree.
        if (magnify_)
        {
            float dx = (uvX - mx) * aspect;
            float dy = uvY - my;
            import std.math : sqrt, pow;
            float dist = cast(float) sqrt(dx * dx + dy * dy);
            float radius = lensRadius_;
            if (dist < radius)
            {
                float normDist = dist / radius;
                float z = cast(float) sqrt(1.0f - normDist * normDist);
                float factor = 1.0f - lensPower_ * cast(float) pow(z, 1.4f);
                uvX = mx + (uvX - mx) * factor;
                uvY = my + (uvY - my) * factor;
            }
        }

        float uiX = uvX * cast(float) screenW;
        float uiY = (1.0f - uvY) * cast(float) screenH;
        return PointF(uiX, uiY);
    }

    private void ensureShader() @system
    {
        if (shaderLoaded)
            return;
        shader = LoadShaderFromMemory(null, crtFragmentShader.ptr);
        shaderLoaded = IsShaderValid(shader);
        if (shaderLoaded)
        {
            resLoc = GetShaderLocation(shader, "resolution".ptr);
            timeLoc = GetShaderLocation(shader, "time".ptr);
            mouseLoc = GetShaderLocation(shader, "mouse".ptr);
            tiltLoc = GetShaderLocation(shader, "mouseTilt".ptr);
            magnifyLoc = GetShaderLocation(shader, "mouseMagnify".ptr);
            cursorShapeLoc = GetShaderLocation(shader, "cursorShape".ptr);
            curvatureLoc = GetShaderLocation(shader, "uCurvature".ptr);
            scanlinesLoc = GetShaderLocation(shader, "uScanlines".ptr);
            maskLoc = GetShaderLocation(shader, "uMask".ptr);
            chromaLoc = GetShaderLocation(shader, "uChromaAberration".ptr);
            vignetteLoc = GetShaderLocation(shader, "uVignette".ptr);
            flickerLoc = GetShaderLocation(shader, "uFlicker".ptr);
            brightnessLoc = GetShaderLocation(shader, "uBrightness".ptr);
            lensRadiusLoc = GetShaderLocation(shader, "uLensRadius".ptr);
            lensPowerLoc = GetShaderLocation(shader, "uLensPower".ptr);
            uiReactiveLoc = GetShaderLocation(shader, "uUiReactive".ptr);
            focusHaloLoc = GetShaderLocation(shader, "uFocusHalo".ptr);
            hoverGlowLoc = GetShaderLocation(shader, "uHoverGlow".ptr);
            selectionBloomLoc = GetShaderLocation(shader, "uSelectionBloom".ptr);
            dividerTensionLoc = GetShaderLocation(shader, "uDividerTension".ptr);
            focusRectLoc = GetShaderLocation(shader, "uFocusRect".ptr);
            hoverRectLoc = GetShaderLocation(shader, "uHoverRect".ptr);
            selectRectLoc = GetShaderLocation(shader, "uSelectRect".ptr);
            splitDividerLoc = GetShaderLocation(shader, "uSplitDivider".ptr);
            scrollbarThumbLoc = GetShaderLocation(shader, "uScrollbarThumb".ptr);
        }
    }

    private void ensureTarget(int w, int h) @system
    {
        if (target.id != 0 && (target.texture.width != w || target.texture.height != h))
        {
            UnloadRenderTexture(target);
            target = RenderTexture2D.init;
        }
        if (target.id == 0 && w > 0 && h > 0)
        {
            target = LoadRenderTexture(w, h);
        }
    }

    /**
    Begins off-screen capture into the render texture if CRT mode is enabled.
    Hides the desktop compositor cursor while CRT mode is active, unless
    $(LREF systemPointer) asks for it to be left alone (`PTR1`).
    Must be paired with $(LREF end).
    */
    void begin(int screenW, int screenH) @system
    {
        // The compositor cursor is hidden only while the shader is drawing one
        // in its place; the two conditions are the same condition, so a mode
        // switch mid-run restores it on the very next frame.
        const wantHidden = enabled_ && !systemPointer_;
        if (wantHidden != cursorHidden_)
        {
            if (wantHidden)
                HideCursor();
            else
                ShowCursor();
            cursorHidden_ = wantHidden;
        }
        if (!enabled_)
            return;

        ensureShader();
        if (!shaderLoaded)
            return;
        ensureTarget(screenW, screenH);
        if (target.id == 0)
            return;
        BeginTextureMode(target);
    }

    /**
    Ends off-screen capture and renders the result through the CRT shader
    onto the screen backbuffer, compositing the CRT-styled cursor.
    */
    void end(int screenW, int screenH, float mouseX = 0, float mouseY = 0) @system
    {
        if (!enabled_ || !shaderLoaded || target.id == 0)
            return;

        lastMouseX_ = mouseX;
        lastMouseY_ = mouseY;

        EndTextureMode();

        if (resLoc >= 0)
        {
            float[2] res = [cast(float) screenW, cast(float) screenH];
            SetShaderValue(shader, resLoc, res.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC2);
        }
        if (timeLoc >= 0)
        {
            float t = cast(float) GetTime();
            SetShaderValue(shader, timeLoc, &t, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        }
        if (mouseLoc >= 0)
        {
            float[2] m = [mouseX, cast(float) screenH - mouseY];
            SetShaderValue(shader, mouseLoc, m.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC2);
        }
        if (tiltLoc >= 0)
        {
            float tv = tilt_ ? 1.0f : 0.0f;
            SetShaderValue(shader, tiltLoc, &tv, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        }
        if (magnifyLoc >= 0)
        {
            float mv = magnify_ ? 1.0f : 0.0f;
            SetShaderValue(shader, magnifyLoc, &mv, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        }
        if (cursorShapeLoc >= 0)
        {
            // `PTR1`: negative means the window system's pointer is the only
            // one on screen, and the shader must draw none.
            float sc = -1.0f;
            if (!systemPointer_)
                switch (shape_) with (PointerShape)
                {
                    case text:     sc = 1.0f; break;
                    case pointer:  sc = 2.0f; break;
                    case ewResize: sc = 3.0f; break;
                    default:       sc = 0.0f; break;
                }
            SetShaderValue(shader, cursorShapeLoc, &sc, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        }
        if (curvatureLoc >= 0)
            SetShaderValue(shader, curvatureLoc, &curvature_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (scanlinesLoc >= 0)
            SetShaderValue(shader, scanlinesLoc, &scanlines_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (maskLoc >= 0)
            SetShaderValue(shader, maskLoc, &mask_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (chromaLoc >= 0)
            SetShaderValue(shader, chromaLoc, &chromaticAberration_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (vignetteLoc >= 0)
            SetShaderValue(shader, vignetteLoc, &vignette_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (flickerLoc >= 0)
            SetShaderValue(shader, flickerLoc, &flicker_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (brightnessLoc >= 0)
            SetShaderValue(shader, brightnessLoc, &brightness_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (lensRadiusLoc >= 0)
            SetShaderValue(shader, lensRadiusLoc, &lensRadius_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (lensPowerLoc >= 0)
            SetShaderValue(shader, lensPowerLoc, &lensPower_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (uiReactiveLoc >= 0)
        {
            float rv = uiReactive_ ? 1.0f : 0.0f;
            SetShaderValue(shader, uiReactiveLoc, &rv, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        }
        if (focusHaloLoc >= 0)
            SetShaderValue(shader, focusHaloLoc, &focusHalo_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (hoverGlowLoc >= 0)
            SetShaderValue(shader, hoverGlowLoc, &hoverGlow_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (selectionBloomLoc >= 0)
            SetShaderValue(shader, selectionBloomLoc, &selectionBloom_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        if (dividerTensionLoc >= 0)
            SetShaderValue(shader, dividerTensionLoc, &dividerTension_, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);

        if (focusRectLoc >= 0)
        {
            float[4] b = toShaderBox(uiContext_.focusBox, cast(float) screenW, cast(float) screenH);
            SetShaderValue(shader, focusRectLoc, b.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC4);
        }
        if (hoverRectLoc >= 0)
        {
            float[4] b = toShaderBox(uiContext_.hoverBox, cast(float) screenW, cast(float) screenH);
            SetShaderValue(shader, hoverRectLoc, b.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC4);
        }
        if (selectRectLoc >= 0)
        {
            float[4] b = toShaderBox(uiContext_.selectBox, cast(float) screenW, cast(float) screenH);
            SetShaderValue(shader, selectRectLoc, b.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC4);
        }
        if (splitDividerLoc >= 0)
        {
            float[4] b = toShaderBox(uiContext_.splitDivider, cast(float) screenW, cast(float) screenH);
            SetShaderValue(shader, splitDividerLoc, b.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC4);
        }
        if (scrollbarThumbLoc >= 0)
        {
            float[4] b = toShaderBox(uiContext_.scrollbarThumb, cast(float) screenW, cast(float) screenH);
            SetShaderValue(shader, scrollbarThumbLoc, b.ptr, ShaderUniformDataType.SHADER_UNIFORM_VEC4);
        }

        BeginShaderMode(shader);
        DrawTextureRec(
            target.texture,
            Rectangle(0, 0, cast(float) target.texture.width, cast(float) -target.texture.height),
            Vector2(0, 0),
            Color(255, 255, 255, 255)
        );
        EndShaderMode();
    }

    /// Releases GPU resources (render texture and compiled shader) and restores cursor.
    void release() @system nothrow @nogc
    {
        if (cursorHidden_)
        {
            ShowCursor();
            cursorHidden_ = false;
        }
        if (target.id != 0)
        {
            UnloadRenderTexture(target);
            target = RenderTexture2D.init;
        }
        if (shaderLoaded)
        {
            UnloadShader(shader);
            shader = Shader.init;
            shaderLoaded = false;
        }
    }

    ~this() @system nothrow @nogc
    {
        release();
    }
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
    auto bEmpty = CrtEffect.toShaderBox(rEmpty, 800, 600);
    assert(bEmpty == [0.0f, 0.0f, 0.0f, 0.0f]);

    UiRect r = UiRect(100, 50, 200, 100);
    assert(!r.empty);
    auto b = CrtEffect.toShaderBox(r, 800, 600);
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
@("ui_raylib.crt.magnifierLensIsCentredOnTheCursor")
@system
unittest
{
    import std.math : abs;

    enum int w = 800, h = 600;

    CrtEffect crt;
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
        crt.pointerPos = mouse;

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
@("ui_raylib.crt.mapPointerToUi.resolvesTheDistortionsCentredOnIt")
@system
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

    CrtEffect crt;
    crt.enabled = true;
    crt.curvature = 0.25f;
    crt.lensRadius = 0.30f;
    crt.lensPower = 0.55f;
    crt.pointerPos = PointF(640, 300);

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
    crt.pointerPos = tilted;
    assert(miss(crt.mapPointerToUi(probe.x, probe.y, w, h), tilted) < 0.5f,
        "the tilt apex did not converge");

    // ...and it converges from a badly wrong starting point, too — the apex is
    // seeded with the previous frame's pointer, which after a jump is stale.
    crt.pointerPos = PointF(10, 700);
    assert(miss(crt.mapPointerToUi(probe.x, probe.y, w, h), tilted) < 1.0f);
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
