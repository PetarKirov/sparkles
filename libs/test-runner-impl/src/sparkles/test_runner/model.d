/**
 * Data model of the test runner: descriptions of discovered tests and the
 * results of executing them.
 *
 * Everything here is runtime data — the compile-time discovery that produces
 * it lives in $(MREF sparkles,test_runner,discovery).
 */
module sparkles.test_runner.model;

import core.time : Duration;

/// Source location of a `unittest` block, from `__traits(getLocation)`.
/// The file path is as the compiler saw it (usually relative to the package
/// root that `dub test` runs in).
struct TestLocation
{
    string file;
    size_t line, column;
}

/// Special handling a test opted into via the attributes in
/// $(MREF sparkles,test_runner,attributes).
struct TestTraits
{
    bool isBetterC;
    bool isCtfe;
    bool isWasm;
    bool isBenchmark;

    /// Fixed benchmark iteration count; `0` auto-scales.
    uint benchIterations;

    /// The test's safety/purity attributes (`"@safe pure nothrow @nogc"`),
    /// re-applied to extracted `@betterC`/`@wasm` test functions.
    string functionAttributes;
}

/// One discovered `unittest` block.
struct Test
{
    /// Fully qualified name of the unittest symbol,
    /// e.g. `sparkles.base.smallbuffer.__unittest_L42_C1`.
    string fullName;

    /// Display name: the first string UDA, or the symbol identifier.
    string name;

    TestLocation location;
    TestTraits traits;

    /// The unittest function itself.
    void function() ptr;

    /// The module part of `fullName` (everything before the last `.`).
    string moduleName() const @safe pure nothrow @nogc return scope
    {
        foreach_reverse (i, c; fullName)
            if (c == '.')
                return fullName[0 .. i];
        return fullName;
    }
}

@("Test.moduleName")
@safe pure nothrow @nogc
unittest
{
    static immutable t = Test(fullName: "pkg.mod.__unittest_L1_C1", name: "x");
    assert(t.moduleName == "pkg.mod");
    static immutable noDot = Test(fullName: "lonely", name: "x");
    assert(noDot.moduleName == "lonely");
}

/// One `Throwable` (possibly chained) caught while executing a test.
struct Thrown
{
    string type;
    string message;
    string file;
    size_t line;
    immutable(string)[] info;
}

/// The outcome of executing one test at runtime.
struct TestResult
{
    Test test;
    bool succeeded;
    bool skipped; /// the body called `skipTest` — neither passed nor failed
    string skipReason;
    Duration duration;
    immutable(Thrown)[] thrown;
}
