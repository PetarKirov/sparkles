/**
The canvas's shading, in D, for the host and the device: what one quad
record is, the vertex function that expands it, and the coverage and colour
functions its fragment function composes (`UVX5`).

Each drawing operation becomes one or more $(LREF Instance)s: fixed-size
records the vertex stage reads at instance rate. The vertex function
expands one into a quad of four vertices — its box, grown by the record's
outset — and hands the record on unchanged. The fragment function, which
samples and so lives in the device-only `canvas_fragment.d`, reads the three
bound images at the fragment's texture coordinate and calls $(LREF shade),
which picks by the record's kind:

$(UL
    $(LI `solid`: the colour over the whole quad. Its box is whole pixels,
    so it changes exactly the pixels the box names (`UVK9`, `UVK10`).)
    $(LI `roundedBox`: a box with a corner radius, filled, and a ring of the
    border's thickness outside it, both from a signed distance (`UVK11`).)
    $(LI `arrow`: the popup arrow's triangle, filled, with its two slanted
    edges stroked one pixel wide.)
    $(LI `coverageGlyph`, `colourGlyph`: a glyph from an atlas page.)
    $(LI `image`: a picture, filtered, times the foreground alpha (`UVK24`).)
    $(LI `shadow`: a box's drop shadow — the box grown by a spread and
    offset, blurred by a Gaussian — drawn only outside the box (`UVK40`).)
    $(LI `outside`: the part of each pixel outside a rounded box, as alpha,
    for erasing what lies beyond a window's rounded corners (`UVK41`).)
)

Everything is premultiplied gamma-space colour (`UVK6`): the result is
composited by fixed-function blending as `src + dst·(1 − α_src)`. On an sRGB
target the straight colour is decoded to linear first (`UVK7`).

Everything here but the entry point's sampling is ordinary D the host calls
too, which is how the coverage functions are tested against a supersampled
oracle without a GPU (`shading_test.d`).
*/
@compute(CompileFor.hostAndDevice) @profiles(vulkan13, vulkan11)
module sparkles.ui_vulkan.shading;

import sparkles.shaders;

@safe pure nothrow @nogc:

/// What a quad record draws, by its `shape.x`.
enum QuadKind : int
{
    solid = 0,         ///
    roundedBox = 1,    ///
    arrow = 2,         ///
    coverageGlyph = 3, ///
    colourGlyph = 4,   ///
    image = 5,         ///
    shadow = 6,        ///
    outside = 7,       ///
}

/// The bindings of descriptor set 0, fixed (`SHR7`) so the host's layout
/// and the fragment function name them from one place.
enum Binding : int
{
    coverage = 1, /// the coverage atlas page
    colour = 2,   /// the colour atlas page
    image = 3,    /// the bound image
    nearest = 4,  /// the nearest-filtering sampler, for atlas pages (`UVK21`)
    linear = 5,   /// the linear-filtering sampler, for images (`UVK24`)
}

/// The push-constant block both stages read.
struct CanvasView
{
    /// The display's size, in pixels: what records are placed in. The
    /// target's, unless it is turned.
    vec2 extent;
    float srgb = 0;   /// 1 on an sRGB target (`UVK7`), else 0
    /// Quarter turns clockwise the presentation engine gives the target on
    /// its way to the display (`UVK39`): a pre-rotated swapchain on a turned
    /// Android panel. 0–3; the records stay in display pixels.
    float turn = 0;
}

/**
Display pixel `p` in a target the presentation engine turns `turn` quarter
turns clockwise onto a display of `display` pixels (`UVK39`).
*/
vec2 displayToTarget(vec2 p, vec2 display, float turn)
{
    if (turn > 2.5f)
        return v2(p.y, display.x - p.x);
    if (turn > 1.5f)
        return v2(display.x - p.x, display.y - p.y);
    if (turn > 0.5f)
        return v2(display.y - p.y, p.x);
    return p;
}

/// ditto, the other way: where target pixel `q` shows on the display.
vec2 targetToDisplay(vec2 q, vec2 display, float turn)
{
    if (turn > 2.5f)
        return v2(display.x - q.y, q.x);
    if (turn > 1.5f)
        return v2(display.x - q.x, display.y - q.y);
    if (turn > 0.5f)
        return v2(q.y, display.y - q.x);
    return q;
}

