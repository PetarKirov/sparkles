/++
The table playground's WebAssembly module (docs/libs/core-cli/table.md): the
shared memory interface of $(MREF sparkles, base, wasm) plus
`spk_table_render`, which renders a table described in JSON with `drawTable`.
A `wasip1` reactor built by `dub build :table-wasm
--arch=wasm32-unknown-wasip1` (docs/specs/toolchain/wasm-modules.md).

The specification is an object with optional `props` (the `TableProps`
fields, a glyph `preset`, `glyphs` overrides and alignments) and either
`cells` (rows of strings or `{content, colSpan, rowSpan}` objects) or, with
`"mode": "sparse"`, `placements`. A value of the wrong JSON type is an invalid
specification.
+/
module spk_table_wasm;

import std.algorithm.iteration : map;
import std.array : array;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;

import sparkles.base.text.width : Align;
import sparkles.ui.components.table : Cell, drawTable, EmphasisGlyphs, Placement,
    stylePresets, TableGlyphs, TableProps, VAlign;

/++
Renders the table the JSON `spec` describes into `output` (`TCM5`).

Returns: `n >= 0`, the length of the rendering written to `output`; `-1`
when it does not fit; `-(k + 1)` for an invalid `spec`, with `k >= 1` bytes
of the message written to `output`, cut at a code point boundary.
+/
int tableRender(const(char)[] spec, scope char[] output) @safe
{
    auto writer = OutputBuffer(output);
    try
    {
        render(writer, parseJSON(spec));
        return writer.overflowed ? -1 : cast(int) writer.length;
    }
    catch (Exception e)
    {
        const msg = e.msg.length ? e.msg : "invalid table specification";
        size_t k = msg.length < output.length ? msg.length : output.length;
        while (k < msg.length && k > 0 && (msg[k] & 0xC0) == 0x80)
            --k;
        if (k == 0)
            return -1;
        output[0 .. k] = msg[0 .. k];
        return -cast(int) k - 1;
    }
}

///
@("spk_table_wasm.tableRender.renders")
@safe unittest
{
    char[256] output;
    const n = tableRender(`{"cells": [["a", "bb"], ["ccc", "d"]], "props": {"preset": "ascii"}}`, output[]);
    assert(output[0 .. n] == "+-----+----+\n| a   | bb |\n| ccc | d  |\n+-----+----+\n");
}

@("spk_table_wasm.tableRender.invalidJson")
@safe unittest
{
    char[256] output;
    const r = tableRender(`{"cells": [["a",`, output[]);
    assert(r < -1);
    assert(output[0 .. -r - 1] == "Unexpected end of data. (Line 1:16)");
}

@("spk_table_wasm.tableRender.invalidSpecification")
@safe unittest
{
    char[256] output;
    auto r = tableRender(`{"cells": [["a"]], "props": {"preset": "nope"}}`, output[]);
    assert(output[0 .. -r - 1] == "unknown preset: nope");
    r = tableRender(`{"cells": "a", "props": {}}`, output[]);
    assert(output[0 .. -r - 1] == "JSONValue is not an array");
    r = tableRender(`{"cells": [["a"]], "props": {"headerRows": -1}}`, output[]);
    assert(output[0 .. -r - 1] == "headerRows: a size must not be negative");
}

@("spk_table_wasm.tableRender.tooSmall")
@safe unittest
{
    char[8] output;
    assert(tableRender(`{"cells": [["a", "bb"]], "props": {}}`, output[]) == -1);
    // A message is cut to the buffer, never inside a code point.
    char[24] message;
    assert(tableRender(`{"cells": [["a"]], "props": {"preset": "€€"}}`, message[0 .. 18]) == -17);
    assert(message[0 .. 16] == "unknown preset: ");
    assert(tableRender(`{"cells": [["a"]], "props": {"preset": "€€"}}`, message[0 .. 19]) == -20);
    assert(message[0 .. 19] == "unknown preset: €");
}

version (WASI)
{
    import sparkles.base.wasm : hostSlice, memoryBytes, validRanges;

    /++
    Renders the JSON table specification at `inPtr` into `outCap` bytes at
    `outPtr` ($(LREF tableRender)). Ranges outside memory or overlapping each
    other are invalid input.
    +/
    extern (C) export int spk_table_render(uint inPtr, uint inLen, uint outPtr, uint outCap)
        @system
    {
        auto output = hostSlice!char(outPtr, outCap);
        if (!validRanges(memoryBytes, inPtr, inLen, outPtr, outCap))
        {
            enum msg = "input and output ranges must lie in memory and not overlap";
            if (!validRanges(memoryBytes, 0, 0, outPtr, outCap) || outCap < msg.length)
                return -1;
            output[0 .. msg.length] = msg;
            return -cast(int) msg.length - 1;
        }
        return tableRender(hostSlice!char(inPtr, inLen), output);
    }
}

// ---------------------------------------------------------------------------
// JSON → drawTable
// ---------------------------------------------------------------------------

// The host's output buffer as an output range: the table is written straight
// into it, and anything past its end marks the render as overflowed.
private struct OutputBuffer
{
    char[] buf;
    size_t length;
    bool overflowed;

    void put(scope const(char)[] s) @safe pure nothrow @nogc
    {
        if (overflowed || s.length > buf.length - length)
        {
            overflowed = true;
            return;
        }
        buf[length .. length + s.length] = s[];
        length += s.length;
    }

    void put(char c) @safe pure nothrow @nogc
    {
        char[1] one = c;
        put(one[]);
    }
}

