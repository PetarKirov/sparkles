/**
A swapchain, the render target over its images and the frame synchronization
that guards them, driven as one: $(LREF Presenter.rebuild) for a size,
$(LREF presentFrame) for one acquire–record–submit–present.

Every direct-draw program repeated the same two sequences around these three
objects — wait for the frames in flight, recreate, retarget, replace the
per-image semaphores; wait for the slot, acquire, wait for the image, begin,
record, submit, present, advance — with the same rules each time: a
suboptimal acquire is drawn and presented and the swapchain rebuilt after it,
an out-of-date one rebuilds before anything is drawn, the fence is reset only
once the frame will be submitted (`FrameSync`). Here they are written once.

What stays the program's: what a frame records (the `record` callback), what
size it asks for, and when it rebuilds — `presentFrame` reports a stale swapchain and
leaves the rebuild to the caller, who knows the size. A window system whose
connection the presentation engine borrows (Wayland: `sparkles:wsi` pauses its
own dispatch) is passed as `io`, anything with `beginNativeIo` and
`endNativeIo`; the swapchain's own calls are bracketed with them.
*/
module sparkles.vulkan_wsi.presenter;

import core.time : Duration, MonoTime;

import sparkles.base.expected : err, ok;

import sparkles.vulkan;
import sparkles.vulkan_wsi.commands : CommandPool;
import sparkles.vulkan_wsi.error : PresentationResult;
import sparkles.vulkan_wsi.frame : decideAcquire, FrameSync;
import sparkles.vulkan_wsi.swapchain : anyPresentMode, Swapchain, SwapchainResize;
import sparkles.vulkan_wsi.triangle : RenderTarget;

/// What one $(LREF presentFrame) came to.
struct FrameResult
{
    /// The frame was drawn and the presentation engine queued it. A frame
    /// drawn and submitted whose present came back out of date was not.
    bool presented;
    /// The swapchain no longer matches the surface: rebuild it (`force`)
    /// before the next frame. Set after a suboptimal frame too, which was
    /// still presented.
    bool stale;
    VkResult acquired = VkResult.VK_SUCCESS;  /// what the acquire returned
    VkResult presentResult = VkResult.VK_SUCCESS; /// what the present returned
}

/// What a presenter has done, for a run's report.
struct PresentStats
{
    uint framesPresented;   ///
    uint swapchainsBuilt;   ///
    uint acquireSuboptimal; ///
    uint acquireOutOfDate;  ///
    uint presentSuboptimal; ///
    uint presentOutOfDate;  ///
    uint reaps;             /// calls to $(LREF Presenter.reap)
}

/// Where the last frame and the last rebuild spent their time.
struct PresentTiming
{
    Duration waitFrame; /// for the frame slot's previous submit
    Duration acquire;   ///
    Duration record;    /// the `record` callback
    Duration present;   ///
    Duration waitAll;   /// the last rebuild's wait for the frames in flight
    Duration create;    /// the last rebuild's `Swapchain.recreate`
}

/// ditto
struct Presenter
{
    Swapchain swapchain; ///
    RenderTarget target; /// the views (and, without dynamic rendering, the pass and framebuffers)
    FrameSync sync;      ///
    PresentStats stats;  ///
    PresentTiming timing; ///

    @disable this(this);

    /// Whether there is a swapchain with an area to draw.
    bool ready() const @safe pure nothrow @nogc
        => swapchain.handle !is null && swapchain.extent.width > 0
            && swapchain.extent.height > 0;

