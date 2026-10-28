/**
The toolkit's canvas drawn with Vulkan on `sparkles:wsi`.

$(UL
$(LI $(MREF sparkles,ui_vulkan,canvas) — the canvas: a frame's operations
    recorded into a command buffer and a target its host supplies.)
$(LI $(MREF sparkles,ui_vulkan,painter) — the batcher: operations to quad
    records and draw runs, in order, and the frame's degradation report.)
$(LI $(MREF sparkles,ui_vulkan,shading) — the shaders in D: the quad record,
    the vertex function, and the coverage and colour functions the fragment
    function composes.)
$(LI $(MREF sparkles,ui_vulkan,pipelines) — the device-scoped objects: layouts,
    samplers, and a pipeline per target format.)
$(LI $(MREF sparkles,ui_vulkan,resources) — buffers and images bound to
    memory from `sparkles:vulkan`'s sub-allocator.)
$(LI $(MREF sparkles,ui_vulkan,frame_buffers) — per-frame buffer space over
    a frame arena's ranges.)
$(LI $(MREF sparkles,ui_vulkan,upload) — image uploads staged in a frame's
    buffer space and recorded before its rendering.))

The contract is `docs/specs/ui-vulkan/SPEC.md`.
*/
module sparkles.ui_vulkan;

public import sparkles.ui_vulkan.canvas;
public import sparkles.ui_vulkan.frame_buffers;
public import sparkles.ui_vulkan.painter;
public import sparkles.ui_vulkan.pipelines;
public import sparkles.ui_vulkan.resources;
public import sparkles.ui_vulkan.shading;
public import sparkles.ui_vulkan.text_rendering;
public import sparkles.ui_vulkan.upload;
