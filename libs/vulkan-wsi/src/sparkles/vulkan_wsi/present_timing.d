/**
When presents reached the display, as `VK_EXT_present_timing` reports them
(`OPL22` of the output-latency specification), and a present aimed at a
time.

A swapchain created for present timing (`Swapchain.presentTiming`) keeps
results for a bounded queue of presents. Each present tagged with an id
(`VkPresentId2KHR`) may ask, through the request $(LREF PresentTimes.request)
builds, when it reached one stage: the first pixel visible where the surface
reports it, else the first pixel out. $(LREF PresentTimes.poll) reads the
results that are ready without waiting, as times on the `CLOCK_MONOTONIC`
clock `MonoTime` reads; the swapchain's refresh duration comes with them.
Where the device and the surface support it, a present aimed at a predicted
refresh carries that time as an absolute target, for the refresh nearest it.

A swapchain reports its times on `CLOCK_MONOTONIC` itself, or on a domain
local to the swapchain or to the stage (Mesa's, whatever the clock beneath).
A local domain is calibrated against `CLOCK_MONOTONIC` with
`vkGetCalibratedTimestampsKHR` (`VkSwapchainCalibratedTimestampInfoEXT`
naming the swapchain and stage), once when set up and again each second, and
results and targets cross by that offset.
*/
module sparkles.vulkan_wsi.present_timing;

import core.time : Duration, MonoTime, nsecs, seconds;

import sparkles.vulkan;

/**
The stage to ask a present's time at, of those the surface `offered`: the
first pixel visible, else the first pixel out; 0 when neither, which times
nothing.
*/
VkPresentStageFlagsEXT chooseStage(VkPresentStageFlagsEXT offered) @safe pure nothrow @nogc
{
    with (VkPresentStageFlagBitsEXT)
        return (offered & VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT)
            ? VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT
            : (offered & VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT)
            ? VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT : 0;
}

///
@("vulkan_wsi.present_timing.chooseStage.visibleElseOut")
@safe pure nothrow @nogc unittest
{
    with (VkPresentStageFlagBitsEXT)
    {
        assert(chooseStage(VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT
            | VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT)
            == VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT);
        assert(chooseStage(VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT
            | VK_PRESENT_STAGE_QUEUE_OPERATIONS_END_BIT_EXT)
            == VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT);
        assert(chooseStage(VK_PRESENT_STAGE_QUEUE_OPERATIONS_END_BIT_EXT) == 0,
            "a stage before the display is not a presentation time");
    }
}

/**
The time domain to read a swapchain's results on, among its `domains` (with
`ids`, as `vkGetSwapchainTimeDomainPropertiesEXT` lists them): `CLOCK_MONOTONIC`
where listed, needing no calibration; else one local to the present stage,
else to the swapchain, which `calibrates` (a device with calibrated
timestamps) allows. Sets `domain` and `id`; false when none fits, and nothing
is timed.
*/
bool findTimingDomain(scope const VkTimeDomainKHR[] domains, scope const ulong[] ids,
    bool calibrates, out VkTimeDomainKHR domain, out ulong id) @safe pure nothrow @nogc
{
    with (VkTimeDomainKHR)
    {
        static immutable VkTimeDomainKHR[3] preferred = [VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR,
            VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT, VK_TIME_DOMAIN_SWAPCHAIN_LOCAL_EXT];
        foreach (want; preferred[0 .. calibrates ? $ : 1])
            foreach (i, d; domains)
                if (d == want && i < ids.length)
                {
                    domain = d;
                    id = ids[i];
                    return true;
                }
    }
    return false;
}

