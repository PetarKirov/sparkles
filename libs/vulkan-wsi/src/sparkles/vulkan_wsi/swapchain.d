/**
The swapchain: choosing it, creating it, and surviving a resize.

Swapchain creation is four policy decisions — extent, surface format, present
mode, image count — wrapped in one Vulkan call. The decisions are where the
bugs live, and none of them needs a GPU to test, so each is a pure function
over the driver's reported capabilities and the Vulkan call is left thin.

Skia's Graphite backend consumes the images this produces, so the usage flags
and format chosen here are part of that contract rather than local taste.
*/
module sparkles.vulkan_wsi.swapchain;

import sparkles.base.expected : err, ok;

import sparkles.metadata.case_style : CaseStyle;
import sparkles.metadata.wire : WireCase;
import sparkles.vulkan;
import sparkles.vulkan_wsi.error;

version (unittest)
{
    import sparkles.vulkan_wsi.context : VulkanContext;
    import sparkles.wsi : PixelSize = PhysicalSize;
}

/**
The extent to create a swapchain at.

`currentExtent` is the surface's own answer, except when it is `0xFFFFFFFF` in
both axes — Vulkan's "the surface has no fixed size; the swapchain decides".
Several Wayland and RADV paths report exactly that, and a swapchain that trusts
it asks for a four-billion-pixel image. The window's pixel size is the answer
there, clamped to what the surface will actually accept.

A surface turned 90° or 270° from its panel (Android, with the display turned)
has images that keep the panel's orientation: they are created with
`preTransform` set to that turn and drawn pre-rotated, so their extent is the
window's with width and height swapped. Implementations disagree on which
orientation `currentExtent` reports then (the emulator's gives the display's,
Adreno the panel's), so the window's own pixels decide: of the current extent
and its swap, the one shaped opposite to the window. Without window pixels the
current extent is swapped, as Android's pre-rotation guide describes.
*/
VkExtent2D chooseExtent(Size)(in VkSurfaceCapabilitiesKHR caps,
    in Size windowPixels, in Size minAlloc = Size.init)
    @safe pure nothrow @nogc
{
    enum turned = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR
        | VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_270_BIT_KHR;
    if (caps.currentExtent.width != uint.max)
    {
        const current = caps.currentExtent;
        if ((caps.currentTransform & turned) == 0)
            return current;
        const swapped = VkExtent2D(current.height, current.width);
        const w = cast(uint) windowPixels.width, h = cast(uint) windowPixels.height;
        if (w == 0 || h == 0 || w == h)
            return swapped;
        // Shaped opposite to the window: tall for a wide window.
        return (w > h) == (current.height > current.width) ? current : swapped;
    }

    // The surface has no size of its own. `minAlloc` is the display-sized
    // pad: a swapchain created at that size can shrink with the window by
    // viewport alone, and only has to grow when the window exceeds it.
    auto width = maxU(cast(uint) windowPixels.width, cast(uint) minAlloc.width);
    auto height = maxU(cast(uint) windowPixels.height, cast(uint) minAlloc.height);
    return VkExtent2D(
        width: clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
        height: clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
    );
}

private uint clamp(uint v, uint lo, uint hi) @safe pure nothrow @nogc
    => v < lo ? lo : (v > hi ? hi : v);

private uint maxU(uint a, uint b) @safe pure nothrow @nogc => a > b ? a : b;

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

The one-argument form is that policy. The two-argument form honours
`preferred` when the surface offers it, and is what a CLI `--present-mode`
feeds; a missing preferred mode is the caller's error, not a silent
fallback — $(LREF offersPresentMode) is the check.
*/
VkPresentModeKHR choosePresentMode(scope const VkPresentModeKHR[] available)
    @safe pure nothrow @nogc
{
    foreach (mode; available)
        if (mode == VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR)
            return mode;

    return VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR;
}

/// ditto
VkPresentModeKHR choosePresentMode(scope const VkPresentModeKHR[] available,
    VkPresentModeKHR preferred) @safe pure nothrow @nogc
{
    if (offersPresentMode(available, preferred))
        return preferred;
    return choosePresentMode(available);
}

