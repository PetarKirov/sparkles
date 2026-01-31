module sparkles.core_cli.prettyprint;

import std.typecons : Tuple;

import sparkles.core_cli.term_style : escapeSeq, Style, stylize;

struct PrettyPrintOptions
{
    ushort indentStep   = 2;   // spaces per indent level
    ushort maxDepth     = 8;   // recursion limit
    uint   maxItems     = 32;  // for arrays/ranges/AAs
    uint   softMaxWidth = 80;  // try single-line if output fits (0 = always multi-line)
    bool   useColors    = true;
}

/// Pretty-prints a value to a writer.
/// Returns the writer for chaining.
ref Writer prettyPrint(T, Writer)(
    in T value,
    return ref Writer writer,
    PrettyPrintOptions opt = PrettyPrintOptions()
)
{
    prettyPrintImpl(value, writer, opt, 0);
    return writer;
}

/// Convenience overload that returns a string.
string prettyPrint(T)(in T value, PrettyPrintOptions opt = PrettyPrintOptions())
{
    import std.array : appender;
    auto w = appender!string;
    prettyPrint(value, w, opt);
    return w[];
}

private void prettyPrintImpl(T, Writer)(
    in T value,
    ref Writer w,
    in PrettyPrintOptions opt,
    ushort depth
)
{
    import std.range.primitives : isForwardRange, hasLength, put;
    import std.traits : isSomeChar, isSomeString, isNumeric, isFloatingPoint,
        isPointer, isAssociativeArray, isStaticArray, isDynamicArray;

    // Check depth limit
    if (depth > opt.maxDepth)
        return coloredWrite(w, "...", Style.red, opt.useColors);

    enum isNullable = __traits(compiles, T.init is null) && !is(T == U[], U);

    // 1. Null
    static if (isNullable)
    {
        if (value is null)
            return coloredWrite(w, "null", Style.yellow, opt.useColors);
    }

    // 2. Enums
    static if (is(T == enum))
    {
        coloredWrite(w, T.stringof, Style.magenta, opt.useColors);
        put(w, ".");
        coloredWrite(w, value, Style.green, opt.useColors);
    }
    // 3. Boolean
    else static if (is(T == bool))
    {
        coloredWrite(w, value ? "true" : "false", Style.yellow, opt.useColors);
    }
    // 4. Strings and individual chars
    else static if (isSomeChar!T || isSomeString!T)
    {
        coloredWrite!"%(%s%)"(w, [value], Style.green, opt.useColors);
    }
    // 5. Numeric types
    else static if (isNumeric!T)
    {
        static if (isFloatingPoint!T)
        {
            import std.math : isNaN, isInfinity;
            if (isNaN(value))
                return coloredWrite(w, "NaN", Style.red, opt.useColors);
            else if (isInfinity(value))
                return coloredWrite(w, value > 0 ? "+∞" : "-∞", Style.red, opt.useColors);
        }

        coloredWrite(w, value, Style.blue, opt.useColors);
    }
    // 6. Pointers
    else static if (isPointer!T)
    {
        coloredWrite(w, "&", Style.magenta, opt.useColors);
        prettyPrintImpl(*value, w, opt, cast(ushort)(depth + 1));
    }
    // 7. std.typecons.Tuple
    else static if (is(T : Tuple!Args, Args...))
    {
        prettyPrintTuple(value, w, opt, depth);
    }
    // 8. Associative arrays
    else static if (isAssociativeArray!T)
    {
        prettyPrintAA(value, w, opt, depth);
    }
    // 9. Static arrays - slice them
    else static if (isStaticArray!T)
    {
        prettyPrintRange(value[], w, opt, depth);
    }
    // 10. Dynamic arrays / slices and forward ranges with length
    else static if (isDynamicArray!T || (isForwardRange!T && hasLength!T))
    {
        prettyPrintRange(value, w, opt, depth);
    }
    // 11. Structs and classes
    else static if (is(T == struct) || is(T == class))
    {
        prettyPrintAggregate(value, w, opt, depth);
    }
    else static if (!isNullable)
    {
        static assert(false, "prettyPrint: unsupported type " ~ T.stringof);
    }
}