///
@("vulkan_wsi.present_timing.findTimingDomain.monotonicElseACalibratedLocal")
@safe pure nothrow @nogc unittest
{
    with (VkTimeDomainKHR)
    {
        VkTimeDomainKHR domain;
        ulong id;
        const VkTimeDomainKHR[3] domains = [VK_TIME_DOMAIN_SWAPCHAIN_LOCAL_EXT,
            VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT, VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR];
        const ulong[3] ids = [7, 8, 9];
        assert(findTimingDomain(domains, ids, true, domain, id)
            && domain == VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR && id == 9);
        assert(findTimingDomain(domains[0 .. 2], ids[0 .. 2], true, domain, id)
            && domain == VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT && id == 8, "the stage's own clock");
        assert(findTimingDomain(domains[0 .. 1], ids[0 .. 1], true, domain, id)
            && domain == VK_TIME_DOMAIN_SWAPCHAIN_LOCAL_EXT && id == 7);
        assert(!findTimingDomain(domains[0 .. 2], ids[0 .. 2], false, domain, id),
            "a local domain is unusable without calibration");
    }
}

/**
The timing request for one present: when it reaches `stage`, on the domain
`domainId`, and — with `absolute` and a `target` — at the refresh nearest
`target`, as an absolute time on that domain, which is `offsetNanos` behind
`CLOCK_MONOTONIC`.
*/
VkPresentTimingInfoEXT presentTimingInfo(VkPresentStageFlagsEXT stage, ulong domainId,
    bool absolute, MonoTime target, long offsetNanos = 0) @safe pure nothrow @nogc
{
    auto info = vkInfo(VkPresentTimingInfoEXT(timeDomainId: domainId,
        presentStageQueries: stage));
    const at = (target - MonoTime.zero).total!"nsecs" - offsetNanos;
    if (absolute && target > MonoTime.zero && at > 0)
    {
        info.flags = VkPresentTimingInfoFlagBitsEXT
            .VK_PRESENT_TIMING_INFO_PRESENT_AT_NEAREST_REFRESH_CYCLE_BIT_EXT;
        info.targetTime = at;
        info.targetTimeDomainPresentStage = stage;
    }
    return info;
}

///
@("vulkan_wsi.present_timing.presentTimingInfo.aimsOnlyWhereAbsoluteTimesAre")
@safe pure nothrow @nogc unittest
{
    enum visible = VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT;
    // A whole number of seconds, exact on any tick rate (mach ticks are
    // 1/24 µs on Apple silicon).
    const at = MonoTime.zero + nsecs(5_000_000_000);
    const aimed = presentTimingInfo(visible, 3, true, at);
    assert(aimed.presentStageQueries == visible && aimed.timeDomainId == 3);
    assert(aimed.targetTime == 5_000_000_000 && aimed.targetTimeDomainPresentStage == visible);
    assert(aimed.flags == VkPresentTimingInfoFlagBitsEXT
        .VK_PRESENT_TIMING_INFO_PRESENT_AT_NEAREST_REFRESH_CYCLE_BIT_EXT, "absolute, not relative");
    // Without the support, or a target, the present only asks its time.
    const asked = presentTimingInfo(visible, 3, false, at);
    assert(asked.targetTime == 0 && asked.flags == 0 && asked.presentStageQueries == visible);
    assert(presentTimingInfo(visible, 3, true, MonoTime.init).targetTime == 0);
    // On a domain 100 ns behind `CLOCK_MONOTONIC`, the target is 100 ns less.
    assert(presentTimingInfo(visible, 3, true, at, 100).targetTime == 4_999_999_900);
}

/**
When the present `t` reports reaching `stage`, in nanoseconds on
`CLOCK_MONOTONIC`, where it is reported on `domain` with the id `domainId`,
`offsetNanos` behind `CLOCK_MONOTONIC`; 0 when it is not, which is no time:
a result on another domain is not used.
*/
long shownNanos(in VkPastPresentationTimingEXT t, VkPresentStageFlagsEXT stage,
    VkTimeDomainKHR domain, ulong domainId, long offsetNanos = 0) @trusted pure nothrow @nogc
{
    if (t.timeDomain != domain || t.timeDomainId != domainId || t.pPresentStages is null)
        return 0;
    foreach (ref s; t.pPresentStages[0 .. t.presentStageCount])
        if (s.stage == stage && s.time)
            return cast(long) s.time + offsetNanos;
    return 0;
}

