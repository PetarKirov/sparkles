module sparkles.core_cli.prettyprint;

import std.typecons : Tuple;

import sparkles.core_cli.term_style : Style;
import sparkles.core_cli.text_writers : EnumRender, writeEscapeSeq, writeStylized, writeStyledValue;

struct PrettyPrintOptions(SourceUriHook = void)
{
    ushort indentStep   = 2;     // spaces per indent level
    ushort maxDepth     = 8;     // recursion limit
    uint   maxItems     = 32;    // for arrays/ranges/AAs
    uint   softMaxWidth = 80;    // try single-line if output fits (0 = always multi-line)
    bool   useColors    = true;
    bool   useOscLinks  = false; // wrap type names in OSC 8 hyperlinks

    // Zero-state optimization (DbI §5.3):
    // Only store hook if it has runtime state
    static if (!is(SourceUriHook == void))
        SourceUriHook sourceUriHook;
}

/// Pretty-prints a value to a writer.
/// Returns the writer for chaining.
ref Writer prettyPrint(T, Writer, Hook = void)(
    in T value,
    return ref Writer writer,
    in PrettyPrintOptions!Hook opt = PrettyPrintOptions!Hook()
)
{
    prettyPrintImpl(value, writer, opt, 0);
    return writer;
}

/// Convenience overload that returns a string.
string prettyPrint(T, Hook = void)(in T value, in PrettyPrintOptions!Hook opt = PrettyPrintOptions!Hook())
{
    import std.array : appender;
    auto w = appender!string;
    prettyPrint(value, w, opt);
    return w[];
}

private void prettyPrintImpl(T, Writer, Hook)(
    in T value,
    ref Writer w,
    in PrettyPrintOptions!Hook opt,
    ushort depth
)
{
    import std.range.primitives : isForwardRange, hasLength, put;
    import std.traits : isSomeChar, isSomeString, isNumeric,
        isPointer, isAssociativeArray, isStaticArray, isDynamicArray;

    // Check depth limit
    if (depth > opt.maxDepth)
        return writeStylized(w, "...", opt.useColors ? Style.red : Style.none);

    enum isNullable = __traits(compiles, T.init is null) && !is(T == U[], U);

    // 1. Null
    static if (isNullable)
    {
        if (value is null)
            return writeStylized(w, "null", opt.useColors ? Style.yellow : Style.none);
    }

    // 2. Enums
    static if (is(T == enum))
    {
        writeTypeName!T(w, opt);
        put(w, ".");
        writeStyledValue(w, value, prettyLeafHook, opt.useColors);
    }
    // 3. Leaf types (bool, char, string, numeric)
    else static if (is(T == bool) || isSomeChar!T || isSomeString!T || isNumeric!T)
    {
        writeStyledValue(w, value, prettyLeafHook, opt.useColors);
    }
    // 4. Pointers
    else static if (isPointer!T)
    {
        writeStylized(w, "&", opt.useColors ? Style.magenta : Style.none);
        prettyPrintImpl(*value, w, opt, cast(ushort)(depth + 1));
    }
    // 5. std.typecons.Tuple
    else static if (is(T : Tuple!Args, Args...))
    {
        prettyPrintTuple(value, w, opt, depth);
    }
    // 6. Associative arrays
    else static if (isAssociativeArray!T)
    {
        prettyPrintAA(value, w, opt, depth);
    }
    // 7. Static arrays - slice them
    else static if (isStaticArray!T)
    {
        prettyPrintRange(value[], w, opt, depth);
    }
    // 8. Dynamic arrays / slices and forward ranges with length
    else static if (isDynamicArray!T || (isForwardRange!T && hasLength!T))
    {
        prettyPrintRange(value, w, opt, depth);
    }
    // 9. Structs and classes
    else static if (is(T == struct) || is(T == class))
    {
        prettyPrintAggregate(value, w, opt, depth);
    }
    else static if (!isNullable)
    {
        static assert(false, "prettyPrint: unsupported type " ~ T.stringof);
    }
}

private void prettyPrintTuple(Writer, Hook, Args...)(
    in Tuple!Args value,
    ref Writer w,
    in PrettyPrintOptions!Hook opt,
    ushort depth
)
{
    import std.range.primitives : put;

    put(w, "(");

    foreach (i, field; value.expand)
    {
        if (i > 0)
            put(w, ", ");

        // Print field name if available
        static if (value.fieldNames[i].length > 0)
        {
            writeStylized(w, value.fieldNames[i], opt.useColors ? Style.brightCyan : Style.none);
            put(w, ": ");
        }

        prettyPrintImpl(field, w, opt, cast(ushort)(depth + 1));
    }

    put(w, ")");
}

