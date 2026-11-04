/** Experimental analytic glyph coverage from a bounded geometry texture. */
@compute(CompileFor.deviceOnly) @profiles(vulkan13, vulkan11)
module sparkles.ui_vulkan.coverage_fragment;

import sparkles.shaders;
import sparkles.ui_vulkan.coverage_shading : CoverageAccumulator;
import sparkles.ui_vulkan.shading : Binding, CanvasView, shade, targetToDisplay;

/// Every band has the same padded stride: fetches execute uniformly within
/// each derivative quad, even when its fragments select different bands.
@fragment vec4 coverageFragment(@builtin(Builtin.fragCoord) vec4 position,
    @input vec4 vBox, @input vec4 vFill, @input vec4 vEdge, @input vec4 vShape,
    @input vec2 vTexCoord, @input vec4 vMeta, PushConstants!CanvasView view,
    @binding(Binding.coverage) Sampler2D geometry, @binding(Binding.nearest) SamplerState nearest)
{
    const at = targetToDisplay(v2(position.x, position.y), view.extent, view.turn);
    const local = floor(at - v2(vBox.x, vBox.y));
    const count = cast(int)floor(vMeta.y + 0.5f);
    const band = vMeta.w > 0.5f ? cast(int)clamp(floor(local.y / vMeta.w),
        0.0f, max(0.0f, -floor(-vBox.w / vMeta.w) - 1)) : 0;
    const first = cast(int)floor(vMeta.x + 0.5f) + band * count;
    const unionCoverage = vMeta.z > 0.5f;
    CoverageAccumulator accumulator;
    accumulator.clear();
    for (int i = 0; i < count; ++i)
    {
        const index = first + i;
        const uv = v2((cast(float)(index & 511) + 0.5f) / 512,
            (cast(float)(index >> 9) + 0.5f) / 256);
        accumulator.add(geometry.sample(nearest, uv), local, unionCoverage);
    }
    const coverage = accumulator.finish(unionCoverage);
    return shade(at, vBox, vFill, vEdge, vShape, v4(coverage, 0, 0, 0), v4(0), v4(0), view.srgb);
}