/// `true` when `mode` is in the surface's list.
bool offersPresentMode(scope const VkPresentModeKHR[] available, VkPresentModeKHR mode)
    @safe pure nothrow @nogc
{
    foreach (offered; available)
        if (offered == mode)
            return true;
    return false;
}

/// Sentinel for "no preference": $(LREF choosePresentMode) then picks.
enum VkPresentModeKHR anyPresentMode = cast(VkPresentModeKHR) uint.max;

/**
A present mode as a command line names it, `auto` included: `@WireCase`
kebab-cases the members (`fifoRelaxed` is `fifo-relaxed`), and the trailing
underscore of `auto_` is a word separator, so its name is `auto`. The values
are `VkPresentModeKHR`'s, and `auto_` is $(LREF anyPresentMode).
*/
@WireCase(CaseStyle.kebabCase)
enum PresentMode : uint
{
    immediate   = VkPresentModeKHR.VK_PRESENT_MODE_IMMEDIATE_KHR, ///
    mailbox     = VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR, ///
    fifo        = VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR, ///
    fifoRelaxed = VkPresentModeKHR.VK_PRESENT_MODE_FIFO_RELAXED_KHR, ///
    auto_       = anyPresentMode, /// the swapchain picks
}

/// The Vulkan present mode `mode` asks for; $(LREF anyPresentMode) for `auto`.
VkPresentModeKHR toVk(PresentMode mode) @safe pure nothrow @nogc
    => cast(VkPresentModeKHR) mode;