///
@("vulkan_wsi.present_timing.shownNanos.onlyOnTheDomainReadAndShifted")
@system pure nothrow @nogc unittest
{
    enum visible = VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT;
    enum mono = VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR;
    enum local = VkTimeDomainKHR.VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT;
    VkPresentStageTimeEXT[1] stages = [VkPresentStageTimeEXT(visible, 42_000)];
    auto t = vkInfo(VkPastPresentationTimingEXT(presentId: 5, presentStageCount: 1,
        pPresentStages: stages.ptr, timeDomain: mono, timeDomainId: 3, reportComplete: VK_TRUE));
    assert(shownNanos(t, visible, mono, 3) == 42_000);
    assert(shownNanos(t, visible, mono, 4) == 0, "another domain's id");
    t.timeDomain = VkTimeDomainKHR.VK_TIME_DOMAIN_DEVICE_KHR;
    assert(shownNanos(t, visible, mono, 3) == 0, "another clock");
    t.timeDomain = local;
    assert(shownNanos(t, visible, local, 3, 1_000) == 43_000,
        "a local domain's time, moved onto CLOCK_MONOTONIC");
    stages[0].time = 0;
    assert(shownNanos(t, visible, local, 3, 1_000) == 0, "a present never shown");
}

/**
How far `domain` (with the id `domainId`, of `swapchain`, at `stage`) is
behind `CLOCK_MONOTONIC`, in nanoseconds, through `sample` (a
`vkGetCalibratedTimestampsKHR`) on `device`; false where it cannot be read.
*/
private bool calibrateDomain(Sample)(Sample sample, VkDevice device, VkSwapchainKHR swapchain,
    VkPresentStageFlagsEXT stage, VkTimeDomainKHR domain, ulong domainId, out long offsetNanos)
    @system
{
    if (domain == VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR)
        return true;
    if (sample is null)
        return false;
    auto which = vkInfo(VkSwapchainCalibratedTimestampInfoEXT(swapchain: swapchain,
        presentStage: domain == VkTimeDomainKHR.VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT ? stage : 0,
        timeDomainId: domainId));
    VkCalibratedTimestampInfoKHR[2] infos = [
        vkInfo(VkCalibratedTimestampInfoKHR(pNext: &which, timeDomain: domain)),
        vkInfo(VkCalibratedTimestampInfoKHR(
            timeDomain: VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR)),
    ];
    ulong[2] values;
    ulong deviation;
    if (sample(device, 2, infos.ptr, values.ptr, &deviation) != VkResult.VK_SUCCESS)
        return false;
    offsetNanos = cast(long)(values[1] - values[0]);
    return true;
}

/// The reader for one swapchain at a time; see the module documentation.
struct PresentTimes
{
    /// The swapchain's refresh duration where fixed and known; zero for
    /// unknown or variable (`OPL17`).
    Duration refresh;

    private VkSwapchainKHR swapchain_;
    private VkPresentStageFlagsEXT stage_;
    private VkTimeDomainKHR domain_;
    private ulong domainId_;
    private long offset_;      // how far the domain is behind CLOCK_MONOTONIC
    private bool ready_;       // a stage, and a domain on or calibrated to CLOCK_MONOTONIC
    private MonoTime calibrated_;
    private bool absolute_;
    private uint queueSize_, inQueue_;
    private ulong propertiesCounter_ = ulong.max, domainsCounter_ = ulong.max;
    private MonoTime lastResult_;

    /// Whether presents to the swapchain set up last are timed: it has a
    /// stage the surface reports and a domain on `CLOCK_MONOTONIC`, or one
    /// calibrated to it.
    bool ready() const @safe pure nothrow @nogc => ready_;

    /// The stage presents are timed at.
    VkPresentStageFlagsEXT stage() const @safe pure nothrow @nogc => stage_;

