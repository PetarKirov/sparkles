/**
Frame marks, CPU zones, plots and messages for the Tracy profiler (`PRF20`).

Built with `version (SparklesTracy)` — the `tracy` configuration of
`sparkles:profiling` sets it and links `libTracyClient` — each call reaches
Tracy's C client, which queues what it is given until a profiler (the `tracy`
GUI, or `tracy-capture`) connects. Without the version nothing of Tracy is
compiled: the same API is a set of empty inline functions, so a caller needs
no `version` blocks of its own.

Tracy identifies a zone's source location, a frame set and a plot by the
address of its name, so each name is a template argument and lives in static
data for the life of the program.
*/
module sparkles.profiling.tracy;

version (SparklesTracy)
{
    import sparkles.profiling.tracy_c : ___tracy_c_zone_context, ___tracy_connected,
        ___tracy_emit_frame_mark, ___tracy_emit_message, ___tracy_emit_plot,
        ___tracy_emit_zone_begin, ___tracy_emit_zone_end, ___tracy_source_location_data;

    /// Whether this build sends to Tracy.
    enum bool tracyEnabled = true;
}
else
{
    /// ditto
    enum bool tracyEnabled = false;
}

/**
Ends a frame of Tracy's default frame set, or of the set named `set`.

A frame set measures the time from one mark to the next; call it once per
presented frame.
*/
pragma(inline, true)
void tracyFrameMark()() @safe nothrow @nogc
{
    version (SparklesTracy)
        () @trusted { ___tracy_emit_frame_mark(null); }();
}

/// ditto
pragma(inline, true)
void tracyFrameMark(string set)() @safe nothrow @nogc
{
    version (SparklesTracy)
        () @trusted { ___tracy_emit_frame_mark(Names!set.ptr); }();
}

/// Adds `value` to the plot named `name`.
pragma(inline, true)
void tracyPlot(string name)(double value) @safe nothrow @nogc
{
    version (SparklesTracy)
        () @trusted { ___tracy_emit_plot(Names!name.ptr, value); }();
}

/// Sends `text` to Tracy's message log; Tracy copies it.
pragma(inline, true)
void tracyMessage()(in char[] text) @safe nothrow @nogc
{
    version (SparklesTracy)
        () @trusted { ___tracy_emit_message(text.ptr, text.length, 0); }();
}

/// Whether a profiler is connected (always `false` without the version).
pragma(inline, true)
bool tracyConnected()() @safe nothrow @nogc
{
    version (SparklesTracy)
        return () @trusted { return ___tracy_connected() != 0; }();
    else
        return false;
}

/**
A CPU zone, open from `tracyZone` until it is ended or destroyed.

Tracy's zones nest: on a thread, the zone opened last must end first. `next`
ends the zone and opens the following one in its place, for a sequence of
phases.
*/
struct TracyZone
{
    // Without the version the zone is an empty struct with no destructor.
    version (SparklesTracy)
    {
        private ___tracy_c_zone_context context;
        private bool open;

        ~this() @safe nothrow @nogc
        {
            end();
        }
    }

    @disable this(this);

    /// Ends the zone, if it is open.
    pragma(inline, true)
    void end() @safe nothrow @nogc
    {
        version (SparklesTracy)
        {
            if (!open)
                return;
            open = false;
            () @trusted { ___tracy_emit_zone_end(context); }();
        }
    }

    /// Ends the zone and opens the one named `name`.
    pragma(inline, true)
    void next(string name, string function_ = __FUNCTION__, string file = __FILE__,
        uint line = __LINE__)() @safe nothrow @nogc
    {
        end();
        version (SparklesTracy)
            begin(&Locations!(name, function_, file, line));
    }

    /// Whether the zone is open (always `false` without the version).
    bool isOpen() const @safe pure nothrow @nogc
    {
        version (SparklesTracy)
            return open;
        else
            return false;
    }

    version (SparklesTracy)
    private void begin(immutable(___tracy_source_location_data)* location) @trusted nothrow @nogc
    {
        // The header's parameter is `const`; ImportC drops a pointee's
        // `const`, and Tracy only reads it.
        context = ___tracy_emit_zone_begin(cast(___tracy_source_location_data*) location, 1);
        open = true;
    }
}

/**
Opens the zone named `name`, at the caller's function, file and line; it ends
when the returned `TracyZone` does.
*/
pragma(inline, true)
TracyZone tracyZone(string name, string function_ = __FUNCTION__, string file = __FILE__,
    uint line = __LINE__)() @safe nothrow @nogc
{
    TracyZone zone;
    zone.next!(name, function_, file, line)();
    return zone;
}

version (SparklesTracy)
{
    // One NUL-terminated copy of each name, at one address for the program.
    private template Names(string text)
    {
        static immutable string Names = text ~ "\0";
    }

    // The static source location Tracy keeps a pointer to.
    private template Locations(string name, string function_, string file, uint line)
    {
        static immutable Locations = immutable(___tracy_source_location_data)(
            name, function_, file, line, 0);
    }
}

///
@("profiling.tracy.zonesFramesAndPlots")
@safe nothrow @nogc
unittest
{
    // No profiler is connected: Tracy's client queues it all, or, without
    // the version, nothing happens at all.
    {
        auto frame = tracyZone!"frame";
        auto phase = tracyZone!"build";
        assert(phase.isOpen == tracyEnabled);
        phase.next!"record";
        assert(phase.isOpen == tracyEnabled);
        phase.end();
        assert(!phase.isOpen);
        phase.end(); // ending twice is harmless
        tracyPlot!"frame ms"(16.6);
        tracyMessage("a message");
    }
    tracyFrameMark();
    tracyFrameMark!"secondary"();
}

@("profiling.tracy.enabledByTheVersion")
@safe pure nothrow @nogc
unittest
{
    version (SparklesTracy)
        static assert(tracyEnabled);
    else
        static assert(!tracyEnabled);
}
