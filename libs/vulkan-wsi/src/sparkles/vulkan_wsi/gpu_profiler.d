/**
The device's time for named scopes of a frame's command buffer (`PRF10`–`PRF12`
of the profiling specification).

A $(LREF GpuProfiler) owns one timestamp query pool per frame slot. A frame
opens its slot with $(LREF GpuProfiler.beginFrame), then brackets its work in
scopes — nested or one after another, up to `maxGpuScopes` — with
$(LREF GpuProfiler.begin) and $(LREF GpuProfiler.end). Nothing is read back
while the frame runs: when the slot comes round again and its fence has been
waited, $(LREF GpuProfiler.collect) reads what the slot's previous frame
measured, without the wait bit, and adds it to a `FrameRecord`. The times are
therefore those of the frame drawn `framesInFlight` frames before the record
they are added to; where they are calibrated, their starts say when they ran.

What the driver supports decides the rest, and the profiler says what it got:

$(UL
$(LI $(B `supported`): the queue's timestamps carry valid bits. A queue whose
    `timestampValidBits` is 0 gets no pools, and every call is a no-op. The
    counter wraps at its valid bits, and every difference is taken modulo
    them.)
$(LI $(B `calibrated`): the device enabled `VK_KHR_calibrated_timestamps` (or
    the EXT) and samples the clock `MonoTime` reads
    (`VulkanDevice.calibratedTimestamps`). A (device, host) pair is sampled
    at most once a second, and each scope's start is placed on the CPU's
    timeline, as a `Duration` since the `FrameClock`'s origin. Without it a
    scope's start is from the frame's first scope.)
$(LI $(B `labels`): the instance enabled `VK_EXT_debug_utils`
    (`VulkanDevice.debugUtils`). Each scope is then also a debug label
    carrying its name, so RenderDoc, Nsight and RGP show the same structure.))

Scope names are registered once ($(LREF GpuProfiler.name)) into a table a
trace export reads (`writeChromeTrace`'s `gpuNames`); a `GpuScope` carries
the index.

The device commands are reached through `vk.device`, and the capabilities
through `vk.timestampValidBits`, `vk.properties.limits.timestampPeriod`,
`vk.calibratedTimestamps` and `vk.debugUtils`: a `VulkanDevice` or a
`VulkanContext`, or a test's stand-in.
*/
module sparkles.vulkan_wsi.gpu_profiler;

import core.time : Duration, MonoTime, nsecs, seconds, ticksToNSecs;

import sparkles.base.expected : err, ok;
import sparkles.base.text.cstring : toTempStringz;
import sparkles.profiling.frame : FrameClock, FrameRecord, GpuScope, maxGpuScopes;
import sparkles.vulkan;
import sparkles.vulkan_wsi.device : monoTimeDomain;
import sparkles.vulkan_wsi.error : PresentationResult;

/**
A (device, host) clock pair sampled together: the device's timestamp, in
ticks within the valid bits, and the host's clock, in nanoseconds of
`MonoTime`'s clock.
*/
struct GpuCalibration
{
    ulong gpuTicks;  ///
    long hostNanos;  ///
    bool valid;      ///
}

/**
The ticks from `from` to `to` on a counter that wraps at `mask + 1`: a later
reading past the wrap is still later.
*/
ulong tickDelta(ulong from, ulong to, ulong mask) @safe pure nothrow @nogc
    => (to - from) & mask;

/**
`ticks`, a device timestamp, on the CPU's timeline: a `Duration` since
`originNanos` (a `MonoTime` in nanoseconds), through calibration `c`.

The reading may be before or after the calibration: the nearer way round the
counter's wrap is taken, so a timestamp just before the sample is not read as
one a whole wrap after it.
*/
Duration onCpuTimeline(ulong ticks, in GpuCalibration c, ulong mask, double nanosPerTick,
    long originNanos) @safe pure nothrow @nogc
{
    const forward = tickDelta(c.gpuTicks, ticks, mask);
    const signed = forward > (mask >> 1) ? -cast(long) tickDelta(ticks, c.gpuTicks, mask)
        : cast(long) forward;
    return nsecs(c.hostNanos + cast(long)(signed * nanosPerTick) - originNanos);
}

