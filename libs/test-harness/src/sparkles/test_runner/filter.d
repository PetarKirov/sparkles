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
    const t = Test(fullName: "pkg.mod.__unittest_L1_C1", name: "SharedBuffer.append");
    assert(t.matchesFilter(null, null));
    assert(t.matchesFilter("SharedBuffer", null));
    assert(!t.matchesFilter(null, "SharedBuffer"));
    // Include and exclude combine: matches include but excluded → skipped.
    assert(!t.matchesFilter("SharedBuffer", "append"));
    // Matches include and not excluded → run.
    assert(t.matchesFilter("SharedBuffer", "Buffer.remove"));
}

/// Which tests a run keeps by their `@slow` marker: all of them (the
/// default), none of them (`--skip-slow`), or only them (`--only-slow`).
enum SlowSelection
{
    run,
    skip,
    only,
}

/// Whether `test` is kept under `selection`.
bool matchesSlowSelection(in Test test, SlowSelection selection) @safe pure nothrow @nogc
{
    final switch (selection)
    {
        case SlowSelection.run:  return true;
        case SlowSelection.skip: return !test.traits.isSlow;
        case SlowSelection.only: return test.traits.isSlow;
    }
}

@("matchesSlowSelection.basic") @safe pure nothrow @nogc
unittest
{
    import sparkles.test_runner.model : TestTraits;

    const fast = Test(name: "fast");
    const slow = Test(name: "slow", traits: TestTraits(isSlow: true));
    assert(fast.matchesSlowSelection(SlowSelection.run));
    assert(slow.matchesSlowSelection(SlowSelection.run));
    assert(fast.matchesSlowSelection(SlowSelection.skip));
    assert(!slow.matchesSlowSelection(SlowSelection.skip));
    assert(!fast.matchesSlowSelection(SlowSelection.only));
    assert(slow.matchesSlowSelection(SlowSelection.only));
}
