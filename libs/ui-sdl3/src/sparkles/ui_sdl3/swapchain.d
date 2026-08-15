/**
The swapchain: choosing it, creating it, and surviving a resize.

Swapchain creation is four policy decisions — extent, surface format, present
mode, image count — wrapped in one Vulkan call. The decisions are where the
bugs live, and none of them needs a GPU to test, so each is a pure function
over the driver's reported capabilities and the Vulkan call is left thin.

Skia's Graphite backend consumes the images this produces, so the usage flags
and format chosen here are part of that contract rather than local taste.
*/
module sparkles.ui_sdl3.swapchain;

import expected : err, ok;

import sparkles.ui_sdl3.error;
import sparkles.ui_sdl3.sdl3_c;
import sparkles.ui_sdl3.vulkan_context;
import sparkles.ui_sdl3.window;
import sparkles.vulkan;

/**
The extent to create a swapchain at.

`currentExtent` is the surface's own answer, except when it is `0xFFFFFFFF` in
both axes — Vulkan's "the surface has no fixed size; the swapchain decides".
Several Wayland and RADV paths report exactly that, and a swapchain that trusts
it asks for a four-billion-pixel image. The window's pixel size is the answer
there, clamped to what the surface will actually accept.
*/
VkExtent2D chooseExtent(in VkSurfaceCapabilitiesKHR caps, in PixelSize windowPixels)
    @safe pure nothrow @nogc
{
    if (caps.currentExtent.width != uint.max)
        return caps.currentExtent;

    return VkExtent2D(
        width: clamp(cast(uint) windowPixels.width,
            caps.minImageExtent.width, caps.maxImageExtent.width),
        height: clamp(cast(uint) windowPixels.height,
            caps.minImageExtent.height, caps.maxImageExtent.height),
    );
}

private uint clamp(uint v, uint lo, uint hi) @safe pure nothrow @nogc
    => v < lo ? lo : (v > hi ? hi : v);

/**
The surface format to render into.

A UNORM back buffer is preferred over SRGB: Skia manages colour space itself,
and letting the swapchain also apply an sRGB transfer function double-corrects
everything it draws. `B8G8R8A8` first because it is what the common desktop
drivers report first, with `R8G8B8A8` as the equally-good sibling.

Falls back to whatever the surface offers first, which the spec guarantees is
non-empty for a supported surface.
*/
VkSurfaceFormatKHR chooseSurfaceFormat(scope const VkSurfaceFormatKHR[] available)
    @safe pure nothrow @nogc
in (available.length > 0, "a supported surface always reports at least one format")
{
    static immutable VkFormat[2] preferred = [
        VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
        VkFormat.VK_FORMAT_R8G8B8A8_UNORM,
    ];

    foreach (want; preferred)
        foreach (fmt; available)
            if (fmt.format == want
                && fmt.colorSpace == VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
                return fmt;

    return available[0];
}

/**
The present mode.

`FIFO` is the only mode the spec guarantees, and it is vsync. `MAILBOX` is
vsync without blocking the submitter — it replaces the queued frame rather than
waiting — which is what a UI wants when it can render faster than the display.
`IMMEDIATE` tears and is never chosen automatically.
*/
VkPresentModeKHR choosePresentMode(scope const VkPresentModeKHR[] available)
    @safe pure nothrow @nogc
{
    foreach (mode; available)
        if (mode == VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR)
            return mode;

    return VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR;
}

/**
How many images to ask for.

One more than the minimum, so the application can be drawing into one while the
presentation engine holds another; at exactly the minimum it may have to wait
for the driver every frame. `maxImageCount == 0` means "no limit".
*/
uint chooseImageCount(in VkSurfaceCapabilitiesKHR caps) @safe pure nothrow @nogc
{
    const wanted = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && wanted > caps.maxImageCount)
        return caps.maxImageCount;
    return wanted;
}

/**
A swapchain and the images it owns.

Not RAII over the device: teardown needs the `DeviceCommands` that created it,
so $(D destroy) takes the context rather than the destructor guessing.
*/
struct Swapchain
{
    VkSwapchainKHR handle;
    VkFormat format;
    VkColorSpaceKHR colorSpace;
    VkPresentModeKHR presentMode;
    VkExtent2D extent;

    /// The presentable images. Owned by the swapchain, not by us.
    VkImage[] images;

    @disable this(this);

    /**
    Create a swapchain sized for `windowPixels`.

    `previous` is passed to the driver as `oldSwapchain` so a resize can reuse
    its resources; it is destroyed here once the new one exists, which is the
    only order the spec allows.
    */
    static SdlExpected!() create(out Swapchain sc, ref VulkanContext vk,
        in PixelSize windowPixels, VkSwapchainKHR previous = null) @system nothrow
    {
        VkSurfaceCapabilitiesKHR caps;
        auto queried = vk.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
            vk.physicalDevice, vk.surface, &caps).check;
        if (queried.hasError)
            return err!void("vkGetPhysicalDeviceSurfaceCapabilitiesKHR: "
                ~ resultName(queried.error));

