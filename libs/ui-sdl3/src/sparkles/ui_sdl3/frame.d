/**
Frame synchronisation: the semaphores, fences and the rules for reusing them.

Presenting a frame is four Vulkan calls — acquire, wait, submit, present — and
almost none of the difficulty is in the calls. It is in what may be reused
when, and the failures are not compile errors or even runtime errors: they are
a validation message, a hang, or a frame that renders into an image the display
is still scanning out. This module owns those rules so a caller writes the four
calls and gets them right.

$(B Three objects, three different lifetimes.) It is tempting to size all of
them by frames-in-flight and be done. Two of them are:

$(UL
$(LI $(B `imageAvailable`), signalled by `vkAcquireNextImageKHR` and waited on
    by the submit — per $(I frame in flight), because only one acquire is
    outstanding per frame slot.)
$(LI $(B `inFlight`), the fence the submit signals, which is what lets the CPU
    know the slot's command buffer is free again — per $(I frame in flight),
    for the same reason.)
$(LI $(B `renderFinished`), signalled by the submit and waited on by the
    present — per $(I swapchain image), $(B not) per frame. This is the one
    that is routinely got wrong, and $(LREF FrameSync) exists mostly to get it
    right; see $(LREF FrameSync.renderFinished).))

$(B And a fourth thing that is not an object.) A frame slot coming round again
says nothing about the $(I image) the presentation engine handed back — with
mailbox, or with more images than frame slots, the same image can return while
an earlier frame is still drawing into it. $(LREF FrameSync.waitForImage)
tracks which fence guards each image so that case waits instead of racing.

Skia's Graphite backend does its own recording, but it does not own the
swapchain and does not present, so this is the layer that stays underneath it
unchanged.
*/
module sparkles.ui_sdl3.frame;

import expected : err, ok;

import sparkles.ui_sdl3.error;
import sparkles.ui_sdl3.vulkan_context;
import sparkles.vulkan;

/**
What a `vkAcquireNextImageKHR` result means for the frame in progress.

The interesting case is `VK_SUBOPTIMAL_KHR`, because the obvious reading of it
is wrong. "Suboptimal" sounds like "throw this frame away and rebuild", but the
acquire $(I succeeded): it returned an image index and it $(B signalled the
semaphore). Abandoning the frame there leaves a signalled semaphore with
nothing waiting on it, and the next acquire on that same semaphore is a
validation error — in practice a hang, since the loop then waits on a
semaphore whose signal was already consumed by nothing.

So a suboptimal frame is drawn and presented like any other, and the swapchain
is rebuilt $(I after) it. `VK_ERROR_OUT_OF_DATE_KHR` is the opposite: no index,
no signal, nothing to unwind, rebuild now.
*/
struct AcquireDecision
{
    /// Record, submit and present this frame.
    bool proceed;

    /// Rebuild the swapchain — before the next frame if $(D proceed), now if not.
    bool recreate;

    /// A genuine failure, as opposed to a resize or an empty tick.
    bool failed;

    /// Neither a frame nor a rebuild: a finite-timeout acquire that came up empty.
    bool idle() const @safe pure nothrow @nogc
        => !proceed && !recreate && !failed;
}

/// ditto
AcquireDecision decideAcquire(VkResult r) @safe pure nothrow @nogc
{
    with (VkResult) switch (r)
    {
        case VK_SUCCESS:
            return AcquireDecision(proceed: true);

        // Signalled the semaphore and gave us an index: finish the frame, then
        // rebuild. See the note above — this is the case worth reading twice.
        case VK_SUBOPTIMAL_KHR:
            return AcquireDecision(proceed: true, recreate: true);

        // Signalled nothing. Rebuild before trying again.
        case VK_ERROR_OUT_OF_DATE_KHR:
        case VK_ERROR_SURFACE_LOST_KHR:
            return AcquireDecision(recreate: true);

        // Only reachable with a finite timeout: no image yet, and nothing is
        // wrong. The caller ticks again.
        case VK_TIMEOUT:
        case VK_NOT_READY:
            return AcquireDecision.init;

        default:
            return AcquireDecision(failed: true);
    }
}