private void prettyPrintAA(T, Writer, Hook)(
    auto ref const T aa,
    ref Writer w,
    in PrettyPrintOptions!Hook opt,
    ushort depth
)
{
    import std.range : repeat;
    import std.range.primitives : put;
    import std.traits : KeyType, ValueType;

    import sparkles.core_cli.text_writers : writeInteger;

    if (aa.length == 0)
    {
        writeTypeName!(KeyType!T)(w, opt);
        put(w, "[");
        writeTypeName!(ValueType!T)(w, opt);
        put(w, "][]");
        return;
    }

    // Try single-line format first
    if (opt.softMaxWidth > 0 && aa.length <= opt.maxItems)
    {
        auto singleLineOpt = PrettyPrintOptions!void(
            indentStep: opt.indentStep,
            maxDepth: opt.maxDepth,
            maxItems: opt.maxItems,
            softMaxWidth: 0,
            useColors: false
        );
        string singleLine = prettyPrintAAInline!T(aa, singleLineOpt, depth);
        if (singleLine.length <= opt.softMaxWidth)
        {
            put(w, "[");
            bool first = true;
            foreach (key, val; aa)
            {
                if (!first)
                    put(w, ", ");
                first = false;
                prettyPrintImpl(key, w, opt, cast(ushort)(depth + 1));
                put(w, ": ");
                prettyPrintImpl(val, w, opt, cast(ushort)(depth + 1));
            }
            put(w, "]");
            return;
        }
    }

    put(w, "[");

    auto indent = ' '.repeat(opt.indentStep * (depth + 1));
    auto closingIndent = ' '.repeat(opt.indentStep * depth);

    uint count = 0;
    foreach (key, val; aa)
    {
        if (count > 0)
            put(w, ",");

        if (count >= opt.maxItems)
        {
            put(w, "\n");
            put(w, indent);
            if (opt.useColors)
                writeEscapeSeq(w, Style.gray[0]);
            put(w, "... ");
            writeInteger(w, aa.length - count);
            put(w, " more");
            if (opt.useColors)
                writeEscapeSeq(w, Style.gray[1]);
            break;
        }

        put(w, "\n");
        put(w, indent);
        prettyPrintImpl(key, w, opt, cast(ushort)(depth + 1));
        put(w, ": ");
        prettyPrintImpl(val, w, opt, cast(ushort)(depth + 1));
        count++;
    }

    put(w, "\n");
    put(w, closingIndent);
    put(w, "]");
}

private string prettyPrintAAInline(T)(in T aa, in PrettyPrintOptions!void opt, ushort depth)
{
    import std.array : appender;
    auto w = appender!string;
    w.put("[");
    bool first = true;
    foreach (key, val; aa)
    {
        if (!first)
            w.put(", ");
        first = false;
        prettyPrintImpl(key, w, opt, cast(ushort)(depth + 1));
        w.put(": ");
        prettyPrintImpl(val, w, opt, cast(ushort)(depth + 1));
    }
    w.put("]");
    return w.data;
}

private string prettyPrintRangeInline(R)(R range, in PrettyPrintOptions!void opt, ushort depth)
{
    import std.array : appender;
    auto w = appender!string;
    w.put("[");
    bool first = true;
    foreach (elem; range)
    {
        if (!first)
            w.put(", ");
        first = false;
        prettyPrintImpl(elem, w, opt, cast(ushort)(depth + 1));
    }
    w.put("]");
    return w.data;
}

private string prettyPrintAggregateInline(T)(auto ref const T value, in PrettyPrintOptions!void opt, ushort depth)
{
    import std.array : appender;
    import std.traits : FieldNameTuple;

    auto w = appender!string;
    w.put(T.stringof);
    w.put("(");

    alias fieldNames = FieldNameTuple!T;
    bool first = true;
    static foreach (i, fieldName; fieldNames)
    {{
        static if (fieldName.length > 0)
        {
            if (!first)
                w.put(", ");
            first = false;
            w.put(fieldName);
            w.put(": ");
            prettyPrintImpl(value.tupleof[i], w, opt, cast(ushort)(depth + 1));
        }
    }}
    w.put(")");
    return w.data;
}

