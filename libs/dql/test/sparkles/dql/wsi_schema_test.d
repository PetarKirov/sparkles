/**
Integration schema: `sparkles.wsi.WindowEvent` through the reflection kernel.

The lossless WSI event is plain data; the schema inside DQL reads it via
`sparkles.reflection` — transparent `payload`, the envelope's `ulong`
sequence, inline UTF-8 as a value-like leaf, and the composition's static
segment array with enumerated indices.
*/
module sparkles.dql.wsi_schema_test;

version (unittest)
{
import sparkles.dql.engine : DqlEngine;
import sparkles.dql.eval : evalDql;
import sparkles.dql.parser : parseDql;
import sparkles.dql.schema : DqlSchema, DqlResolution, isDqlCategory,
    isDqlPath;
import sparkles.dql.resolve : resolveDqlPath;
import sparkles.wsi : CompositionEvent, CompositionSegmentStyle, FrameReadyEvent,
    KeyboardEvent, ScrollEvent, TextCommittedEvent, WindowEvent,
    WindowEventPayload, WindowId;
import std.sumtype : SumType;

alias WindowSchema = DqlSchema!WindowEvent;

@("dql.wsi-schema: envelope fields and mechanical variant names")
@safe unittest
{
    foreach (path; [
        "sequence", "window.slot", "window.generation",
        "keyboard.action", "keyboard.location", "keyboard.composing",
        "keyboard.modifiers.ctrl",
        "textCommitted.text",
        "composition.preedit", "composition.cursor",
        "composition.segments[0].style", "composition.segments[7].length",
        "pointer.phase", "pointer.logicalPosition.x", "pointer.pressure",
        "scroll.dy", "scroll.source", "scroll.inverted",
        "touch.pressure", "output.refreshMilliHertz",
        "dataOffer.mimeType",
        "popupConfigured.repositionToken",
        "frameReady.token", "frameReady.predictedPresentationNanoseconds",
        "focusChanged.focused", "occluded.occluded",
        "closeRequested", "destroyed",
    ])
        assert(isDqlPath!WindowSchema(path), path);

    // The payload hop is transparent; the strict spelling does not exist.
    assert(!isDqlPath!WindowSchema("payload.keyboard.action"));

    // A Vector's private backing array is not addressable: each component
    // has exactly one address (`…logicalPosition.x`), not a second one
    // through the union storage.
    assert(!isDqlPath!WindowSchema("pointer.logicalPosition.data[0]"));
    assert(!isDqlPath!WindowSchema("popupConfigured.size.data[0]"));

    foreach (name; ["keyboard", "textCommitted", "composition", "pointer",
        "scroll", "touch", "frameReady", "closeRequested"])
        assert(isDqlCategory!WindowSchema(name), name);
}

@("dql.wsi-schema: ulong widths survive exact comparisons")
@safe unittest
{
    DqlEngine engine;
    WindowEvent event = {
        sequence: ulong.max,
        window: WindowId(4, 2),
        payload: WindowEventPayload(FrameReadyEvent(
            token: 9_007_199_254_740_993UL,
            predictedPresentationNanoseconds: 42,
        )),
    };

    foreach (query; [
        "sequence == 18446744073709551615",
        "window.slot == 4",
        "frameReady.token == 9007199254740993",
        "frameReady.predictedPresentationNanoseconds == 42",
    ])
    {
        auto parsed = parseDql!WindowSchema(engine, query);
        assert(parsed.hasValue, parsed.error.message);
        assert(evalDql!WindowSchema(engine, parsed.value, event), query);
    }
}

@("dql.wsi-schema: inline text, segments, and presence")
@safe unittest
{
    DqlEngine engine;

    TextCommittedEvent committed;
    assert(committed.text.assign("hello"));
    WindowEvent text = WindowEvent(1, WindowId(1, 1),
        WindowEventPayload(committed));

    auto textQuery = parseDql!WindowSchema(engine,
        "textCommitted.text == `hello`");
    assert(textQuery.hasValue, textQuery.error.message);
    assert(evalDql!WindowSchema(engine, textQuery.value, text));

    CompositionEvent composition;
    composition.segments[7].style = CompositionSegmentStyle.selected;
    WindowEvent ime = WindowEvent(2, WindowId(1, 1),
        WindowEventPayload(composition));

    auto segment = parseDql!WindowSchema(engine,
        "composition.segments[7].style == selected");
    assert(segment.hasValue, segment.error.message);
    assert(evalDql!WindowSchema(engine, segment.value, ime));

    // Out-of-range static index: present schema address, absent value.
    struct Reject
    {
        void opCall(V)(in V) {}
    }

    assert(resolveDqlPath!WindowSchema(ime, "composition.segments[8].style",
        Reject.init) == DqlResolution.absent);
    assert(resolveDqlPath!WindowSchema(ime, "composition.segments[9]",
        Reject.init) == DqlResolution.absent);
    assert(resolveDqlPath!WindowSchema(ime, "composition.segments[x]",
        Reject.init) == DqlResolution.unknown);

    // Inactive variants are absent; the envelope is always present.
    assert(resolveDqlPath!WindowSchema(text, "scroll.dy", Reject.init)
        == DqlResolution.absent);
    assert(resolveDqlPath!WindowSchema(text, "sequence", Reject.init)
        == DqlResolution.value);
}
}
