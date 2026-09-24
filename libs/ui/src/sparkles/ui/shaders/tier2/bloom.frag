// The `bloom` built-in's passes (a tier-2 effect). HAND-WRITTEN: tier 2 has
// no per-cell twin for `shader-compile` to derive it from (`EFX20` binds tier
// 0), so this is a body, assembled in `effect.d` as
//     dialect prologue ~ "#define BLOOM_PASS n" ~ this file
// once per pass. `SAMPLE`/`OUT_COLOR` come from the prologue.
//
// Ported from the CRT's bloom (`CRT3`): separable, because a radius-r gaussian
// costs 2r taps in two passes instead of r*r in one; at half resolution,
// because a glow is low-frequency by definition.

uniform sampler2D texture0;
uniform sampler2D texture1;
uniform vec4 colDiffuse;
uniform vec2 uResolution;      // this pass's output, in pixels
uniform float uBloomThreshold; // luminance above which a pixel blooms
uniform float uBloomRadius;    // blur step, in output pixels
uniform float uBloomIntensity; // how much of the glow is added back

// A 9-tap gaussian, normalized — the row of Pascal's triangle that
// approximates sigma ~ 2 closely enough for a glow nobody measures.
const float w0 = 0.2270270270;
const float w1 = 0.1945945946;
const float w2 = 0.1216216216;
const float w3 = 0.0540540541;
const float w4 = 0.0162162162;

vec3 blur(vec2 uv, vec2 dir)
{
    vec2 s = dir * uBloomRadius / uResolution;
    vec3 sum = SAMPLE(texture0, uv).rgb * w0;
    sum += (SAMPLE(texture0, uv + s * 1.0).rgb + SAMPLE(texture0, uv - s * 1.0).rgb) * w1;
    sum += (SAMPLE(texture0, uv + s * 2.0).rgb + SAMPLE(texture0, uv - s * 2.0).rgb) * w2;
    sum += (SAMPLE(texture0, uv + s * 3.0).rgb + SAMPLE(texture0, uv - s * 3.0).rgb) * w3;
    sum += (SAMPLE(texture0, uv + s * 4.0).rgb + SAMPLE(texture0, uv - s * 4.0).rgb) * w4;
    return sum;
}

void main()
{
    vec2 uv = fragTexCoord;
#if BLOOM_PASS == 0
    // Bright-pass extraction, smoothly, so a pixel drifting across the cut
    // does not pop. A transparent pixel is black here, and contributes none.
    vec4 c = SAMPLE(texture0, uv);
    float lum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
    float keep = smoothstep(uBloomThreshold, uBloomThreshold + 0.25, lum) * c.a;
    OUT_COLOR = vec4(c.rgb * keep, 1.0);
#elif BLOOM_PASS == 1
    OUT_COLOR = vec4(blur(uv, vec2(1.0, 0.0)), 1.0);
#elif BLOOM_PASS == 2
    OUT_COLOR = vec4(blur(uv, vec2(0.0, 1.0)), 1.0);
#else
    // Composite: the bracket (texture0) with the blurred glow (texture1)
    // added. The glow also reaches pixels the subtree left transparent — a
    // halo around text on nothing is the point — so the alpha grows with it,
    // and the colour is un-premultiplied to survive the blend.
    vec4 base = SAMPLE(texture0, uv) * colDiffuse * fragColor;
    vec3 glow = SAMPLE(texture1, uv).rgb * uBloomIntensity;
    float ga = clamp(max(glow.r, max(glow.g, glow.b)), 0.0, 1.0);
    float a = base.a + ga * (1.0 - base.a);
    vec3 rgb = a > 0.0 ? (base.rgb * base.a + glow) / a : vec3(0.0);
    OUT_COLOR = vec4(min(rgb, vec3(1.0)), a);
#endif
}
