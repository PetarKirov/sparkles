/**
`sparkles:dql` — D Query Language.

Path-based addressing, typed constraint evaluation, fuzzy matching,
and zero-allocation predicate filtering.
*/
module sparkles.dql;

public import sparkles.dql.ast;
public import sparkles.dql.engine;
public import sparkles.dql.eval;
public import sparkles.dql.help;
public import sparkles.dql.parser;

@("dql: end-to-end filter compilation and evaluation")
unittest
{
    // 1. Initialise the DQL engine (owns interned strings, matchers, and reusable workspaces)
    DqlEngine engine;

    // 2. Compile an expressive DQL filter combining categories, comparisons, and pattern matching
    const expr = "pointer && (pointer.phase == pressed || pointer.button == left) && pointer.x >= 100 && globMatch(target, `*.button`)";
    auto filterRes = parseDql(engine, expr);
    assert(!filterRes.hasError, "Filter should parse successfully");
    ref const filter = filterRes.value;

    // 3. Define a mock event data structure and resolver
    struct MockPointerEvent
    {
        string category = "pointer";
        string phase = "pressed";
        string button = "left";
        double x = 150.0;
        double y = 50.0;
        string target = "submit.button";
    }

    struct MockResolver
    {
        const(MockPointerEvent)* event;

        bool resolveCategory(scope const(char)[] cat) scope @safe pure nothrow @nogc
        {
            return cat == event.category;
        }

        bool resolveValue(scope const(char)[] path, out const(char)[] value) scope @safe pure nothrow @nogc
        {
            switch (path)
            {
                case "pointer.phase":
                    value = event.phase;
                    return true;
                case "pointer.button":
                    value = event.button;
                    return true;
                case "target":
                    value = event.target;
                    return true;
                default:
                    return false;
            }
        }

        bool resolveValue(scope const(char)[] path, out double value) scope @safe pure nothrow @nogc
        {
            switch (path)
            {
                case "pointer.x":
                    value = event.x;
                    return true;
                case "pointer.y":
                    value = event.y;
                    return true;
                default:
                    return false;
            }
        }
    }

    // 4. Evaluate matching event -> true
    MockPointerEvent matchingEvent = MockPointerEvent("pointer", "pressed", "left", 150.0, 50.0, "submit.button");
    MockResolver matchingResolver = MockResolver(&matchingEvent);
    assert(evalDql(engine, filter, matchingResolver), "Matching event must evaluate to true");

    // 5. Evaluate non-matching event (x < 100) -> false
    MockPointerEvent nonMatchingEvent1 = MockPointerEvent("pointer", "pressed", "left", 50.0, 50.0, "submit.button");
    MockResolver nonMatchingResolver1 = MockResolver(&nonMatchingEvent1);
    assert(!evalDql(engine, filter, nonMatchingResolver1), "Event with x < 100 must evaluate to false");

    // 6. Evaluate non-matching event (target doesn't match glob `*.button`) -> false
    MockPointerEvent nonMatchingEvent2 = MockPointerEvent("pointer", "pressed", "left", 150.0, 50.0, "canvas.view");
    MockResolver nonMatchingResolver2 = MockResolver(&nonMatchingEvent2);
    assert(!evalDql(engine, filter, nonMatchingResolver2), "Event with non-matching target must evaluate to false");
}
