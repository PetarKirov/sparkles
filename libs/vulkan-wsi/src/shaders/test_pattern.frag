#version 450
//
// A diagnostic test pattern for a window-system lane, computed per pixel.
//
// Everything is laid out in display pixels, the upright orientation the user
// sees: `toDisplay` undoes the swapchain's pre-transform, so the pattern is
// the same whether the compositor or this shader turns the image. The safe
// area is the display minus `u_safe_insets`.
//
// - Outside the safe area: a 45° dark-red/black caution hatch that moves
//   with the frame counter.
// - The safe area's edge: a 2-pixel amber border, inside the safe area.
// - The display's corners: 1-pixel crosshairs, 32 pixels along each edge,
//   red at the top left, green at the top right, blue at the bottom left and
//   white at the bottom right, so a capture shows the orientation too.
// - Liveness, at the safe area's top left: a 1-pixel ticker sweeping a
//   64-pixel strip, and an 8-pixel box strobing black/white every frame.
// - Portrait (taller than wide): a 32-step grayscale ladder down the centre,
//   alternating 1-pixel horizontal lines along both sides, and a circle of
//   radius 0.4 × the safe width with a centre cross.
// - Landscape: 75% and 100% colour bars (white, yellow, cyan, green, magenta,
//   red, blue, black), a continuous grey ramp, near-black (0–16) and
//   near-white (235–255) patches, and 16:9, 18:9 and 21:9 outlines.
//
// Colours are 8-bit code values: on an sRGB swapchain they are decoded to
// linear first, so the hardware's encode stores exactly them.
//
// Regenerate the SPIR-V beside this file after any edit:
//
//     glslangValidator -V -g0 test_pattern.frag -o test_pattern.frag.spv

layout(push_constant) uniform FrameContext {
    vec2 u_resolution;    // display size in physical pixels (width, height)
    vec4 u_safe_insets;   // (left, top, right, bottom) in physical pixels
    uint u_pre_transform; // VkSurfaceTransformFlagBitsKHR of the swapchain
    uint u_frame_count;   // monotonic, for liveness
};

layout(constant_id = 0) const bool kSrgbTarget = false;

layout(location = 0) out vec4 outColor;

const uint kRotate90 = 0x2u;
const uint kRotate180 = 0x4u;
const uint kRotate270 = 0x8u;

const vec3 kAmber = vec3(1.0, 215.0 / 255.0, 0.0);
const vec3 kHatch = vec3(140.0 / 255.0, 16.0 / 255.0, 16.0 / 255.0);
const vec3 kBackground = vec3(20.0 / 255.0);

// A pre-transform of 90° means the image holds the display turned 90°
// clockwise, and the presentation engine turns it back; so framebuffer pixel
// `p` lands at the returned display position. (Checked on Android, where a
// capture shows each corner crosshair at its own corner.)
vec2 toDisplay(vec2 p)
{
    const vec2 r = u_resolution;
    if ((u_pre_transform & kRotate90) != 0u)
        return vec2(p.y, r.y - p.x);
    if ((u_pre_transform & kRotate180) != 0u)
        return r - p;
    if ((u_pre_transform & kRotate270) != 0u)
        return vec2(r.x - p.y, p.x);
    return p;
}

vec3 decode(vec3 code)
{
    if (!kSrgbTarget)
        return code;
    const vec3 low = code / 12.92;
    const vec3 high = pow((code + 0.055) / 1.055, vec3(2.4));
    return mix(high, low, lessThanEqual(code, vec3(0.04045)));
}

bool within(ivec2 p, ivec2 lo, ivec2 hi)
{
    return all(greaterThanEqual(p, lo)) && all(lessThan(p, hi));
}

// A 2-pixel outline of the rectangle [lo, hi).
bool outline(ivec2 p, ivec2 lo, ivec2 hi)
{
    return within(p, lo, hi) && !within(p, lo + 2, hi - 2);
}