    /**
    Builds the swapchain for `size`, or rebuilds it: `Swapchain.recreate`
    decides (`paused` for a zero size, `unchanged` when it already fits,
    unless `force`), and only a rebuild retargets the views and replaces the
    per-image semaphores — the old ones may still be waited on by a present,
    so they are retired, for $(LREF reap). Waits for the frames in flight
    first, never for the device.
    */
    PresentationResult!SwapchainResize rebuild(Context, Size, Io = typeof(null))(ref Context vk,
        in Size size, bool force = false, in Size minAlloc = Size.init,
        VkPresentModeKHR presentMode = anyPresentMode, bool growOnly = false, Io io = null) @system
    {
        auto started = MonoTime.currTime;
        auto waited = sync.waitAll(vk);
        timing.waitAll = MonoTime.currTime - started;
        if (waited.hasError)
            return err!SwapchainResize("vkWaitForFences: " ~ describeResult(waited.error));

        started = MonoTime.currTime;
        if (auto failed = borrow(io))
            return err!SwapchainResize(failed);
        auto updated = Swapchain.recreate(swapchain, vk, size, force, minAlloc, presentMode,
            growOnly);
        auto returned = giveBack(io);
        timing.create = MonoTime.currTime - started;
        if (updated.hasError)
            return updated;
        if (returned)
            return err!SwapchainResize(returned);
        if (updated.value != SwapchainResize.rebuilt)
            return updated;

        auto retargeted = target.views.length == 0
            ? RenderTarget.create(target, vk, swapchain)
            : target.rebind(vk, swapchain);
        if (retargeted.hasError)
            return err!SwapchainResize(retargeted.error);
        const images = cast(uint) swapchain.images.length;
        auto synced = sync.imageCount == 0
            ? FrameSync.create(sync, vk, images)
            : sync.replaceImages(vk, images);
        if (synced.hasError)
            return err!SwapchainResize(synced.error);
        ++stats.swapchainsBuilt;
        return updated;
    }

    /// Whether a rebuild left semaphores or a swapchain for $(LREF reap).
    bool hasRetired() const @safe pure nothrow @nogc
        => sync.hasRetired || swapchain.hasRetired;

    /**
    Destroys what rebuilds retired, a little at a time — eight semaphores and
    one swapchain a call — so a run of rebuilds does not hitch when it ends.
    Call it once the presents that used them are done: a few quiet frames
    after the last rebuild.
    */
    void reap(Context)(ref Context vk) @system nothrow
    {
        sync.reap(vk, 8);
        swapchain.reap(vk, 1);
        ++stats.reaps;
    }

    /// Destroys the three, the device idle.
    void destroy(Context)(ref Context vk) @system nothrow
    {
        sync.destroy(vk);
        target.destroy(vk);
        swapchain.destroy(vk);
        sync = FrameSync.init;
        target = RenderTarget.init;
        swapchain = Swapchain.init;
    }
}

// The window system's connection, lent to the presentation engine and taken
// back: a failure's diagnostic, or null.
private string borrow(Io)(Io io) @system
{
    static if (is(Io == typeof(null)))
        return null;
    else
    {
        auto r = io.beginNativeIo();
        return r.hasError ? "native I/O: " ~ r.error.diagnostic[].idup : null;
    }
}

/// ditto
private string giveBack(Io)(Io io) @system
{
    static if (is(Io == typeof(null)))
        return null;
    else
    {
        auto r = io.endNativeIo();
        return r.hasError ? "native I/O: " ~ r.error.diagnostic[].idup : null;
    }
}

