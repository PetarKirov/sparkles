/**
One window-system event as a log line: `#<sequence> <payload>`, the text a
`TextCommittedEvent` or a `CompositionEvent` names read and quoted.

Text is pooled (`ED8`): an event names it by `TextId`, and the backend's
`withText` reads it only during the drain that delivers the event. So these
take the backend, and must be called inside that drain — the rule a program
that logs events after the drain returns breaks, quietly printing no text.
*/
module sparkles.wsi.event_log;

import std.conv : text;
import std.range.primitives : put;
import std.sumtype : match;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.wsi.events : CompositionEvent, DataOfferEvent, TextCommittedEvent, TextId,
    WindowEvent;

/**
Writes `event` to `w` as one line, its pooled text (a commit, a preedit, an
offer's MIME type) read and quoted. Call it inside the drain that delivers
`event`: its text is read through `wsi`.
*/
void writeEvent(Writer, Backend)(ref Writer w, ref Backend wsi, in WindowEvent event,
    in PrettyPrintOptions!void options = PrettyPrintOptions!void(colored: false))
{
    // One line however wide: past `softMaxWidth` the pretty-printer breaks
    // an aggregate a field per line, and a log is read a line per event.
    PrettyPrintOptions!void opt = options;
    opt.softMaxWidth = uint.max;
    put(w, '#');
    put(w, text(event.sequence));
    put(w, ' ');
    void quoted(TextId id)
    {
        bool read;
        cast(void) wsi.withText(id, (scope const(char)[] t, bool truncated) {
            read = true;
            writeQuoted(w, t);
            if (truncated)
                put(w, " (truncated)");
        });
        if (!read)
            put(w, "(text no longer readable)");
    }
    event.payload.match!(
        (in TextCommittedEvent value) {
            put(w, "TextCommittedEvent ");
            quoted(value.text);
        },
        (in CompositionEvent value) {
            put(w, "CompositionEvent ");
            quoted(value.preedit);
            put(w, ' ');
            put(w, text(prettyPrint(value, opt)));
        },
        (in DataOfferEvent value) {
            put(w, "DataOfferEvent ");
            quoted(value.mimeType);
            put(w, ' ');
            put(w, text(prettyPrint(value, opt)));
        },
        (other) => put(w, text(prettyPrint(other, opt))));
}

/// ditto, as a string.
string eventLine(Backend)(ref Backend wsi, in WindowEvent event,
    in PrettyPrintOptions!void opt = PrettyPrintOptions!void(colored: false))
{
    import std.array : appender;

    auto w = appender!string;
    writeEvent(w, wsi, event, opt);
    return w[];
}

///
@("wsi.event_log.readsTheText")
@system unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import sparkles.wsi.events : KeyboardEvent, WindowEventPayload;

    // A backend whose pool holds one text, and none after the drain.
    static struct Pool
    {
        bool live = true;

        auto withText(Fn)(TextId, scope Fn fn)
        {
            static struct Result { bool hasError; }
            if (!live)
                return Result(true);
            fn("héllo", false);
            return Result(false);
        }
    }

    Pool pool;
    const typed = WindowEvent(7, payload: WindowEventPayload(TextCommittedEvent.init));
    assert(eventLine(pool, typed) == `#7 TextCommittedEvent "héllo"`);
    pool.live = false;
    assert(eventLine(pool, typed).canFind("no longer readable"), "read after its drain");
    pool.live = true;
    const offer = WindowEvent(9, payload: WindowEventPayload(DataOfferEvent.init));
    assert(eventLine(pool, offer).startsWith(`#9 DataOfferEvent "héllo" DataOfferEvent(`));
    const composing = WindowEvent(10, payload: WindowEventPayload(CompositionEvent.init));
    assert(!eventLine(pool, composing).canFind('\n'), "a wide event stays one line");
    const key = WindowEvent(8, payload: WindowEventPayload(KeyboardEvent.init));
    assert(eventLine(pool, key).startsWith("#8 KeyboardEvent("));
}

// `t` in double quotes, UTF-8 as it is; quotes, backslashes and control
// characters escaped, so a line stays one line.
private void writeQuoted(Writer)(ref Writer w, scope const(char)[] t)
{
    static immutable hex = "0123456789abcdef";
    put(w, '"');
    foreach (char c; t)
    {
        if (c == '"' || c == '\\')
        {
            put(w, '\\');
            put(w, c);
        }
        else if (c == '\n')
            put(w, `\n`);
        else if (c < 0x20 || c == 0x7f)
        {
            put(w, `\x`);
            put(w, hex[c >> 4]);
            put(w, hex[c & 0xf]);
        }
        else
        {
            // A unit, not a code point: a writer taking `dchar` would encode
            // a byte of a multi-byte sequence again.
            const char[1] unit = c;
            put(w, unit[]);
        }
    }
    put(w, '"');
}