/**
The per-frame and per-image synchronisation objects for one swapchain.

Sized from the swapchain's image count, so it is recreated alongside it. The
intended order of a frame, which is the order the members are written to
enforce:

---
sync.waitForFrame(vk);                       // slot's previous submit is done
const got = sync.acquire(vk, swapchain);     // → AcquireDecision + image index
if (!got.decision.proceed) { ...rebuild or tick... }
sync.waitForImage(vk, got.index);            // an earlier frame may still hold it
sync.beginFrame(vk, got.index);              // reset the fence, claim the image
// ... record into a command buffer ...
sync.submit(vk, cmd, got.index);
swapchain.present(vk, got.index, sync.renderFinished(got.index));
sync.advance();
---

$(B The fence is reset in `beginFrame`, not in `waitForFrame`.) Resetting it up
front reads more naturally and deadlocks: an acquire that bails between the two
leaves an unsignalled fence that no submit will ever signal, and the next
`waitForFrame` on that slot waits forever. Reset only once the frame is
certain to be submitted.
*/
struct FrameSync
{
    /// Frames the CPU may run ahead of the presentation engine.
    enum uint defaultFramesInFlight = 2;

    /// Per frame in flight.
    private VkSemaphore[] _imageAvailable;
    private VkFence[] _inFlight;

    /// Per swapchain image.
    private VkSemaphore[] _renderFinished;

    /**
    Which frame's fence, if any, is still guarding each image.

    Borrowed from `_inFlight` — never created or destroyed here. `null` means
    no frame has drawn into that image yet.
    */
    private VkFence[] _imageGuard;

    private uint _frame;

    @disable this(this);

    /**
    Create the objects for a swapchain of `imageCount` images.

    `framesInFlight` is a latency/throughput dial, not a correctness one: 1
    means the CPU waits for each frame to finish before starting the next, 2 is
    the usual balance, and more mostly adds input lag.
    */
    static SdlExpected!() create(out FrameSync sync, ref VulkanContext vk,
        uint imageCount, uint framesInFlight = defaultFramesInFlight) @system nothrow
    in (imageCount > 0, "a swapchain always has at least one image")
    in (framesInFlight > 0, "at least one frame must be in flight")
    {
        sync._imageAvailable = new VkSemaphore[framesInFlight];
        sync._inFlight = new VkFence[framesInFlight];
        sync._renderFinished = new VkSemaphore[imageCount];
        sync._imageGuard = new VkFence[imageCount];

        auto semInfo = vkInfo(VkSemaphoreCreateInfo());

        // Created signalled: the first `waitForFrame` on each slot has no
        // submit to wait for, and an unsignalled fence would hang it.
        auto fenceInfo = vkInfo(VkFenceCreateInfo(
            flags: VkFenceCreateFlagBits.VK_FENCE_CREATE_SIGNALED_BIT,
        ));

        foreach (i; 0 .. framesInFlight)
        {
            auto s = vk.device.createSemaphore(
                vk.device.device, &semInfo, null, &sync._imageAvailable[i]).check;
            if (s.hasError)
            {
                sync.destroy(vk);
                return err!void("vkCreateSemaphore: " ~ describeResult(s.error));
            }

            auto f = vk.device.createFence(
                vk.device.device, &fenceInfo, null, &sync._inFlight[i]).check;
            if (f.hasError)
            {
                sync.destroy(vk);
                return err!void("vkCreateFence: " ~ describeResult(f.error));
            }
        }

        foreach (i; 0 .. imageCount)
        {
            auto s = vk.device.createSemaphore(
                vk.device.device, &semInfo, null, &sync._renderFinished[i]).check;
            if (s.hasError)
            {
                sync.destroy(vk);
                return err!void("vkCreateSemaphore: " ~ describeResult(s.error));
            }
        }

        return ok!string();
    }

    /// The frame slot the next frame will use.
    uint frame() const @safe pure nothrow @nogc => _frame;

    /// How many frames may be in flight at once.
    uint framesInFlight() const @safe pure nothrow @nogc
        => cast(uint) _inFlight.length;

    /// How many swapchain images this was sized for.
    uint imageCount() const @safe pure nothrow @nogc
        => cast(uint) _renderFinished.length;

    /**
    The semaphore `vkAcquireNextImageKHR` signals for the current frame.

    Not `const`, here and below: handing back a handle hands back mutable
    access to the object it names, and `const` would only propagate onto the
    pointer — where it means nothing to Vulkan and everything to the type
    system, which then refuses to pass it to a command that takes a handle.
    */
    VkSemaphore imageAvailable() @safe pure nothrow @nogc
        => _imageAvailable[_frame];

