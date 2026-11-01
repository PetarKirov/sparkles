/**
How long a run's frames took: how many, their mean, the slowest, and how many
went over 50 and 100 ms — what tells a stall from a slow frame, and what a
headless lane can check without reading a line per frame.
*/
module sparkles.vulkan_wsi.frame_stats;

import core.time : Duration, msecs;

/// ditto
struct FrameStats
{
    uint frames;       /// frames noted
    Duration total;    /// their time, together
    Duration slowest;  ///
    uint over50ms;     /// frames that took 50 ms or more
    uint over100ms;    /// frames that took 100 ms or more

    /// Notes one frame that took `took`.
    void note(Duration took) @safe pure nothrow @nogc
    {
        ++frames;
        total += took;
        if (took > slowest)
            slowest = took;
        if (took >= 50.msecs)
            ++over50ms;
        if (took >= 100.msecs)
            ++over100ms;
    }

    /// The mean frame; zero before the first.
    Duration mean() const @safe pure nothrow @nogc => frames ? total / frames : Duration.zero;

    /// `300 frames: mean 3.2 ms, slowest 46.9 ms, 0 over 50 ms, 0 over 100 ms`.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text : writeInteger;

        static void ms(ref Writer w, Duration d)
        {
            const tenths = (d.total!"usecs" + 50) / 100;
            writeInteger(w, tenths / 10);
            put(w, '.');
            writeInteger(w, tenths % 10);
            put(w, " ms");
        }

        writeInteger(w, frames);
        put(w, frames == 1 ? " frame" : " frames");
        if (frames == 0)
            return;
        put(w, ": mean ");
        ms(w, mean);
        put(w, ", slowest ");
        ms(w, slowest);
        put(w, ", ");
        writeInteger(w, over50ms);
        put(w, " over 50 ms, ");
        writeInteger(w, over100ms);
        put(w, " over 100 ms");
    }

    /// `prettyPrint` writes the same line.
    void writePretty(Writer, Opts)(ref Writer w, in Opts, ushort = 0) const => toString(w);
}

///
@("vulkan_wsi.frame_stats.notesAndWrites")
@safe pure nothrow @nogc unittest
{
    import core.time : usecs;
    import sparkles.base.buffer : checkToString;

    FrameStats s;
    checkToString(s, "0 frames");
    s.note(2.msecs);
    s.note(4.msecs);
    s.note(120.msecs);
    assert(s.frames == 3 && s.slowest == 120.msecs && s.over50ms == 1 && s.over100ms == 1);
    assert(s.mean == 42.msecs);
    checkToString(s, "3 frames: mean 42.0 ms, slowest 120.0 ms, 1 over 50 ms, 1 over 100 ms");
    FrameStats one;
    one.note(3250.usecs);
    checkToString(one, "1 frame: mean 3.3 ms, slowest 3.3 ms, 0 over 50 ms, 0 over 100 ms");
}