/// The target's size for a display of `display` pixels turned `turn`
/// quarter turns: a quarter or three-quarter turn swaps the sides.
vec2 targetExtent(vec2 display, float turn)
{
    if ((turn > 0.5f && turn < 1.5f) || turn > 2.5f)
        return v2(display.y, display.x);
    return display;
}

/**
One quad record, read at instance rate (`UVX5`). Positions are in target
pixels; colours are straight RGBA in 0–1.
*/
struct Instance
{
    vec4 box;     /// x, y, width, height
    vec4 fill;    /// the fill: a box's background, a glyph's ink, an image's alpha in `w`
    /// the stroke: a rounded box's border, the arrow's outline; a shadow's
    /// blur (the Gaussian's standard deviation), spread and offset
    vec4 edge;
    /// `x` the `QuadKind`; `y` the corner radius; `z` the border's
    /// thickness; `w` how far the quad reaches past `box` on every side
    vec4 shape;
    vec4 texRect; /// the texture coordinates of `box`'s corners: u0, v0, u1, v1
}

/// What the vertex stage hands the fragment stage: the record, and the
/// fragment's texture coordinate.
struct CanvasVaryings
{
    @builtin(Builtin.position) vec4 position; ///
    vec4 vBox;       ///
    vec4 vFill;      ///
    vec4 vEdge;      ///
    vec4 vShape;     ///
    vec2 vTexCoord;  ///
    vec4 vMeta;      /// per-primitive payload for analytic glyph coverage
}

/**
Corner `index` (0–3, a triangle strip) of the quad record's box grown by its
outset, in clip space for a display of `canvasView.extent` pixels, on a
target turned `canvasView.turn` quarter turns from it.
*/
@vertex CanvasVaryings canvasVertex(@builtin(Builtin.vertexIndex) int index,
    @input vec4 quadBox, @input vec4 quadFill, @input vec4 quadEdge, @input vec4 quadShape,
    @input vec4 quadTexRect, PushConstants!CanvasView canvasView)
{
    const cx = cast(float)(index % 2);
    const cy = cast(float)(index / 2);
    const outset = quadShape.w;
    const px = quadBox.x - outset + cx * (quadBox.z + 2.0f * outset);
    const py = quadBox.y - outset + cy * (quadBox.w + 2.0f * outset);
    const q = displayToTarget(v2(px, py), canvasView.extent, canvasView.turn);
    const target = targetExtent(canvasView.extent, canvasView.turn);
    CanvasVaryings v;
    v.position = v4(q.x / target.x * 2.0f - 1.0f, q.y / target.y * 2.0f - 1.0f, 0.0f, 1.0f);
    v.vBox = quadBox;
    v.vFill = quadFill;
    v.vEdge = quadEdge;
    v.vShape = quadShape;
    v.vMeta = quadTexRect;
    v.vTexCoord = v2(quadTexRect.x + cx * (quadTexRect.z - quadTexRect.x),
        quadTexRect.y + cy * (quadTexRect.w - quadTexRect.y));
    return v;
}

/**
The push-constant block of an effect pass's vertex stage (`UVK15`).

The generated passes were written against OpenGL's images, whose first row
is the bottom one: a pass reads its sources at `fragTexCoord` with y up. Every
image an effect chain makes on Vulkan is kept in that orientation — the first
row of memory is `fragTexCoord.y = 0` — so an intermediate pass writes its
top row (framebuffer y = 0) at y = 0. The pass that composites onto the
canvas's target writes the picture upright instead: its top row is
`fragTexCoord.y = 1`.
*/
struct EffectView
{
    /// 1 for the pass that composites onto the target, else 0.
    float upright = 0;
}

/// What an effect pass's vertex stage hands the generated fragment stage:
/// the varyings raylib's default vertex shader emits, at the locations the
/// generated passes read them from (`fragTexCoord` 0, `fragColor` 1).
struct EffectVaryings
{
    @builtin(Builtin.position) vec4 position; ///
    vec2 fragTexCoord; ///
    vec4 fragColor;    /// the vertex colour: white, as raylib draws a texture
}

/**
Corner `index` (0–3, a triangle strip) of the quad covering the viewport, for
an effect pass: `fragTexCoord` spans 0–1 across it, y up on the upright pass
($(LREF EffectView)).
*/
@vertex EffectVaryings effectVertex(@builtin(Builtin.vertexIndex) int index,
    PushConstants!EffectView effectView)
{
    const cx = cast(float)(index % 2);
    const cy = cast(float)(index / 2);
    EffectVaryings v;
    v.position = v4(cx * 2.0f - 1.0f, cy * 2.0f - 1.0f, 0.0f, 1.0f);
    v.fragTexCoord = v2(cx, effectView.upright > 0.5f ? 1.0f - cy : cy);
    v.fragColor = v4(1.0f, 1.0f, 1.0f, 1.0f);
    return v;
}

