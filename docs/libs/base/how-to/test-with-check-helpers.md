# Test `@nogc` code with check helpers

Use allocation-free check helpers to write unit tests for output-range formatting functions and explain how recycled exception instances enable throwing in `@nogc` functions.

## Testing Output Ranges without Allocation

Normally, testing a custom `toString(Writer)(ref Writer w)` method or a writer function involves allocating a `string` or using `std.array.appender` which GC-allocates and breaks `@nogc` constraints.

`sparkles:base` provides two core check helpers in `sparkles.base.smallbuffer` that operate entirely within `@nogc` buffers and compare output using a recycled exception mechanism on failure:

- **`checkToString(value, expected)`**: Tests any type that implements `void toString(Writer)(ref Writer w)`.
- **`checkWriter!render(expected)`**: Tests a custom lambda/expression `render(ref Writer)` that writes to an output range.

Example unit test:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_test_with_check_helpers"
    dependency "sparkles:base" version="*"
+/
import sparkles.base.smallbuffer : checkToString, checkWriter;
import sparkles.base.styled_template : writeStyled, styledWriteln;
import core.exception : AssertError;

struct Point
{
    int x;
    int y;

    void toString(Writer)(ref Writer w) const
    {
        writeStyled(w, i"($(x),$(y))");
    }
}

void main()
{
    try
    {
        // 1. Test toString using checkToString
        checkToString(Point(3, 4), "(3,4)");

        // 2. Test a custom writer using checkWriter
        checkWriter!((ref b) {
            import sparkles.base.text.writers : writeIntegerPadded;
            writeIntegerPadded(b, 5, 3);
        })("005");

        styledWriteln(i"{green ✓ All tests passed successfully!}");
    }
    catch (AssertError e)
    {
        styledWriteln(i"{red ✗ Test failed: $(e.msg)}");
    }
}
```

```ansi
[32m✓ All tests passed successfully![39m
```

## How Recycled Errors Work

GC exceptions are prohibited in `@safe pure nothrow @nogc` code. To allow throwing assertions on mismatch without violating `@nogc`, the check helpers use the `recycledErrorInstance` utility from `sparkles.base.lifetime`.

### `recycledErrorInstance`

`recycledErrorInstance!T(message, args...)` returns a reference to a thread-local static instance of type `T` (which must inherit from `Error`), reinitializing it with the provided message and arguments.

```d
import sparkles.base.lifetime : recycledErrorInstance;
import core.exception : AssertError;

@nogc pure nothrow void checkValue(int x) @trusted
{
    if (x < 0)
    {
        // Throwing without GC allocation
        throw recycledErrorInstance!AssertError("Value cannot be negative");
    }
}
```

### Important Constraints and Warnings:

1. **Reused Memory:** The static buffer resides in thread-local storage and is reused every time `recycledErrorInstance` is called. Reinitialization emplaces the new values into the same memory slot.
2. **Short-Lived References:** Do not store or capture references to the returned exception object. Since subsequent calls recycle the memory, old references will be silently modified or corrupted.
3. **Destruction:** Destructors are not called for classes (to avoid GC overhead), so class types used with this pattern should not manage resources requiring cleanup.
4. **Safety Attribute:** The function is `@system` because `pure` is technically bypassed under the hood by using thread-local memory. Callers must wrap the throw or construction in a `@trusted` block.
