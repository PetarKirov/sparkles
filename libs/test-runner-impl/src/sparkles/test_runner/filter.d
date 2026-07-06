module sparkles.test_runner.filter;

import sparkles.test_runner.model : Test;

/// Whether `test` passes the include/exclude regular expression filters.
/// Matching is against `fullName ~ " " ~ name` (silly's convention). When both
/// are set they combine (silly's semantics): the test must match `include` and
/// must not match `exclude`.
bool matchesFilter(in Test test, string include, string exclude) @safe
{
    import std.regex : matchFirst;

    if (!include.length && !exclude.length)
        return true;

    const haystack = test.fullName ~ " " ~ test.name;
    if (include.length && haystack.matchFirst(include).empty)
        return false;
    if (exclude.length && !haystack.matchFirst(exclude).empty)
        return false;
    return true;
}

@("matchesFilter.basic") @safe
unittest
{
    const t = Test(fullName: "pkg.mod.__unittest_L1_C1", name: "SmallBuffer.append");
    assert(t.matchesFilter(null, null));
    assert(t.matchesFilter("SmallBuffer", null));
    assert(!t.matchesFilter(null, "SmallBuffer"));
    // Include and exclude combine: matches include but excluded → skipped.
    assert(!t.matchesFilter("SmallBuffer", "append"));
    // Matches include and not excluded → run.
    assert(t.matchesFilter("SmallBuffer", "Buffer.remove"));
}