///
@("vulkan_wsi.swapchain.presentModeNamesTheVulkanOne")
@safe pure nothrow @nogc unittest
{
    assert(PresentMode.mailbox.toVk == VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR);
    assert(PresentMode.auto_.toVk == anyPresentMode);
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
What a resize should do with the swapchain we already have.

`wanted` is $(LREF chooseExtent)'s answer, so a minimised window on X11/Win32
is `0×0` here and a Wayland surface that reports the "you decide" sentinel has
already been clamped to the window's pixels (or to `minImageExtent`).

$(UL
$(LI $(D paused) — zero area. Keep the old swapchain; the caller stops drawing.)
$(LI $(D unchanged) — already at this extent, or $(D growOnly) and the
    wanted size fits inside the one we have. Skip the create. $(D force)
    disables this: an `OUT_OF_DATE` acquire at the same size (restore, rotation)
    still has to retire the handle the driver rejected.)
$(LI $(D rebuilt) — create a new swapchain, passing the old one as
    `oldSwapchain`.))
*/
enum SwapchainResize
{
    paused,
    unchanged,
    rebuilt,
}

/// ditto
SwapchainResize decideResize(bool hasSwapchain, VkExtent2D current, VkExtent2D wanted,
    bool force = false, bool growOnly = false) @safe pure nothrow @nogc
{
    if (wanted.width == 0 || wanted.height == 0)
        return SwapchainResize.paused;
    if (!hasSwapchain || force)
        return SwapchainResize.rebuilt;
    if (current.width == wanted.width && current.height == wanted.height)
        return SwapchainResize.unchanged;
    if (growOnly && wanted.width <= current.width && wanted.height <= current.height)
        return SwapchainResize.unchanged;
    return SwapchainResize.rebuilt;
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
    /// What the images were created for: a renderer that names them (an
    /// imageless framebuffer) needs it, and a readback needs `TRANSFER_SRC`.
    VkImageUsageFlags usage;
    /// How the presentation engine turns the images onto the display: the
    /// surface's `currentTransform` when the swapchain was built. On
    /// Android it is a rotation while the display is turned from its panel's
    /// orientation; the images keep the panel's, and the renderer draws into
    /// them pre-rotated rather than leaving the turn to the compositor.
    VkSurfaceTransformFlagBitsKHR transform =
        VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;

    /// The presentable images. Owned by the swapchain, not by us.
    VkImage[] images;

    /**
    The owner's count of what it has presented, which a handle retired by
    $(LREF recreate) is stamped with, so $(LREF reapThrough) can destroy each
    once enough has been presented after it, however many rebuilds follow.
    */
    ulong epoch;

    /**
    Whether the images' alpha is to reach the compositor, for a window that
    is transparent where it draws nothing — a client-drawn frame's shadow
    and rounded corners. Read by $(LREF create) and by each $(LREF recreate);
    what the surface allowed is $(LREF compositeAlpha).
    */
    bool wantsAlpha;

    /// How the presentation engine composites the images' alpha, as
    /// $(LREF chooseCompositeAlpha) chose it.
    VkCompositeAlphaFlagBitsKHR compositeAlpha =
        VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;

    /**
    Previous handles retired by $(LREF recreate), and the `epoch` each was
    retired at. A present may still be scanning their images, so they
    cannot be destroyed until the queue is done with them — see $(LREF reap).
    */
    private VkSwapchainKHR[] _retired;
    private ulong[] _retiredAt; // ditto

    @disable this(this);

    /**
    Create a swapchain sized for `windowPixels`.

    `previous` is passed to the driver as `oldSwapchain` so a resize can reuse
    its resources. Prefer $(LREF recreate) for a live swapchain: it retires
    the old handle instead of destroying it while a present may still hold
    its images.
    */
    static PresentationResult!void create(Context, Size)(ref Swapchain sc,
        ref Context vk, in Size windowPixels, VkSwapchainKHR previous = null,
        in Size minAlloc = Size.init,
        VkPresentModeKHR preferredPresentMode = anyPresentMode) @system nothrow
    {
        VkSurfaceCapabilitiesKHR caps;
        auto queried = vk.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
            vk.physicalDevice, vk.surface, &caps).check;
        if (queried.hasError)
            return err!void("vkGetPhysicalDeviceSurfaceCapabilitiesKHR: "
                ~ describeResult(queried.error));

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
        if (preferredPresentMode != anyPresentMode)
        {
            if (!offersPresentMode(modes, preferredPresentMode))
                return err!void("present mode `" ~ presentModeName(preferredPresentMode)
                    ~ "` is not available");
            sc.presentMode = preferredPresentMode;
        }
        else
            sc.presentMode = choosePresentMode(modes);
        sc.extent = chooseExtent(caps, windowPixels, minAlloc);
        // COLOR_ATTACHMENT to render into; TRANSFER_DST because Skia
        // resolves and blits into the presentable image on some paths;
        // TRANSFER_SRC, where the surface allows it, so a frame can be read
        // back (a screenshot).
        sc.usage = VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT
            | (caps.supportedUsageFlags & VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
        sc.compositeAlpha = chooseCompositeAlpha(caps.supportedCompositeAlpha, sc.wantsAlpha);

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
            imageUsage: sc.usage,
            imageSharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
            preTransform: caps.currentTransform,
            compositeAlpha: sc.compositeAlpha,
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
            return err!void("vkCreateSwapchainKHR: " ~ describeResult(created.error));
        sc.transform = caps.currentTransform;

        sc.images = queryVkList!VkImage(
            vk.device.getSwapchainImagesKHR, vk.device.device, sc.handle);
        if (sc.images.length == 0)
            return err!void("swapchain reports no images");

        return ok!string();
    }

    /**
    Whether the surface now wants another swapchain than this one: another
    extent for `windowPixels`, or another transform. It queries the surface's
    capabilities and waits for nothing, so a renderer can ask before every
    frame. That is what a turned Android display needs: the window's new size
    and the surface's new transform arrive separately, a rebuild made between
    them is shaped for neither, and a size mismatch is not an error the
    present reports.
    */
    bool outdated(Context, Size)(ref Context vk, in Size windowPixels,
        in Size minAlloc = Size.init) @system nothrow
    {
        if (handle is null)
            return true;
        VkSurfaceCapabilitiesKHR caps;
        if (vk.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
                vk.physicalDevice, vk.surface, &caps) < 0)
            return false;
        const wanted = chooseExtent(caps, windowPixels, minAlloc);
        return caps.currentTransform != transform
            || wanted.width != extent.width || wanted.height != extent.height;
    }

    /**
    Rebuild this swapchain for a new window size, without re-asking the
    surface what it can do.

    Format, colour space and present mode do not change with the window, so
    the two enumerations `create` does are skipped. Capabilities are still
    queried — `currentExtent` / `currentTransform` / the image-count bounds
    are the resize. `oldSwapchain` is this handle, so the driver can keep
    presenting the old images until it has finished with them. The old
    handle is not destroyed here —
    `VUID-vkDestroySwapchainKHR-swapchain-01282` forbids that while a
    present is still using its images. $(LREF reap) destroys the retired
    set once the queue is idle.

    `force` is the acquire/present `OUT_OF_DATE` path: same pixel size still
    recreates, because the driver has retired this handle. A `PIXEL_SIZE_CHANGED`
    drain leaves it false so a drag that reports the same size twice does not
    build a swapchain for nothing.

    The caller must have waited for every in-flight fence before this returns
    $(D rebuilt). Views and framebuffers name the old images; creating the new
    swapchain does not wait for them.

    `minAlloc` pads a surface-defined extent up to the display size so a
    shrink is a viewport change, not a create. Ignored when the surface
    names its own `currentExtent`. `growOnly` keeps a larger swapchain when
    the window shrinks; the default is off so a shrink rebuilds to the
    window (a scaled pad letterboxes or stamps on compositors that scale
    the whole image).
    */
    static PresentationResult!SwapchainResize recreate(Context, Size)(
        ref Swapchain sc, ref Context vk, in Size windowPixels,
        bool force = false, in Size minAlloc = Size.init,
        VkPresentModeKHR preferredPresentMode = anyPresentMode,
        bool growOnly = false) @system nothrow
    {
        VkSurfaceCapabilitiesKHR caps;
        auto queried = vk.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
            vk.physicalDevice, vk.surface, &caps).check;
        if (queried.hasError)
            return err!SwapchainResize("vkGetPhysicalDeviceSurfaceCapabilitiesKHR: "
                ~ describeResult(queried.error));

        if (sc.handle is null)
        {
            auto first = decideResize(false, VkExtent2D.init,
                chooseExtent(caps, windowPixels, minAlloc), force);
            if (first != SwapchainResize.rebuilt)
                return ok!string(first);

            auto made = create(sc, vk, windowPixels, null, minAlloc, preferredPresentMode);
            return made.hasError
                ? err!SwapchainResize(made.error)
                : ok!string(SwapchainResize.rebuilt);
        }

        const extent = chooseExtent(caps, windowPixels, minAlloc);
        // A turned display can keep the extent and change only the
        // transform; the images must then be rebuilt for it all the same.
        const turned = caps.currentTransform != sc.transform;
        auto action = decideResize(true, sc.extent, extent, force || turned, growOnly);
        if (action != SwapchainResize.rebuilt)
            return ok!string(action);

        auto previous = sc.handle;
        // Chosen again: a window that comes to want alpha (a client frame
        // after fullscreen) gains it at its next rebuild.
        sc.compositeAlpha = chooseCompositeAlpha(caps.supportedCompositeAlpha, sc.wantsAlpha);
        auto info = vkInfo(VkSwapchainCreateInfoKHR(
            surface: vk.surface,
            minImageCount: chooseImageCount(caps),
            imageFormat: sc.format,
            imageColorSpace: sc.colorSpace,
            imageExtent: extent,
            imageArrayLayers: 1,
            // The usage `create` chose and `usage` reports: a reader of the
            // images (the canvas's loupe) copies from them by it.
            imageUsage: sc.usage,
            imageSharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
            preTransform: caps.currentTransform,
            compositeAlpha: sc.compositeAlpha,
            presentMode: sc.presentMode,
            clipped: VK_TRUE,
            oldSwapchain: previous,
        ));

        VkSwapchainKHR next;
        auto created = vk.device.createSwapchainKHR(
            vk.device.device, &info, null, &next).check;

        // Retired either way: on success the driver has taken what it wanted,
        // and on failure the spec still retires oldSwapchain. Destroying it
        // here would race any present still scanning its images.
        sc._retired ~= previous;
        sc._retiredAt ~= sc.epoch;
        sc.handle = null;
        sc.images = null;

        if (created.hasError)
            return err!SwapchainResize("vkCreateSwapchainKHR: "
                ~ describeResult(created.error));

        sc.handle = next;
        sc.extent = extent;
        sc.transform = caps.currentTransform;
        sc.images = queryVkList!VkImage(
            vk.device.getSwapchainImagesKHR, vk.device.device, sc.handle);
        if (sc.images.length == 0)
            return err!SwapchainResize("swapchain reports no images");

        return ok!string(SwapchainResize.rebuilt);
    }

    /// `true` when $(LREF reap) has retired swapchains to destroy.
    bool hasRetired() const @safe pure nothrow @nogc => _retired.length > 0;

    /**
    Destroy swapchains retired by $(LREF recreate).

    The queue must already be done with those images — wait a few quiet
    frames after the last rebuild, or `queueWaitIdle` first. `limit` caps
    how many handles this call destroys so a pile of 5K swapchains is not
    torn down in one frame. $(LREF FrameSync.reap) has the same contract.
    */
    void reap(Context)(ref Context vk, uint limit = uint.max) @system nothrow
    {
        if (_retired.length == 0 || vk.device.device is null
            || vk.device.destroySwapchainKHR is null)
            return;

        uint n;
        foreach (h; _retired)
        {
            if (n >= limit)
                break;
            if (h !is null)
                vk.device.destroySwapchainKHR(vk.device.device, h, null);
            n++;
        }
        _retired = n >= _retired.length ? null : _retired[n .. $];
        _retiredAt = n >= _retiredAt.length ? null : _retiredAt[n .. $];
    }

    /**
    Destroy the swapchains retired at `epoch` or before — the oldest first,
    as they were retired — and keep the rest. The caller picks an `epoch`
    the queue is done with; the contract is $(LREF reap)'s.
    */
    void reapThrough(Context)(ref Context vk, ulong epoch) @system nothrow
    {
        uint n;
        while (n < _retiredAt.length && _retiredAt[n] <= epoch)
            n++;
        if (n)
            reap(vk, n);
    }

    /**
    Acquire the next image index, signalling `available` when it is ready.

    `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` both mean "recreate",
    and are reported as the typed result rather than as failure — the caller
    decides whether to rebuild now or present one more stale frame.
    */
    VkExpected!uint acquire(Context)(ref Context vk, VkSemaphore available,
        ulong timeout = ulong.max) @system nothrow
    {
        uint index;
        const r = vk.device.acquireNextImageKHR(
            vk.device.device, handle, timeout, available, null, &index);
        return check(r, index);
    }

    /// Queue `imageIndex` for presentation once `finished` signals.
    VkExpected!VkResult present(Context)(ref Context vk, uint imageIndex,
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

    /**
    How a swapchain's alpha is composited, from what the surface `supported`:
    premultiplied where `wantsAlpha` and the surface allows it — the canvas
    draws premultiplied colour — else opaque, else whatever the surface
    offers (an Android surface may offer only `INHERIT`).
    */
    static VkCompositeAlphaFlagBitsKHR chooseCompositeAlpha(VkCompositeAlphaFlagsKHR supported,
        bool wantsAlpha) @safe pure nothrow @nogc
    {
        with (VkCompositeAlphaFlagBitsKHR)
        {
            if (wantsAlpha && (supported & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR))
                return VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
            foreach (bit; [VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
                    VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR, VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR])
                if (supported & bit)
                    return bit;
            return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        }
    }

    /// `true` when a result from $(D acquire) or $(D present) means "rebuild me".
    static bool needsRecreation(VkResult r) @safe pure nothrow @nogc
        => r == VkResult.VK_ERROR_OUT_OF_DATE_KHR
            || r == VkResult.VK_SUBOPTIMAL_KHR;

    /// Destroy the swapchain. The images go with it; they were never ours.
    void destroy(Context)(ref Context vk) @system nothrow
    {
        reap(vk);
        if (handle !is null && vk.device.destroySwapchainKHR !is null)
        {
            vk.device.destroySwapchainKHR(vk.device.device, handle, null);
            handle = null;
        }
        images = null;
    }
}