/// A host clock reading of $(LREF monoTimeDomain), in `MonoTime` nanoseconds.
long hostNanos(ulong value) @safe pure nothrow @nogc
{
    version (Windows)
        return ticksToNSecs(cast(long) value); // QueryPerformanceCounter ticks
    else
        return cast(long) value; // CLOCK_MONOTONIC, in nanoseconds
}

/// ditto
struct GpuProfiler
{
    /// The most scope names one profiler registers.
    enum size_t maxNames = 255;

    /// The queue has timestamps and the pools exist: scopes are measured.
    bool supported;
    /// Scope starts are placed on the CPU's timeline (`PRF11`).
    bool calibrated;
    /// Each scope is also a debug label (`PRF12`).
    bool labels;

    private Slot[] slots;
    private ulong mask;
    private double nanosPerTick = 0;
    private GpuCalibration calibration;
    private MonoTime calibratedAt;
    private MonoTime calibrationTried;
    private string[maxNames] nameTable;
    private ubyte nameCount;

    @disable this(this);

    /**
    Makes the profiler for `slots` frame slots on `vk`'s queue. A queue whose
    timestamps have no valid bits leaves it unsupported, which is not an
    error; a query pool the device refuses is.
    */
    static PresentationResult!void create(Context)(out GpuProfiler p, ref Context vk,
        uint slots) @system
    in (slots > 0, "at least one frame slot")
    {
        const bits = vk.timestampValidBits;
        const period = vk.properties.limits.timestampPeriod;
        if (bits == 0 || period <= 0)
            return ok!string();
        p.mask = bits >= 64 ? ulong.max : (1UL << bits) - 1;
        p.nanosPerTick = period;
        p.slots = new Slot[slots];
        auto info = vkInfo(VkQueryPoolCreateInfo(
            queryType: VkQueryType.VK_QUERY_TYPE_TIMESTAMP,
            queryCount: 2 * maxGpuScopes,
        ));
        foreach (ref s; p.slots)
        {
            const r = vk.device.createQueryPool(vk.device.device, &info, null, &s.pool);
            if (r != VkResult.VK_SUCCESS)
            {
                s.pool = null;
                p.destroy(vk);
                return err!void("vkCreateQueryPool: " ~ describeResult(r));
            }
        }
        p.supported = true;
        p.calibrated = vk.calibratedTimestamps && calibrationCommand(vk) !is null;
        p.labels = vk.debugUtils && vk.device.cmdBeginDebugUtilsLabelEXT !is null
            && vk.device.cmdEndDebugUtilsLabelEXT !is null;
        return ok!string();
    }

    /// Destroys the pools, the device idle; idempotent.
    void destroy(Context)(ref Context vk) @system
    {
        foreach (ref s; slots)
            if (s.pool !is null && vk.device.device !is null)
                vk.device.destroyQueryPool(vk.device.device, s.pool, null);
        this = GpuProfiler.init;
    }

    /**
    The index of scope name `n`, registered on first use: calling it every
    frame finds the same index. `n` is kept, not copied. Past `maxNames`
    names, the last index is shared.
    */
    ubyte name(string n) @safe pure nothrow @nogc
    {
        foreach (i, known; nameTable[0 .. nameCount])
            if (known == n)
                return cast(ubyte) i;
        if (nameCount == maxNames)
            return cast(ubyte)(maxNames - 1);
        nameTable[nameCount] = n;
        return nameCount++;
    }

    /// The registered names, by index: a trace's `gpuNames`.
    const(string)[] names() const @safe pure nothrow @nogc return => nameTable[0 .. nameCount];

    /// How many frame slots there are; 0 when unsupported.
    size_t slotCount() const @safe pure nothrow @nogc => slots.length;

    /**
    Opens frame slot `slot` in `cmd`: resets its queries, so it must be
    recorded outside a render pass, before the frame's first scope. What the
    slot held must have been collected first.
    */
    void beginFrame(Context)(ref Context vk, VkCommandBuffer cmd, uint slot) @system
    {
        if (!supported || slot >= slots.length)
            return;
        auto s = &slots[slot];
        s.count = s.open = s.dropped = s.labels = 0;
        s.recorded = true;
        vk.device.cmdResetQueryPool(cmd, s.pool, 0, 2 * maxGpuScopes);
    }

