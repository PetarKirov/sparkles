module sparkles.core_cli.lifetime;

import core.lifetime : emplace;

/**
 * Returns a reference to a thread-local static instance of type `T`,
 * (re)initialized with the provided arguments.
 *
 * The instance is "recycled" - the same memory location is reused across
 * calls. Each call reinitializes the instance with new arguments, which
 * means any previously obtained references will see the updated values.
 *
 * This is primarily useful for throwing `Error`s in `@nogc` code, where
 * allocating new objects is not allowed, but reusing a static instance
 * is permitted.
 *
 * For structs, the destructor is called before reinitialization. For
 * classes, destructors are NOT called (to maintain `@nogc` compatibility),
 * so class types used with this function should not hold resources that
 * require cleanup.
 *
 * Warning: Do not store references across multiple calls - they will be
 * invalidated when the instance is recycled.
 *
 * Example:
 * ---
 * @nogc void foo() {
 *     throw recycledInstance!Error("Something went wrong");
 * }
 * ---
 */
T recycledInstance(T, Args...)(auto ref Args args)
if (is(T == class))
{
    enum size = __traits(classInstanceSize, T);
    enum alignment = __traits(classInstanceAlignment, T);

    align(alignment) static ubyte[size] buffer;

    // Reinitialize on each access
    emplace!T(buffer[], args);

    return cast(T) buffer.ptr;
}

/// ditto
ref T recycledInstance(T, Args...)(auto ref Args args)
if (!is(T == class))
{
    static T instance;
    instance = T(args);
    return instance;
}

@("recycledInstance.struct.reinitialization")
@nogc nothrow @safe
unittest
{
    // Test that struct reinitialization works correctly
    static struct Data
    {
        int a;
        string b;
        double c;
    }

    auto d1 = &recycledInstance!Data(1, "first", 1.5);
    assert(d1.a == 1);
    assert(d1.b == "first");
    assert(d1.c == 1.5);

    auto d2 = &recycledInstance!Data(2, "second", 2.5);
    assert(d2.a == 2);
    assert(d2.b == "second");
    assert(d2.c == 2.5);

    // d1 and d2 point to the same instance
    assert(d1 is d2);
    assert(d1.a == 2); // d1 sees the updated values
}

@("recycledInstance.struct.nested")
@nogc nothrow @safe
unittest
{
    // Test nested structs
    static struct Inner
    {
        int value;
    }

    static struct Outer
    {
        Inner inner;
        int other;
    }

    auto o = &recycledInstance!Outer(Inner(42), 100);
    assert(o.inner.value == 42);
    assert(o.other == 100);

    auto o2 = &recycledInstance!Outer(Inner(99), 200);
    assert(o.inner.value == 99); // Original reference sees new values
    assert(o.other == 200);
}

@("recycledInstance.struct.withArray")
@nogc nothrow @safe
unittest
{
    // Test struct containing fixed-size array
    static struct ArrayContainer
    {
        int[4] data;
    }

    int[4] initData = [1, 2, 3, 4];
    auto c = &recycledInstance!ArrayContainer(initData);
    assert(c.data == [1, 2, 3, 4]);

    int[4] newData = [5, 6, 7, 8];
    auto c2 = &recycledInstance!ArrayContainer(newData);
    assert(c.data == [5, 6, 7, 8]); // Same instance
}

@("recycledInstance.struct.differentTypesAreDifferentInstances")
@nogc nothrow @system
unittest
{
    // Verify that different struct types get different static instances
    static struct TypeA { int value; }
    static struct TypeB { int value; }

    auto a = &recycledInstance!TypeA(10);
    auto b = &recycledInstance!TypeB(20);

    // Different types should have different instances
    assert(cast(void*) a !is cast(void*) b);
    assert(a.value == 10);
    assert(b.value == 20);

    // Modifying one shouldn't affect the other
    recycledInstance!TypeA(100);
    assert(a.value == 100);
    assert(b.value == 20); // Unchanged
}

@("recycledInstance.struct.alignment")
@nogc nothrow @system
unittest
{
    // Test structs with specific alignment requirements
    static struct Aligned
    {
        align(32) long[4] data;
    }

    long[4] initData = [1L, 2L, 3L, 4L];
    auto a = &recycledInstance!Aligned(initData);
    assert(a.data == [1L, 2L, 3L, 4L]);

    // Verify alignment
    auto addr = cast(size_t) &a.data[0];
    assert(addr % 32 == 0, "Data should be 32-byte aligned");
}

@("recycledInstance.struct.largeStruct")
@nogc nothrow @safe
unittest
{
    // Test with a larger struct to ensure memory handling is correct
    static struct LargeStruct
    {
        long[64] data; // 512 bytes
    }

    long[64] expected;
    foreach (i; 0 .. 64)
        expected[i] = i * 100;

    auto large = &recycledInstance!LargeStruct(expected);

    foreach (i; 0 .. 64)
        assert(large.data[i] == i * 100);
}