    /**
    Sets up for `swapchain`, created for present timing with a queue of
    `queueSize`, its surface reporting `stages`, and `absolute` when a
    present may carry an absolute target time; a swapchain already set up
    is left as it is. Reads the time domains and the refresh. False when
    presents to it cannot be timed.
    */
    bool prepare(Context)(ref Context vk, VkSwapchainKHR swapchain,
        VkPresentStageFlagsEXT stages, bool absolute, uint queueSize) @system
    {
        if (swapchain is swapchain_)
            return ready_;
        this = PresentTimes.init;
        swapchain_ = swapchain;
        stage_ = chooseStage(stages);
        absolute_ = absolute;
        queueSize_ = queueSize;
        if (swapchain is null || stage_ == 0 || queueSize == 0
            || vk.device.getPastPresentationTimingEXT is null)
            return false;
        readDomains(vk);
        readRefresh(vk);
        return ready_;
    }

    /**
    Whether the next present may ask its time: set up, and with room in the
    swapchain's timing queue, whose entries a $(LREF poll) frees. A queue
    that stays full for a second (a result that never came) is taken as
    empty again.
    */
    bool canRequest(MonoTime now) @safe pure nothrow @nogc
    {
        if (!ready_)
            return false;
        if (inQueue_ >= queueSize_ && now - lastResult_ > 1.seconds)
            inQueue_ = 0;
        return inQueue_ < queueSize_;
    }

    /// The request a present carries, aimed at `target` where absolute
    /// times are supported and `target` is set (`OPL22`).
    VkPresentTimingInfoEXT request(MonoTime target) const @safe pure nothrow @nogc
        => presentTimingInfo(stage_, domainId_, absolute_, target, offset_);

    /// The domain results are read on, and how far it is behind
    /// `CLOCK_MONOTONIC`, in nanoseconds: zero on that clock itself.
    VkTimeDomainKHR domain() const @safe pure nothrow @nogc => domain_;
    /// ditto
    long offsetNanos() const @safe pure nothrow @nogc => offset_;

    /// Notes that a present carried a request; `now` stamps it.
    void requested(MonoTime now) @safe pure nothrow @nogc
    {
        if (inQueue_ == 0)
            lastResult_ = now;
        ++inQueue_;
    }

    /// How many requested presents have no result read yet.
    uint outstanding() const @safe pure nothrow @nogc => inQueue_;

    /**
    Passes each present the swapchain reports since the last poll to
    `sink(id, shownNanos)`, `shownNanos` on `CLOCK_MONOTONIC`, oldest first,
    without waiting; results on another domain, or without the stage, are
    read and dropped. Re-reads the refresh and the domains when the
    swapchain says they changed, and recalibrates a local domain each
    second. Returns how many it reported.
    */
    size_t poll(Context, Sink)(ref Context vk, scope Sink sink) @system
    {
        if (!ready_ || vk.device.getPastPresentationTimingEXT is null)
            return 0;
        enum batch = 8;
        VkPresentStageTimeEXT[4][batch] stages;
        VkPastPresentationTimingEXT[batch] past;
        auto info = vkInfo(VkPastPresentationTimingInfoEXT(swapchain: swapchain_));
        size_t total;
        for (;;)
        {
            foreach (i, ref p; past)
                p = vkInfo(VkPastPresentationTimingEXT(
                    presentStageCount: cast(uint) stages[i].length, pPresentStages: stages[i].ptr));
            auto props = vkInfo(VkPastPresentationTimingPropertiesEXT(
                presentationTimingCount: batch, pPresentationTimings: past.ptr));
            const r = vk.device.getPastPresentationTimingEXT(vk.device.device, &info, &props);
            if (r < 0)
                return total;
            if (domain_ != VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR
                && MonoTime.currTime - calibrated_ >= 1.seconds)
                cast(void) calibrate(vk);
            if (props.timingPropertiesCounter != propertiesCounter_)
                readRefresh(vk);
            if (props.timeDomainsCounter != domainsCounter_)
                readDomains(vk);
            const count = props.presentationTimingCount < batch ? props.presentationTimingCount
                : batch;
            if (count)
                lastResult_ = MonoTime.currTime;
            foreach (ref t; past[0 .. count])
            {
                if (inQueue_)
                    --inQueue_;
                const at = shownNanos(t, stage_, domain_, domainId_, offset_);
                if (at)
                {
                    sink(t.presentId, at);
                    ++total;
                }
            }
            if (r != VkResult.VK_INCOMPLETE || count == 0)
                return total;
        }
    }