/**
The fraction of the pixel centred at a point that a region covers, from the
point's signed distance `d` to the region's edge in pixels, negative inside:
exact for an edge along either axis, which is every edge of a box.
*/
float coverageOf(float d) => clamp(0.5f - d, 0.0f, 1.0f);

/// The signed distance from `p` to the box `box` (x, y, width, height) with
/// corners of radius `r`: negative inside.
float roundedBoxDistance(vec2 p, vec4 box, float r)
{
    const hw = box.z * 0.5f;
    const hh = box.w * 0.5f;
    const qx = abs(p.x - (box.x + hw)) - hw + r;
    const qy = abs(p.y - (box.y + hh)) - hh + r;
    const outside = length(v2(max(qx, 0.0f), max(qy, 0.0f)));
    return outside + min(max(qx, qy), 0.0f) - r;
}

/// How many sub-pixels per axis a pixel within a pixel of a curved or slanted
/// edge is split into.
enum int subSamples = 4;

/**
The fraction of the pixel centred at `p` inside the box `box` with corners of
radius `r`. A pixel a pixel or more from the edge is wholly in or out; one
nearer is split into `subSamples`² sub-pixels, each covered as $(LREF
coverageOf) covers a pixel at its own scale, which is exact along the box's
straight edges and within the canvas's tolerance on its corners (`UVK11`).
*/
float roundedBoxCoverage(vec2 p, vec4 box, float r)
{
    const d = roundedBoxDistance(p, box, r);
    if (abs(d) >= 1.0f)
        return coverageOf(d);
    const pitch = 1.0f / subSamples;
    float sum = 0.0f;
    foreach (j; 0 .. subSamples)
        foreach (i; 0 .. subSamples)
        {
            const s = v2(p.x - 0.5f + (i + 0.5f) * pitch, p.y - 0.5f + (j + 0.5f) * pitch);
            sum += coverageOf(roundedBoxDistance(s, box, r) * subSamples);
        }
    return sum / (subSamples * subSamples);
}

/**
The error function, to within 5·10⁻⁴ (Abramowitz and Stegun, 7.1.27): what a
Gaussian blur of an edge leaves across it.
*/
float erf(float x)
{
    const s = x < 0.0f ? -1.0f : 1.0f;
    const a = abs(x);
    float t = 1.0f + (0.278393f + (0.230389f + 0.078108f * (a * a)) * a) * a;
    t = t * t;
    return s - s / (t * t);
}

/// How many rows across ±3σ $(LREF blurredBoxCoverage) integrates over.
enum int shadowRows = 6;

/**
The rounded box `box` with corners of radius `r`, blurred by a Gaussian of
standard deviation `sigma`, at the point `p`: the box's coverage convolved
with the Gaussian. Exact across the box's straight edges in `x` (an `erf`
of each row's span), and integrated over `shadowRows` rows in `y` (Evan
Wallace's method), which is within the canvas's tolerance of the true
convolution (`UVK40`). Below a quarter pixel of blur, the box's own
coverage.
*/
float blurredBoxCoverage(vec2 p, vec4 box, float r, float sigma)
{
    if (sigma < 0.25f)
        return roundedBoxCoverage(p, box, r);
    const hw = box.z * 0.5f;
    const hh = box.w * 0.5f;
    const cx = p.x - (box.x + hw);
    const cy = p.y - (box.y + hh);
    const corner = min(r, min(hw, hh));
    const reach = 3.0f * sigma;
    const start = clamp(-reach, cy - hh, cy + hh);
    const end = clamp(reach, cy - hh, cy + hh);
    const pitch = (end - start) / shadowRows;
    const k = 0.70710678f / sigma;
    float sum = 0.0f;
    foreach (i; 0 .. shadowRows)
    {
        // A row `y` from the point, at the row's height in the box: its
        // span, narrowed at the corners, blurred across in `x`.
        const y = start + (i + 0.5f) * pitch;
        const inset = min(hh - corner - abs(cy - y), 0.0f);
        const half = hw - corner + sqrt(max(0.0f, corner * corner - inset * inset));
        const across = 0.5f * (erf((cx + half) * k) - erf((cx - half) * k));
        sum += across * exp(-(y * y) / (2.0f * sigma * sigma)) * pitch;
    }
    return sum / (2.5066283f * sigma);
}

