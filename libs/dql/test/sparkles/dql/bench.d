/// Runtime bench rows for reflected filtering (`dub test :dql -b bench --
/// --bench`): evalDql over the real input vocabulary with representative
/// filter shapes, plus the bare resolver and literal-comparison costs. These
/// pin the per-event price of the schema-driven path — the loop a consumer
/// runs on every polled event.
module sparkles.dql.bench;

version (unittest):

import sparkles.test_runner.attributes : benchmark;

import sparkles.dql.ast : DqlFilter, DqlOp, DqlValue;
import sparkles.dql.engine : DqlEngine;
import sparkles.dql.eval : compareValues, evalDql;
import sparkles.dql.parser : parseDql;
import sparkles.dql.resolve : resolveDqlPath;
import sparkles.dql.schema : DqlSchema;
import sparkles.input : Event, Key, KeyAction, KeyEvent, Mods, Point,
    PointerAction, PointerButton, PointerEvent, WheelEvent;

private alias InputSchema = DqlSchema!Event;

/// A small ring of the event shapes a real stream interleaves.
private Event[3] makeRing() @safe pure nothrow @nogc
{
    Event[3] ring = [
        Event(KeyEvent(key: Key.char_, ch: 'h', mods: Mods(ctrl: true),
            action: KeyAction.press)),
        Event(PointerEvent(action: PointerAction.move,
            button: PointerButton.none, pos: Point(150, 200),
            mods: Mods(), pointerId: 1)),
        Event(WheelEvent(dx: 0, dy: -3, pos: Point(10, 10), mods: Mods(),
            precise: false)),
    ];
    return ring;
}

@("dql.bench.evalReflected")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    DqlEngine engine;
    auto ring = makeRing();

    // Parsed once, outside the measured loop — exactly a consumer's shape.
    static immutable filters = [
        "category": "key",
        "negated": "!key",
        "fieldEq": "pointer.action == move",
        "compound": "key.mods.ctrl == true && key.action == press",
        "regex": "regexMatch(key.text, `^h`)",
    ];
    foreach (label, source; filters)
    {
        import core.lifetime : move;

        auto parsed = parseDql!InputSchema(engine, source);
        assert(parsed.hasValue, parsed.error.message);
        // DqlFilter is move-only (its node arena is a unique SmallBuffer);
        // move it onto the heap so the measured closure owns it.
        auto filter = new DqlFilter;
        *filter = parsed.value.move;
        benchIter({
            foreach (ref event; ring)
                blackBox(evalDql!InputSchema(engine, *filter, event));
        }, ["op": "evalDql", "filter": label]);
    }
}

@("dql.bench.resolvePath")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    auto ring = makeRing();

    static struct Ignore
    {
        void opCall(V)(in V) @safe pure nothrow @nogc {}
    }

    benchIter({
        foreach (ref event; ring)
            blackBox(resolveDqlPath!InputSchema(event, "pointer.pos.x",
                Ignore.init));
    }, ["op": "resolveDqlPath", "path": "pointer.pos.x"]);
}

@("dql.bench.compareValues")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    DqlEngine engine;
    benchIter({
        blackBox(compareValues(engine, DqlValue(9_007_199_254_740_993L),
            DqlOp.eq, DqlValue(9_007_199_254_740_992.0)));
        blackBox(compareValues(engine, DqlValue(ulong.max), DqlOp.gt,
            DqlValue(long.max)));
    }, ["op": "compareValues"]);
}