vec3 portrait(ivec2 p, ivec2 size)
{
    vec3 color = kBackground;

    // Grayscale ladder: 32 uniform steps from 0 to 255, top to bottom.
    const int ladderWidth = max(size.x / 8, 32);
    const int ladderTop = size.y / 10;
    const int ladderHeight = size.y - 2 * ladderTop;
    if (abs(p.x - size.x / 2) < ladderWidth / 2 && p.y >= ladderTop
        && p.y < ladderTop + ladderHeight)
    {
        const int step = (p.y - ladderTop) * 32 / ladderHeight;
        color = vec3(float(step) / 31.0);
    }

    // The reticle: a circle bounded by the width, which stays round only if
    // nothing stretches the image.
    const vec2 centre = vec2(size) * 0.5;
    const float radius = 0.4 * float(size.x);
    const vec2 at = vec2(p) + 0.5 - centre;
    if (abs(length(at) - radius) < 1.0)
        color = vec3(0.0, 1.0, 0.0);
    if ((abs(at.x) < 0.5 || abs(at.y) < 0.5) && max(abs(at.x), abs(at.y)) < radius * 0.15)
        color = vec3(0.0, 1.0, 1.0);

    // 1-pixel line gratings along both sides: any scaling blurs them grey.
    if (p.x < 26 || p.x >= size.x - 26)
        color = (p.y & 1) == 0 ? vec3(1.0) : vec3(0.0);
    return color;
}

vec3 landscape(ivec2 p, ivec2 size)
{
    vec3 color = kBackground;
    const float y = (float(p.y) + 0.5) / float(size.y);
    const float x = (float(p.x) + 0.5) / float(size.x);

    // White, yellow, cyan, green, magenta, red, blue, black.
    const int bar = min(p.x * 8 / size.x, 7);
    const vec3 bars = vec3(bar < 2 || bar == 4 || bar == 5 ? 1.0 : 0.0,
        bar < 4 ? 1.0 : 0.0, bar == 0 || bar == 2 || bar == 4 || bar == 6 ? 1.0 : 0.0);
    if (y < 0.45)
        color = bars * 0.75;
    else if (y < 0.6)
        color = bars;
    else if (y < 0.75)
        color = vec3(x);
    else if (y < 0.9)
    {
        // 17 near-black patches (0–16), then 21 near-white ones (235–255).
        const int patchIndex = p.x * 38 / size.x;
        const float code = patchIndex < 17 ? float(patchIndex) : float(235 + patchIndex - 17);
        color = vec3(code / 255.0);
    }

    // Aspect-ratio frames centred in the safe area.
    const float ratios[3] = float[](16.0 / 9.0, 18.0 / 9.0, 21.0 / 9.0);
    const vec3 frames[3] = vec3[](vec3(0.0, 1.0, 1.0), vec3(1.0, 0.0, 1.0), vec3(1.0, 1.0, 0.0));
    for (int i = 0; i < 3; ++i)
    {
        const float width = min(float(size.x) * 0.96, float(size.y) * 0.96 * ratios[i]);
        const ivec2 half_ = ivec2(width, width / ratios[i]) / 2;
        const ivec2 mid = size / 2;
        if (outline(p, mid - half_, mid + half_))
            color = frames[i];
    }
    return color;
}

void main()
{
    const ivec2 res = ivec2(u_resolution);
    const ivec2 p = ivec2(floor(toDisplay(gl_FragCoord.xy)));
    const ivec2 safeLo = ivec2(u_safe_insets.xy);
    const ivec2 safeHi = res - ivec2(u_safe_insets.zw);

    vec3 color;
    if (!within(p, safeLo, safeHi))
    {
        const float d = float(p.x + p.y) + float(u_frame_count % 32u);
        color = mod(floor(d / 16.0), 2.0) < 1.0 ? kHatch : vec3(0.0);
    }
    else
    {
        const ivec2 local = p - safeLo;
        const ivec2 size = safeHi - safeLo;
        color = res.y > res.x ? portrait(local, size) : landscape(local, size);
        if (outline(p, safeLo, safeHi))
            color = kAmber;

        // Liveness: the ticker strip and the strobe box.
        if (within(local, ivec2(6, 6), ivec2(70, 16)))
            color = local.x - 6 == int(u_frame_count % 64u) ? vec3(1.0) : vec3(0.0);
        if (within(local, ivec2(74, 6), ivec2(82, 14)))
            color = vec3(float(u_frame_count & 1u));
    }

    // Corner crosshairs on the panel's true edges.
    const ivec2 last = res - 1;
    if ((p.y == 0 || p.y == last.y || p.x == 0 || p.x == last.x)
        && (min(p.x, last.x - p.x) < 32 && min(p.y, last.y - p.y) < 32))
    {
        const bool right = p.x > last.x / 2;
        const bool bottom = p.y > last.y / 2;
        color = !bottom ? (right ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0))
            : (right ? vec3(1.0) : vec3(0.0, 0.0, 1.0));
    }
    outColor = vec4(decode(color), 1.0);
}
