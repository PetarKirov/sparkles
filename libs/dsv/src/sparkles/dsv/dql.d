/**
DQL (Data Query Language) resolver for DSV records (`DSF1`–`DSF3`).

Spec: `docs/specs/dql/SPEC.md`, `docs/specs/hue/dsv-preview.md`.
*/
module sparkles.dsv.dql;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.text.float_conv : readDecimalFloat;
import sparkles.dsv.model : ColumnType, decodeCell, DsvDoc, DsvRecord;

@safe:

private bool asciiEqNoCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca += 32;
        if (cb >= 'A' && cb <= 'Z') cb += 32;
        if (ca != cb)
            return false;
    }
    return true;
}

/**
Resolves fields from a `DsvRecord` for DQL evaluation.
Columns can be addressed by case-insensitive name or by 1-based index (e.g. `#1`, `#2`).

A resolved string borrows this resolver's decode buffer: consume it before
the next resolve call on the same resolver, and never let it outlive the
resolver. (The dynamic evaluation protocol hands values to the evaluator
synchronously, so ordinary filters satisfy this without thinking about it.)
*/
struct DsvRecordResolver
{
    const(DsvDoc)* doc;
    const(DsvRecord)* record;
    const(const(char)[])[] headerNames;
    const(ColumnType)[] types;

    /// Decoded cell bytes live here between resolve calls; resolved strings
    /// borrow it (see the struct comment).
    private SharedBuffer!(char, 256) decodeBuf;

    /// Fast category check (e.g. `record`, `row`)
    bool resolveCategory(scope const(char)[] name) const scope @safe pure nothrow @nogc
    {
        return name == "record" || name == "row";
    }

    /// ditto
    alias hasCategory = resolveCategory;
    alias resolveValue = resolveField;
    alias resolveString = resolveField;
    alias resolveInt = resolveField;
    alias resolveNumber = resolveField;
    alias resolveBool = resolveField;

    private ptrdiff_t findColumn(scope const(char)[] path) const scope @safe pure nothrow @nogc
    {
        if (path.length >= 2 && path[0] == '#')
        {
            uint n = 0;
            foreach (char c; path[1 .. $])
            {
                if (c < '0' || c > '9') return -1;
                n = n * 10 + (c - '0');
            }
            if (n == 0) return -1;
            return cast(ptrdiff_t)(n - 1);
        }

        foreach (i, h; headerNames)
        {
            if (asciiEqNoCase(path, h))
                return cast(ptrdiff_t) i;
        }
        return -1;
    }

    private const(char)[] getCellText(size_t col) return scope @safe pure nothrow @nogc
    {
        if (doc is null || record is null || col >= record.cellCount)
            return null;
        return decodeCell(*doc, doc.cells[record.cellsStart + col], decodeBuf);
    }

    /// String field resolver. The returned slice borrows this resolver's
    /// decode buffer - see the struct comment; this is why the method (and
    /// the whole resolver protocol) must not be `const`.
    bool resolveField(scope const(char)[] path, out const(char)[] value) scope @safe pure nothrow @nogc
    {
        const col = findColumn(path);
        if (col < 0) return false;
        // dip1000 cannot see that the decode buffer is a member of `this`,
        // which the caller owns for the whole evaluation: the borrow is
        // sound for as long as the resolver itself (struct comment).
        () @trusted { value = getCellText(col); }();
        if (value is null)
            value = "";
        return true;
    }

    /// Integer field resolver
    bool resolveField(scope const(char)[] path, out long value) scope @safe pure nothrow @nogc
    {
        const col = findColumn(path);
        if (col < 0) return false;
        const text = getCellText(col);
        if (text.length == 0) return false;
        bool neg = false;
        size_t idx = 0;
        if (text[0] == '-')
        {
            neg = true;
            idx = 1;
        }
        else if (text[0] == '+')
        {
            idx = 1;
        }
        if (idx >= text.length) return false;
        long acc = 0;
        foreach (char c; text[idx .. $])
        {
            if (c < '0' || c > '9') return false;
            acc = acc * 10 + (c - '0');
        }
        value = neg ? -acc : acc;
        return true;
    }

    /// Floating point / number field resolver
    bool resolveField(scope const(char)[] path, out double value) scope @safe pure nothrow @nogc
    {
        const col = findColumn(path);
        if (col < 0) return false;
        const text = getCellText(col);
        scope const(char)[] t = text;
        const res = readDecimalFloat(t);
        if (res.hasError) return false;
        value = res.value;
        return true;
    }

    /// Boolean field resolver
    bool resolveField(scope const(char)[] path, out bool value) scope @safe pure nothrow @nogc
    {
        const col = findColumn(path);
        if (col < 0) return false;
        const text = getCellText(col);
        if (text == "true" || text == "TRUE" || text == "1") { value = true; return true; }
        if (text == "false" || text == "FALSE" || text == "0") { value = false; return true; }
        return false;
    }
}

@("dsv.dql: DsvRecordResolver field and expression evaluation")
@safe unittest
{
    import sparkles.dql;
    import sparkles.dsv.model : Dialect;
    import sparkles.dsv.parse : parseDsv;

    const src = "name,age,active,score\nAlice,30,true,95.5\nBob,25,false,82.0\n";
    auto parsed = parseDsv(src, Dialect(','));
    assert(!parsed.hasError);
    const doc = parsed.value;

    const(const(char)[])[] headers = ["name", "age", "active", "score"];
    const rec0 = doc.records[1]; // Alice
    const rec1 = doc.records[2]; // Bob

    DsvRecordResolver res0 = DsvRecordResolver(&doc, &rec0, headers, null);
    DsvRecordResolver res1 = DsvRecordResolver(&doc, &rec1, headers, null);

    DqlEngine engine;
    auto f1 = parseDql(engine, "age > 28 && active == true && score >= 90.0");
    assert(!f1.hasError);
    assert(evalDql(engine, f1.value, res0));
    assert(!evalDql(engine, f1.value, res1));

    // Column by #index
    auto f2 = parseDql(engine, "#1 == `Bob` && #2 == 25 && #3 == false");
    assert(!f2.hasError);
    assert(!evalDql(engine, f2.value, res0));
    assert(evalDql(engine, f2.value, res1));
}
