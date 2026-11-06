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
    /// The id the present carried (`VK_KHR_present_id`); 0 when untagged.
    ulong presentId;
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

/**
Which tagged presents completed (`PRF13` of the profiling specification),
learned without waiting: each present a device with `VK_KHR_present_id` and
`VK_KHR_present_wait` makes carries an id ($(LREF PresentWait.idFor)), and
$(LREF pollCompleted) asks `vkWaitForPresentKHR`, with a zero timeout,
about the oldest ids not yet known complete. A present completes when its
image is shown; ids complete in order, and a present the engine skipped
(mailbox) completes with the next one shown.

The time a present completed is the time a poll first saw it: as fine as the
caller polls, once a frame for $(LREF presentFrame). A rebuilt swapchain's
outstanding ids are dropped — the old one is retired, and ids are per
swapchain.
*/
struct PresentWait
{
    /// The most ids outstanding; past it the oldest is dropped, and it
    /// completes unseen with a newer one.
    enum size_t capacity = 8;

    private ulong[capacity] pending_; // oldest first
    private size_t count_;
    private VkSwapchainKHR swapchain_;
    ulong lastSubmitted; /// the newest id presented
    ulong completed;     /// the newest id known complete; 0 for none
    MonoTime completedAt; /// when a poll first saw `completed`

@safe pure nothrow @nogc:

    /**
    The id the present of frame `frame` carries: `frame + 1` (an id of 0 is
    no id, and a `FrameTimer` numbers frames from 0), or the next after the
    last when that would not increase — ids must, over a swapchain's life.
    */
    ulong idFor(ulong frame) const
        => frame + 1 > lastSubmitted ? frame + 1 : lastSubmitted + 1;

    /// Notes that `id` was presented to `swapchain`; a new swapchain drops
    /// the old one's outstanding ids.
    void submitted(VkSwapchainKHR swapchain, ulong id)
    {
        if (swapchain !is swapchain_)
        {
            swapchain_ = swapchain;
            count_ = 0;
        }
        if (count_ == capacity)
            dropOldest();
        pending_[count_++] = id;
        lastSubmitted = id;
    }

    /// How many ids are outstanding.
    size_t outstanding() const => count_;

    /// Forgets the outstanding ids and their swapchain (it is retired or
    /// gone: waiting on it is no longer valid).
    void forget()
    {
        count_ = 0;
        swapchain_ = null;
    }

    private void dropOldest()
    {
        foreach (i; 1 .. count_)
            pending_[i - 1] = pending_[i];
        --count_;
    }
}

/**
Blocks until the newest present submitted to `wait`'s swapchain is shown, or
`timeout` passes, then polls (`pollCompleted`), so what completed is stamped
as it was shown. A frame loop the window system does not pace (X11) waits
here before its next frame: it draws a frame a refresh, and each frame is
shown, where mailbox would drop all but the last of a refresh's frames. False
with nothing outstanding, without the commands, on a timeout or an error
(which drops the outstanding ids).
*/
bool waitForNewest(Context, Sink = typeof(null))(ref PresentWait wait, ref Context vk,
    Duration timeout, scope Sink sink = null) @system
{
    if (wait.count_ == 0 || wait.swapchain_ is null || vk.device.waitForPresentKHR is null)
        return false;
    const r = vk.device.waitForPresentKHR(vk.device.device, wait.swapchain_, wait.lastSubmitted,
        timeout.total!"nsecs");
    if (r < 0)
    {
        wait.forget();
        return false;
    }
    if (r != VkResult.VK_SUCCESS)
        return false;
    pollCompleted(wait, vk, sink);
    return true;
}

