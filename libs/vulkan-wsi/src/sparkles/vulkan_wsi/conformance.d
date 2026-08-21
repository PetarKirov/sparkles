/**
Backend-agnostic native-surface conformance probe.

The probe is written once against the WSI value contract and the live ICD:
create a window, wait for ready, hand the typed native handles to
`VulkanContext.create`, require a complete present-capable context, then
prove the backend's single Event Horizon wait still progresses after the
driver ran on its thread or connection. A platform driver supplies only the
backend, the loop, and a `Hooks` value with one required hook:

$(LIST
    * `void step(Duration timeout)` — advance the backend's integrated or
        hosted wait once.
)

Design by Introspection covers the platform differences: a backend exposing
the native-I/O borrow (`beginNativeIo`/`endNativeIo`) gets every ICD call
bracketed by it automatically, and the post-probe pump uses whichever of
`pumpEvents`/`pumpMessages` the backend offers.

Context-creation failure is returned, not asserted, so a driver can render
the environment-dependent outcomes — no Vulkan runtime, no present-capable
device — as an honest skip while its verify lane decides whether a skip
fails.
*/
module sparkles.vulkan_wsi.conformance;

import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;
import sparkles.vulkan : apiVersion11;
import sparkles.vulkan_wsi.context : ContextRequest, VulkanContext;
import sparkles.vulkan_wsi.error : VulkanWsiResult, vulkanWsiOk;
import sparkles.wsi.events;
import sparkles.wsi.types;

private void timerComplete(void* context, ref Completion completion)
    nothrow @nogc
{
    *cast(bool*) context = completion.res == 0;
}

/**
Runs the shared surface probe on `wsi`.

The window is created, probed, and destroyed inside this call; assertion
failures name the property that broke, and the returned result carries the
context-creation error when the environment cannot provide one.
*/
VulkanWsiResult!void checkSurfaceConformance(Backend, Hooks)(ref Backend wsi,
    ref DefaultLoop loop, ref Hooks hooks, string applicationName)
{
    // Property: creation reaches ready, with ordered sequences throughout.
    WindowConfig config;
    assert(config.title.assign(applicationName));
    config.logicalSize = LogicalSize(480, 320);
    const id = wsi.createWindow(config).value;

    bool ready;
    ulong lastSequence;
    void drainAll()
    {
        auto drained = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence,
                "event sequence did not increase");
            lastSequence = event.sequence;
            if (event.window == id)
                event.payload.match!(
                    (in ReadyEvent _) { ready = true; },
                    (_) {});
        });
        assert(!drained.hasError, "draining the event queue failed");
    }

    void driveUntil(scope bool delegate() satisfied, string what)
    {
        const deadline = MonoTime.currTime + 5.seconds;
        drainAll();
        while (!satisfied())
        {
            assert(MonoTime.currTime < deadline, what);
            hooks.step(2.seconds);
            drainAll();
        }
    }

    driveUntil(() => ready, "no ReadyEvent after createWindow");

    auto handles = wsi.nativeHandles(id).value;

    // Property: the typed handles reach a present-capable device on the
    // live ICD. Mesa may round-trip the shared connection while querying
    // surface support, so a backend with the borrow requires it around
    // every ICD call — creation and destruction alike.
    enum hasBorrow = is(typeof(wsi.beginNativeIo()));
    static if (hasBorrow)
        assert(!wsi.beginNativeIo().hasError);
    VulkanContext vk;
    auto broughtUp = VulkanContext.create(vk, handles,
        ContextRequest(applicationName: applicationName,
            apiVersion: apiVersion11));
    if (!broughtUp.hasError)
    {
        assert(vk.instance.instance !is null);
        assert(vk.surface !is null);
        assert(vk.physicalDevice !is null);
        assert(vk.device.device !is null);
        assert(vk.queue !is null);
        assert(vk.queueFamily != uint.max);
        vk.destroy();
    }
    static if (hasBorrow)
        assert(!wsi.endNativeIo().hasError);
    if (broughtUp.hasError)
    {
        assert(!wsi.destroyWindow(id).hasError);
        return broughtUp;
    }

    // Property: the single wait still progresses after the driver ran —
    // pump anything the ICD read past, then land an Event Horizon timer
    // through the same wait.
    static if (is(typeof(wsi.pumpEvents())))
        assert(!wsi.pumpEvents().hasError);
    else static if (is(typeof(wsi.pumpMessages())))
        assert(!wsi.pumpMessages().hasError);
    bool timerFired;
    assert(!loop.submitAfter(25.msecs, &timerComplete, &timerFired).hasError,
        "arming the probe timer failed");
    const deadline = MonoTime.currTime + 5.seconds;
    while (!timerFired)
    {
        assert(MonoTime.currTime < deadline,
            "the timer never fired through the shared wait");
        hooks.step(2.seconds);
    }

    assert(!wsi.destroyWindow(id).hasError);
    return vulkanWsiOk();
}