@("vulkan_wsi.swapchain.extentHonoursTheSurfaceDefinedSentinel")
@safe pure nothrow @nogc unittest
{
    VkSurfaceCapabilitiesKHR caps;
    caps.minImageExtent = VkExtent2D(1, 1);
    caps.maxImageExtent = VkExtent2D(4096, 4096);

    // The ordinary case: the surface knows its own size and wins.
    caps.currentExtent = VkExtent2D(800, 600);
    assert(chooseExtent(caps, PixelSize(1920, 1080)) == VkExtent2D(800, 600));
    // A turned surface reports the display's orientation; the images keep the
    // panel's.
    caps.currentTransform = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_ROTATE_90_BIT_KHR;
    // The display's orientation reported (the emulator)...
    caps.currentExtent = VkExtent2D(800, 600);
    assert(chooseExtent(caps, PixelSize(800, 600)) == VkExtent2D(600, 800));
    // ...or the panel's (Adreno): either way the images are tall.
    caps.currentExtent = VkExtent2D(600, 800);
    assert(chooseExtent(caps, PixelSize(800, 600)) == VkExtent2D(600, 800));
    // No window pixels: Android's documented swap.
    assert(chooseExtent(caps, PixelSize(0, 0)) == VkExtent2D(800, 600));
    caps.currentExtent = VkExtent2D(800, 600);
    caps.currentTransform = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;

    // The trap: 0xFFFFFFFF means "you decide". Trusting it verbatim asks for a
    // four-billion-pixel image; the window's pixels are the answer.
    caps.currentExtent = VkExtent2D(uint.max, uint.max);
    assert(chooseExtent(caps, PixelSize(1280, 720)) == VkExtent2D(1280, 720));

    // ... still clamped to what the surface will accept.
    assert(chooseExtent(caps, PixelSize(99_999, 99_999)) == VkExtent2D(4096, 4096));
    assert(chooseExtent(caps, PixelSize(0, 0)) == VkExtent2D(1, 1));

    // A display-sized pad: the window is 800×600, we pre-allocate 1920×1080
    // so a later shrink is a viewport change. The surface-defined sentinel
    // is what makes this legal; a named currentExtent still wins.
    assert(chooseExtent(caps, PixelSize(800, 600), PixelSize(1920, 1080))
        == VkExtent2D(1920, 1080));
    caps.currentExtent = VkExtent2D(800, 600);
    assert(chooseExtent(caps, PixelSize(800, 600), PixelSize(1920, 1080))
        == VkExtent2D(800, 600));
}