@("recycledInstance.primitiveTypes")
@nogc nothrow @system
unittest
{
    // Test recycling behavior with primitive types
    auto i1 = &recycledInstance!int(42);
    assert(*i1 == 42);

    auto i2 = &recycledInstance!int(100);
    assert(*i1 == 100); // Same instance, sees new value
    assert(i1 is i2);

    // Different primitive types get different instances
    auto intVal = &recycledInstance!int(1);
    auto longVal = &recycledInstance!long(2);
    auto doubleVal = &recycledInstance!double(3.0);

    assert(*intVal == 1);
    assert(*longVal == 2);
    assert(*doubleVal == 3.0);

    assert(cast(void*) intVal !is cast(void*) longVal);
    assert(cast(void*) longVal !is cast(void*) doubleVal);
}

@("recycledInstance.struct.destructorBehavior")
@nogc nothrow @safe
unittest
{
    // Test struct destructor behavior during reinitialization:
    // 1. Destructor is called on each reinitialization
    // 2. Destructor receives the previous instance's state
    static int destructorCallCount = 0;
    static int lastDestroyedValue = -1;

    static struct TrackedStruct
    {
        int value;

        @nogc nothrow this(int v)
        {
            value = v;
        }

        @nogc nothrow ~this()
        {
            destructorCallCount++;
            lastDestroyedValue = value;
        }
    }

    // Reset counters
    destructorCallCount = 0;
    lastDestroyedValue = -1;

    // First initialization
    recycledInstance!TrackedStruct(100);
    int countAfterFirst = destructorCallCount;

    // Second initialization - destructor called with previous value
    recycledInstance!TrackedStruct(200);
    assert(destructorCallCount > countAfterFirst, "Destructor should be called on reinit");
    assert(lastDestroyedValue == 100, "Destructor should see previous value (100)");

    // Third initialization - destructor called again
    recycledInstance!TrackedStruct(300);
    assert(lastDestroyedValue == 200, "Destructor should see previous value (200)");

    // Fourth initialization - verify count keeps incrementing
    int countBefore = destructorCallCount;
    recycledInstance!TrackedStruct(400);
    assert(destructorCallCount > countBefore, "Destructor called on each reinit");
    assert(lastDestroyedValue == 300, "Destructor should see previous value (300)");
}

/**
 * Returns a recycled error instance, suitable for throwing in `@nogc` code.
 *
 * This is a convenience wrapper around `recycledInstance` with attributes
 * appropriate for error handling: `@system pure nothrow @nogc`.
 *
 * The function is marked `@system` because `pure` is technically a lie -
 * the implementation uses thread-local state. However, this is acceptable
 * for error throwing because:
 * $(UL
 *   $(LI Try-catch code typically doesn't rely on object identity)
 *   $(LI Exception object lifetimes are stack-bound)
 * )
 *
 * Callers should wrap calls in `@trusted` after verifying correct usage.
 *
 * Example:
 * ---
 * @nogc pure nothrow void foo() @trusted {
 *     throw recycledErrorInstance!Error("Something went wrong");
 * }
 * ---
 */
T recycledErrorInstance(T, Args...)(auto ref Args args) @system pure nothrow @nogc
if (is(T == class) && is(T : Error))
{
    return (cast(T function(Args) @system pure nothrow @nogc) &recycledErrorInstanceImpl!(T, Args))(args);
}

private T recycledErrorInstanceImpl(T, Args...)(Args args) @nogc nothrow
if (is(T == class) && is(T : Error))
{
    return recycledInstance!T(args);
}

@("recycledErrorInstance.reinitialization")
@nogc nothrow pure @safe
unittest
{
    // Thoroughly test that reinitialization works correctly
    static class CountingError : Error
    {
        int value;

        @nogc nothrow pure this(string msg, int val)
        {
            super(msg);
            this.value = val;
        }
    }

    // First initialization
    auto err1 = () @trusted { return recycledErrorInstance!CountingError("msg1", 100); }();
    assert(err1.value == 100);
    assert(err1.msg == "msg1");

    // Reinitialize with different values
    auto err2 = () @trusted { return recycledErrorInstance!CountingError("msg2", 200); }();
    assert(err2.value == 200);
    assert(err2.msg == "msg2");

    // The original reference should see the new values (same instance)
    assert(err1.value == 200);
    assert(err1.msg == "msg2");

    // Third reinitialization
    auto err3 = () @trusted { return recycledErrorInstance!CountingError("msg3", 300); }();
    assert(err1.value == 300);
    assert(err2.value == 300);
    assert(err3.value == 300);
}

@("recycledErrorInstance.canThrowInNoGC")
@nogc nothrow @system
unittest
{
    // Verifies that recycledErrorInstance can actually be used for throwing in @nogc code
    static class TestError : Error
    {
        @nogc nothrow this(string msg)
        {
            super(msg);
        }
    }

    static void throwingFunc() @nogc @trusted
    {
        throw recycledErrorInstance!TestError("test error in @nogc");
    }

    bool caught = false;
    try
    {
        auto instance = () @trusted { return recycledErrorInstance!TestError("compiles in @nogc"); }();
        assert(instance !is null);
        throw instance;
    }
    catch (Error)
    {
        caught = true;
    }

    assert(caught, "Should have caught the thrown error");
}

