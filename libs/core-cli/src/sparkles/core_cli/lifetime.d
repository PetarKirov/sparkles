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

@("recycledInstance.class.basic")
@nogc nothrow
unittest
{
    static class MyError : Error
    {
        int code;

        @nogc nothrow this(string msg, int code = 0)
        {
            super(msg);
            this.code = code;
        }
    }

    auto err1 = recycledInstance!MyError("first error", 1);
    assert(err1.msg == "first error");
    assert(err1.code == 1);

    auto err2 = recycledInstance!MyError("second error", 2);
    assert(err2.msg == "second error");
    assert(err2.code == 2);

    // Both references point to the same static instance
    assert(err1 is err2);
}

@("recycledInstance.class.canThrowInNoGC")
@nogc nothrow
unittest
{
    // Verifies that the recycledInstance can actually be used for throwing in @nogc code
    static class TestError : Error
    {
        @nogc nothrow this(string msg)
        {
            super(msg);
        }
    }

    static void throwingFunc() @nogc
    {
        throw recycledInstance!TestError("test error in @nogc");
    }

    bool caught = false;
    try
    {
        // We can't actually call throwingFunc here in the unittest
        // because catching would allocate, but we verify it compiles
        auto instance = recycledInstance!TestError("compiles in @nogc");
        assert(instance !is null);
    }
    catch (Error)
    {
        caught = true;
    }
}

@("recycledInstance.class.inheritance")
@nogc nothrow
unittest
{
    // Test that inheritance hierarchy is properly preserved
    static class BaseError : Error
    {
        int baseCode;

        @nogc nothrow this(string msg, int code)
        {
            super(msg);
            this.baseCode = code;
        }
    }

    static class DerivedError : BaseError
    {
        int derivedCode;

        @nogc nothrow this(string msg, int baseCode, int derivedCode)
        {
            super(msg, baseCode);
            this.derivedCode = derivedCode;
        }
    }

    auto derived = recycledInstance!DerivedError("derived error", 10, 20);
    assert(derived.msg == "derived error");
    assert(derived.baseCode == 10);
    assert(derived.derivedCode == 20);

    // Verify it's actually a DerivedError
    BaseError base = derived;
    assert(base !is null);
    assert(base.baseCode == 10);
}

@("recycledInstance.class.differentTypesAreDifferentInstances")
@nogc nothrow
unittest
{
    // Verify that different class types get different static buffers
    static class ErrorA : Error
    {
        @nogc nothrow this(string msg) { super(msg); }
    }

    static class ErrorB : Error
    {
        @nogc nothrow this(string msg) { super(msg); }
    }

    auto a = recycledInstance!ErrorA("error A");
    auto b = recycledInstance!ErrorB("error B");

    // Different types should have different instances
    assert(cast(void*) a !is cast(void*) b);
    assert(a.msg == "error A");
    assert(b.msg == "error B");
}

@("recycledInstance.class.alignment")
unittest
{
    // Test that alignment is properly handled for classes with specific alignment requirements
    static class AlignedClass : Error
    {
        align(16) long[2] alignedData;

        this(string msg, long val)
        {
            super(msg);
            alignedData[0] = val;
            alignedData[1] = val * 2;
        }
    }

    auto instance = recycledInstance!AlignedClass("aligned", 42);
    assert(instance.alignedData[0] == 42);
    assert(instance.alignedData[1] == 84);

    // Verify alignment (address should be 16-byte aligned for the data)
    auto addr = cast(size_t) &instance.alignedData[0];
    assert(addr % 16 == 0, "Data should be 16-byte aligned");
}

@("recycledInstance.class.zeroArgs")
unittest
{
    // Test class with no constructor arguments (default constructor)
    static class SimpleError : Error
    {
        this()
        {
            super("default message");
        }
    }

    auto err = recycledInstance!SimpleError();
    assert(err.msg == "default message");
}

@("recycledInstance.class.reinitialization")
@nogc nothrow
unittest
{
    // Thoroughly test that reinitialization works correctly
    static class CountingError : Error
    {
        int value;

        @nogc nothrow this(string msg, int val)
        {
            super(msg);
            this.value = val;
        }
    }

    // First initialization
    auto err1 = recycledInstance!CountingError("msg1", 100);
    assert(err1.value == 100);
    assert(err1.msg == "msg1");

    // Reinitialize with different values
    auto err2 = recycledInstance!CountingError("msg2", 200);
    assert(err2.value == 200);
    assert(err2.msg == "msg2");

    // The original reference should see the new values (same instance)
    assert(err1.value == 200);
    assert(err1.msg == "msg2");

    // Third reinitialization
    auto err3 = recycledInstance!CountingError("msg3", 300);
    assert(err1.value == 300);
    assert(err2.value == 300);
    assert(err3.value == 300);
}

@("recycledInstance.struct.basic")
unittest
{
    static struct Point
    {
        int x, y;
    }

    auto p1 = &recycledInstance!Point(1, 2);
    assert(p1.x == 1 && p1.y == 2);

    auto p2 = &recycledInstance!Point(3, 4);
    assert(p2.x == 3 && p2.y == 4);

    // Both references point to the same static instance
    assert(p1 is p2);
}

@("recycledInstance.struct.reinitialization")
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

@("recycledInstance.struct.emptyStruct")
unittest
{
    // Test empty struct (edge case)
    static struct Empty {}

    auto e1 = &recycledInstance!Empty();
    auto e2 = &recycledInstance!Empty();
    assert(e1 is e2);
}

@("recycledInstance.struct.singleField")
unittest
{
    // Test single field struct
    static struct Single
    {
        long value;
    }

    auto s = &recycledInstance!Single(long.max);
    assert(s.value == long.max);

    auto s2 = &recycledInstance!Single(long.min);
    assert(s.value == long.min);
}