    // The swapchain's domain on `CLOCK_MONOTONIC`, else a local one
    // calibrated to it, without which nothing is timed.
    private void readDomains(Context)(ref Context vk) @system
    {
        VkTimeDomainKHR[8] domains;
        ulong[8] ids;
        auto props = vkInfo(VkSwapchainTimeDomainPropertiesEXT(timeDomainCount: domains.length,
            pTimeDomains: domains.ptr, pTimeDomainIds: ids.ptr));
        ulong counter;
        const r = vk.device.getSwapchainTimeDomainPropertiesEXT is null ? VkResult.VK_NOT_READY
            : vk.device.getSwapchainTimeDomainPropertiesEXT(vk.device.device, swapchain_, &props,
                &counter);
        const n = props.timeDomainCount < domains.length ? props.timeDomainCount : domains.length;
        ready_ = r >= 0 && stage_ != 0 && findTimingDomain(domains[0 .. n], ids[0 .. n],
            calibrationCommand(vk) !is null, domain_, domainId_) && calibrate(vk);
        domainsCounter_ = r >= 0 ? counter : ulong.max;
    }

    // Reads how far the domain is behind `CLOCK_MONOTONIC`; whether it could.
    private bool calibrate(Context)(ref Context vk) @system
    {
        calibrated_ = MonoTime.currTime;
        return calibrateDomain(calibrationCommand(vk), vk.device.device, swapchain_, stage_,
            domain_, domainId_, offset_);
    }

    // The refresh duration, zero until the swapchain knows it.
    private void readRefresh(Context)(ref Context vk) @system
    {
        auto props = vkInfo(VkSwapchainTimingPropertiesEXT());
        ulong counter;
        const r = vk.device.getSwapchainTimingPropertiesEXT is null ? VkResult.VK_NOT_READY
            : vk.device.getSwapchainTimingPropertiesEXT(vk.device.device, swapchain_, &props,
                &counter);
        refresh = r == VkResult.VK_SUCCESS && props.refreshDuration
            ? nsecs(cast(long) props.refreshDuration) : Duration.zero;
        propertiesCounter_ = r == VkResult.VK_SUCCESS ? counter : ulong.max;
    }
}

// The device's calibration command: the KHR's, else the EXT's; null for
// neither.
private auto calibrationCommand(Context)(ref Context vk)
    => vk.device.getCalibratedTimestampsKHR !is null ? vk.device.getCalibratedTimestampsKHR
        : vk.device.getCalibratedTimestampsEXT;