/**
One frame of `presenter`: wait for the slot, acquire an image, wait for whatever still
draws into it, then `record(image)` into `pool`'s buffer for the slot
(`sync.frame`), submit it and present.

With `block` false nothing waits: a slot still in use or no image ready
is a frame not drawn (`presented` false, no error) — what a frame drawn
from inside a window system's dispatch needs. An out-of-date acquire
draws nothing and reports `stale`; a suboptimal one is drawn, presented
and reported `stale`.
*/
PresentationResult!FrameResult presentFrame(alias record, Context, Io = typeof(null))(
    ref Presenter presenter, ref Context vk, ref CommandPool pool, bool block = true,
    Io io = null) @system
{
    with (presenter)
    {
        FrameResult result;
        timing.waitFrame = timing.acquire = timing.record = timing.present = Duration.zero;
        if (!ready)
            return ok!string(result);

        auto started = MonoTime.currTime;
        // Not `waitForFrame` when nothing may wait: its result counts
        // `VK_TIMEOUT` as success, as Vulkan counts every non-negative code,
        // and a slot still in flight must not be acquired, reset or re-recorded.
        VkResult waited = VkResult.VK_SUCCESS;
        if (block)
        {
            auto slot = sync.waitForFrame(vk);
            if (slot.hasError)
                waited = slot.error;
        }
        else
            waited = waitWithoutBlocking(vk, sync);
        timing.waitFrame = MonoTime.currTime - started;
        if (waited == VkResult.VK_TIMEOUT)
            return ok!string(result);
        if (waited < 0)
            return err!FrameResult("vkWaitForFences: " ~ describeResult(waited));

        uint image;
        started = MonoTime.currTime;
        if (auto failed = borrow(io))
            return err!FrameResult(failed);
        result.acquired = vk.device.acquireNextImageKHR(vk.device.device, swapchain.handle,
            block ? ulong.max : 0, sync.imageAvailable, null, &image);
        if (auto failed = giveBack(io))
            return err!FrameResult(failed);
        timing.acquire = MonoTime.currTime - started;
        if (result.acquired == VkResult.VK_SUBOPTIMAL_KHR)
            ++stats.acquireSuboptimal;
        else if (result.acquired == VkResult.VK_ERROR_OUT_OF_DATE_KHR)
            ++stats.acquireOutOfDate;
        const decision = decideAcquire(result.acquired);
        if (decision.failed)
            return err!FrameResult("vkAcquireNextImageKHR: " ~ describeResult(result.acquired));
        result.stale = decision.recreate;
        if (!decision.proceed)
            return ok!string(result);

        auto held = sync.waitForImage(vk, image);
        if (held.hasError)
            return err!FrameResult("vkWaitForFences (image): " ~ describeResult(held.error));
        auto begun = sync.beginFrame(vk, image);
        if (begun.hasError)
            return err!FrameResult("vkResetFences: " ~ describeResult(begun.error));

        started = MonoTime.currTime;
        auto recorded = record(image);
        timing.record = MonoTime.currTime - started;
        if (recorded.hasError)
            return err!FrameResult(recorded.error);
        auto submitted = sync.submit(vk, pool.buffers[sync.frame], image);
        if (submitted.hasError)
            return err!FrameResult("vkQueueSubmit: " ~ describeResult(submitted.error));

        started = MonoTime.currTime;
        if (auto failed = borrow(io))
            return err!FrameResult(failed);
        auto shown = swapchain.present(vk, image, sync.renderFinished(image));
        if (auto failed = giveBack(io))
            return err!FrameResult(failed);
        timing.present = MonoTime.currTime - started;
        // The slot's submit went in either way, so the slot moves on; the
        // frame is presented only if the engine queued it.
        sync.advance();
        result.presentResult = shown.hasError ? shown.error : shown.value;
        if (result.presentResult == VkResult.VK_SUBOPTIMAL_KHR)
            ++stats.presentSuboptimal;
        else if (result.presentResult == VkResult.VK_ERROR_OUT_OF_DATE_KHR)
            ++stats.presentOutOfDate;
        if (shown.hasError && !Swapchain.needsRecreation(shown.error))
            return err!FrameResult("vkQueuePresentKHR: " ~ describeResult(shown.error));
        if (!shown.hasError)
        {
            result.presented = true;
            ++stats.framesPresented;
        }
        result.stale |= Swapchain.needsRecreation(result.presentResult);
        return ok!string(result);
    }
}

///
@("vulkan_wsi.presenter.startsEmpty")
@safe pure nothrow @nogc unittest
{
    // Nothing to draw into and nothing to reap until the first rebuild; a
    // frame not drawn says so without a result to read.
    Presenter p;
    assert(!p.ready && !p.hasRetired);
    assert(p.stats == PresentStats.init);
    const FrameResult none;
    assert(!none.presented && !none.stale && none.acquired == VkResult.VK_SUCCESS);
}

// The frame slot's fence, polled: `VK_TIMEOUT` while its submit still runs.
private VkResult waitWithoutBlocking(Context)(ref Context vk, ref FrameSync sync) @system
{
    auto fence = sync.inFlight;
    return vk.device.waitForFences(vk.device.device, 1, &fence, VK_TRUE, 0);
}