private void prettyPrintRange(R, Writer, Hook)(
    R range,
    ref Writer w,
    in PrettyPrintOptions!Hook opt,
    ushort depth
)
{
    import std.range : repeat;
    import std.range.primitives : put, empty, front, popFront, hasLength;

    import sparkles.core_cli.text_writers : writeInteger;

    static if (hasLength!R)
    {
        const len = range.length;
    }

    // Check if empty
    if (range.empty)
    {
        put(w, "[]");
        return;
    }

    // Try single-line format first
    static if (hasLength!R)
    {
        if (opt.softMaxWidth > 0 && len <= opt.maxItems)
        {
            auto singleLineOpt = PrettyPrintOptions!void(
                indentStep: opt.indentStep,
                maxDepth: opt.maxDepth,
                maxItems: opt.maxItems,
                softMaxWidth: 0,
                useColors: false
            );
            string singleLine = prettyPrintRangeInline(range, singleLineOpt, depth);
            if (singleLine.length <= opt.softMaxWidth)
            {
                put(w, "[");
                bool first = true;
                foreach (elem; range)
                {
                    if (!first)
                        put(w, ", ");
                    first = false;
                    prettyPrintImpl(elem, w, opt, cast(ushort)(depth + 1));
                }
                put(w, "]");
                return;
            }
        }
    }

    put(w, "[");

    auto indent = ' '.repeat(opt.indentStep * (depth + 1));
    auto closingIndent = ' '.repeat(opt.indentStep * depth);

    uint count = 0;
    foreach (elem; range)
    {
        if (count > 0)
            put(w, ",");

        if (count >= opt.maxItems)
        {
            put(w, "\n");
            put(w, indent);
            static if (hasLength!R)
            {
                if (opt.useColors)
                    writeEscapeSeq(w, Style.gray[0]);
                put(w, "... ");
                writeInteger(w, len - count);
                put(w, " more");
                if (opt.useColors)
                    writeEscapeSeq(w, Style.gray[1]);
            }
            else
            {
                writeStylized(w, "... more", opt.useColors ? Style.gray : Style.none);
            }
            break;
        }

        put(w, "\n");
        put(w, indent);
        prettyPrintImpl(elem, w, opt, cast(ushort)(depth + 1));
        count++;
    }

    put(w, "\n");
    put(w, closingIndent);
    put(w, "]");
}