@("vulkan_wsi.swapchain.formatPrefersUnormOverSrgb")
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

@("vulkan_wsi.swapchain.presentModePrefersMailboxFallsBackToFifo")
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

        // A named preference wins when the surface offers it, and is
        // ignored (mailbox-or-fifo) when it does not — the create path
        // rejects a missing preference before it gets here.
        assert(choosePresentMode(
            [VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR],
            VK_PRESENT_MODE_IMMEDIATE_KHR) == VK_PRESENT_MODE_IMMEDIATE_KHR);
        assert(choosePresentMode(
            [VK_PRESENT_MODE_FIFO_KHR],
            VK_PRESENT_MODE_MAILBOX_KHR) == VK_PRESENT_MODE_FIFO_KHR);

        assert(offersPresentMode([VK_PRESENT_MODE_FIFO_KHR], VK_PRESENT_MODE_FIFO_KHR));
        assert(!offersPresentMode([VK_PRESENT_MODE_FIFO_KHR], VK_PRESENT_MODE_MAILBOX_KHR));
        assert(!offersPresentMode([], VK_PRESENT_MODE_FIFO_KHR));
    }
}

@("vulkan_wsi.swapchain.imageCountIsOneAboveMinimumWithinBounds")
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

@("vulkan_wsi.swapchain.suboptimalAndOutOfDateBothMeanRecreate")
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