    /**
    Begins a scope named `nameIndex` (from $(LREF name)) in slot `slot`,
    nested in any scope still open. Past `maxGpuScopes` scopes in a frame,
    the rest are labelled but not timed.
    */
    void begin(Context)(ref Context vk, VkCommandBuffer cmd, uint slot, ubyte nameIndex)
        @system
    {
        if (!supported || slot >= slots.length)
            return;
        auto s = &slots[slot];
        if (labels)
        {
            auto z = (nameIndex < nameCount ? nameTable[nameIndex] : "gpu").toTempStringz;
            auto label = vkInfo(VkDebugUtilsLabelEXT(pLabelName: z.ptr));
            vk.device.cmdBeginDebugUtilsLabelEXT(cmd, &label);
            ++s.labels;
        }
        if (s.count == maxGpuScopes || s.open == s.stack.length)
        {
            ++s.dropped;
            return;
        }
        const index = s.count++;
        s.names[index] = nameIndex;
        s.depths[index] = s.open;
        s.stack[s.open++] = index;
        vk.device.cmdWriteTimestamp(cmd,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, s.pool, 2 * index);
    }

    /// Ends the innermost open scope of slot `slot`.
    void end(Context)(ref Context vk, VkCommandBuffer cmd, uint slot) @system
    {
        if (!supported || slot >= slots.length)
            return;
        auto s = &slots[slot];
        // Only a label it pushed: an `end` with nothing open must not close
        // the caller's own.
        if (labels && s.labels)
        {
            vk.device.cmdEndDebugUtilsLabelEXT(cmd);
            --s.labels;
        }
        if (s.dropped)
        {
            --s.dropped;
            return;
        }
        if (s.open == 0)
            return;
        const index = s.stack[--s.open];
        vk.device.cmdWriteTimestamp(cmd,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, s.pool, 2 * index + 1);
    }

    /**
    The frame recorded in slot `slot` since $(LREF beginFrame) was not
    submitted (its recording or its submit failed): its queries were never
    reset, and still hold an older frame's results, which `collect` must not
    read as new.
    */
    void abandon(uint slot) @safe pure nothrow @nogc
    {
        if (slot < slots.length)
            slots[slot].recorded = false;
    }