private void prettyPrintAggregate(T, Writer, Hook)(
    auto ref const T value,
    ref Writer w,
    in PrettyPrintOptions!Hook opt,
    ushort depth
)
{
    import std.range : repeat;
    import std.range.primitives : put;
    import std.traits : FieldNameTuple, isNested;

    alias fieldNames = FieldNameTuple!T;

    static if (fieldNames.length == 0)
    {
        writeTypeName!T(w, opt);
        put(w, "()");
        return;
    }

    // Try single-line format first
    if (opt.softMaxWidth > 0)
    {
        auto singleLineOpt = PrettyPrintOptions!void(
            indentStep: opt.indentStep,
            maxDepth: opt.maxDepth,
            maxItems: opt.maxItems,
            softMaxWidth: 0,
            useColors: false
        );
        string singleLine = prettyPrintAggregateInline(value, singleLineOpt, depth);
        if (singleLine.length <= opt.softMaxWidth)
        {
            writeTypeName!T(w, opt);
            put(w, "(");
            bool first = true;
            static foreach (i, fieldName; fieldNames)
            {{
                static if (fieldName.length > 0)
                {
                    if (!first)
                        put(w, ", ");
                    first = false;
                    writeStylized(w, fieldName, opt.useColors ? Style.brightCyan : Style.none);
                    put(w, ": ");
                    prettyPrintImpl(value.tupleof[i], w, opt, cast(ushort)(depth + 1));
                }
            }}
            put(w, ")");
            return;
        }
    }

    writeTypeName!T(w, opt);
    put(w, "(");

    auto indent = ' '.repeat(opt.indentStep * (depth + 1));
    auto closingIndent = ' '.repeat(opt.indentStep * depth);

    static foreach (i, fieldName; fieldNames)
    {{
        // Skip context pointer for nested types
        static if (fieldName.length > 0)
        {
            if (i > 0)
                put(w, ",");

            put(w, "\n");
            put(w, indent);
            writeStylized(w, fieldName, opt.useColors ? Style.brightCyan : Style.none);
            put(w, ": ");

            prettyPrintImpl(value.tupleof[i], w, opt, cast(ushort)(depth + 1));
        }
    }}

    put(w, "\n");
    put(w, closingIndent);
    put(w, ")");
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper functions
// ─────────────────────────────────────────────────────────────────────────────

/// DbI hook for `writeStyledValue` that encodes prettyPrint's leaf rendering
/// rules: escaped strings/chars with quotes, enum member names, and
/// per-type/per-value ANSI color selection.
private struct PrettyLeafHook
{
    enum escapeStrings = true;
    enum escapeChars = true;
    enum enumRender = EnumRender.memberName;

    Style styleOf(T)(in T val) const @safe pure nothrow @nogc
    {
        import std.traits : isSomeChar, isSomeString, isNumeric, isFloatingPoint;

        static if (is(T == typeof(null)))
            return Style.yellow;
        else static if (is(T == bool))
            return Style.yellow;
        else static if (is(T == enum))
            return Style.green;
        else static if (isSomeChar!T || isSomeString!T)
            return Style.green;
        else static if (isNumeric!T)
        {
            static if (isFloatingPoint!T)
            {
                import std.math.traits : isNaN, isInfinity;
                if (isNaN(val) || isInfinity(val))
                    return Style.red;
            }
            return Style.blue;
        }
        else
            return Style.none;
    }
}

/// Module-level instance avoids repeated construction.
private immutable PrettyLeafHook prettyLeafHook;

private void writeTypeName(T, Writer, Hook)(ref Writer w, in PrettyPrintOptions!Hook opt)
{
    import std.range.primitives : put;
    import sparkles.core_cli.source_uri : resolveSourcePath, hasWriteSourceUri, FileUriHook;

    enum hasLoc = __traits(compiles, __traits(getLocation, T));

    static if (hasLoc)
    {
        if (opt.useOscLinks)
        {
            enum _loc = __traits(getLocation, T);
            enum absPath = resolveSourcePath(_loc[0]);

            put(w, "\x1b]8;;");

            // DbI dispatch: hook → fallback (§6.1)
            // Source location as template args → CTFE URI → @nogc put
            static if (!is(Hook == void) && hasWriteSourceUri!(Hook, Writer))
                Hook.writeSourceUri!(absPath, _loc[1], _loc[2])(w);
            else
                FileUriHook.writeSourceUri!(absPath, _loc[1], _loc[2])(w);

            put(w, "\x07");
        }
    }

    writeStylized(w, T.stringof, opt.useColors ? Style.magenta : Style.none);

    static if (hasLoc)
    {
        if (opt.useOscLinks)
            put(w, "\x1b]8;;\x07");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.exception : AssertError;
    import std.string : outdent;
    import std.typecons : tuple;

    /// @nogc-compatible check helper using SmallBuffer
    void check(T, Hook = void)(in T value, const(char)[] expected,
            in PrettyPrintOptions!Hook opts = PrettyPrintOptions!Hook(useColors: false),
            string file = __FILE__, size_t line = __LINE__) @trusted
    {
        import sparkles.core_cli.lifetime : recycledErrorInstance;
        import sparkles.core_cli.smallbuffer : SmallBuffer;

        SmallBuffer!(char, 16 * 1024) buf;
        prettyPrint(value, buf, opts);
        const(char)[] actual = buf[];

        if (actual != expected)
        {
            // Build error message in a separate buffer
            SmallBuffer!(char, 4 * 1024) errBuf;
            errBuf.put("prettyPrint mismatch:\nExpected:\n");
            errBuf.put(expected);
            errBuf.put("\nActual:\n");
            errBuf.put(actual);

            throw recycledErrorInstance!AssertError(
                cast(string) errBuf[],
                file, line);
        }
    }
}

@("prettyPrint.null")
@safe pure nothrow @nogc
unittest
{
    check(null, "null");
}

@("prettyPrint.bool")
@safe pure nothrow @nogc
unittest
{
    check(true, "true");
    check(false, "false");
}

@("prettyPrint.integers")
@safe pure nothrow @nogc
unittest
{
    check(42, "42");
    check(-123, "-123");
    check(0uL, "0");
}

@("prettyPrint.floats")
@safe pure nothrow @nogc
unittest
{
    check(3.14, "3.14");
    check(double.nan, "nan");
    check(-double.nan, "-nan");
    check(double.infinity, "inf");
    check(-double.infinity, "-inf");
}

@("prettyPrint.char")
@safe pure nothrow @nogc
unittest
{
    check('a', "'a'");
    check('\n', `'\n'`);
    check('\t', `'\t'`);
}

@("prettyPrint.string")
@safe pure nothrow @nogc
unittest
{
    check("hello", `"hello"`);
    check("line1\nline2", `"line1\nline2"`);
    check("tab\there", `"tab\there"`);
}

@("prettyPrint.enum")
@safe pure nothrow @nogc
unittest
{
    enum Color { red, green, blue }
    check(Color.green, "Color.green");
}

@("prettyPrint.array")
unittest
{
    const opts = PrettyPrintOptions!void(softMaxWidth: 0, useColors: false);
    int[] arr = [1, 2, 3];
    check(arr, outdent(`
        [
          1,
          2,
          3
        ]`)[1..$], opts);

    int[] empty;
    check(empty, "[]", opts);
}

@("prettyPrint.staticArray")
unittest
{
    const opts = PrettyPrintOptions!void(softMaxWidth: 0, useColors: false);
    int[3] arr = [10, 20, 30];
    check(arr, outdent(`
        [
          10,
          20,
          30
        ]`)[1..$], opts);
}

@("prettyPrint.aa")
unittest
{
    int[string] empty;
    check(empty, "null");
}

@("prettyPrint.struct")
unittest
{
    struct Point { int x; int y; }
    const opts = PrettyPrintOptions!void(softMaxWidth: 0, useColors: false);
    auto p = Point(10, 20);
    check(p, outdent(`
        Point(
          x: 10,
          y: 20
        )`)[1..$], opts);
}

@("prettyPrint.nestedStruct")
unittest
{
    struct Inner { int value; }
    struct Outer { string name; Inner inner; }

    const opts = PrettyPrintOptions!void(softMaxWidth: 0, useColors: false);
    auto o = Outer("test", Inner(42));
    check(o, outdent(`
        Outer(
          name: "test",
          inner: Inner(
            value: 42
          )
        )`)[1..$], opts);
}

@("prettyPrint.tuple")
unittest
{
    auto t1 = tuple(1, "hello", 3.14);
    check(t1, `(1, "hello", 3.14)`);

    auto t2 = Tuple!(int, "x", string, "name")(42, "test");
    check(t2, `(x: 42, name: "test")`);
}

@("prettyPrint.pointer")
unittest
{
    int* nullPtr = null;
    check(nullPtr, "null");

    int val = 42;
    int* ptr = &val;
    check(ptr, "&42");
}

@("prettyPrint.maxItems")
unittest
{
    const opts = PrettyPrintOptions!void(maxItems: 3, useColors: false);
    int[] arr = [1, 2, 3, 4, 5];
    check(arr, outdent(`
        [
          1,
          2,
          3,
          ... 2 more
        ]`)[1..$], opts);
}

@("prettyPrint.maxDepth")
unittest
{
    struct Deep { int value; Deep* next; }

    // Define 5 levels of nesting once
    Deep d5 = Deep(5, null);
    Deep d4 = Deep(4, &d5);
    Deep d3 = Deep(3, &d4);
    Deep d2 = Deep(2, &d3);
    Deep d1 = Deep(1, &d2);

    // maxDepth: 1 - only the top-level struct fields are shown
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &...
        )`)[1..$], PrettyPrintOptions!void(maxDepth: 1, softMaxWidth: 0, useColors: false));

    // maxDepth: 2 - one level of pointer dereference, but inner struct fields hit limit
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: ...,
              next: ...
            )
        )`)[1..$], PrettyPrintOptions!void(maxDepth: 2, softMaxWidth: 0, useColors: false));

    // maxDepth: 3 - inner struct fields visible, but next pointer hits limit
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: 2,
              next: &...
            )
        )`)[1..$], PrettyPrintOptions!void(maxDepth: 3, softMaxWidth: 0, useColors: false));

    // maxDepth: 4 - two levels of nesting visible
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: 2,
              next: &Deep(
                  value: ...,
                  next: ...
                )
            )
        )`)[1..$], PrettyPrintOptions!void(maxDepth: 4, softMaxWidth: 0, useColors: false));

    // maxDepth: 5 - three levels of nesting visible
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: 2,
              next: &Deep(
                  value: 3,
                  next: &...
                )
            )
        )`)[1..$], PrettyPrintOptions!void(maxDepth: 5, softMaxWidth: 0, useColors: false));

    // maxDepth: ushort.max - no practical limit, full output
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: 2,
              next: &Deep(
                  value: 3,
                  next: &Deep(
                      value: 4,
                      next: &Deep(
                          value: 5,
                          next: null
                        )
                    )
                )
            )
        )`)[1..$], PrettyPrintOptions!void(maxDepth: ushort.max, softMaxWidth: 0, useColors: false));
}

