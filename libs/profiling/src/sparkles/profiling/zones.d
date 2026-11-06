/**
Named CPU zones inside a frame (`PRF22`): where the build and record phases'
time goes — layout, shaping, rasterizing glyphs, recording the draw list —
summed per name per frame, so a device run reports it without a profiler
attached.

A zone is opened with $(LREF cpuZone) and ends with its scope. Its time is
added to the frame the calling thread is recording, if any: the frame loop
points $(LREF FrameZones.current) at its timer's zones for the frame's
duration, and a zone opened on any other thread, or between frames, costs a
clock read and adds nothing. Zones nest; each is inclusive of the zones inside
it. With `version (SparklesTracy)` each zone is a Tracy zone as well
(`PRF20`).

Names are registered on first use, process-wide, up to $(LREF maxCpuZones);
past that a zone is timed by Tracy only.
*/
module sparkles.profiling.zones;

import core.time : Duration, MonoTime;

import sparkles.base.sync : Mutex;
import sparkles.profiling.tracy : TracyZone, tracyZone;

/// The most zone names a program has.
enum size_t maxCpuZones = 16;

/// What a frame's zones took, by name index (`cpuZoneName`).
struct FrameZones
{
    Duration[maxCpuZones] took; /// summed over the frame
    ushort[maxCpuZones] count;  /// how often each was entered

    /// The zones the calling thread's frame collects into, or `null`.
    static FrameZones* current;

@safe pure nothrow @nogc:

    /// Credits `d` to zone `id`.
    void add(size_t id, Duration d)
    {
        if (id >= maxCpuZones)
            return;
        took[id] += d;
        if (count[id] < ushort.max)
            ++count[id];
    }
}

/// A zone, open until it is destroyed. See $(LREF cpuZone).
struct CpuZone
{
    private FrameZones* into;
    private MonoTime start;
    private ubyte id = ubyte.max;
    private TracyZone tracy;

    @disable this(this);

    ~this() @safe nothrow @nogc
    {
        if (into !is null)
            into.add(id, MonoTime.currTime - start);
    }
}

/**
Opens the zone named `name` for the rest of the caller's scope:
`auto zone = cpuZone!"shape";`.
*/
CpuZone cpuZone(string name, string function_ = __FUNCTION__, string file = __FILE__,
    size_t line = __LINE__)() @safe nothrow @nogc
{
    static ubyte id = ubyte.max; // thread-local: registered once per thread
    if (id == ubyte.max)
        id = registerCpuZone(name);
    CpuZone z;
    z.tracy = tracyZone!(name, function_, file, line);
    z.id = id;
    if (id < maxCpuZones)
    {
        z.into = FrameZones.current;
        if (z.into !is null)
            z.start = MonoTime.currTime;
    }
    return z;
}

/**
A run's zones: for each name, the frames that entered it, its mean time per
such frame, and its 95th percentile. `zones (ms a frame, mean/p95): layout
1.2/1.4 (300), shape 3.1/5.0 (300)`.
*/
struct ZoneStats
{
    import sparkles.profiling.histogram : FrameHistogram;

    uint[maxCpuZones] frames;          ///
    Duration[maxCpuZones] total;       ///
    FrameHistogram[maxCpuZones] histogram; ///

    /// Notes one frame's zones.
    void note(in FrameZones z) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. maxCpuZones)
            if (z.count[i])
            {
                ++frames[i];
                total[i] += z.took[i];
                histogram[i].add(z.took[i]);
            }
    }

    /// Zone `i`'s mean time in a frame that entered it.
    Duration mean(size_t i) const @safe pure nothrow @nogc
        => frames[i] ? total[i] / frames[i] : Duration.zero;

    /// Whether any zone was entered.
    bool any() const @safe pure nothrow @nogc
    {
        foreach (f; frames)
            if (f)
                return true;
        return false;
    }

    /// Writes the summary line, names from the registry.
    void toString(Writer)(ref Writer w) const
    {
        toString(w, (size_t i) => cpuZoneName(i));
    }

    /// ditto, with names from `nameOf`.
    void toString(Writer, Names)(ref Writer w, scope Names nameOf) const
    {
        import std.range.primitives : put;
        import sparkles.base.text : writeInteger;

        static void ms(ref Writer w, Duration d)
        {
            const hundredths = (d.total!"usecs" + 5) / 10;
            writeInteger(w, hundredths / 100);
            put(w, '.');
            const frac = hundredths % 100;
            if (frac < 10)
                put(w, '0');
            writeInteger(w, frac);
        }

        put(w, "zones (ms a frame, mean/p95):");
        bool first = true;
        foreach (i; 0 .. maxCpuZones)
        {
            if (!frames[i])
                continue;
            put(w, first ? " " : ", ");
            first = false;
            const name = nameOf(i);
            put(w, name.length ? name : "?");
            put(w, ' ');
            ms(w, mean(i));
            put(w, '/');
            // Under the histogram's range a percentile reads as the fastest
            // seen, which may be below the mean: say only that it is small.
            const p95 = histogram[i].percentile(0.95);
            if (p95.total!"hnsecs" < FrameHistogram.lowUsecs * 10)
                put(w, "<0.10");
            else
                ms(w, p95);
            put(w, " (");
            writeInteger(w, frames[i]);
            put(w, ')');
        }
        if (first)
            put(w, " none");
    }
}