        auto formats = queryVkList!VkSurfaceFormatKHR(
            vk.instance.getPhysicalDeviceSurfaceFormatsKHR, vk.physicalDevice, vk.surface);
        if (formats.length == 0)
            return err!void("surface reports no formats");

        auto modes = queryVkList!VkPresentModeKHR(
            vk.instance.getPhysicalDeviceSurfacePresentModesKHR,
            vk.physicalDevice, vk.surface);

        const surfaceFormat = chooseSurfaceFormat(formats);
        sc.format = surfaceFormat.format;
        sc.colorSpace = surfaceFormat.colorSpace;
        sc.presentMode = choosePresentMode(modes);
        sc.extent = chooseExtent(caps, windowPixels);

        // A zero-area swapchain is invalid. It happens while a window is
        // minimised, and the caller's answer is to stop drawing, not to fail.
        if (sc.extent.width == 0 || sc.extent.height == 0)
            return err!void("swapchain extent is zero (window minimised?)");

        auto info = vkInfo(VkSwapchainCreateInfoKHR(
            surface: vk.surface,
            minImageCount: chooseImageCount(caps),
            imageFormat: sc.format,
            imageColorSpace: sc.colorSpace,
            imageExtent: sc.extent,
            imageArrayLayers: 1,
            // COLOR_ATTACHMENT to render into; TRANSFER_DST because Skia
            // resolves and blits into the presentable image on some paths.
            imageUsage: VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            imageSharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
            preTransform: caps.currentTransform,
            compositeAlpha: VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            presentMode: sc.presentMode,
            clipped: VK_TRUE,
            oldSwapchain: previous,
        ));

        auto created = vk.device.createSwapchainKHR(
            vk.device.device, &info, null, &sc.handle).check;

        // Whatever happened, the old swapchain is retired: on success the
        // driver has taken what it wanted from it, and on failure it is no
        // longer ours to reuse.
        if (previous !is null)
            vk.device.destroySwapchainKHR(vk.device.device, previous, null);

        if (created.hasError)
            return err!void("vkCreateSwapchainKHR: " ~ resultName(created.error));

        sc.images = queryVkList!VkImage(
            vk.device.getSwapchainImagesKHR, vk.device.device, sc.handle);
        if (sc.images.length == 0)
            return err!void("swapchain reports no images");

        return ok!string();
    }

    /**
    Acquire the next image index, signalling `available` when it is ready.

    `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` both mean "recreate",
    and are reported as the typed result rather than as failure — the caller
    decides whether to rebuild now or present one more stale frame.
    */
    VkExpected!uint acquire(ref VulkanContext vk, VkSemaphore available,
        ulong timeout = ulong.max) @system nothrow
    {
        uint index;
        const r = vk.device.acquireNextImageKHR(
            vk.device.device, handle, timeout, available, null, &index);
        return check(r, index);
    }

    /// Queue `imageIndex` for presentation once `finished` signals.
    VkExpected!VkResult present(ref VulkanContext vk, uint imageIndex,
        VkSemaphore finished) @system nothrow
    {
        auto sc = handle;
        auto sem = finished;
        auto info = vkInfo(VkPresentInfoKHR(
            waitSemaphoreCount: finished is null ? 0 : 1,
            pWaitSemaphores: finished is null ? null : &sem,
            swapchainCount: 1,
            pSwapchains: &sc,
            pImageIndices: &imageIndex,
        ));

        return checked(vk.device.queuePresentKHR(vk.queue, &info));
    }

    /// `true` when a result from $(D acquire) or $(D present) means "rebuild me".
    static bool needsRecreation(VkResult r) @safe pure nothrow @nogc
        => r == VkResult.VK_ERROR_OUT_OF_DATE_KHR
            || r == VkResult.VK_SUBOPTIMAL_KHR;

    /// Destroy the swapchain. The images go with it; they were never ours.
    void destroy(ref VulkanContext vk) @system nothrow
    {
        if (handle !is null && vk.device.destroySwapchainKHR !is null)
        {
            vk.device.destroySwapchainKHR(vk.device.device, handle, null);
            handle = null;
        }
        images = null;
    }
}