@("prettyPrint.withColors")
unittest
{
    // Integer 42 with blue color code prefix and reset to default foreground
    check(42, "\x1b[34m42\x1b[39m", PrettyPrintOptions!void(useColors: true));
}

@("prettyPrint.class")
unittest
{
    class MyClass { int x; string name; }

    const opts = PrettyPrintOptions!void(softMaxWidth: 0, useColors: false);

    MyClass nullObj = null;
    check(nullObj, "null", opts);

    auto obj = new MyClass();
    obj.x = 10;
    obj.name = "test";
    check(obj, outdent(`
        MyClass(
          x: 10,
          name: "test"
        )`)[1..$], opts);
}

@("prettyPrint.oscLink.struct")
@safe pure nothrow
unittest
{
    import sparkles.core_cli.source_uri : resolveSourcePath, FileUriHook;

    struct Coord { int x; int y; }
    enum _loc = __traits(getLocation, Coord);
    enum uri = {
        import std.conv : text;
        enum absPath = resolveSourcePath(_loc[0]);
        return i"file://$(absPath)#L$(_loc[1])".text;
    }();
    check(Coord(1, 2), "\x1b]8;;" ~ uri ~ "\x07" ~ "Coord" ~ "\x1b]8;;\x07" ~ "(x: 1, y: 2)",
        PrettyPrintOptions!void(useColors: false, useOscLinks: true));
}