///
@("profiling.zones.statsPerName")
@safe pure nothrow @nogc unittest
{
    import core.time : msecs, usecs;
    import sparkles.base.buffer : checkWriter;

    ZoneStats stats;
    foreach (k; 0 .. 4)
    {
        FrameZones z;
        z.add(0, (2 + k).msecs);
        z.add(0, 500.usecs); // entered twice: the frame's sum
        if (k == 0)
            z.add(2, 1.msecs);
        stats.note(z);
    }
    assert(stats.frames[0] == 4 && stats.frames[1] == 0 && stats.frames[2] == 1);
    assert(stats.mean(0) == 4.msecs && stats.any);
    static string name(size_t i) => i == 0 ? "shape" : i == 2 ? "raster" : null;
    checkWriter!((ref b) => stats.toString(b, &name))(
        "zones (ms a frame, mean/p95): shape 4.00/5.52 (4), raster 1.00/1.02 (1)"); // p95 at a bin middle
    ZoneStats quick;
    FrameZones z;
    z.add(0, 30.usecs);
    quick.note(z);
    checkWriter!((ref b) => quick.toString(b, &name))("zones (ms a frame, mean/p95): shape 0.03/<0.10 (1)");
    checkWriter!((ref b) => ZoneStats.init.toString(b, &name))("zones (ms a frame, mean/p95): none");
}

/// The name of zone `id`, or `null` if none has it.
string cpuZoneName(size_t id) @trusted nothrow @nogc
{
    registryLock.lock();
    scope (exit)
        registryLock.unlock();
    return id < zoneCount ? zoneNames[id] : null;
}

/// How many zone names are registered.
size_t cpuZoneCount() @trusted nothrow @nogc
{
    registryLock.lock();
    scope (exit)
        registryLock.unlock();
    return zoneCount;
}

private __gshared Mutex registryLock;
private __gshared string[maxCpuZones] zoneNames;
private __gshared size_t zoneCount;

// The index of zone `name`, registering it; past `maxCpuZones`, an index no
// frame collects.
private ubyte registerCpuZone(string name) @trusted nothrow @nogc
{
    registryLock.lock();
    scope (exit)
        registryLock.unlock();
    foreach (i, n; zoneNames[0 .. zoneCount])
        if (n == name)
            return cast(ubyte) i;
    if (zoneCount == maxCpuZones)
        return ubyte.max - 1;
    zoneNames[zoneCount] = name;
    return cast(ubyte) zoneCount++;
}

///
@("profiling.zones.sumPerNameInTheCurrentFrame")
@system nothrow @nogc unittest
{
    FrameZones frame;
    {
        auto outside = cpuZone!"zones.test.outside"; // no frame: adds nothing
    }
    FrameZones.current = &frame;
    scope (exit)
        FrameZones.current = null;
    foreach (_; 0 .. 3)
    {
        auto outer = cpuZone!"zones.test.outer";
        auto inner = cpuZone!"zones.test.inner";
    }
    size_t outer = size_t.max, inner = size_t.max, outside = size_t.max;
    foreach (i; 0 .. cpuZoneCount)
    {
        if (cpuZoneName(i) == "zones.test.outer")
            outer = i;
        else if (cpuZoneName(i) == "zones.test.inner")
            inner = i;
        else if (cpuZoneName(i) == "zones.test.outside")
            outside = i;
    }
    assert(outer < maxCpuZones && inner < maxCpuZones && outside < maxCpuZones);
    assert(frame.count[outer] == 3 && frame.count[inner] == 3);
    assert(frame.count[outside] == 0);
    assert(frame.took[outer] >= frame.took[inner], "a zone includes those inside it");
    assert(cpuZoneName(maxCpuZones) is null);
}
