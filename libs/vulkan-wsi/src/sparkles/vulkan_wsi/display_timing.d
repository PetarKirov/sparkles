/**
When presents reached the display, and the display's refresh period, as
`VK_GOOGLE_display_timing` reports them (`PRF13`, `PRF14` of the profiling
specification) — Android's way, and the only one there.

A present carries an id (`Swapchain.present`'s `displayTimingId`); the
implementation reports each one's `actualPresentTime` some frames later, on
the platform's monotonic clock (`CLOCK_MONOTONIC`, which `MonoTime` reads on
Linux and Android). $(LREF DisplayTimes.poll) reads what is ready without
waiting, and the refresh period is read once per swapchain.
*/
module sparkles.vulkan_wsi.display_timing;

import core.time : Duration, nsecs;

import sparkles.vulkan;

/// ditto
struct DisplayTimes
{
    /// The display's refresh period for the swapchain read last; zero until
    /// known.
    Duration refresh;
    private VkSwapchainKHR refreshOf;

    /// The id a present of frame `frame` carries: never zero, which tags
    /// nothing.
    static uint idFor(ulong frame) @safe pure nothrow @nogc
    {
        const id = cast(uint)(frame + 1);
        return id ? id : 1;
    }

    /**
    Passes each present `swapchain` reports as shown since the last poll to
    `sink(id, shownNanos)` — `shownNanos` on the monotonic clock — oldest
    first, without waiting; reads the refresh period on a new swapchain.
    Returns how many it reported. A device without the extension reports
    none.
    */
    size_t poll(Context, Sink)(ref Context vk, VkSwapchainKHR swapchain, scope Sink sink) @system
    {
        if (!vk.displayTiming || swapchain is null
            || vk.device.getPastPresentationTimingGOOGLE is null)
            return 0;
        if (swapchain !is refreshOf)
        {
            VkRefreshCycleDurationGOOGLE cycle;
            if (vk.device.getRefreshCycleDurationGOOGLE(vk.device.device, swapchain, &cycle)
                == VkResult.VK_SUCCESS && cycle.refreshDuration > 0)
                refresh = nsecs(cast(long) cycle.refreshDuration);
            refreshOf = swapchain;
        }
        // Read in batches: an implementation keeps a bounded queue of them.
        VkPastPresentationTimingGOOGLE[16] past;
        size_t total;
        for (;;)
        {
            uint count = past.length;
            const r = vk.device.getPastPresentationTimingGOOGLE(vk.device.device, swapchain,
                &count, past.ptr);
            if (r < 0)
                return total;
            foreach (ref t; past[0 .. count < past.length ? count : past.length])
                if (t.actualPresentTime)
                {
                    sink(t.presentID, cast(long) t.actualPresentTime);
                    ++total;
                }
            if (r != VkResult.VK_INCOMPLETE || count == 0)
                return total;
        }
    }
}

@("vulkan_wsi.display_timing.idsAreNeverZero")
@safe pure nothrow @nogc unittest
{
    assert(DisplayTimes.idFor(0) == 1 && DisplayTimes.idFor(41) == 42);
    assert(DisplayTimes.idFor(uint.max) == 1, "past the wrap, still a tag");
}

version (unittest)
{
    // A device that has shown `shown` presents (id, time); it answers at most
    // `batch` a call, `VK_INCOMPLETE` while more remain.
    private struct FakeTimes
    {
        VkPastPresentationTimingGOOGLE[40] shown;
        uint count, read, batch = 16, refreshCalls;
    }

    private FakeTimes* timesOf(VkDevice device) @trusted nothrow @nogc
        => cast(FakeTimes*) cast(void*) device;

    private extern (C) nothrow @nogc
    {
        VkResult fakePast(VkDevice device, VkSwapchainKHR, uint* count,
            VkPastPresentationTimingGOOGLE* out_)
        {
            auto f = timesOf(device);
            const left = f.count - f.read;
            const n = left < *count ? left : *count;
            const give = n < f.batch ? n : f.batch;
            foreach (i; 0 .. give)
                out_[i] = f.shown[f.read + i];
            f.read += give;
            *count = give;
            return f.read < f.count ? VkResult.VK_INCOMPLETE : VkResult.VK_SUCCESS;
        }

        VkResult fakeRefresh(VkDevice device, VkSwapchainKHR, VkRefreshCycleDurationGOOGLE* cycle)
        {
            ++timesOf(device).refreshCalls;
            cycle.refreshDuration = 8_333_333; // 120 Hz
            return VkResult.VK_SUCCESS;
        }
    }

    private struct TimesVk
    {
        bool displayTiming = true;
        DeviceCommands device;
    }
}

@("vulkan_wsi.display_timing.pollReadsEveryBatchAndTheRefresh")
@system unittest
{
    FakeTimes f;
    foreach (i; 0 .. 20)
        f.shown[i] = VkPastPresentationTimingGOOGLE(presentID: i + 1,
            actualPresentTime: i == 3 ? 0 : 1_000_000 * (i + 1));
    f.count = 20;
    f.batch = 7;
    TimesVk vk;
    vk.device.device = cast(VkDevice) cast(void*) &f;
    vk.device.getPastPresentationTimingGOOGLE = &fakePast;
    vk.device.getRefreshCycleDurationGOOGLE = &fakeRefresh;
    const swapchain = cast(VkSwapchainKHR) cast(void*) 0x10;

    DisplayTimes times;
    uint[20] ids;
    long[20] at;
    size_t seen;
    void sink(uint id, long shownNanos)
    {
        ids[seen] = id;
        at[seen++] = shownNanos;
    }
    assert(times.poll(vk, swapchain, &sink) == 19, "a present with no time is skipped");
    assert(ids[0] == 1 && ids[3] == 5 && ids[18] == 20 && at[18] == 20_000_000);
    assert(times.refresh == nsecs(8_333_333) && f.refreshCalls == 1);
    assert(times.poll(vk, swapchain, &sink) == 0 && f.refreshCalls == 1,
        "nothing new; the refresh is read once a swapchain");
    vk.displayTiming = false;
    assert(times.poll(vk, swapchain, &sink) == 0);
}
