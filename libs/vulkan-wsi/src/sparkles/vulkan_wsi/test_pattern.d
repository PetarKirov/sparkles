/**
A diagnostic test pattern for a window-system lane.

The pattern is computed per pixel in `shaders/test_pattern.frag` from one
push-constant block, $(LREF FrameContext): the display's size, its safe
insets, the swapchain's pre-transform and a frame counter. The fragment
shader undoes the pre-transform, so the pattern is laid out upright in display
pixels whether the compositor or the renderer turns the image, and the whole
swapchain image is drawn: a rotated swapchain keeps its panel-oriented extent.

What it shows, and how a capture of it is checked, is in the shader's header
and in `libs/wsi/scripts/check-test-pattern.d`.
*/
module sparkles.vulkan_wsi.test_pattern;

import expected : Expected;

import sparkles.vulkan;
import sparkles.vulkan_wsi.swapchain : Swapchain;
import sparkles.vulkan_wsi.triangle : Pipeline;

/// The shader's push-constant block, laid out as `std430` places it.
struct FrameContext
{
    float[2] resolution;   /// the display's size in physical pixels
    float[2] padding_;     /// `vec4` aligns to 16 bytes
    float[4] safeInsets;   /// left, top, right, bottom, in physical pixels
    uint preTransform;     /// the swapchain's `VkSurfaceTransformFlagBitsKHR`
    uint frameCount;       /// monotonic, for the liveness marks
}

static assert(FrameContext.sizeof == 40 && FrameContext.safeInsets.offsetof == 16
    && FrameContext.preTransform.offsetof == 32);

private static immutable uint[] testPatternVert =
    spirvWords(import("test_pattern.vert.spv"));
private static immutable uint[] testPatternFrag =
    spirvWords(import("test_pattern.frag.spv"));

/// Builds the test pattern's pipeline for the swapchain's format.
Expected!(void, string) createTestPattern(Context)(out Pipeline pipeline,
    ref Context vk, in Swapchain swapchain, VkRenderPass renderPass = null) @system
    => Pipeline.create(pipeline, vk, swapchain.format, renderPass,
        testPatternVert, testPatternFrag, cast(uint) FrameContext.sizeof,
        isSrgb(swapchain.format));

/// Whether the hardware encodes to sRGB on store: the pattern's 8-bit code
/// values are then decoded first, so the stored values are exactly them.
bool isSrgb(VkFormat format) @safe pure nothrow @nogc
{
    with (VkFormat) switch (format)
    {
        case VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_SRGB,
            VK_FORMAT_A8B8G8R8_SRGB_PACK32:
            return true;
        default:
            return false;
    }
}

/**
The swapchain image's extent seen upright: a 90° or 270° pre-transform turns
the panel-oriented image onto the display, so its width and height swap.
*/
VkExtent2D displayExtent(in Swapchain swapchain) @safe pure nothrow @nogc
{
    enum turned = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR
        | VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    return (swapchain.transform & turned) != 0
        ? VkExtent2D(swapchain.extent.height, swapchain.extent.width)
        : swapchain.extent;
}

@("vulkan_wsi.test_pattern.aTurnedSwapchainSwapsItsDisplayExtent")
@safe pure nothrow @nogc unittest
{
    Swapchain sc;
    sc.extent = VkExtent2D(1080, 2400);
    assert(displayExtent(sc) == VkExtent2D(1080, 2400));
    sc.transform = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR;
    assert(displayExtent(sc) == VkExtent2D(2400, 1080));
    sc.transform = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_180_BIT_KHR;
    assert(displayExtent(sc) == VkExtent2D(1080, 2400));
    assert(isSrgb(VkFormat.VK_FORMAT_R8G8B8A8_SRGB) && !isSrgb(VkFormat.VK_FORMAT_R8G8B8A8_UNORM));
}