private void render(ref scope OutputBuffer w, const JSONValue spec) @safe
{
    const props = parseProps(spec["props"]);

    if (str(spec, "mode", "dense") == "sparse")
    {
        Placement[] placements;
        foreach (p; spec["placements"].arrayNoRef)
            placements ~= Placement(row: size(p, "row", 0), col: size(p, "col", 0),
                content: str(p, "content", ""),
                colSpan: size(p, "colSpan", 1), rowSpan: size(p, "rowSpan", 1));
        drawTable(w, placements, props);
        return;
    }

    Cell[][] cells;
    foreach (row; spec["cells"].arrayNoRef)
        cells ~= row.arrayNoRef.map!parseCell.array;
    drawTable(w, cells, props);
}

private Cell parseCell(const JSONValue cell) @safe
    => cell.type == JSONType.string
        ? Cell(cell.str)
        : Cell(str(cell, "content", ""), size(cell, "colSpan", 1), size(cell, "rowSpan", 1));

private TableProps parseProps(const JSONValue j) @safe
{
    TableProps p;
    p.border = flag(j, "border", p.border);
    p.columnSeparators = flag(j, "columnSeparators", p.columnSeparators);
    p.rowSeparators = flag(j, "rowSeparators", p.rowSeparators);
    p.headerRows = size(j, "headerRows", p.headerRows);
    p.headerCols = size(j, "headerCols", p.headerCols);
    p.maxWidth = size(j, "maxWidth", p.maxWidth);
    p.title = str(j, "title", p.title);
    p.footer = str(j, "footer", p.footer);

    const preset = str(j, "preset", "rounded");
    const glyphs = preset in stylePresets;
    enforce(glyphs, "unknown preset: " ~ preset);
    p.glyphs = *glyphs;
    if (auto g = "glyphs" in j)
        applyGlyphs(p.glyphs, *g);

    if (auto v = "defaultAlign" in j)
        p.defaultAlign = toAlign(v.str);
    if (auto v = "defaultVAlign" in j)
        p.defaultVAlign = toVAlign(v.str);
    if (auto v = "columnAligns" in j)
        p.columnAligns = v.arrayNoRef.map!(a => toAlign(a.str)).array;
    if (auto v = "columnVAligns" in j)
        p.columnVAligns = v.arrayNoRef.map!(a => toVAlign(a.str)).array;
    if (auto v = "columnMaxWidths" in j)
        p.columnMaxWidths = v.arrayNoRef.map!(a => sizeOf("columnMaxWidths", a)).array;
    return p;
}

// Optional members: absent gives the default; present must have the type.

private string str(const JSONValue j, string key, string default_) @safe
{
    if (auto v = key in j)
        return v.str;
    return default_;
}

private size_t size(const JSONValue j, string key, size_t default_) @safe
{
    if (auto v = key in j)
        return sizeOf(key, *v);
    return default_;
}

private size_t sizeOf(string key, const JSONValue v) @safe
{
    const n = v.get!long;
    enforce(n >= 0, key ~ ": a size must not be negative");
    return cast(size_t) n;
}

private bool flag(const JSONValue j, string key, bool default_) @safe
{
    if (auto v = key in j)
        return v.boolean;
    return default_;
}

private dchar glyph(const JSONValue v) @safe
{
    import std.range.primitives : empty, front;

    const s = v.str;
    return s.empty ? ' ' : s.front;
}

private Align toAlign(string s) @safe
{
    switch (s)
    {
        case "left":    return Align.left;
        case "center":  return Align.center;
        case "right":   return Align.right;
        case "decimal": return Align.decimal;
        case "inherit": return Align.inherit;
        default:        throw new Exception("unknown alignment: " ~ s);
    }
}

private VAlign toVAlign(string s) @safe
{
    switch (s)
    {
        case "top":     return VAlign.top;
        case "middle":  return VAlign.middle;
        case "bottom":  return VAlign.bottom;
        case "inherit": return VAlign.inherit;
        default:        throw new Exception("unknown vertical alignment: " ~ s);
    }
}

// Per-field glyph overrides (each value a one-glyph string) onto a base set:
// the frame and interior fields, and the nested emphasis objects.
private void applyGlyphs(ref TableGlyphs g, const JSONValue j) @safe
{
    foreach (string k, ref const v; j.objectNoRef)
    {
        fields: switch (k)
        {
            case "headerRow":  applyEmphasis(g.headerRow, v);  break;
            case "headerCol":  applyEmphasis(g.headerCol, v);  break;
            case "headerBoth": applyEmphasis(g.headerBoth, v); break;
            static foreach (field; ["topLeft", "topRight", "bottomLeft", "bottomRight",
                "horizontalLine", "verticalLine", "teeDown", "teeUp", "teeRight", "teeLeft",
                "cross", "cornerTL", "cornerTR", "cornerBL", "cornerBR"])
            {
                case field: __traits(getMember, g, field) = glyph(v); break fields;
            }
            default: throw new Exception("unknown glyph: " ~ k);
        }
    }
}

private void applyEmphasis(ref EmphasisGlyphs g, const JSONValue j) @safe
{
    foreach (string k, ref const v; j.objectNoRef)
    {
        fields: switch (k)
        {
            static foreach (field; ["horizontalLine", "verticalLine", "teeDown", "teeUp",
                "teeRight", "teeLeft", "cross", "cornerTL", "cornerTR", "cornerBL", "cornerBR"])
            {
                case field: __traits(getMember, g, field) = glyph(v); break fields;
            }
            default: throw new Exception("unknown emphasis glyph: " ~ k);
        }
    }
}