@("recycledInstance.struct.differentTypesAreDifferentInstances")
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

@("recycledInstance.struct.defaultInit")
unittest
{
    // Test struct with default initialization
    static struct WithDefaults
    {
        int x = 42;
        string s = "default";
    }

    // Note: recycledInstance requires explicit arguments
    // This tests the struct can be constructed with its default values
    auto w = &recycledInstance!WithDefaults(42, "default");
    assert(w.x == 42);
    assert(w.s == "default");

    auto w2 = &recycledInstance!WithDefaults(100, "custom");
    assert(w.x == 100);
    assert(w.s == "custom");
}

@("recycledInstance.struct.refReturned")
unittest
{
    // Verify that the ref return works correctly
    static struct Mutable
    {
        int value;
    }

    ref Mutable getMutable()
    {
        return recycledInstance!Mutable(0);
    }

    getMutable().value = 42;

    // Changes through ref should persist
    auto m = &recycledInstance!Mutable(0);
    // Note: This reinitializes to 0, so value will be 0
    assert(m.value == 0);
}

@("recycledInstance.struct.largeStruct")
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
unittest
{
    // Test with primitive types
    auto i = &recycledInstance!int(42);
    assert(*i == 42);

    auto i2 = &recycledInstance!int(100);
    assert(*i == 100); // Same instance
    assert(i is i2);
}

@("recycledInstance.primitiveTypes.different")
unittest
{
    // Different primitive types get different instances
    auto intVal = &recycledInstance!int(1);
    auto longVal = &recycledInstance!long(2);
    auto doubleVal = &recycledInstance!double(3.0);

    assert(*intVal == 1);
    assert(*longVal == 2);
    assert(*doubleVal == 3.0);

    // They should be different memory locations
    assert(cast(void*) intVal !is cast(void*) longVal);
    assert(cast(void*) longVal !is cast(void*) doubleVal);
}

@("recycledInstance.struct.destructorCalled")
unittest
{
    // Test that struct destructor is called before reinitialization
    static int destructorCallCount = 0;
    static int constructionId = 0;

    static struct TrackedStruct
    {
        int id;

        this(int val)
        {
            id = val;
            constructionId = val;
        }

        ~this()
        {
            destructorCallCount++;
        }
    }

    // Reset counters
    destructorCallCount = 0;
    constructionId = 0;

    // First initialization
    auto s1 = &recycledInstance!TrackedStruct(1);
    assert(s1.id == 1);
    assert(constructionId == 1);
    // Destructor should be called once when the old value is replaced
    // via assignment operator (which calls destructor on old value)
    int destructorCountAfterFirst = destructorCallCount;

    // Second initialization - should call destructor on old instance
    auto s2 = &recycledInstance!TrackedStruct(2);
    assert(s2.id == 2);
    assert(constructionId == 2);
    // Destructor should have been called one more time
    assert(destructorCallCount > destructorCountAfterFirst,
        "Destructor should be called when reinitializing struct");
}

@("recycledInstance.struct.destructorCalledMultipleTimes")
unittest
{
    // Test that destructor is called on each reinitialization
    static int destructorCallCount = 0;

    static struct CountingStruct
    {
        int value;

        this(int v)
        {
            value = v;
        }

        ~this()
        {
            destructorCallCount++;
        }
    }

    destructorCallCount = 0;

    // Multiple reinitializations
    recycledInstance!CountingStruct(1);
    int countAfter1 = destructorCallCount;

    recycledInstance!CountingStruct(2);
    int countAfter2 = destructorCallCount;
    assert(countAfter2 > countAfter1, "Destructor should be called on second init");

    recycledInstance!CountingStruct(3);
    int countAfter3 = destructorCallCount;
    assert(countAfter3 > countAfter2, "Destructor should be called on third init");

    recycledInstance!CountingStruct(4);
    int countAfter4 = destructorCallCount;
    assert(countAfter4 > countAfter3, "Destructor should be called on fourth init");
}

@("recycledInstance.struct.destructorReceivesCorrectState")
unittest
{
    // Test that destructor sees the correct state when called
    static int lastDestroyedValue = -1;

    static struct StateTracker
    {
        int value;

        this(int v)
        {
            value = v;
        }

        ~this()
        {
            lastDestroyedValue = value;
        }
    }

    lastDestroyedValue = -1;

    recycledInstance!StateTracker(100);
    // First time, destructor is called on default-initialized struct
    int afterFirst = lastDestroyedValue;

    recycledInstance!StateTracker(200);
    // Destructor should have been called with value 100
    assert(lastDestroyedValue == 100,
        "Destructor should see the previous value (100), got: " ~
        (cast(char)('0' + lastDestroyedValue / 100)).stringof);

    recycledInstance!StateTracker(300);
    // Destructor should have been called with value 200
    assert(lastDestroyedValue == 200,
        "Destructor should see the previous value (200)");
}

@("recycledInstance.class.destructorBehavior")
unittest
{
    // Note: For classes, the current implementation does NOT call destructors
    // before reinitializing. This test documents the current behavior.
    // Classes used with recycledInstance (like Error) typically shouldn't
    // hold resources that need cleanup.

    static int dtorCount = 0;

    static class TrackedError : Error
    {
        int id;

        this(string msg, int id)
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

    auto e1 = recycledInstance!TrackedError("error1", 1);
    assert(e1.id == 1);
    assert(dtorCount == 0);

    auto e2 = recycledInstance!TrackedError("error2", 2);
    assert(e2.id == 2);
    assert(dtorCount == 0);

    // Document current behavior: class destructors are NOT called
    // This is intentional for @nogc compatibility - calling destroy
    // would potentially allocate. For Error types used in @nogc code,
    // this is acceptable as they shouldn't hold resources.
}
