/**
The toolkit's canvas drawn with Vulkan on `sparkles:wsi`.

$(UL
$(LI $(MREF sparkles,ui_vulkan,resources) — buffers and images bound to
    memory from `sparkles:vulkan`'s sub-allocator.)
$(LI $(MREF sparkles,ui_vulkan,frame_buffers) — per-frame buffer space over
    a frame arena's ranges.)
$(LI $(MREF sparkles,ui_vulkan,upload) — image uploads staged in a frame's
    buffer space and recorded before its rendering.))

The contract is `docs/specs/ui-vulkan/SPEC.md`.
*/
module sparkles.ui_vulkan;

public import sparkles.ui_vulkan.frame_buffers;
public import sparkles.ui_vulkan.resources;
public import sparkles.ui_vulkan.upload;