version (unittest)
{
    // A swapchain that reports `count` presents, `batch` a call, each shown
    // at its id in milliseconds; id 3 on another domain, id 4 never shown.
    // `localOnly` lists only a present-stage-local domain, as Mesa does, its
    // clock 500 ns behind `CLOCK_MONOTONIC`.
    private struct FakeTiming
    {
        uint count, read, batch = 3, domainReads, refreshReads, calibrations;
        ulong counter = 1;
        bool localOnly;
    }

    private FakeTiming* timingOf(VkDevice device) @trusted nothrow @nogc
        => cast(FakeTiming*) cast(void*) device;

    private extern (C) nothrow @nogc
    {
        VkResult fakePastTiming(VkDevice device, const(VkPastPresentationTimingInfoEXT)*,
            VkPastPresentationTimingPropertiesEXT* props)
        {
            auto f = timingOf(device);
            const left = f.count - f.read;
            uint give = left < props.presentationTimingCount ? left : props.presentationTimingCount;
            give = give < f.batch ? give : f.batch;
            foreach (i; 0 .. give)
            {
                auto t = &props.pPresentationTimings[i];
                const id = f.read + i + 1;
                t.presentId = id;
                t.timeDomain = f.localOnly ? VkTimeDomainKHR.VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT
                    : VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR;
                t.timeDomainId = id == 3 ? 99 : f.localOnly ? 0 : 5;
                t.presentStageCount = 1;
                t.pPresentStages[0] = VkPresentStageTimeEXT(f.localOnly
                    ? VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT
                    : VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT,
                    id == 4 ? 0 : id * 1_000_000);
                t.reportComplete = VK_TRUE;
            }
            f.read += give;
            props.presentationTimingCount = give;
            props.timingPropertiesCounter = f.counter;
            props.timeDomainsCounter = 1;
            return f.read < f.count ? VkResult.VK_INCOMPLETE : VkResult.VK_SUCCESS;
        }

        VkResult fakeDomains(VkDevice device, VkSwapchainKHR,
            VkSwapchainTimeDomainPropertiesEXT* props, ulong* counter)
        {
            auto f = timingOf(device);
            ++f.domainReads;
            props.pTimeDomains[0] = VkTimeDomainKHR.VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT;
            props.pTimeDomainIds[0] = f.localOnly ? 0 : 4;
            props.pTimeDomains[1] = VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR;
            props.pTimeDomainIds[1] = 5;
            props.timeDomainCount = f.localOnly ? 1 : 2;
            *counter = 1;
            return VkResult.VK_SUCCESS;
        }

        VkResult fakeCalibrate(VkDevice device, uint count,
            const(VkCalibratedTimestampInfoKHR)* infos, ulong* values, ulong* deviation)
        {
            assert(count == 2);
            assert(infos[0].timeDomain == VkTimeDomainKHR.VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT);
            const which = cast(const(VkSwapchainCalibratedTimestampInfoEXT)*) infos[0].pNext;
            assert(which !is null && which.sType
                == VkStructureType.VK_STRUCTURE_TYPE_SWAPCHAIN_CALIBRATED_TIMESTAMP_INFO_EXT);
            assert(which.presentStage
                == VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT
                && which.timeDomainId == 0 && which.swapchain !is null);
            assert(infos[1].timeDomain == VkTimeDomainKHR.VK_TIME_DOMAIN_CLOCK_MONOTONIC_KHR);
            ++timingOf(device).calibrations;
            values[0] = 1_000;
            values[1] = 1_500;
            *deviation = 1;
            return VkResult.VK_SUCCESS;
        }

        VkResult fakeTimingProperties(VkDevice device, VkSwapchainKHR,
            VkSwapchainTimingPropertiesEXT* props, ulong* counter)
        {
            auto f = timingOf(device);
            ++f.refreshReads;
            props.refreshDuration = f.counter == 1 ? 16_666_667 : 8_333_333;
            *counter = f.counter;
            return VkResult.VK_SUCCESS;
        }
    }

    private struct TimingVk
    {
        DeviceCommands device;
    }
}

