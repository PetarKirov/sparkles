/**
How many events of each kind a run saw: one counter per `WindowEventPayload`
type, generated from the sum type, so a new event kind is counted (and
printed) without a line here.
*/
module sparkles.wsi.event_stats;

import std.meta : staticIndexOf;
import std.sumtype : match;
import std.traits : Unqual;

import sparkles.wsi.events : WindowEvent, WindowEventPayload;

/// The counter a payload type is counted in: `KeyboardEvent` → `keyboard`.
template statName(Payload)
{
    private enum name = Payload.stringof;
    private enum stem = name.length > 5 && name[$ - 5 .. $] == "Event" ? name[0 .. $ - 5] : name;
    enum statName = (stem[0] >= 'A' && stem[0] <= 'Z' ? cast(char)(stem[0] + 32) : stem[0])
        ~ stem[1 .. $];
}

/// Events counted by kind, and in all.
struct EventStats
{
    uint total; /// every event counted

    static foreach (Payload; WindowEventPayload.Types)
        mixin("uint " ~ statName!Payload ~ "; /// `" ~ Payload.stringof ~ "`s");

    /// Counts `event` under its kind.
    void count(in WindowEvent event) @safe pure nothrow @nogc
    {
        ++total;
        const kind = event.payload.match!((ref const payload)
            => staticIndexOf!(Unqual!(typeof(payload)), WindowEventPayload.Types));
        static foreach (i, Payload; WindowEventPayload.Types)
            if (kind == i)
                ++__traits(getMember, this, statName!Payload);
    }

    /// The total and each kind seen, in declaration order:
    /// `3 events: keyboard 2, pointer 1`.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text : writeInteger;

        writeInteger(w, total);
        put(w, total == 1 ? " event" : " events");
        bool first = true;
        static foreach (Payload; WindowEventPayload.Types)
        {{
            const n = __traits(getMember, this, statName!Payload);
            if (n)
            {
                put(w, first ? ": " : ", ");
                first = false;
                put(w, statName!Payload);
                put(w, ' ');
                writeInteger(w, n);
            }
        }}
    }

    /// `prettyPrint` writes the same line: a report keeps the kinds it saw,
    /// not a row for every kind there is.
    void writePretty(Writer, Opts)(ref Writer w, in Opts, ushort = 0) const => toString(w);
}

///
@("wsi.event_stats.countsEveryKind")
@safe pure nothrow @nogc unittest
{
    import sparkles.wsi.events : KeyboardEvent, PointerEvent;

    EventStats stats;
    stats.count(WindowEvent(payload: WindowEventPayload(KeyboardEvent.init)));
    stats.count(WindowEvent(payload: WindowEventPayload(KeyboardEvent.init)));
    stats.count(WindowEvent(payload: WindowEventPayload(PointerEvent.init)));
    assert(stats.total == 3 && stats.keyboard == 2 && stats.pointer == 1);
    assert(stats.scroll == 0);
}

///
@("wsi.event_stats.toString")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkToString;
    import sparkles.wsi.events : KeyboardEvent, PointerEvent;

    EventStats stats;
    checkToString(stats, "0 events");
    stats.count(WindowEvent(payload: WindowEventPayload(PointerEvent.init)));
    checkToString(stats, "1 event: pointer 1");
    stats.count(WindowEvent(payload: WindowEventPayload(KeyboardEvent.init)));
    stats.count(WindowEvent(payload: WindowEventPayload(KeyboardEvent.init)));
    checkToString(stats, "3 events: keyboard 2, pointer 1");
}

@("wsi.event_stats.prettyPrintsAsItsLine")
@system unittest
{
    import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
    import sparkles.wsi.events : KeyboardEvent;

    EventStats stats;
    stats.count(WindowEvent(payload: WindowEventPayload(KeyboardEvent.init)));
    import std.conv : text;

    assert(text(prettyPrint(stats, PrettyPrintOptions!void(colored: false))) == "1 event: keyboard 1");
}

@("wsi.event_stats.everyPayloadHasACounter")
@safe pure nothrow @nogc unittest
{
    EventStats stats;
    static foreach (Payload; WindowEventPayload.Types)
        stats.count(WindowEvent(payload: WindowEventPayload(Payload.init)));
    assert(stats.total == WindowEventPayload.Types.length);
    static foreach (Payload; WindowEventPayload.Types)
        assert(__traits(getMember, stats, statName!Payload) == 1, Payload.stringof);
    static assert(statName!(WindowEventPayload.Types[0]) == "noWindow");
}