    /// The fence the current frame's submit signals.
    VkFence inFlight() @safe pure nothrow @nogc => _inFlight[_frame];

    /**
    The semaphore the submit signals and the present waits on, $(B per image).

    Keying this by frame slot instead is the mistake worth naming, because it
    passes every test that does not involve a driver. Presentation order is not
    frame order: `vkQueuePresentKHR` waits on this semaphore and the
    presentation engine consumes it whenever it gets to that image, so a frame
    slot coming round again says nothing about whether the present that used
    its semaphore has been serviced. Reusing it then signals a semaphore with a
    pending wait already on it, which is
    `VUID-vkQueueSubmit-pSignalSemaphores-00067`.

    Keyed by image, the semaphore cannot be signalled again until that image is
    reacquired, and an image is only reacquired once its present completed.
    */
    VkSemaphore renderFinished(uint imageIndex) @safe pure nothrow @nogc
    in (imageIndex < _renderFinished.length, "image index is out of range")
        => _renderFinished[imageIndex];

    /**
    Wait for the current slot's previous submit to finish.

    Does $(B not) reset the fence — see the note on $(LREF FrameSync).
    */
    VkExpected!() waitForFrame(ref VulkanContext vk, ulong timeout = ulong.max)
        @system nothrow
    {
        auto fence = _inFlight[_frame];
        return check(vk.device.waitForFences(
            vk.device.device, 1, &fence, VK_TRUE, timeout));
    }

    /**
    Wait for whichever earlier frame is still drawing into `imageIndex`.

    Usually a no-op: the frame that last used the image is normally the one
    `waitForFrame` just waited for. It is not a no-op when there are more
    images than frame slots, or under `MAILBOX`, where the presentation engine
    can hand back an image out of order.
    */
    VkExpected!() waitForImage(ref VulkanContext vk, uint imageIndex,
        ulong timeout = ulong.max) @system nothrow
    in (imageIndex < _imageGuard.length, "image index is out of range")
    {
        auto guard = _imageGuard[imageIndex];
        if (guard is null || guard is _inFlight[_frame])
            return check(VkResult.VK_SUCCESS);

        return check(vk.device.waitForFences(
            vk.device.device, 1, &guard, VK_TRUE, timeout));
    }

    /**
    Commit to submitting this frame: reset the slot's fence and claim the image.

    Call once the acquire has succeeded and $(LREF waitForImage) has returned —
    past this point the fence is unsignalled, so the frame $(I must) reach a
    submit or the slot deadlocks.
    */
    VkExpected!() beginFrame(ref VulkanContext vk, uint imageIndex) @system nothrow
    in (imageIndex < _imageGuard.length, "image index is out of range")
    {
        auto fence = _inFlight[_frame];
        auto reset = check(vk.device.resetFences(vk.device.device, 1, &fence));
        if (reset.hasError)
            return reset;

        _imageGuard[imageIndex] = fence;
        return check(VkResult.VK_SUCCESS);
    }

    /**
    Submit `cmd` for `imageIndex`, wired to this frame's synchronisation.

    The wait stage is `COLOR_ATTACHMENT_OUTPUT` rather than `TOP_OF_PIPE`: the
    acquire only has to have completed by the time anything is written to the
    colour attachment, so vertex work overlaps with the wait instead of the
    whole pipeline stalling on it.
    */
    VkExpected!() submit(ref VulkanContext vk, VkCommandBuffer cmd, uint imageIndex)
        @system nothrow
    in (imageIndex < _renderFinished.length, "image index is out of range")
    {
        auto wait = _imageAvailable[_frame];
        auto signal = _renderFinished[imageIndex];
        auto buffer = cmd;
        VkPipelineStageFlags waitStage =
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        auto info = vkInfo(VkSubmitInfo(
            waitSemaphoreCount: 1,
            pWaitSemaphores: &wait,
            pWaitDstStageMask: &waitStage,
            commandBufferCount: 1,
            pCommandBuffers: &buffer,
            signalSemaphoreCount: 1,
            pSignalSemaphores: &signal,
        ));

        return check(vk.device.queueSubmit(vk.queue, 1, &info, _inFlight[_frame]));
    }

