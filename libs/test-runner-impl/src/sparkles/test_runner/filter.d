module sparkles.test_runner.filter;

import sparkles.test_runner.model : Test;

/// Whether `test` passes the include/exclude regular expression filters.
/// Matching is against `fullName ~ " " ~ name` (silly's convention). Include
/// wins when both are set.
bool matchesFilter(in Test test, string include, string exclude) @safe
{
    import std.regex : matchFirst;

    if (!include.length && !exclude.length)
        return true;

    const haystack = test.fullName ~ " " ~ test.name;
    if (include.length)
        return !haystack.matchFirst(include).empty;
    return haystack.matchFirst(exclude).empty;
}

@("matchesFilter.basic") @safe
unittest
{
    const t = Test(fullName: "pkg.mod.__unittest_L1_C1", name: "SmallBuffer.append");
    assert(t.matchesFilter(null, null));
    assert(t.matchesFilter("SmallBuffer", null));
    assert(!t.matchesFilter(null, "SmallBuffer"));
}