version (unittest)
{
    // A device that answers only what a frame asks: the fence wait and the
    // acquire return what the test sets, and every call is counted.
    private __gshared VkResult fenceAnswer, acquireAnswer, presentAnswer;
    private __gshared size_t acquires, resets, submits;

    private extern (C) nothrow
    {
        VkResult fakeWait(VkDevice, uint, const(VkFence)*, VkBool32, ulong) => fenceAnswer;
        VkResult fakeAcquire(VkDevice, VkSwapchainKHR, ulong, VkSemaphore, VkFence, uint* image)
        {
            ++acquires;
            *image = 0;
            return acquireAnswer;
        }
        VkResult fakeReset(VkDevice, uint, const(VkFence)*) { ++resets; return VkResult.VK_SUCCESS; }
        VkResult fakeFence(VkDevice, const(VkFenceCreateInfo)*, const(VkAllocationCallbacks)*, VkFence* f)
        {
            *f = cast(VkFence) cast(void*) 0x10;
            return VkResult.VK_SUCCESS;
        }
        VkResult fakeSemaphore(VkDevice, const(VkSemaphoreCreateInfo)*, const(VkAllocationCallbacks)*,
            VkSemaphore* s)
        {
            *s = cast(VkSemaphore) cast(void*) 0x20;
            return VkResult.VK_SUCCESS;
        }
        void fakeDestroyFence(VkDevice, VkFence, const(VkAllocationCallbacks)*) {}
        void fakeDestroySemaphore(VkDevice, VkSemaphore, const(VkAllocationCallbacks)*) {}
        VkResult fakeSubmit(VkQueue, uint, const(VkSubmitInfo)*, VkFence) { ++submits; return VkResult.VK_SUCCESS; }
        VkResult fakeIdle(VkQueue) => VkResult.VK_SUCCESS;
        VkResult fakePresent(VkQueue, const(VkPresentInfoKHR)*) => presentAnswer;
    }

    private struct FrameDevice
    {
        VkDevice device = cast(VkDevice) cast(void*) 1;
        typeof(&fakeWait) waitForFences = &fakeWait;
        typeof(&fakeAcquire) acquireNextImageKHR = &fakeAcquire;
        typeof(&fakeReset) resetFences = &fakeReset;
        typeof(&fakeFence) createFence = &fakeFence;
        typeof(&fakeSemaphore) createSemaphore = &fakeSemaphore;
        typeof(&fakeDestroyFence) destroyFence = &fakeDestroyFence;
        typeof(&fakeDestroySemaphore) destroySemaphore = &fakeDestroySemaphore;
        typeof(&fakeSubmit) queueSubmit = &fakeSubmit;
        typeof(&fakeIdle) queueWaitIdle = &fakeIdle;
        typeof(&fakePresent) queuePresentKHR = &fakePresent;
    }

    private struct FrameVk
    {
        FrameDevice device;
        VkQueue queue = cast(VkQueue) cast(void*) 2;
    }
}

@("vulkan_wsi.presenter.aBusySlotIsNotDrawnWithoutBlocking")
@system unittest
{
    // `VK_TIMEOUT` is a success to `check`, so a frame that may not wait has
    // to see the fence's own answer: while the slot's submit still runs, it
    // must not acquire, reset the fence or record.
    FrameVk vk;
    Presenter p;
    assert(!FrameSync.create(p.sync, vk, 2).hasError);
    p.swapchain.handle = cast(VkSwapchainKHR) cast(void*) 0x30;
    p.swapchain.extent = VkExtent2D(64, 64);
    CommandPool pool;
    pool.buffers = [cast(VkCommandBuffer) cast(void*) 0x40, cast(VkCommandBuffer) cast(void*) 0x41];
    size_t recorded;
    auto record(uint) { ++recorded; return ok!string(); }

    fenceAnswer = VkResult.VK_TIMEOUT;
    acquires = resets = submits = 0;
    auto busy = p.presentFrame!record(vk, pool, false);
    assert(!busy.hasError && !busy.value.presented && !busy.value.stale);
    assert(acquires == 0 && resets == 0 && recorded == 0, "a busy slot is left alone");

    // An out-of-date acquire draws nothing and says to rebuild.
    fenceAnswer = VkResult.VK_SUCCESS;
    acquireAnswer = VkResult.VK_ERROR_OUT_OF_DATE_KHR;
    auto stale = p.presentFrame!record(vk, pool, false);
    assert(!stale.hasError && !stale.value.presented && stale.value.stale);
    assert(acquires == 1 && resets == 0 && recorded == 0);

    // A suboptimal one is drawn and presented, and then says to rebuild.
    acquireAnswer = VkResult.VK_SUBOPTIMAL_KHR;
    auto shown = p.presentFrame!record(vk, pool);
    assert(!shown.hasError && shown.value.presented && shown.value.stale);
    assert(resets == 1 && recorded == 1 && submits == 1 && p.stats.framesPresented == 1);

    // A present the engine rejects as out of date queued nothing: the frame
    // was drawn and submitted, but not presented, and the swapchain is stale.
    acquireAnswer = VkResult.VK_SUCCESS;
    presentAnswer = VkResult.VK_ERROR_OUT_OF_DATE_KHR;
    auto rejected = p.presentFrame!record(vk, pool);
    assert(!rejected.hasError && !rejected.value.presented && rejected.value.stale);
    assert(submits == 2 && p.stats.framesPresented == 1 && p.stats.presentOutOfDate == 1);
    presentAnswer = VkResult.VK_SUCCESS;
}