/// The signed distance from `p` to the arrow's triangle bounded by `box`:
/// apex at the middle of its top, base along its bottom. Exact inside; an
/// underestimate outside, near a corner.
float arrowDistance(vec2 p, vec4 box)
{
    const apex = v2(box.x + box.z * 0.5f, box.y);
    const left = v2(box.x, box.y + box.w);
    const right = v2(box.x + box.z, box.y + box.w);
    const centre = v2(apex.x, box.y + box.w * 0.6f);
    return max(max(edgeDistance(p, left, right, centre), edgeDistance(p, left, apex, centre)),
        edgeDistance(p, apex, right, centre));
}

/// The fraction of the pixel centred at `p` inside the arrow's triangle, as
/// $(LREF roundedBoxCoverage) finds it for a box.
float arrowCoverage(vec2 p, vec4 box)
{
    const d = arrowDistance(p, box);
    if (abs(d) >= 1.0f)
        return coverageOf(d);
    const pitch = 1.0f / subSamples;
    float sum = 0.0f;
    foreach (j; 0 .. subSamples)
        foreach (i; 0 .. subSamples)
        {
            const s = v2(p.x - 0.5f + (i + 0.5f) * pitch, p.y - 0.5f + (j + 0.5f) * pitch);
            sum += coverageOf(arrowDistance(s, box) * subSamples);
        }
    return sum / (subSamples * subSamples);
}

/// The signed distance from `p` to the line through `a` and `b`, positive on
/// the side away from `inside`.
float edgeDistance(vec2 p, vec2 a, vec2 b, vec2 inside)
{
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = sqrt(dx * dx + dy * dy);
    const nx = -dy / len;
    const ny = dx / len;
    const s = (inside.x - a.x) * nx + (inside.y - a.y) * ny > 0.0f ? -1.0f : 1.0f;
    return s * ((p.x - a.x) * nx + (p.y - a.y) * ny);
}

/// How much of the pixel at `p` a one-pixel stroke centred on the segment
/// from `a` to `b` covers, its ends cut square.
float strokeCoverage(vec2 p, vec2 a, vec2 b)
{
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = sqrt(dx * dx + dy * dy);
    const along = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len;
    const across = abs(((p.x - a.x) * -dy + (p.y - a.y) * dx) / len);
    const band = coverageOf(across - 0.5f);
    return band * coverageOf(-along) * coverageOf(along - len);
}

/// `c` composited over `under`, both premultiplied.
vec4 over(vec4 c, vec4 under) => c + under * (1.0f - c.w);

/// A channel in the sRGB encoding, decoded to linear light.
float srgbToLinear(float c)
    => c <= 0.04045f ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);

/// A channel in linear light, encoded to sRGB.
float linearToSrgb(float c)
    => c <= 0.0031308f ? c * 12.92f : 1.055f * pow(c, 1.0f / 2.4f) - 0.055f;

/// The relative luminance (Rec. 709) of a linear-light colour.
float luminance(float r, float g, float b) => 0.2126f * r + 0.7152f * g + 0.0722f * b;