@("prettyPrint.oscLink.enum")
@safe pure nothrow
unittest
{
    import sparkles.core_cli.source_uri : resolveSourcePath;

    enum Dir { north, south }
    enum _loc = __traits(getLocation, Dir);
    enum uri = {
        import std.conv : text;
        enum absPath = resolveSourcePath(_loc[0]);
        return i"file://$(absPath)#L$(_loc[1])".text;
    }();
    check(Dir.south, "\x1b]8;;" ~ uri ~ "\x07" ~ "Dir" ~ "\x1b]8;;\x07" ~ ".south",
        PrettyPrintOptions!void(useColors: false, useOscLinks: true));
}

@("prettyPrint.oscLink.disabled")
@safe pure nothrow
unittest
{
    struct Pair { int a; int b; }
    check(Pair(3, 4), "Pair(a: 3, b: 4)",
        PrettyPrintOptions!void(useColors: false, useOscLinks: false));
}

@("prettyPrint.oscLink.withColors")
@safe pure nothrow
unittest
{
    import sparkles.core_cli.source_uri : resolveSourcePath;

    struct Cell { int v; }
    enum _loc = __traits(getLocation, Cell);
    enum uri = {
        import std.conv : text;
        enum absPath = resolveSourcePath(_loc[0]);
        return i"file://$(absPath)#L$(_loc[1])".text;
    }();
    // Nesting order: OSC_OPEN → SGR_OPEN → text → SGR_CLOSE → OSC_CLOSE
    // Field names (brightCyan=96) and values (blue=34) also get color codes
    check(Cell(7),
        "\x1b]8;;" ~ uri ~ "\x07" ~ "\x1b[35mCell\x1b[39m" ~ "\x1b]8;;\x07"
        ~ "(\x1b[96mv\x1b[39m: \x1b[34m7\x1b[39m)",
        PrettyPrintOptions!void(useColors: true, useOscLinks: true));
}

@("prettyPrint.oscLink.schemeHook")
@safe pure nothrow
unittest
{
    import sparkles.core_cli.source_uri : resolveSourcePath, SchemeHook;

    struct Dot { int r; }
    enum _loc = __traits(getLocation, Dot);
    enum uri = {
        import std.conv : text;
        enum absPath = resolveSourcePath(_loc[0]);
        return i"vscode://file$(absPath):$(_loc[1]):$(_loc[2])".text;
    }();
    check(Dot(5), "\x1b]8;;" ~ uri ~ "\x07" ~ "Dot" ~ "\x1b]8;;\x07" ~ "(r: 5)",
        PrettyPrintOptions!(SchemeHook!"code")(useColors: false, useOscLinks: true));
}