    /**
    Reads what slot `slot`'s previous frame measured into `record`, once the
    slot's fence has been waited: its scopes, in the order they began, and
    `record.gpu`, the span from the first top-level scope's start to the last
    one's end. Never waits: a scope whose timestamps are not available (it was
    never ended, or its submit has not run) is absent. Calibrated starts are
    since `clock`'s origin; `now` decides whether to recalibrate. Returns
    whether it added any scope.
    */
    bool collect(Context)(ref Context vk, uint slot, ref FrameRecord record, in FrameClock clock,
        MonoTime now = MonoTime.currTime) @system
    {
        if (!supported || slot >= slots.length || !slots[slot].recorded || slots[slot].count == 0)
            return false;
        auto s = &slots[slot];
        s.recorded = false;
        // Each query as its value and its availability, so one scope still
        // pending leaves the others readable.
        ulong[2][2 * maxGpuScopes] results;
        const got = vk.device.getQueryPoolResults(vk.device.device, s.pool, 0, 2 * s.count,
            results[0].sizeof * 2 * s.count, results.ptr, results[0].sizeof,
            VkQueryResultFlagBits.VK_QUERY_RESULT_64_BIT
                | VkQueryResultFlagBits.VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
        if (got != VkResult.VK_SUCCESS && got != VkResult.VK_NOT_READY)
            return false;

        const onTimeline = calibrated && calibrate(vk, now);
        const originNanos = ticksToNSecs(clock.originTime.ticks);
        bool any, spanSet;
        ulong first, spanStart, spanEnd;
        foreach (i; 0 .. s.count)
        {
            const begun = results[2 * i], ended = results[2 * i + 1];
            if (begun[1] == 0 || ended[1] == 0)
                continue;
            const start = begun[0] & mask, stop = ended[0] & mask;
            if (!any)
                first = start;
            any = true;
            const from = tickDelta(first, start, mask);
            const took = tickDelta(start, stop, mask);
            GpuScope g;
            g.name = s.names[i];
            g.depth = s.depths[i];
            g.took = ticks(took);
            g.calibrated = onTimeline;
            g.start = onTimeline
                ? onCpuTimeline(start, calibration, mask, nanosPerTick, originNanos)
                : ticks(from);
            record.addGpuScope(g);
            if (s.depths[i] == 0)
            {
                if (!spanSet)
                    spanStart = from;
                spanSet = true;
                if (from + took > spanEnd)
                    spanEnd = from + took;
            }
        }
        if (spanSet)
            record.gpu = ticks(spanEnd - spanStart);
        return any;
    }

    /// The calibration in use, for a report.
    GpuCalibration currentCalibration() const @safe pure nothrow @nogc => calibration;

    private Duration ticks(ulong n) const @safe pure nothrow @nogc
        => nsecs(cast(long)(n * nanosPerTick));

    // Samples a (device, host) pair where the last is a second old or more;
    // whether a calibration is valid.
    private bool calibrate(Context)(ref Context vk, MonoTime now) @system
    {
        // A calibration places a scope the nearer way round the counter's
        // wrap, so it is kept for at most a quarter of the wrap, and a second.
        const wrapNanos = mask == ulong.max ? double.infinity : (mask + 1.0) * nanosPerTick;
        const keep = wrapNanos / 4 < 1e9 ? nsecs(cast(long)(wrapNanos / 4)) : 1.seconds;
        const fresh = calibration.valid && now - calibratedAt < keep;
        // Sampled at most once a keep period, so a failing driver is not
        // asked every frame; an expired calibration is never used.
        if (fresh || (calibrationTried != MonoTime.init && now - calibrationTried < keep))
            return fresh;
        calibrationTried = now;
        auto sample = calibrationCommand(vk);
        if (sample is null)
            return false;
        VkCalibratedTimestampInfoKHR[2] infos = [
            vkInfo(VkCalibratedTimestampInfoKHR(
                timeDomain: VkTimeDomainKHR.VK_TIME_DOMAIN_DEVICE_KHR)),
            vkInfo(VkCalibratedTimestampInfoKHR(timeDomain: monoTimeDomain)),
        ];
        ulong[2] values;
        ulong deviation;
        if (sample(vk.device.device, 2, infos.ptr, values.ptr, &deviation) != VkResult.VK_SUCCESS)
            return false;
        calibration = GpuCalibration(gpuTicks: values[0] & mask,
            hostNanos: hostNanos(values[1]), valid: true);
        calibratedAt = now;
        return true;
    }
}

// The device's calibration command: the KHR's, else the EXT's.
private auto calibrationCommand(Context)(ref Context vk)
    => vk.device.getCalibratedTimestampsKHR !is null ? vk.device.getCalibratedTimestampsKHR
        : vk.device.getCalibratedTimestampsEXT;

// One frame slot's queries: scope `i` writes queries `2i` (start) and
// `2i + 1` (end) of `pool`.
private struct Slot
{
    VkQueryPool pool;
    ubyte count;    // scopes begun in the frame
    ubyte open;     // scopes open, on `stack`
    ubyte dropped;  // scopes begun past the capacity, still open
    bool recorded;  // `beginFrame` reset the queries since the last collect
    ubyte labels;   // debug labels open in the frame's command buffer
    ubyte[maxGpuScopes] names;
    ubyte[maxGpuScopes] depths;
    ubyte[maxGpuScopes] stack;
}

@("vulkan_wsi.gpu_profiler.calibratedConversion")
@safe pure nothrow @nogc unittest
{
    import core.time : msecs, usecs;

    // 24 valid bits at 2 ns a tick, calibrated at tick 1000 = 5 s on the
    // host clock; the run began at 4 s.
    enum mask = (1UL << 24) - 1;
    const c = GpuCalibration(gpuTicks: 1000, hostNanos: 5_000_000_000, valid: true);
    const origin = 4_000_000_000;
    assert(onCpuTimeline(1000, c, mask, 2.0, origin) == 1000.msecs);
    assert(onCpuTimeline(1500, c, mask, 2.0, origin) == 1000.msecs + 1.usecs);
    // Before the sample: earlier on the host's clock, not a wrap later.
    assert(onCpuTimeline(500, c, mask, 2.0, origin) == 1000.msecs - 1.usecs);
    // Across the wrap: a sample near the top, a reading just past zero.
    const top = GpuCalibration(gpuTicks: mask - 9, hostNanos: 5_000_000_000, valid: true);
    assert(onCpuTimeline(10, top, mask, 2.0, origin) == 1000.msecs + nsecs(40));
    // 64 valid bits wrap at the integer's own width.
    const wide = GpuCalibration(gpuTicks: ulong.max - 1, hostNanos: 5_000_000_000, valid: true);
    assert(onCpuTimeline(2, wide, ulong.max, 1.0, origin) == 1000.msecs + nsecs(4));
    assert(tickDelta(mask - 1, 3, mask) == 5);
}

version (unittest)
{
    // A device that keeps the timestamps a test writes into its pools and
    // answers a results query from them: what `vkCmdWriteTimestamp` records
    // is `nextTick`, and only queries written since the last reset are
    // available. The device and the command buffer handles both point at the
    // test's own `FakeGpu`, so tests running in parallel share nothing.
    private struct FakePool
    {
        FakeGpu* gpu;
        ulong[2 * maxGpuScopes] value;
        bool[2 * maxGpuScopes] available;
    }

    private struct FakeGpu
    {
        ulong nextTick;
        FakePool[4] pools;
        size_t poolsMade, poolsDestroyed, calibrations, labelsBegun, labelsEnded;
        ulong[2] calibrationAnswer;
        VkResult poolAnswer = VkResult.VK_SUCCESS;
        char[32] lastLabel;
    }

    private FakeGpu* gpuOf(T)(T handle) @trusted nothrow @nogc => cast(FakeGpu*) cast(void*) handle;
    private FakePool* poolOf(VkQueryPool handle) @trusted nothrow @nogc
        => cast(FakePool*) cast(void*) handle;

    private extern (C) nothrow @nogc
    {
        VkResult gpuFakeCreatePool(VkDevice device, const(VkQueryPoolCreateInfo)* info,
            const(VkAllocationCallbacks)*, VkQueryPool* pool)
        {
            auto gpu = gpuOf(device);
            if (gpu.poolAnswer != VkResult.VK_SUCCESS)
                return gpu.poolAnswer;
            assert(info.queryType == VkQueryType.VK_QUERY_TYPE_TIMESTAMP);
            assert(info.queryCount == 2 * maxGpuScopes);
            auto made = &gpu.pools[gpu.poolsMade++];
            made.gpu = gpu;
            *pool = cast(VkQueryPool) cast(void*) made;
            return VkResult.VK_SUCCESS;
        }
        void gpuFakeDestroyPool(VkDevice device, VkQueryPool, const(VkAllocationCallbacks)*)
        {
            ++gpuOf(device).poolsDestroyed;
        }
        void gpuFakeReset(VkCommandBuffer, VkQueryPool pool, uint first, uint count)
        {
            poolOf(pool).available[first .. first + count] = false;
        }
        void gpuFakeWrite(VkCommandBuffer, VkPipelineStageFlagBits, VkQueryPool pool, uint query)
        {
            auto p = poolOf(pool);
            p.value[query] = p.gpu.nextTick;
            p.available[query] = true;
        }
        VkResult gpuFakeResults(VkDevice, VkQueryPool pool, uint first, uint count, size_t size,
            void* data, VkDeviceSize stride, VkQueryResultFlags flags)
        {
            assert(flags & VkQueryResultFlagBits.VK_QUERY_RESULT_64_BIT);
            assert(!(flags & VkQueryResultFlagBits.VK_QUERY_RESULT_WAIT_BIT), "reading never waits");
            assert(flags & VkQueryResultFlagBits.VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
            assert(stride == 16 && size >= count * stride);
            auto p = poolOf(pool);
            auto out_ = cast(ulong*) data;
            bool all = true;
            foreach (q; first .. first + count)
            {
                all &= p.available[q];
                out_[2 * (q - first)] = p.available[q] ? p.value[q] : 0xDEAD;
                out_[2 * (q - first) + 1] = p.available[q];
            }
            return all ? VkResult.VK_SUCCESS : VkResult.VK_NOT_READY;
        }
        VkResult gpuFakeCalibrate(VkDevice device, uint count,
            const(VkCalibratedTimestampInfoKHR)* infos, ulong* values, ulong* deviation)
        {
            assert(count == 2);
            assert(infos[0].timeDomain == VkTimeDomainKHR.VK_TIME_DOMAIN_DEVICE_KHR);
            assert(infos[1].timeDomain == monoTimeDomain);
            auto gpu = gpuOf(device);
            ++gpu.calibrations;
            values[0] = gpu.calibrationAnswer[0];
            values[1] = gpu.calibrationAnswer[1];
            *deviation = 1;
            return VkResult.VK_SUCCESS;
        }
        void gpuFakeBeginLabel(VkCommandBuffer cmd, const(VkDebugUtilsLabelEXT)* label)
        {
            import core.stdc.string : strlen;

            auto gpu = gpuOf(cmd);
            ++gpu.labelsBegun;
            const n = strlen(label.pLabelName);
            gpu.lastLabel[] = 0;
            gpu.lastLabel[0 .. n] = label.pLabelName[0 .. n];
        }
        void gpuFakeEndLabel(VkCommandBuffer cmd) { ++gpuOf(cmd).labelsEnded; }
    }

    private struct ProfilerDevice
    {
        VkDevice device;
        typeof(&gpuFakeCreatePool) createQueryPool = &gpuFakeCreatePool;
        typeof(&gpuFakeDestroyPool) destroyQueryPool = &gpuFakeDestroyPool;
        typeof(&gpuFakeReset) cmdResetQueryPool = &gpuFakeReset;
        typeof(&gpuFakeWrite) cmdWriteTimestamp = &gpuFakeWrite;
        typeof(&gpuFakeResults) getQueryPoolResults = &gpuFakeResults;
        typeof(&gpuFakeCalibrate) getCalibratedTimestampsKHR;
        typeof(&gpuFakeCalibrate) getCalibratedTimestampsEXT;
        typeof(&gpuFakeBeginLabel) cmdBeginDebugUtilsLabelEXT;
        typeof(&gpuFakeEndLabel) cmdEndDebugUtilsLabelEXT;
    }

    // What `GpuProfiler` reads of a `VulkanDevice`, over a `FakeGpu`.
    private struct ProfilerVk
    {
        ProfilerDevice device;
        VkPhysicalDeviceProperties properties;
        uint timestampValidBits;
        bool calibratedTimestamps;
        bool debugUtils;
        VkCommandBuffer cmd;

        this(FakeGpu* gpu, uint bits, float period = 1.0f) @trusted nothrow @nogc
        {
            device.device = cast(VkDevice) cast(void*) gpu;
            cmd = cast(VkCommandBuffer) cast(void*) gpu;
            timestampValidBits = bits;
            properties.limits.timestampPeriod = period;
        }
    }
}

@("vulkan_wsi.gpu_profiler.unsupportedQueueDoesNothing")
@system unittest
{
    // No valid bits: no pools, no commands, no scopes — and no error.
    FakeGpu gpu;
    auto vk = ProfilerVk(&gpu, 0);
    GpuProfiler p;
    assert(!GpuProfiler.create(p, vk, 2).hasError);
    assert(!p.supported && p.slotCount == 0 && gpu.poolsMade == 0);
    p.beginFrame(vk, vk.cmd, 0);
    p.begin(vk, vk.cmd, 0, p.name("frame"));
    p.end(vk, vk.cmd, 0);
    FrameRecord r;
    assert(!p.collect(vk, 0, r, FrameClock.init));
    assert(r.scopes.length == 0 && r.gpu == Duration.zero);
    p.destroy(vk);

    // A pool the device refuses is an error, and what was made is released.
    FakeGpu refusing;
    refusing.poolAnswer = VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    auto vk2 = ProfilerVk(&refusing, 64);
    assert(GpuProfiler.create(p, vk2, 2).hasError);
    assert(!p.supported && p.slotCount == 0);
}

@("vulkan_wsi.gpu_profiler.nestedScopesReadLate")
@system unittest
{
    import core.time : usecs;

    // Two slots, 1 ns a tick, no calibration: starts are from the frame's
    // first scope.
    FakeGpu gpu;
    auto vk = ProfilerVk(&gpu, 64);
    auto cmd = vk.cmd;
    GpuProfiler p;
    assert(!GpuProfiler.create(p, vk, 2).hasError);
    assert(p.supported && !p.calibrated && !p.labels && p.slotCount == 2 && gpu.poolsMade == 2);
    const frame = p.name("frame"), canvas = p.name("canvas"), text = p.name("text");
    assert(p.name("canvas") == canvas, "a name registers once");
    assert(p.names == ["frame", "canvas", "text"]);

    // Slot 0: frame [1000, 9000] holding canvas [2000, 5000] and text
    // [5000, 8000], one after the other.
    void tick(ulong t) { gpu.nextTick = t; }
    p.beginFrame(vk, cmd, 0);
    tick(1000); p.begin(vk, cmd, 0, frame);
    tick(2000); p.begin(vk, cmd, 0, canvas);
    tick(5000); p.end(vk, cmd, 0);
    p.begin(vk, cmd, 0, text);
    tick(8000); p.end(vk, cmd, 0);
    tick(9000); p.end(vk, cmd, 0);

    // Slot 1 records meanwhile; the frame after reads slot 0, its fence
    // waited.
    p.beginFrame(vk, cmd, 1);
    tick(20_000); p.begin(vk, cmd, 1, frame);
    tick(23_000); p.end(vk, cmd, 1);

    FrameRecord r;
    assert(p.collect(vk, 0, r, FrameClock.init));
    assert(r.scopes.length == 3 && r.gpu == 8.usecs);
    with (r.scopes[0]) assert(name == frame && depth == 0 && start == Duration.zero
        && took == 8.usecs && !calibrated);
    with (r.scopes[1]) assert(name == canvas && depth == 1 && start == 1.usecs && took == 3.usecs);
    with (r.scopes[2]) assert(name == text && depth == 1 && start == 4.usecs && took == 3.usecs);

    // Read once: the slot is empty until it records again.
    FrameRecord again;
    assert(!p.collect(vk, 0, again, FrameClock.init) && again.scopes.length == 0);

    FrameRecord second;
    assert(p.collect(vk, 1, second, FrameClock.init));
    assert(second.scopes.length == 1 && second.gpu == 3.usecs);

    // Sequential top-level scopes: the frame's span runs from the first's
    // start to the last's end.
    p.beginFrame(vk, cmd, 0);
    tick(100); p.begin(vk, cmd, 0, canvas);
    tick(300); p.end(vk, cmd, 0);
    tick(700); p.begin(vk, cmd, 0, text);
    tick(1100); p.end(vk, cmd, 0);
    FrameRecord seq;
    assert(p.collect(vk, 0, seq, FrameClock.init));
    assert(seq.scopes.length == 2 && seq.gpu == 1.usecs && seq.scopes[1].start == nsecs(600));

    p.destroy(vk);
    assert(gpu.poolsDestroyed == 2 && !p.supported);
}

@("vulkan_wsi.gpu_profiler.unendedAndExcessScopes")
@system unittest
{
    FakeGpu gpu;
    auto vk = ProfilerVk(&gpu, 64);
    auto cmd = vk.cmd;
    GpuProfiler p;
    assert(!GpuProfiler.create(p, vk, 1).hasError);
    scope (exit) p.destroy(vk);
    const n = p.name("s");

    // A scope never ended is absent; the one that ended is read without
    // waiting for it.
    p.beginFrame(vk, cmd, 0);
    gpu.nextTick = 10; p.begin(vk, cmd, 0, n);
    gpu.nextTick = 20; p.begin(vk, cmd, 0, n);
    gpu.nextTick = 30; p.end(vk, cmd, 0);
    FrameRecord r;
    assert(p.collect(vk, 0, r, FrameClock.init));
    assert(r.scopes.length == 1 && r.scopes[0].depth == 1 && r.scopes[0].took == nsecs(10));
    assert(r.gpu == Duration.zero, "no top-level scope ended");

    // Past `maxGpuScopes`, scopes are not timed, and their ends do not close
    // a timed one.
    p.beginFrame(vk, cmd, 0);
    gpu.nextTick = 0; p.begin(vk, cmd, 0, n);
    foreach (i; 0 .. maxGpuScopes + 4)
    {
        gpu.nextTick = 1 + i; p.begin(vk, cmd, 0, n);
        gpu.nextTick = 2 + i; p.end(vk, cmd, 0);
    }
    gpu.nextTick = 100; p.end(vk, cmd, 0);
    FrameRecord full;
    assert(p.collect(vk, 0, full, FrameClock.init));
    assert(full.scopes.length == maxGpuScopes);
    assert(full.scopes[0].took == nsecs(100) && full.gpu == nsecs(100));
}

@("vulkan_wsi.gpu_profiler.validBitsWrap")
@system unittest
{
    // 32 valid bits at 2.5 ns a tick: the high bits are garbage, and a scope
    // across the wrap still measures forward.
    FakeGpu gpu;
    auto vk = ProfilerVk(&gpu, 32, 2.5f);
    GpuProfiler p;
    assert(!GpuProfiler.create(p, vk, 1).hasError);
    scope (exit) p.destroy(vk);
    const n = p.name("frame");
    p.beginFrame(vk, vk.cmd, 0);
    gpu.nextTick = 0xABCD_0000_0000_0000 | (uint.max - 99); p.begin(vk, vk.cmd, 0, n);
    gpu.nextTick = 0x1234_0000_0000_0000 | 300; p.end(vk, vk.cmd, 0);
    FrameRecord r;
    assert(p.collect(vk, 0, r, FrameClock.init));
    assert(r.scopes[0].took == nsecs(1000) && r.gpu == nsecs(1000));
}

@("vulkan_wsi.gpu_profiler.calibratedStartsAndLabels")
@system unittest
{
    import core.time : msecs;

    // Calibrated and labelled: the device's tick 5000 is the host's 7 s;
    // the run's clock began at its origin.
    FakeGpu gpu;
    auto vk = ProfilerVk(&gpu, 64);
    vk.calibratedTimestamps = true;
    vk.debugUtils = true;
    vk.device.getCalibratedTimestampsEXT = &gpuFakeCalibrate;
    vk.device.cmdBeginDebugUtilsLabelEXT = &gpuFakeBeginLabel;
    vk.device.cmdEndDebugUtilsLabelEXT = &gpuFakeEndLabel;
    GpuProfiler p;
    assert(!GpuProfiler.create(p, vk, 1).hasError);
    scope (exit) p.destroy(vk);
    assert(p.calibrated && p.labels, "the EXT stands in for the KHR");

    const clock = FrameClock.monotonic();
    const originNanos = ticksToNSecs(clock.originTime.ticks);
    gpu.calibrationAnswer = [5000, 7_000_000_000];

    void frameAt(ulong t)
    {
        p.beginFrame(vk, vk.cmd, 0);
        gpu.nextTick = t; p.begin(vk, vk.cmd, 0, p.name("frame"));
        gpu.nextTick = t + 2000; p.end(vk, vk.cmd, 0);
    }
    frameAt(6000);
    assert(gpu.labelsBegun == 1 && gpu.labelsEnded == 1 && gpu.lastLabel[0 .. 6] == "frame\0");

    const t0 = clock.originTime + 5.msecs;
    FrameRecord r;
    assert(p.collect(vk, 0, r, clock, t0));
    assert(gpu.calibrations == 1);
    with (r.scopes[0])
        assert(calibrated && took == nsecs(2000)
            && start == nsecs(7_000_000_000 + 1000 - originNanos));

    // Within the second the same calibration serves; after it, a new one.
    gpu.calibrationAnswer = [100_000, 8_000_000_000];
    frameAt(6000);
    FrameRecord soon;
    assert(p.collect(vk, 0, soon, clock, t0 + 999.msecs));
    assert(gpu.calibrations == 1 && soon.scopes[0].start == r.scopes[0].start);
    frameAt(100_500);
    FrameRecord later;
    assert(p.collect(vk, 0, later, clock, t0 + 1000.msecs));
    assert(gpu.calibrations == 2);
    assert(later.scopes[0].start == nsecs(8_000_000_000 + 500 - originNanos));
    assert(p.currentCalibration == GpuCalibration(100_000, 8_000_000_000, true));
}

@("vulkan_wsi.gpu_profiler.abandonedFramesAndForeignLabels")
@system unittest
{
    // A frame recorded but never submitted leaves the older results in the
    // pool: abandoned, they are not read as new. An `end` with nothing open
    // leaves the caller's own label alone.
    FakeGpu gpu;
    auto vk = ProfilerVk(&gpu, 64);
    vk.debugUtils = true;
    vk.device.cmdBeginDebugUtilsLabelEXT = &gpuFakeBeginLabel;
    vk.device.cmdEndDebugUtilsLabelEXT = &gpuFakeEndLabel;
    GpuProfiler p;
    assert(!GpuProfiler.create(p, vk, 1).hasError);
    scope (exit) p.destroy(vk);
    const frame = p.name("frame");

    p.beginFrame(vk, vk.cmd, 0);
    gpu.nextTick = 1000; p.begin(vk, vk.cmd, 0, frame);
    gpu.nextTick = 2000; p.end(vk, vk.cmd, 0);
    p.end(vk, vk.cmd, 0); // nothing open
    assert(gpu.labelsBegun == 1 && gpu.labelsEnded == 1, "only its own label is closed");
    p.abandon(0);
    FrameRecord r;
    assert(!p.collect(vk, 0, r, FrameClock.init) && r.scopes.length == 0);
}