@("vulkan_wsi.swapchain.decideResizePausesOnZeroAndSkipsAMatchingExtent")
@safe pure nothrow @nogc unittest
{
    const at = VkExtent2D(800, 600);

    // No swapchain yet: a real size builds, a minimise does not.
    assert(decideResize(false, VkExtent2D.init, at) == SwapchainResize.rebuilt);
    assert(decideResize(false, VkExtent2D.init, VkExtent2D(0, 0))
        == SwapchainResize.paused);
    assert(decideResize(true, at, VkExtent2D(0, 540)) == SwapchainResize.paused);

    // The hot path during a drag: PIXEL_SIZE_CHANGED for a size we already
    // built. Recreating would wait on in-flight fences for nothing.
    assert(decideResize(true, at, at) == SwapchainResize.unchanged);
    assert(decideResize(true, at, VkExtent2D(1280, 720)) == SwapchainResize.rebuilt);

    // OUT_OF_DATE at the same pixel size (restore, rotation) still rebuilds —
    // the driver has retired this handle, matching extent or not.
    assert(decideResize(true, at, at, true) == SwapchainResize.rebuilt);
    assert(decideResize(true, at, VkExtent2D(0, 0), true) == SwapchainResize.paused);

    // growOnly: a shrink fits inside the padded swapchain; a grow does not.
    assert(decideResize(true, at, VkExtent2D(640, 480), false, true)
        == SwapchainResize.unchanged);
    assert(decideResize(true, at, VkExtent2D(1280, 720), false, true)
        == SwapchainResize.rebuilt);
    assert(decideResize(true, at, VkExtent2D(640, 480), true, true)
        == SwapchainResize.rebuilt, "force still wins over growOnly");
}