    /// Move to the next frame slot, wrapping.
    void advance() @safe pure nothrow @nogc
    {
        _frame = cast(uint)((_frame + 1) % _inFlight.length);
    }

    /**
    Destroy every object created here.

    The device must be idle first — these are the objects pending work points
    at. Callers rebuilding a swapchain go through `vkDeviceWaitIdle`, which
    $(D VulkanContext.destroy) also does.
    */
    void destroy(ref VulkanContext vk) @system nothrow
    {
        if (vk.device.device is null)
            return;

        if (vk.device.destroySemaphore !is null)
        {
            foreach (s; _imageAvailable)
                if (s !is null)
                    vk.device.destroySemaphore(vk.device.device, s, null);
            foreach (s; _renderFinished)
                if (s !is null)
                    vk.device.destroySemaphore(vk.device.device, s, null);
        }

        if (vk.device.destroyFence !is null)
            foreach (f; _inFlight)
                if (f !is null)
                    vk.device.destroyFence(vk.device.device, f, null);

        _imageAvailable = null;
        _renderFinished = null;
        _inFlight = null;
        _imageGuard = null;
        _frame = 0;
    }
}

@("ui_sdl3.frame.suboptimalFinishesTheFrameOutOfDateAbandonsIt")
@safe pure nothrow @nogc unittest
{
    with (VkResult)
    {
        assert(decideAcquire(VK_SUCCESS) == AcquireDecision(proceed: true));

        // The whole reason this is a function and not an `if`. Suboptimal
        // signalled the semaphore, so the frame must be finished — bailing
        // here leaves a signalled semaphore nothing will ever wait on, and the
        // loop hangs on the next acquire rather than failing where the bug is.
        const suboptimal = decideAcquire(VK_SUBOPTIMAL_KHR);
        assert(suboptimal.proceed, "a suboptimal acquire still handed us an image");
        assert(suboptimal.recreate);

        // Out of date signalled nothing: there is no frame to finish.
        const stale = decideAcquire(VK_ERROR_OUT_OF_DATE_KHR);
        assert(!stale.proceed && stale.recreate && !stale.failed);
    }
}

@("ui_sdl3.frame.timeoutIsNeitherAFrameNorAFailure")
@safe pure nothrow @nogc unittest
{
    with (VkResult)
    {
        // Reachable only with a finite timeout, and it means "no image yet".
        // Treating it as failure kills a loop that is merely running ahead.
        assert(decideAcquire(VK_TIMEOUT).idle);
        assert(decideAcquire(VK_NOT_READY).idle);

        // A real error is neither idle nor a rebuild.
        const lost = decideAcquire(VK_ERROR_DEVICE_LOST);
        assert(lost.failed && !lost.proceed && !lost.recreate && !lost.idle);
        assert(decideAcquire(VK_ERROR_OUT_OF_DEVICE_MEMORY).failed);

        // A lost surface is a rebuild rather than a hard failure: the window
        // may simply have been reparented.
        assert(decideAcquire(VK_ERROR_SURFACE_LOST_KHR).recreate);
    }
}

@("ui_sdl3.frame.frameSlotsWrapIndependentlyOfImageCount")
@safe pure nothrow unittest
{
    // Frame slots and images are counted separately on purpose: three images
    // with two frames in flight is the ordinary desktop case, and it is
    // exactly the case where a per-frame `renderFinished` would alias.
    FrameSync sync;
    sync._imageAvailable = new VkSemaphore[2];
    sync._inFlight = new VkFence[2];
    sync._renderFinished = new VkSemaphore[3];
    sync._imageGuard = new VkFence[3];

    assert(sync.framesInFlight == 2);
    assert(sync.imageCount == 3);

    assert(sync.frame == 0);
    sync.advance();
    assert(sync.frame == 1);
    sync.advance();
    assert(sync.frame == 0, "frame slots wrap at framesInFlight, not at imageCount");
}

@("ui_sdl3.frame.destroyIsIdempotentOnAHalfBuiltSync")
@system nothrow unittest
{
    // `create` tears down its own partial state on the first failed call, and
    // the caller may destroy again afterwards. With a null device there is
    // nothing to release and it must simply return.
    VulkanContext vk;
    FrameSync sync;
    sync.destroy(vk);
    sync.destroy(vk);
    assert(sync.framesInFlight == 0);
    assert(sync.imageCount == 0);
}