@("ui_sdl3.swapchain.extentHonoursTheSurfaceDefinedSentinel")
@safe pure nothrow @nogc unittest
{
    VkSurfaceCapabilitiesKHR caps;
    caps.minImageExtent = VkExtent2D(1, 1);
    caps.maxImageExtent = VkExtent2D(4096, 4096);

    // The ordinary case: the surface knows its own size and wins.
    caps.currentExtent = VkExtent2D(800, 600);
    assert(chooseExtent(caps, PixelSize(1920, 1080)) == VkExtent2D(800, 600));

    // The trap: 0xFFFFFFFF means "you decide". Trusting it verbatim asks for a
    // four-billion-pixel image; the window's pixels are the answer.
    caps.currentExtent = VkExtent2D(uint.max, uint.max);
    assert(chooseExtent(caps, PixelSize(1280, 720)) == VkExtent2D(1280, 720));

    // ... still clamped to what the surface will accept.
    assert(chooseExtent(caps, PixelSize(99_999, 99_999)) == VkExtent2D(4096, 4096));
    assert(chooseExtent(caps, PixelSize(0, 0)) == VkExtent2D(1, 1));
}

@("ui_sdl3.swapchain.formatPrefersUnormOverSrgb")
@safe pure nothrow @nogc unittest
{
    static VkSurfaceFormatKHR fmt(VkFormat f, VkColorSpaceKHR cs)
        => VkSurfaceFormatKHR(f, cs);

    enum srgbNonlinear = VkColorSpaceKHR.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;

    // Skia applies its own colour management, so an SRGB swapchain would
    // double-correct. UNORM is chosen even when SRGB is offered first.
    const VkSurfaceFormatKHR[2] both = [
        fmt(VkFormat.VK_FORMAT_B8G8R8A8_SRGB, srgbNonlinear),
        fmt(VkFormat.VK_FORMAT_B8G8R8A8_UNORM, srgbNonlinear),
    ];
    assert(chooseSurfaceFormat(both).format == VkFormat.VK_FORMAT_B8G8R8A8_UNORM);

    // BGRA is preferred over RGBA when both are present.
    const VkSurfaceFormatKHR[2] swapped = [
        fmt(VkFormat.VK_FORMAT_R8G8B8A8_UNORM, srgbNonlinear),
        fmt(VkFormat.VK_FORMAT_B8G8R8A8_UNORM, srgbNonlinear),
    ];
    assert(chooseSurfaceFormat(swapped).format == VkFormat.VK_FORMAT_B8G8R8A8_UNORM);

    // Nothing preferred on offer: take what there is rather than fail.
    const VkSurfaceFormatKHR[1] exotic =
        [fmt(VkFormat.VK_FORMAT_R5G6B5_UNORM_PACK16, srgbNonlinear)];
    assert(chooseSurfaceFormat(exotic).format == VkFormat.VK_FORMAT_R5G6B5_UNORM_PACK16);
}

@("ui_sdl3.swapchain.presentModePrefersMailboxFallsBackToFifo")
@safe pure nothrow @nogc unittest
{
    with (VkPresentModeKHR)
    {
        assert(choosePresentMode([VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_MAILBOX_KHR])
            == VK_PRESENT_MODE_MAILBOX_KHR);

        // FIFO is the only mode the spec guarantees, so it is the fallback —
        // including when the driver reports a tearing mode we never want.
        assert(choosePresentMode([VK_PRESENT_MODE_IMMEDIATE_KHR])
            == VK_PRESENT_MODE_FIFO_KHR);
        assert(choosePresentMode([]) == VK_PRESENT_MODE_FIFO_KHR);
    }
}

@("ui_sdl3.swapchain.imageCountIsOneAboveMinimumWithinBounds")
@safe pure nothrow @nogc unittest
{
    VkSurfaceCapabilitiesKHR caps;

    // One spare, so the app can draw while the compositor holds a frame.
    caps.minImageCount = 2;
    caps.maxImageCount = 0; // unlimited
    assert(chooseImageCount(caps) == 3);

    // ... but never past the driver's ceiling.
    caps.maxImageCount = 2;
    assert(chooseImageCount(caps) == 2);

    caps.minImageCount = 3;
    caps.maxImageCount = 8;
    assert(chooseImageCount(caps) == 4);
}

@("ui_sdl3.swapchain.suboptimalAndOutOfDateBothMeanRecreate")
@safe pure nothrow @nogc unittest
{
    with (VkResult)
    {
        // Out-of-date is a hard "you cannot present"; suboptimal still
        // presents but the swapchain no longer matches the surface. Both are
        // rebuild signals, and only one of them is an error code — which is
        // why `acquire` reports them as results rather than failures.
        assert(Swapchain.needsRecreation(VK_ERROR_OUT_OF_DATE_KHR));
        assert(Swapchain.needsRecreation(VK_SUBOPTIMAL_KHR));
        assert(!Swapchain.needsRecreation(VK_SUCCESS));
        assert(!Swapchain.needsRecreation(VK_ERROR_DEVICE_LOST));
    }
}