@("vulkan_wsi.swapchain.hasRetiredTracksTheRetiredList")
@safe nothrow unittest
{
    Swapchain sc;
    assert(!sc.hasRetired);
    sc._retired = new VkSwapchainKHR[2];
    assert(sc.hasRetired);
    sc._retired = null;
    assert(!sc.hasRetired);
}

version (unittest)
{
    // A device that only counts the swapchains destroyed on it.
    private struct CountingDevice
    {
        VkDevice device = cast(VkDevice) cast(void*) 1;
        extern (C) void function(VkDevice, VkSwapchainKHR, const(VkAllocationCallbacks)*) nothrow
            destroySwapchainKHR = &countDestroyedSwapchain;
    }

    private struct CountingVk
    {
        CountingDevice device;
    }

    private __gshared size_t destroyedSwapchains;

    private extern (C) void countDestroyedSwapchain(VkDevice, VkSwapchainKHR h, const(VkAllocationCallbacks)*)
        nothrow
    {
        if (h !is null)
            ++destroyedSwapchains;
    }
}

@("vulkan_wsi.swapchain.reapThroughTakesOnlyWhatIsOldEnough")
@system nothrow unittest
{
    // Three rebuilds in three frames: each retiree goes once its own epoch
    // is old enough, whatever followed it — a resize that rebuilds every
    // frame does not keep every swapchain alive until it stops.
    Swapchain sc;
    CountingVk vk;
    destroyedSwapchains = 0;
    foreach (epoch; [10UL, 11, 12])
    {
        sc._retired ~= cast(VkSwapchainKHR) cast(void*) epoch;
        sc._retiredAt ~= epoch;
    }
    sc.reapThrough(vk, 9);
    assert(destroyedSwapchains == 0 && sc._retired.length == 3);
    sc.reapThrough(vk, 11);
    assert(destroyedSwapchains == 2 && sc._retired.length == 1 && sc._retiredAt == [12]);
    sc.reapThrough(vk, 100);
    assert(destroyedSwapchains == 3 && !sc.hasRetired && sc._retiredAt.length == 0);
}