/**
A coverage glyph of straight colour `fill` covering `coverage` of a pixel
whose background is the straight colour `background` (`background.w` 1 when
the painter knows it, else 0), as premultiplied colour for the canvas's
gamma-space blending, by `mode` — a `Compositing`:

$(UL
    $(LI `gamma` (0): coverage as alpha, blended as encoded.)
    $(LI `linear` (1): the blend in linear light, re-encoded. The colour
    returned leaves exactly that over the background: it is the linear
    result less what blending keeps of the background.)
    $(LI `linearCorrected` (2): linear, with the coverage pushed towards an
    S-curve by `contrast` (0–1), which sharpens stems, then chosen to give
    the luminance gamma blending would — the weight the face looks designed
    at, whichever way round the colours are.)
)

Without a known background, or on an sRGB target (which blends in linear
light itself), it is `gamma`'s.
*/
vec4 glyphColour(vec4 fill, vec4 background, float coverage, float mode, float contrast, float srgb)
{
    if (mode < 0.5f || background.w < 0.5f || srgb > 0.5f)
        return premultiplied(fill, coverage, srgb);
    const fr = srgbToLinear(fill.x), fg = srgbToLinear(fill.y), fb = srgbToLinear(fill.z);
    const br = srgbToLinear(background.x), bg = srgbToLinear(background.y), bb = srgbToLinear(background.z);
    float a = coverage * fill.w;
    if (mode > 1.5f)
    {
        a = a + (a * a * (3.0f - 2.0f * a) - a) * contrast;
        const fy = luminance(fr, fg, fb), by = luminance(br, bg, bb);
        if (abs(fy - by) > 0.0001f)
        {
            const want = srgbToLinear(linearToSrgb(by) + (linearToSrgb(fy) - linearToSrgb(by)) * a);
            a = clamp((want - by) / (fy - by), 0.0f, 1.0f);
        }
    }
    const keep = 1.0f - a;
    return v4(linearToSrgb(br + (fr - br) * a) - background.x * keep,
        linearToSrgb(bg + (fg - bg) * a) - background.y * keep,
        linearToSrgb(bb + (fb - bb) * a) - background.z * keep, a);
}

/// The straight colour `c` covering `coverage` of a pixel, premultiplied,
/// decoded to linear first on an sRGB target.
vec4 premultiplied(vec4 c, float coverage, float srgb)
{
    const a = c.w * coverage;
    if (srgb > 0.5f)
        return v4(srgbToLinear(c.x) * a, srgbToLinear(c.y) * a, srgbToLinear(c.z) * a, a);
    return v4(c.x * a, c.y * a, c.z * a, a);
}

/**
The premultiplied colour a quad record leaves at the pixel centred at `p`,
given the texels its texture coordinate reads from the coverage page, the
colour page and the image. `srgb` is the view's flag.
*/
vec4 shade(vec2 p, vec4 box, vec4 fill, vec4 edge, vec4 shape, vec4 coverageTexel,
    vec4 colourTexel, vec4 imageTexel, float srgb)
{
    const kind = shape.x;
    if (kind < 0.5f)
        return premultiplied(fill, 1.0f, srgb);
    if (kind < 1.5f)
    {
        // The border is a ring outside the box, its outer edge the box grown
        // by the thickness with the radius grown by it too.
        const t = shape.z;
        const inner = roundedBoxCoverage(p, box, shape.y);
        const outer = t > 0.0f
            ? roundedBoxCoverage(p, v4(box.x - t, box.y - t, box.z + 2.0f * t, box.w + 2.0f * t),
                shape.y + t)
            : inner;
        return over(premultiplied(edge, outer - inner, srgb), premultiplied(fill, inner, srgb));
    }
    if (kind < 2.5f)
    {
        const apex = v2(box.x + box.z * 0.5f, box.y);
        const left = v2(box.x, box.y + box.w);
        const right = v2(box.x + box.z, box.y + box.w);
        const stroke = max(strokeCoverage(p, left, apex), strokeCoverage(p, apex, right));
        return over(premultiplied(edge, stroke, srgb),
            premultiplied(fill, arrowCoverage(p, box), srgb));
    }
    if (kind < 3.5f)
        return glyphColour(fill, edge, coverageTexel.x, shape.y, shape.z, srgb);
    if (kind < 4.5f)
    {
        // Premultiplied already; straightened only to decode.
        const a = colourTexel.w;
        const straight = a > 0.0f ? v4(colourTexel.x / a, colourTexel.y / a, colourTexel.z / a, a)
            : v4(0.0f);
        return premultiplied(straight, fill.w, srgb);
    }
    if (kind < 5.5f)
        return premultiplied(imageTexel, fill.w, srgb);
    if (kind < 6.5f)
    {
        // Under the box, nothing: a window's shadow does not darken it.
        const hole = roundedBoxCoverage(p, box, shape.y);
        if (hole >= 1.0f)
            return v4(0.0f);
        const spread = edge.y;
        const thrown = v4(box.x - spread + edge.z, box.y - spread + edge.w,
            box.z + 2.0f * spread, box.w + 2.0f * spread);
        const r = shape.y > 0.0f ? max(shape.y + spread, 0.0f) : 0.0f;
        return premultiplied(fill, blurredBoxCoverage(p, thrown, r, edge.x) * (1.0f - hole), srgb);
    }
    return premultiplied(fill, 1.0f - roundedBoxCoverage(p, box, shape.y), srgb);
}