@("recycledErrorInstance.inheritance")
@nogc nothrow pure @safe
unittest
{
    // Test that inheritance hierarchy is properly preserved
    static class BaseError : Error
    {
        int baseCode;

        @nogc nothrow pure this(string msg, int code)
        {
            super(msg);
            this.baseCode = code;
        }
    }

    static class DerivedError : BaseError
    {
        int derivedCode;

        @nogc nothrow pure this(string msg, int baseCode, int derivedCode)
        {
            super(msg, baseCode);
            this.derivedCode = derivedCode;
        }
    }

    auto derived = () @trusted { return recycledErrorInstance!DerivedError("derived error", 10, 20); }();
    assert(derived.msg == "derived error");
    assert(derived.baseCode == 10);
    assert(derived.derivedCode == 20);

    // Verify it's actually a DerivedError
    BaseError base = derived;
    assert(base !is null);
    assert(base.baseCode == 10);
}

@("recycledErrorInstance.differentTypesAreDifferentInstances")
@nogc nothrow pure @system
unittest
{
    // Verify that different class types get different static buffers
    static class ErrorA : Error
    {
        @nogc nothrow pure this(string msg) { super(msg); }
    }

    static class ErrorB : Error
    {
        @nogc nothrow pure this(string msg) { super(msg); }
    }

    auto a = () @trusted { return recycledErrorInstance!ErrorA("error A"); }();
    auto b = () @trusted { return recycledErrorInstance!ErrorB("error B"); }();

    // Different types should have different instances
    assert(cast(void*) a !is cast(void*) b);
    assert(a.msg == "error A");
    assert(b.msg == "error B");
}

@("recycledErrorInstance.alignment")
@nogc nothrow pure @system
unittest
{
    // Test that alignment is properly handled for classes with specific alignment requirements
    static class AlignedError : Error
    {
        align(16) long[2] alignedData;

        @nogc nothrow pure this(string msg, long val)
        {
            super(msg);
            alignedData[0] = val;
            alignedData[1] = val * 2;
        }
    }

    auto instance = () @trusted { return recycledErrorInstance!AlignedError("aligned", 42); }();
    assert(instance.alignedData[0] == 42);
    assert(instance.alignedData[1] == 84);

    // Verify alignment (address should be 16-byte aligned for the data)
    auto addr = cast(size_t) &instance.alignedData[0];
    assert(addr % 16 == 0, "Data should be 16-byte aligned");
}

@("recycledErrorInstance.destructorBehavior")
@nogc nothrow @safe
unittest
{
    // Note: For classes, the current implementation does NOT call destructors
    // before reinitializing. This test documents the current behavior.
    // Classes used with recycledErrorInstance (like Error) typically shouldn't
    // hold resources that need cleanup.

    static int dtorCount = 0;

    static class TrackedError : Error
    {
        int id;

        @nogc nothrow this(string msg, int id)
        {
            super(msg);
            this.id = id;
        }

        ~this()
        {
            dtorCount++;
        }
    }

    assert(dtorCount == 0);

    auto e1 = () @trusted { return recycledErrorInstance!TrackedError("error1", 1); }();
    assert(e1.id == 1);
    assert(dtorCount == 0);

    auto e2 = () @trusted { return recycledErrorInstance!TrackedError("error2", 2); }();
    assert(e2.id == 2);
    assert(dtorCount == 0);

    // Document current behavior: class destructors are NOT called
    // This is intentional for @nogc compatibility - calling destroy
    // would potentially allocate. For Error types used in @nogc code,
    // this is acceptable as they shouldn't hold resources.
}

@("recycledErrorInstance.canBeUsedInPureNogcNothrowCode")
@nogc nothrow pure @safe
unittest
{
    static class TestError : Error
    {
        @nogc nothrow pure this(string msg)
        {
            super(msg);
        }
    }

    // Verify the function can be called from @nogc pure nothrow code with @trusted
    static void throwingFunc() @nogc pure nothrow @trusted
    {
        throw recycledErrorInstance!TestError("test error");
    }

    // Verify it compiles - we can't actually throw in unittest
    auto instance = () @trusted { return recycledErrorInstance!TestError("compiles"); }();
    assert(instance !is null);
}

@("recycledErrorInstance.onlyAcceptsErrorSubclasses")
@nogc nothrow pure @system
unittest
{
    // This test verifies the template constraint: only Error subclasses are accepted
    // The following should NOT compile (verified by static assert):

    static class NotAnError {}

    // Verify constraint rejects non-Error classes
    static assert(!__traits(compiles, recycledErrorInstance!NotAnError()));

    // Verify constraint rejects structs
    static struct SomeStruct { int x; }
    static assert(!__traits(compiles, recycledErrorInstance!SomeStruct(1)));

    // Verify constraint rejects primitives
    static assert(!__traits(compiles, recycledErrorInstance!int(42)));

    // Verify it accepts Error subclasses
    static class CustomError : Error
    {
        @nogc nothrow pure this(string msg) { super(msg); }
    }
    static assert(__traits(compiles, recycledErrorInstance!CustomError("ok")));
}