private void prettyPrintTuple(Writer, Args...)(
    in Tuple!Args value,
    ref Writer w,
    in PrettyPrintOptions opt,
    ushort depth
)
{
    import std.range.primitives : put;
    import std.format : formattedWrite;

    put(w, "(");

    foreach (i, field; value.expand)
    {
        if (i > 0)
            put(w, ", ");

        // Print field name if available
        static if (value.fieldNames[i].length > 0)
        {
            coloredWrite(w, value.fieldNames[i], Style.brightCyan, opt.useColors);
            put(w, ": ");
        }

        prettyPrintImpl(field, w, opt, cast(ushort)(depth + 1));
    }

    put(w, ")");
}

private void prettyPrintAA(T, Writer)(
    auto ref const T aa,
    ref Writer w,
    in PrettyPrintOptions opt,
    ushort depth
)
{
    import std.range : repeat;
    import std.range.primitives : put;
    import std.format : formattedWrite;
    import std.traits : KeyType, ValueType;

    if (aa.length == 0)
    {
        coloredWrite(w, KeyType!T.stringof, Style.magenta, opt.useColors);
        put(w, "[");
        coloredWrite(w, ValueType!T.stringof, Style.magenta, opt.useColors);
        put(w, "][]");
        return;
    }

    // Try single-line format first
    if (opt.softMaxWidth > 0 && aa.length <= opt.maxItems)
    {
        auto singleLineOpt = PrettyPrintOptions(
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
                put(w, Style.gray[0].escapeSeq);
            w.formattedWrite("... %d more", aa.length - count);
            if (opt.useColors)
                put(w, Style.gray[1].escapeSeq);
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

private string prettyPrintAAInline(T)(in T aa, in PrettyPrintOptions opt, ushort depth)
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

private string prettyPrintRangeInline(R)(R range, in PrettyPrintOptions opt, ushort depth)
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

private string prettyPrintAggregateInline(T)(auto ref const T value, in PrettyPrintOptions opt, ushort depth)
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

private void prettyPrintRange(R, Writer)(
    R range,
    ref Writer w,
    in PrettyPrintOptions opt,
    ushort depth
)
{
    import std.range : repeat;
    import std.range.primitives : put, empty, front, popFront, hasLength;
    import std.format : formattedWrite;

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
            auto singleLineOpt = PrettyPrintOptions(
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
                    put(w, Style.gray[0].escapeSeq);
                w.formattedWrite("... %d more", len - count);
                if (opt.useColors)
                    put(w, Style.gray[1].escapeSeq);
            }
            else
            {
                coloredWrite(w, "... more", Style.gray, opt.useColors);
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

private void prettyPrintAggregate(T, Writer)(
    auto ref const T value,
    ref Writer w,
    in PrettyPrintOptions opt,
    ushort depth
)
{
    import std.range : repeat;
    import std.range.primitives : put;
    import std.traits : FieldNameTuple, isNested;

    alias fieldNames = FieldNameTuple!T;

    static if (fieldNames.length == 0)
    {
        coloredWrite(w, T.stringof, Style.magenta, opt.useColors);
        put(w, "()");
        return;
    }

    // Try single-line format first
    if (opt.softMaxWidth > 0)
    {
        auto singleLineOpt = PrettyPrintOptions(
            indentStep: opt.indentStep,
            maxDepth: opt.maxDepth,
            maxItems: opt.maxItems,
            softMaxWidth: 0,
            useColors: false
        );
        string singleLine = prettyPrintAggregateInline(value, singleLineOpt, depth);
        if (singleLine.length <= opt.softMaxWidth)
        {
            coloredWrite(w, T.stringof, Style.magenta, opt.useColors);
            put(w, "(");
            bool first = true;
            static foreach (i, fieldName; fieldNames)
            {{
                static if (fieldName.length > 0)
                {
                    if (!first)
                        put(w, ", ");
                    first = false;
                    coloredWrite(w, fieldName, Style.brightCyan, opt.useColors);
                    put(w, ": ");
                    prettyPrintImpl(value.tupleof[i], w, opt, cast(ushort)(depth + 1));
                }
            }}
            put(w, ")");
            return;
        }
    }

    coloredWrite(w, T.stringof, Style.magenta, opt.useColors);
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
            coloredWrite(w, fieldName, Style.brightCyan, opt.useColors);
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

private void coloredWrite(string fmt = "%s", Writer, T)(ref Writer w, in T value, Style style, bool useColors)
{
    import std.range.primitives : put;
    import std.traits : isSomeString;

    string text;
    static if (fmt == "%s" && isSomeString!T)
        text = value;
    else
    {
        import std.format : format;
        text = format!fmt(value);
    }

    put(w, useColors ? text.stylize(style) : text);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.exception : AssertError;
    import std.string : outdent;
    import std.typecons : tuple;

    void check(T)(in T value, string expected, PrettyPrintOptions opts = PrettyPrintOptions(useColors: false),
            string file = __FILE__, size_t line = __LINE__)
    {
        import std.exception : assumeUnique;
        import sparkles.core_cli.lifetime : recycledInstance;

        static char[16 * 1024] buf;
        static size_t len;
        len = 0;

        static struct BufWriter
        {
            char[] buf;
            size_t* plen;

            void put(const(char)[] s) @nogc nothrow @trusted
            {
                buf[*plen .. *plen + s.length] = s;
                *plen += s.length;
            }

            void put(char c) @nogc nothrow @trusted
            {
                buf[*plen] = c;
                (*plen)++;
            }
        }

        auto writer = BufWriter(buf[], &len);
        prettyPrint(value, writer, opts);
        const(char)[] actual = buf[0 .. len];

        if (actual != expected)
        {
            enum header = "prettyPrint mismatch:\nExpected:\n";
            enum middle = "\nActual:\n";

            writer.put(header);
            writer.put(expected);
            writer.put(middle);
            writer.put(actual);

            throw recycledInstance!AssertError(
                buf[len .. *writer.plen].assumeUnique,
                file, line);
        }
    }
}

@("prettyPrint.null")
unittest
{
    check(null, "null");
}

@("prettyPrint.bool")
unittest
{
    check(true, "true");
    check(false, "false");
}

@("prettyPrint.integers")
unittest
{
    check(42, "42");
    check(-123, "-123");
    check(0uL, "0");
}

@("prettyPrint.floats")
unittest
{
    check(3.14, "3.14");
    check(double.nan, "NaN");
    check(double.infinity, "+∞");
    check(-double.infinity, "-∞");
}

@("prettyPrint.char")
unittest
{
    check('a', "'a'");
    check('\n', `'\n'`);
    check('\t', `'\t'`);
}

@("prettyPrint.string")
unittest
{
    check("hello", `"hello"`);
    check("line1\nline2", `"line1\nline2"`);
    check("tab\there", `"tab\there"`);
}

@("prettyPrint.enum")
unittest
{
    enum Color { red, green, blue }
    check(Color.green, "Color.green");
}

@("prettyPrint.array")
unittest
{
    const opts = PrettyPrintOptions(softMaxWidth: 0, useColors: false);
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
    const opts = PrettyPrintOptions(softMaxWidth: 0, useColors: false);
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
    const opts = PrettyPrintOptions(softMaxWidth: 0, useColors: false);
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

    const opts = PrettyPrintOptions(softMaxWidth: 0, useColors: false);
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
    const opts = PrettyPrintOptions(maxItems: 3, useColors: false);
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
        )`)[1..$], PrettyPrintOptions(maxDepth: 1, softMaxWidth: 0, useColors: false));

    // maxDepth: 2 - one level of pointer dereference, but inner struct fields hit limit
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: ...,
              next: ...
            )
        )`)[1..$], PrettyPrintOptions(maxDepth: 2, softMaxWidth: 0, useColors: false));

    // maxDepth: 3 - inner struct fields visible, but next pointer hits limit
    check(d1, outdent(`
        Deep(
          value: 1,
          next: &Deep(
              value: 2,
              next: &...
            )
        )`)[1..$], PrettyPrintOptions(maxDepth: 3, softMaxWidth: 0, useColors: false));

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
        )`)[1..$], PrettyPrintOptions(maxDepth: 4, softMaxWidth: 0, useColors: false));

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
        )`)[1..$], PrettyPrintOptions(maxDepth: 5, softMaxWidth: 0, useColors: false));

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
        )`)[1..$], PrettyPrintOptions(maxDepth: ushort.max, softMaxWidth: 0, useColors: false));
}

@("prettyPrint.withColors")
unittest
{
    // Integer 42 with blue color code prefix and reset to default foreground
    check(42, "\x1b[34m42\x1b[39m", PrettyPrintOptions(useColors: true));
}

@("prettyPrint.class")
unittest
{
    class MyClass { int x; string name; }

    const opts = PrettyPrintOptions(softMaxWidth: 0, useColors: false);

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