@("vulkan_wsi.present_timing.pollReportsMonotonicTimesAndFreesTheQueue")
@system unittest
{
    // `OPL22`: results come back without waiting, in batches; one on another
    // domain and one never shown are read and dropped; each frees its entry
    // in the timing queue; a changed counter re-reads the refresh.
    FakeTiming f;
    TimingVk vk;
    vk.device.device = cast(VkDevice) cast(void*) &f;
    vk.device.getPastPresentationTimingEXT = &fakePastTiming;
    vk.device.getSwapchainTimeDomainPropertiesEXT = &fakeDomains;
    vk.device.getSwapchainTimingPropertiesEXT = &fakeTimingProperties;
    const swapchain = cast(VkSwapchainKHR) cast(void*) 0x10;
    enum stages = VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT
        | VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_VISIBLE_BIT_EXT;

    PresentTimes times;
    assert(times.prepare(vk, swapchain, stages, true, 3));
    assert(times.refresh == nsecs(16_666_667) && f.domainReads == 1 && f.refreshReads == 1);
    assert(times.request(MonoTime.zero + nsecs(1)).timeDomainId == 5);
    assert(times.prepare(vk, swapchain, stages, true, 3) && f.domainReads == 1,
        "set up once a swapchain");

    const now = MonoTime.currTime;
    foreach (_; 0 .. 3)
    {
        assert(times.canRequest(now));
        times.requested(now);
    }
    assert(!times.canRequest(now), "the queue is full until a poll frees it");

    ulong[8] ids;
    long[8] at;
    size_t seen;
    void sink(ulong id, long ns)
    {
        ids[seen] = id;
        at[seen++] = ns;
    }
    f.count = 5;
    f.counter = 2; // the refresh changed
    assert(times.poll(vk, &sink) == 3);
    assert(ids[0 .. 3] == [1, 2, 5] && at[2] == 5_000_000);
    assert(times.outstanding == 0 && times.canRequest(now));
    assert(times.refresh == nsecs(8_333_333));
    assert(times.poll(vk, &sink) == 0, "nothing new");

    // A swapchain that names no stage on the display is not timed.
    PresentTimes none;
    assert(!none.prepare(vk, swapchain, VkPresentStageFlagBitsEXT
        .VK_PRESENT_STAGE_QUEUE_OPERATIONS_END_BIT_EXT, true, 3));
    assert(!none.canRequest(now) && none.poll(vk, &sink) == 0);
}

@("vulkan_wsi.present_timing.aStageLocalDomainIsCalibratedToTheMonotonicClock")
@system unittest
{
    // `OPL22` on a swapchain listing only a present-stage-local domain, as
    // Mesa's do: it is calibrated against `CLOCK_MONOTONIC` through the
    // swapchain and stage, results move onto that clock and targets off it;
    // without a calibration command nothing is timed.
    FakeTiming f;
    f.localOnly = true;
    TimingVk vk;
    vk.device.device = cast(VkDevice) cast(void*) &f;
    vk.device.getPastPresentationTimingEXT = &fakePastTiming;
    vk.device.getSwapchainTimeDomainPropertiesEXT = &fakeDomains;
    vk.device.getSwapchainTimingPropertiesEXT = &fakeTimingProperties;
    const swapchain = cast(VkSwapchainKHR) cast(void*) 0x10;
    enum outStage = VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_IMAGE_FIRST_PIXEL_OUT_BIT_EXT;
    enum stages = outStage | VkPresentStageFlagBitsEXT.VK_PRESENT_STAGE_QUEUE_OPERATIONS_END_BIT_EXT;

    PresentTimes uncalibrated;
    assert(!uncalibrated.prepare(vk, swapchain, stages, true, 3),
        "a local domain without a calibration command");

    vk.device.getCalibratedTimestampsKHR = &fakeCalibrate;
    PresentTimes times;
    assert(times.prepare(vk, swapchain, stages, true, 3));
    assert(times.domain == VkTimeDomainKHR.VK_TIME_DOMAIN_PRESENT_STAGE_LOCAL_EXT
        && times.offsetNanos == 500 && f.calibrations == 1);
    const target = times.request(MonoTime.zero + nsecs(2_000_500));
    assert(target.timeDomainId == 0 && target.targetTime == 2_000_000, "aimed on the local clock");

    ulong[8] ids;
    long[8] at;
    size_t seen;
    void sink(ulong id, long ns)
    {
        ids[seen] = id;
        at[seen++] = ns;
    }
    f.count = 2;
    assert(times.poll(vk, &sink) == 2);
    assert(ids[0 .. 2] == [1, 2] && at[0 .. 2] == [1_000_500, 2_000_500],
        "shown on CLOCK_MONOTONIC");
}

@("vulkan_wsi.present_timing.aQueueFullForASecondIsTakenAsEmpty")
@safe pure nothrow @nogc unittest
{
    PresentTimes t;
    t.ready_ = true;
    t.queueSize_ = 1;
    const at = MonoTime.zero + 10.seconds;
    t.requested(at);
    assert(!t.canRequest(at + nsecs(500_000_000)));
    assert(t.canRequest(at + 2.seconds), "a result that never came frees its entry");
}