version (unittest)
{
    // A context that answers what `recreate` asks, and keeps the create info
    // it was given.
    private __gshared VkSwapchainCreateInfoKHR lastCreate;

    private struct RecreateInstance
    {
        extern (C) VkResult function(VkPhysicalDevice, VkSurfaceKHR, VkSurfaceCapabilitiesKHR*)
            nothrow getPhysicalDeviceSurfaceCapabilitiesKHR = &fakeCaps;
        // What only `create` asks, which `recreate` reaches for a first build.
        extern (C) VkResult function(VkPhysicalDevice, VkSurfaceKHR, uint*, VkSurfaceFormatKHR*)
            nothrow getPhysicalDeviceSurfaceFormatsKHR;
        extern (C) VkResult function(VkPhysicalDevice, VkSurfaceKHR, uint*, VkPresentModeKHR*)
            nothrow getPhysicalDeviceSurfacePresentModesKHR;
    }

    private struct RecreateDevice
    {
        VkDevice device = cast(VkDevice) cast(void*) 1;
        extern (C) VkResult function(VkDevice, const(VkSwapchainCreateInfoKHR)*,
            const(VkAllocationCallbacks)*, VkSwapchainKHR*) nothrow createSwapchainKHR = &fakeCreate;
        extern (C) VkResult function(VkDevice, VkSwapchainKHR, uint*, VkImage*) nothrow
            getSwapchainImagesKHR = &fakeImages;
        extern (C) void function(VkDevice, VkSwapchainKHR, const(VkAllocationCallbacks)*) nothrow
            destroySwapchainKHR;
    }

    private struct RecreateVk
    {
        RecreateInstance instance;
        RecreateDevice device;
        VkPhysicalDevice physicalDevice;
        VkSurfaceKHR surface;
    }

    private extern (C) VkResult fakeCaps(VkPhysicalDevice, VkSurfaceKHR,
        VkSurfaceCapabilitiesKHR* caps) nothrow
    {
        *caps = VkSurfaceCapabilitiesKHR.init;
        caps.minImageCount = 2;
        caps.maxImageCount = 4;
        caps.currentExtent = VkExtent2D(640, 480);
        caps.minImageExtent = VkExtent2D(1, 1);
        caps.maxImageExtent = VkExtent2D(4096, 4096);
        caps.currentTransform = VkSurfaceTransformFlagBitsKHR.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        caps.supportedCompositeAlpha = VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
            | VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
        return VkResult.VK_SUCCESS;
    }

    private extern (C) VkResult fakeCreate(VkDevice, const(VkSwapchainCreateInfoKHR)* info,
        const(VkAllocationCallbacks)*, VkSwapchainKHR* made) nothrow
    {
        lastCreate = cast() *info;
        *made = cast(VkSwapchainKHR) cast(void*) 0x2;
        return VkResult.VK_SUCCESS;
    }

    private extern (C) VkResult fakeImages(VkDevice, VkSwapchainKHR, uint* count, VkImage* images)
        nothrow
    {
        if (images !is null)
            foreach (i; 0 .. *count)
                images[i] = cast(VkImage) cast(void*)(0x10 + i);
        else
            *count = 2;
        return VkResult.VK_SUCCESS;
    }
}

@("vulkan_wsi.swapchain.recreateKeepsTheImagesUsage")
@system nothrow unittest
{
    // A swapchain created for transfers out (the canvas's loupe reads its
    // images) keeps that usage through a recreate; built with the default
    // usage, a blit from it is `VUID-vkCmdBlitImage-srcImage-00219`.
    import sparkles.wsi : PixelSize = PhysicalSize;

    Swapchain sc;
    RecreateVk vk;
    sc.handle = cast(VkSwapchainKHR) cast(void*) 0x1;
    sc.extent = VkExtent2D(320, 240);
    sc.format = VkFormat.VK_FORMAT_B8G8R8A8_SRGB;
    sc.usage = VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
        | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    sc.wantsAlpha = true; // and it had none: an opaque swapchain coming to want alpha
    const r = Swapchain.recreate(sc, vk, PixelSize(640, 480), true);
    assert(!r.hasError && r.value == SwapchainResize.rebuilt);
    assert(lastCreate.imageUsage == sc.usage && lastCreate.oldSwapchain is cast(VkSwapchainKHR) cast(void*) 0x1);
    assert(lastCreate.compositeAlpha == VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
        && sc.compositeAlpha == lastCreate.compositeAlpha, "it gains alpha at the rebuild");
    sc.wantsAlpha = false;
    assert(!Swapchain.recreate(sc, vk, PixelSize(640, 480), true).hasError);
    assert(lastCreate.compositeAlpha == VkCompositeAlphaFlagBitsKHR.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        "and gives it up again");
    assert(sc.extent == VkExtent2D(640, 480) && sc.images.length == 2 && sc.hasRetired);
}

@("vulkan_wsi.swapchain.chooseCompositeAlpha")
@safe pure nothrow @nogc unittest
{
    with (VkCompositeAlphaFlagBitsKHR)
    {
        const desktop = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR | VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
        assert(Swapchain.chooseCompositeAlpha(desktop, true) == VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR);
        assert(Swapchain.chooseCompositeAlpha(desktop, false) == VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR);
        // A surface without premultiplied alpha is opaque, asked or not.
        assert(Swapchain.chooseCompositeAlpha(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, true)
            == VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR);
        // One that offers only `INHERIT` gets it, not a mode it lacks.
        assert(Swapchain.chooseCompositeAlpha(VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR, false)
            == VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR);
    }
}
