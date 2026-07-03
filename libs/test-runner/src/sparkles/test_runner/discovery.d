/**
 * Compile-time test discovery.
 *
 * Walks the modules listed by dub's generated `dub_test_root.allModules`,
 * collecting every `unittest` block — module-level and nested in aggregates —
 * into runtime $(REF Test, sparkles,test_runner,model) descriptions, and
 * exposes the attribute metadata needed by the specialized execution modes.
 */
module sparkles.test_runner.discovery;

import std.meta : Alias;
import std.traits : fullyQualifiedName, getUDAs, hasUDA;

import sparkles.test_runner.attributes : benchmark, betterC, ctfe, wasm;
import sparkles.test_runner.model : Test, TestLocation, TestTraits;

/// The module containing `m`: `m` itself when it is a module, or its parent
/// when the module contains a member of the same name (in which case dub's
/// `allModules` yields the member).
template moduleOf(alias m)
{
    static if (__traits(isModule, m))
        alias moduleOf = m;
    else
        alias moduleOf = Alias!(__traits(parent, m));
}

/// The display name of a unittest: its first string UDA, or its identifier.
string testName(alias test)()
{
    foreach (attribute; __traits(getAttributes, test))
        static if (is(typeof(attribute) : string))
            return attribute;
    return __traits(identifier, test);
}

/// The source location of a unittest block.
TestLocation testLocation(alias test)()
{
    auto loc = __traits(getLocation, test);
    return TestLocation(file: loc[0], line: loc[1], column: loc[2]);
}

/// The subset of a test's function attributes that extracted `@betterC` /
/// `@wasm` test functions re-apply (safety, purity, `nothrow`, `@nogc`).
string functionAttributesOf(alias test)()
{
    string attributes;
    static foreach (attribute; __traits(getFunctionAttributes, test))
    {
        static if (attribute == "@safe" || attribute == "@system"
            || attribute == "pure" || attribute == "nothrow" || attribute == "@nogc")
        {
            attributes ~= attribute ~ " ";
        }
    }
    return attributes;
}

/// The runner-attribute traits of a unittest block.
TestTraits testTraits(alias test)()
{
    TestTraits traits;
    traits.isBetterC = hasUDA!(test, betterC);
    traits.isCtfe = hasUDA!(test, ctfe);
    traits.isWasm = hasUDA!(test, wasm);
    static if (hasUDA!(test, betterC) || hasUDA!(test, wasm))
        traits.functionAttributes = functionAttributesOf!test;
    static if (hasUDA!(test, benchmark))
    {
        traits.isBenchmark = true;
        alias uda = Alias!(getUDAs!(test, benchmark)[0]);
        // `@benchmark` attaches the type; `@benchmark(...)` attaches a value.
        static if (!is(uda))
            traits.benchIterations = uda.iterations;
    }
    return traits;
}

/// A runtime description of one unittest block.
Test makeTest(alias test)()
{
    return Test(
        fullName: fullyQualifiedName!test,
        name: testName!test,
        location: testLocation!test,
        traits: testTraits!test,
        ptr: &test,
    );
}

/// All tests declared at module level or inside aggregates of `module_`.
Test[] moduleTests(alias module_)()
{
    Test[] tests;

    foreach (test; __traits(getUnitTests, module_))
        tests ~= makeTest!test;

    // Unittests nested in structs and classes (the guard chain mirrors the
    // one battle-tested in silly).
    foreach (member; __traits(derivedMembers, module_))
        static if (__traits(compiles, __traits(getMember, module_, member)) &&
            __traits(compiles, __traits(isTemplate, __traits(getMember, module_, member))) &&
            !__traits(isTemplate, __traits(getMember, module_, member)) &&
            __traits(compiles, __traits(parent, __traits(getMember, module_, member))) &&
            __traits(isSame, __traits(parent, __traits(getMember, module_, member)), module_) &&
            __traits(compiles, __traits(getUnitTests, __traits(getMember, module_, member))))
        {
            foreach (test; __traits(getUnitTests, __traits(getMember, module_, member)))
                tests ~= makeTest!test;
        }

    return tests;
}

/// All tests of the given modules (pass `dub_test_root.allModules`).
Test[] discoverTests(Modules...)()
{
    Test[] tests;
    static foreach (m; Modules)
        tests ~= moduleTests!(moduleOf!m)();
    return tests;
}

version (unittest)
{
    @("discovery.selfTest")
    @betterC @safe pure nothrow @nogc
    unittest
    {
        // Discovered by the tests below via reflection on this module.
        assert(1 + 1 == 2);
    }
}

@("discovery.moduleTests")
@safe
unittest
{
    alias thisModule = Alias!(__traits(parent, moduleTests));
    enum tests = moduleTests!thisModule();
    static assert(tests.length >= 2);

    enum self = () {
        foreach (t; tests)
            if (t.name == "discovery.selfTest")
                return t;
        assert(0, "discovery.selfTest not found");
    }();
    static assert(self.traits.isBetterC);
    static assert(!self.traits.isCtfe);
    static assert(self.location.file.length > 0);
    static assert(self.location.line > 0);
    assert(self.moduleName == "sparkles.test_runner.discovery");
}
