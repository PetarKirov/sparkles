/**
The canvas's fragment function. It samples, so it is device-only (`SHF1`):
everything it computes is `shade` of `sparkles.ui_vulkan.shading`, which the
host tests.

Every image is read before the kind is known, in uniform control flow, so no
sample depends on derivatives taken in a branch. Atlas pages are read
through the nearest-filtering sampler and images through the linear one
(`UVK21`, `UVK24`); the bindings are `Binding`'s.
*/
@compute(CompileFor.deviceOnly) @profiles(vulkan13, vulkan11)
module sparkles.ui_vulkan.canvas_fragment;

import sparkles.shaders;
import sparkles.ui_vulkan.shading : Binding, canvasVertex, CanvasView, shade;

/// The premultiplied colour the record leaves at this fragment.
@fragment vec4 canvasFragment(@builtin(Builtin.fragCoord) vec4 position,
    @input vec4 vBox, @input vec4 vFill, @input vec4 vEdge, @input vec4 vShape,
    @input vec2 vTexCoord, PushConstants!CanvasView canvasView,
    @binding(Binding.coverage) Sampler2D coveragePage, @binding(Binding.colour) Sampler2D colourPage,
    @binding(Binding.image) Sampler2D boundImage, @binding(Binding.nearest) SamplerState nearestSampler,
    @binding(Binding.linear) SamplerState linearSampler)
{
    const coverageTexel = coveragePage.sample(nearestSampler, vTexCoord);
    const colourTexel = colourPage.sample(nearestSampler, vTexCoord);
    const imageTexel = boundImage.sample(linearSampler, vTexCoord);
    return shade(v2(position.x, position.y), vBox, vFill, vEdge, vShape, coverageTexel,
        colourTexel, imageTexel, canvasView.srgb);
}

static assert(stagesLink!(canvasVertex, canvasFragment));
