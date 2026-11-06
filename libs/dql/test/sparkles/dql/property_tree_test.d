/**
Integration: the generated query schema and `sparkles.ui`'s property tree
address one value through the same reflection walk.

The test lives here rather than in the property tree because this package's
tests can depend on `sparkles:ui`, and `sparkles:ui` has no dependency on this
one (build-graph decision D15).
*/
module sparkles.dql.property_tree_test;

version (unittest):

import sparkles.dql.engine : DqlEngine;
import sparkles.dql.eval : evalDql;
import sparkles.dql.parser : parseDql;
import sparkles.dql.schema : DqlSchema, isDqlPath;
import sparkles.ui.property_tree : PathSeg, parsePath, resolve;

@("dql.property-tree: paths resolve the same leaves")
@safe unittest
{
    static struct SubItem
    {
        int count;
        string name;
    }
    static struct Root
    {
        SubItem item;
        bool active;
    }

    // One reflection walk feeds both address spaces: the generated query
    // schema over `Root` and the property tree's own dispatch must agree on
    // every canonical address, and DQL evaluation must agree with the values
    // the tree hands out. No resolver is hand-written here - a duplicated
    // schema is exactly the drift this test exists to catch.
    alias Schema = DqlSchema!Root;
    Root r = Root(SubItem(42, "sparkle"), true);

    static struct Reached
    {
        bool hit;
        void opCall(T)(ref T) { hit = true; }
    }

    foreach (doc; Schema.paths)
    {
        PathSeg[] segs;
        assert(parsePath(doc.path, segs), doc.path);
        auto reach = Reached.init;
        assert(resolve!reach(r, segs) && reach.hit, doc.path);
    }

    PathSeg[] missing;
    assert(parsePath("item.missing", missing));
    auto miss = Reached.init;
    assert(!resolve!miss(r, missing) && !miss.hit);
    assert(!isDqlPath!Schema("item.missing"));

    DqlEngine engine;
    foreach (query, expected; [
        "item.count == 42 && item.name == `sparkle` && active == true": true,
        "item.count > 100 || active == false": false,
        "item.count == null": false,
        "active != null": true,
    ])
    {
        auto parsed = parseDql!Schema(engine, query);
        assert(parsed.hasValue, parsed.error.message);
        assert(evalDql!Schema(engine, parsed.value, r) == expected, query);
    }
}
