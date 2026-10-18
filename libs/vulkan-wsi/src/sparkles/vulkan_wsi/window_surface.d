/**
The surface-scoped half of Vulkan presentation (§10.1): one `VkSurfaceKHR` on a
process-scoped `VulkanDevice`, for one native surface of a window.

A window can have a series of surfaces (an Android window gains one on each
return from the background), so making one costs only the `VkSurfaceKHR` and a
check that the device's queue presents to it. A `WindowSurface` is also the
context the swapchain, its render target, its frame synchronization and its
command pool are built from: it answers for the device it was made on.
*/
module sparkles.vulkan_wsi.window_surface;

import sparkles.vulkan;
import sparkles.vulkan_wsi.device : VulkanDevice;
import sparkles.vulkan_wsi.error;
import sparkles.vulkan_wsi.surface : createNativeSurface;
import sparkles.wsi : NativeHandles;

@safe:

/// One native surface of a window, on a process-scoped device.
struct WindowSurface
{
    private VulkanDevice* owner_;
    VkSurfaceKHR surface;

    @disable this(this);

    ~this() @trusted nothrow
    {
        destroy();
    }

    /**
    Makes the Vulkan surface for the window whose handles are `handles`, on
    `device`, which must outlive it and not move. Fails with
    `noPresentDevice` when the device's queue cannot present to it.
    */
    static VulkanWsiResult!void create(out WindowSurface s, ref VulkanDevice device,
        in NativeHandles handles) @trusted nothrow
    {
        auto made = createNativeSurface(device.instance, handles);
        if (made.hasError)
            return vulkanWsiErr!void(made.error);
        s.owner_ = &device;
        s.surface = made.value;
        VkBool32 presentable;
        if (device.instance.getPhysicalDeviceSurfaceSupportKHR(device.physicalDevice,
                device.queueFamily, s.surface, &presentable) < 0 || !presentable)
        {
            s.destroy();
            return device.fail(VulkanWsiErrorKind.noPresentDevice,
                VulkanWsiOperation.selectDevice, VkResult.VK_SUCCESS,
                "the device's queue cannot present to this surface");
        }
        return vulkanWsiOk();
    }

    /// Destroys the surface; idempotent. Destroy its swapchain first.
    void destroy() @trusted nothrow
    {
        if (surface !is null && owner_ !is null && owner_.instance.destroySurfaceKHR !is null)
            owner_.instance.destroySurfaceKHR(owner_.instance.instance, surface, null);
        surface = null;
    }

    // The device's members, as the swapchain and its companions read them.
    ref inout(DeviceCommands) device() inout return pure nothrow @nogc => owner_.device;
    ref inout(InstanceCommands) instance() inout return pure nothrow @nogc => owner_.instance;
    VkPhysicalDevice physicalDevice() pure nothrow @nogc => owner_.physicalDevice;
    VkQueue queue() pure nothrow @nogc => owner_.queue;
    uint queueFamily() const pure nothrow @nogc => owner_.queueFamily;
    bool dynamicRendering() const pure nothrow @nogc => owner_.dynamicRendering;
    VkPipelineCache pipelineCache() pure nothrow @nogc => owner_.pipelineCache;
}

@("vulkan_wsi.window_surface.destroyIsIdempotentWithoutHandles")
@system nothrow unittest
{
    WindowSurface surface;
    surface.destroy();
    surface.destroy();
    assert(surface.surface is null);
}
