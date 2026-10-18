/**
A device and one surface together: the shape of a single-window desktop
program, which makes both at once.

`VulkanContext` is a `VulkanDevice` chosen for a first surface (its queue must
present to it) plus that surface. A program with more than one surface over
its life, or one that makes its device before its window has a surface (an
Android activity), uses `VulkanDevice` and `WindowSurface` directly (§10.1).
*/
module sparkles.vulkan_wsi.context;

public import sparkles.vulkan_wsi.device : ContextRequest;

import sparkles.vulkan;
import sparkles.vulkan_wsi.device : VulkanDevice;
import sparkles.vulkan_wsi.error;
import sparkles.vulkan_wsi.surface;
import sparkles.wsi : NativeHandles;

@safe:

/**
The Vulkan objects whose selection depends on a native surface.

The window/display remain owned by `sparkles:wsi`. This object owns the Vulkan
surface and destroys it before the instance, so WSI must outlive the context.
On Wayland, creation and every surface/swapchain query must run between
`WaylandWsi.beginNativeIo` and `WaylandWsi.endNativeIo`: Vulkan drivers may
perform a private round trip on the shared display.
*/
struct VulkanContext
{
    VulkanDevice base;
    alias base this;
    VkSurfaceKHR surface;

    @disable this(this);

    ~this() @trusted nothrow
    {
        destroy();
    }

    static VulkanWsiResult!void create(out VulkanContext context,
        in NativeHandles handles,
        in ContextRequest request = ContextRequest.init) @trusted nothrow
    {
        auto planned = planNativeSurface(handles);
        if (planned.hasError)
            return vulkanWsiErr!void(planned.error);

        auto madeInstance = context.base.createInstance(planned.value.backend, request);
        if (madeInstance.hasError)
        {
            context.destroy();
            return madeInstance;
        }

        auto madeSurface = createNativeSurface(context.base.instance, handles);
        if (madeSurface.hasError)
        {
            context.destroy();
            return vulkanWsiErr!void(madeSurface.error);
        }
        context.surface = madeSurface.value;

        // The device is chosen for this surface: its queue must present to it.
        auto madeDevice = context.base.selectAndCreateDevice(request,
            (VkPhysicalDevice physical, uint family) {
                VkBool32 presentable;
                return context.base.instance.getPhysicalDeviceSurfaceSupportKHR(
                    physical, family, context.surface, &presentable) >= 0 && presentable;
            });
        if (madeDevice.hasError)
        {
            context.destroy();
            return madeDevice;
        }
        return vulkanWsiOk();
    }

    /// Releases the device, then the surface, then the instance; idempotent.
    void destroy() @trusted nothrow
    {
        base.releaseDevice();
        if (surface !is null && base.instance.instance !is null
            && base.instance.destroySurfaceKHR !is null)
            base.instance.destroySurfaceKHR(base.instance.instance, surface, null);
        surface = null;
        base.releaseInstance();
    }
}

@("vulkan_wsi.context.destroyIsIdempotentWithoutHandles")
@system nothrow unittest
{
    VulkanContext context;
    context.destroy();
    context.destroy();
    assert(context.surface is null);
    assert(context.queueFamily == uint.max);
}