/**
Polls `wait` without blocking: every outstanding id the device reports
complete, oldest first, is passed to `sink(id, at)` (when given) and becomes
`wait.completed`, at `at`, the time this poll saw it. Returns how many
completed. An error — the surface lost, out of date — drops the outstanding
ids; a device without the commands reports none.
*/
size_t pollCompleted(Context, Sink = typeof(null))(ref PresentWait wait, ref Context vk,
    scope Sink sink = null) @system
{
    size_t done;
    while (wait.count_ > 0 && wait.swapchain_ !is null)
    {
        const id = wait.pending_[0];
        const r = vk.device.waitForPresentKHR is null ? VkResult.VK_TIMEOUT
            : vk.device.waitForPresentKHR(vk.device.device, wait.swapchain_, id, 0);
        if (r == VkResult.VK_TIMEOUT || r == VkResult.VK_NOT_READY)
            break;
        if (r < 0)
        {
            wait.forget();
            break;
        }
        const at = MonoTime.currTime;
        wait.dropOldest();
        wait.completed = id;
        wait.completedAt = at;
        ++done;
        static if (!is(Sink == typeof(null)))
            sink(id, at);
    }
    return done;
}

/// ditto
struct Presenter
{
    Swapchain swapchain; ///
    RenderTarget target; /// the views (and, without dynamic rendering, the pass and framebuffers)
    FrameSync sync;      ///
    PresentStats stats;  ///
    PresentTiming timing; ///
    /// The tagged presents and which completed, where the device has
    /// `VK_KHR_present_wait` (`VulkanDevice.presentWait`).
    PresentWait presentWait;

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
        // The old swapchain is retired: its presents are not waited on.
        presentWait.forget();
        return updated;
    }

    /// Whether a rebuild left semaphores or a swapchain for $(LREF reap).
    bool hasRetired() const @safe pure nothrow @nogc
        => sync.hasRetired || swapchain.hasRetired;

    /**
    Destroys retired resources whose epoch has a completed image-reacquisition
    proof. A rendered-frame count is insufficient: if resize replaces every
    swapchain before reacquisition, resources remain retained until a later
    swapchain completes a present and returns one of its images.
    */
    void reap(Context)(ref Context vk) @system nothrow
    {
        if (!sync.presentationCompletionKnown) return;
        sync.reapThrough(vk, sync.completedPresentEpoch);
        swapchain.reapThrough(vk, sync.completedPresentEpoch);
        ++stats.reaps;
    }

    /// Destroys the three, the device idle.
    void destroy(Context)(ref Context vk) @system nothrow
    {
        presentWait.forget();
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

Where the device has `VK_KHR_present_wait` (`vk.presentWait`), the present
carries `presenter.presentWait.idFor(frame)` — `frame + 1` for a program's
frame numbers from 0 — reported as `presentId`, and every frame then polls,
without waiting, which presents completed (`presenter.presentWait`).
*/
PresentationResult!FrameResult presentFrame(alias record, Context, Io = typeof(null))(
    ref Presenter presenter, ref Context vk, ref CommandPool pool, bool block = true,
    Io io = null, ulong frame = 0) @system
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
        const tagged = canWaitForPresent(vk);
        const presentId = tagged ? presentWait.idFor(frame) : 0;
        swapchain.epoch = ++sync.epoch;
        auto shown = swapchain.present(vk, image, sync.renderFinished(image), presentId);
        if (auto failed = giveBack(io))
            return err!FrameResult(failed);
        timing.present = MonoTime.currTime - started;
        static if (is(typeof(vk.presentWait) : bool))
        {
            if (tagged)
            {
                if (!shown.hasError)
                {
                    presentWait.submitted(swapchain.handle, presentId);
                    result.presentId = presentId;
                }
                presentWait.pollCompleted(vk);
            }
        }
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
            sync.notePresent(image);
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

// Whether `vk`'s device tags presents and waits on them (`VulkanDevice.presentWait`).
private bool canWaitForPresent(Context)(ref Context vk)
{
    static if (is(typeof(vk.presentWait) : bool))
        return vk.presentWait && vk.device.waitForPresentKHR !is null;
    else
        return false;
}

// The frame slot's fence, polled: `VK_TIMEOUT` while its submit still runs.
private VkResult waitWithoutBlocking(Context)(ref Context vk, ref FrameSync sync) @system
{
    auto fence = sync.inFlight;
    const result = vk.device.waitForFences(vk.device.device, 1, &fence, VK_TRUE, 0);
    if (result == VkResult.VK_SUCCESS) sync.frameCompleted(sync.frame);
    return result;
}

version (unittest)
{
    // A device that answers only what a frame asks: the fence wait and the
    // acquire return what the test sets, and every call is counted. The
    // state is thread-local: tests on different runner threads keep their own.
    private VkResult fenceAnswer, acquireAnswer, presentAnswer;
    private size_t acquires, resets, submits;

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
        VkResult fakePresent(VkQueue, const(VkPresentInfoKHR)* info)
        {
            // The id a tagged present carries, chained as `VkPresentIdKHR`.
            auto tag = cast(const(VkPresentIdKHR)*) info.pNext;
            presentedId = tag is null ? 0 : tag.pPresentIds[0];
            return presentAnswer;
        }
        // Complete up to `shownUpTo`; `waitAnswer` overrides when set.
        VkResult fakeWaitForPresent(VkDevice, VkSwapchainKHR, ulong id, ulong timeout)
        {
            ++presentWaits;
            if (timeout != 0)
                lastBlockingTimeout = timeout;
            if (waitAnswer != VkResult.VK_SUCCESS)
                return waitAnswer;
            return id <= shownUpTo ? VkResult.VK_SUCCESS : VkResult.VK_TIMEOUT;
        }
    }
    private ulong presentedId, shownUpTo;
    private size_t presentWaits;
    private ulong lastBlockingTimeout; // nanoseconds; 0 while only polls ran
    private VkResult waitAnswer;

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
        typeof(&fakeWaitForPresent) waitForPresentKHR = &fakeWaitForPresent;
    }

    private struct FrameVk
    {
        FrameDevice device;
        VkQueue queue = cast(VkQueue) cast(void*) 2;
        bool presentWait; // as `VulkanDevice.presentWait`
    }

    // A presenter with a swapchain of one image and two frame slots.
    private void readyPresenter(ref Presenter p, ref FrameVk vk, ref CommandPool pool)
    {
        assert(!FrameSync.create(p.sync, vk, 2).hasError);
        p.swapchain.handle = cast(VkSwapchainKHR) cast(void*) 0x30;
        p.swapchain.extent = VkExtent2D(64, 64);
        pool.buffers = [cast(VkCommandBuffer) cast(void*) 0x40, cast(VkCommandBuffer) cast(void*) 0x41];
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

@("vulkan_wsi.presenter.presentsCarryIdsAndCompleteWithoutWaiting")
@system unittest
{
    // `PRF13`: with `VK_KHR_present_wait`, each present carries its frame's
    // number + 1, and every frame polls — with a zero timeout — which
    // presents completed, oldest first, stamping when it first saw each.
    FrameVk vk;
    vk.presentWait = true;
    Presenter p;
    CommandPool pool;
    readyPresenter(p, vk, pool);
    auto record(uint) => ok!string();
    fenceAnswer = acquireAnswer = presentAnswer = waitAnswer = VkResult.VK_SUCCESS;
    shownUpTo = presentWaits = 0;

    auto first = p.presentFrame!record(vk, pool, true, null, 0);
    assert(!first.hasError && first.value.presented && first.value.presentId == 1);
    assert(presentedId == 1 && p.presentWait.completed == 0 && p.presentWait.outstanding == 1);

    // Frame 5 is shown before the poll that follows its present: both ids
    // complete at once, and only the newest is the one to read.
    shownUpTo = 6;
    const before = MonoTime.currTime;
    auto sixth = p.presentFrame!record(vk, pool, true, null, 5);
    assert(sixth.value.presentId == 6 && presentedId == 6);
    assert(p.presentWait.completed == 6 && p.presentWait.outstanding == 0);
    assert(p.presentWait.completedAt >= before);

    // A frame number that would not increase still gets an increasing id.
    auto again = p.presentFrame!record(vk, pool, true, null, 2);
    assert(again.value.presentId == 7 && p.presentWait.outstanding == 1);

    // Polled directly, with a sink: nothing new until it is shown.
    ulong[4] seen;
    size_t count;
    void sink(ulong id, MonoTime) { seen[count++] = id; }
    assert(p.presentWait.pollCompleted(vk, &sink) == 0);
    shownUpTo = 7;
    assert(p.presentWait.pollCompleted(vk, &sink) == 1 && seen[0] == 7 && count == 1);

    // A lost surface drops what is outstanding; a rebuilt swapchain too.
    p.presentFrame!record(vk, pool, true, null, 10);
    waitAnswer = VkResult.VK_ERROR_SURFACE_LOST_KHR;
    assert(p.presentWait.pollCompleted(vk) == 0 && p.presentWait.outstanding == 0);
    waitAnswer = VkResult.VK_SUCCESS;
    p.presentWait.submitted(cast(VkSwapchainKHR) cast(void*) 0x30, 12);
    p.presentWait.submitted(cast(VkSwapchainKHR) cast(void*) 0x31, 13);
    assert(p.presentWait.outstanding == 1 && p.presentWait.lastSubmitted == 13);

    // Past capacity the oldest is dropped, to complete with a newer one.
    foreach (id; 14 .. 14 + PresentWait.capacity + 2)
        p.presentWait.submitted(cast(VkSwapchainKHR) cast(void*) 0x31, id);
    assert(p.presentWait.outstanding == PresentWait.capacity);

    // Without the feature a present carries no id and nothing is polled.
    vk.presentWait = false;
    const polls = presentWaits;
    auto plain = p.presentFrame!record(vk, pool);
    assert(plain.value.presented && plain.value.presentId == 0 && presentedId == 0);
    assert(presentWaits == polls);
    assert(lastBlockingTimeout == 0, "a poll never waits");
}

@("vulkan_wsi.presenter.waitsForTheNewestToBeShown")
@system unittest
{
    import core.time : msecs;

    // A loop the window system does not pace (X11) waits, before its next
    // frame, until its last present is shown; what completed is stamped then.
    FrameVk vk;
    vk.presentWait = true;
    Presenter p;
    CommandPool pool;
    readyPresenter(p, vk, pool);
    waitAnswer = VkResult.VK_SUCCESS;
    shownUpTo = lastBlockingTimeout = 0;
    PresentWait none;
    assert(!none.waitForNewest(vk, 20.msecs), "nothing outstanding: no wait");
    assert(lastBlockingTimeout == 0);

    const sc = cast(VkSwapchainKHR) cast(void*) 0x40;
    p.presentWait.submitted(sc, 1);
    p.presentWait.submitted(sc, 2);
    assert(!p.presentWait.waitForNewest(vk, 20.msecs), "not shown in time");
    assert(lastBlockingTimeout == 20_000_000 && p.presentWait.outstanding == 2);

    shownUpTo = 2;
    ulong[2] seen;
    size_t count;
    void sink(ulong id, MonoTime) { seen[count++] = id; }
    assert(p.presentWait.waitForNewest(vk, 20.msecs, &sink));
    assert(count == 2 && seen == [1, 2] && p.presentWait.completed == 2);

    p.presentWait.submitted(sc, 3);
    waitAnswer = VkResult.VK_ERROR_SURFACE_LOST_KHR;
    assert(!p.presentWait.waitForNewest(vk, 20.msecs) && p.presentWait.outstanding == 0);
    waitAnswer = VkResult.VK_SUCCESS;
    lastBlockingTimeout = 0;
}
