// wasm32-wasip1 entry module backing the interactive drawTable playground in
// docs/libs/core-cli/table.md. Compiled by `nix build .#table-wasm` against the
// real `sparkles.core_cli.ui.table` (the LDC WASI fork gives us full Phobos + a
// GC), then shrunk with wasm-opt and served as docs/public/spk-table.wasm.
//
// ABI (mirrors libs/base/wasm/spk_text_wasm.d's shared-scratch-buffer pattern):
//   spk_buf_ptr() / spk_buf_cap()          — address & size of the shared buffer
//   spk_table_render(in,inLen,out,outCap)  — JSON spec in → rendered string out
//
// Init handshake (resolved by the docs/… spike; see TablePlayground.vue):
//   * The JS host must supply *real* wasi `clock_res_get` / `clock_time_get`
//     imports that write a non-zero value — otherwise core.time's TickDuration
//     ctor divides by a zero clock resolution and traps.
//   * The host calls `__wasm_call_ctors()` once after instantiation; that runs the
//     C-level init_array which sets up the GC. drawTable then allocates freely.
//   * D `static this()` module ctors do NOT run under this druntime, so we never
//     touch `stylePresets` (an AA seeded by a module ctor) — presets come from the
//     pure `presetGlyphs(name)` instead.
module spk_table_wasm;

import std.json : parseJSON, JSONValue, JSONType;
import std.algorithm : map;
import std.array : array;

import sparkles.core_cli.ui.table :
    drawTable, TableProps, TableGlyphs, EmphasisGlyphs, Cell, Placement, presetGlyphs;
import sparkles.base.text.width : Align;
import sparkles.base.text.grapheme : byGraphemeCluster;
import sparkles.core_cli.ui.table : VAlign;

// Shared scratch buffer: JS writes the JSON request at offset 0 and reads the
// rendered UTF-8 (or an error message) back from a caller-chosen output offset.
private __gshared ubyte[262144] g_buf;

extern (C) export uint spk_buf_ptr()
{
    return cast(uint) cast(size_t)&g_buf[0];
}

extern (C) export uint spk_buf_cap()
{
    return cast(uint) g_buf.length;
}

// Segment the string at (ptr, len) into grapheme clusters, writing one
// (byteOffset, byteLen, cellWidth) uint triple per cluster to (outPtr) and
// returning the count. The JS host uses this to lay each rendered line onto
// fixed-width cells — so the browser's CJK/emoji glyph metrics can't desync the
// column borders, because these widths come from the SAME oracle drawTable uses.
// ANSI escapes are emitted as width-0 units (their bytes start with 0x1b).
extern (C) export int spk_segment(uint ptr, uint len, uint outPtr, uint outCapTriples)
{
    auto s = (cast(const(char)*) cast(size_t) ptr)[0 .. len];
    auto o = (cast(uint*) cast(size_t) outPtr)[0 .. outCapTriples * 3];
    int n = 0;
    uint off = 0;
    foreach (u; s.byGraphemeCluster)
    {
        if (n >= cast(int) outCapTriples)
            break;
        o[n * 3 + 0] = off;
        o[n * 3 + 1] = cast(uint) u.slice.length;
        o[n * 3 + 2] = cast(uint) u.width;
        off += cast(uint) u.slice.length;
        ++n;
    }
    return n;
}

// Render the table described by the JSON at (inPtr, inLen); write the result UTF-8
// to (outPtr, outCap) and return its byte length, or a negative code on failure.
//
// NB: D exception *unwinding* does not work under this ldc-wasm druntime — a thrown
// exception traps rather than reaching a `catch`. So the parser below is written to
// never call a throwing `std.json` accessor (it checks `.type` before every read),
// and the JS host is expected to pre-validate that the input is syntactically valid
// JSON (parseJSON itself throws on malformed input). The try/catch remains only as a
// best-effort backstop.
extern (C) export int spk_table_render(uint inPtr, uint inLen, uint outPtr, uint outCap)
{
    try
    {
        auto input = (cast(const(char)*) cast(size_t) inPtr)[0 .. inLen];
        auto j = parseJSON(input);
        return writeOut(render(j), outPtr, outCap);
    }
    catch (Throwable t)
    {
        const msg = t.msg.length ? t.msg : "render failed";
        const k = msg.length > outCap ? outCap : msg.length;
        (cast(ubyte*) cast(size_t) outPtr)[0 .. k] = cast(const(ubyte)[]) msg[0 .. k];
        return -cast(int) k;
    }
}

// Dummy entry so the WASI crt1 _start/_Dmain links; the widget never calls it.
void main()
{
}

// ---------------------------------------------------------------------------
// JSON → drawTable
// ---------------------------------------------------------------------------

private int writeOut(string result, uint outPtr, uint outCap)
{
    if (result.length > outCap)
        return -2;
    (cast(ubyte*) cast(size_t) outPtr)[0 .. result.length] = cast(const(ubyte)[]) result[];
    return cast(int) result.length;
}

private string render(const JSONValue j)
{
    auto props = parseProps(field(j, "props"));
    const mode = asStr(j, "mode", "dense");

    if (mode == "sparse")
    {
        Placement[] pls;
        foreach (pj; arrayOf(field(j, "placements")))
        {
            Placement pl;
            pl.row = asSize(pj, "row");
            pl.col = asSize(pj, "col");
            pl.content = asStr(pj, "content");
            pl.colSpan = asSize(pj, "colSpan", 1);
            pl.rowSpan = asSize(pj, "rowSpan", 1);
            pls ~= pl;
        }
        return drawTable(pls, props);
    }

    Cell[][] cells;
    foreach (rowj; arrayOf(field(j, "cells")))
    {
        Cell[] row;
        foreach (cj; arrayOf(rowj))
            row ~= parseCell(cj);
        cells ~= row;
    }
    return drawTable(cells, props);
}

private Cell parseCell(const JSONValue j)
{
    if (j.type == JSONType.string)
        return Cell(j.str);
    return Cell(asStr(j, "content"), asSize(j, "colSpan", 1), asSize(j, "rowSpan", 1));
}

private TableProps parseProps(const JSONValue j)
{
    TableProps p;
    p.border = asBool(j, "border", p.border);
    p.columnSeparators = asBool(j, "columnSeparators", p.columnSeparators);
    p.rowSeparators = asBool(j, "rowSeparators", p.rowSeparators);
    p.headerRows = asSize(j, "headerRows", p.headerRows);
    p.headerCols = asSize(j, "headerCols", p.headerCols);
    p.maxWidth = asSize(j, "maxWidth", p.maxWidth);
    p.title = asStr(j, "title", p.title);
    p.footer = asStr(j, "footer", p.footer);

    p.glyphs = presetGlyphs(asStr(j, "preset", "rounded"));
    if ("glyphs" in j)
        applyGlyphs(p.glyphs, field(j, "glyphs"));

    if ("defaultAlign" in j)
        p.defaultAlign = toAlign(asStr(j, "defaultAlign"));
    if ("defaultVAlign" in j)
        p.defaultVAlign = toVAlign(asStr(j, "defaultVAlign"));
    if ("columnAligns" in j)
        p.columnAligns = arrayOf(field(j, "columnAligns")).map!(v => toAlign(strOf(v))).array;
    if ("columnVAligns" in j)
        p.columnVAligns = arrayOf(field(j, "columnVAligns")).map!(v => toVAlign(strOf(v))).array;
    if ("columnMaxWidths" in j)
        p.columnMaxWidths = arrayOf(field(j, "columnMaxWidths")).map!(v => sizeOf(v)).array;
    return p;
}

// ---------------------------------------------------------------------------
// small JSON helpers — every accessor is type-checked so none can throw (see the
// note on spk_table_render: exception unwinding traps under this druntime).
// ---------------------------------------------------------------------------

// The value at `key`, or a JSON `null` if absent (whose accessors all yield defaults).
private JSONValue field(const JSONValue j, string key)
{
    if (j.type == JSONType.object)
        if (auto v = key in j)
            return *v;
    return JSONValue(null);
}

private const(JSONValue)[] arrayOf(const JSONValue j)
{
    return j.type == JSONType.array ? j.arrayNoRef : null;
}

private string strOf(const JSONValue j)
{
    return j.type == JSONType.string ? j.str : "";
}

private size_t sizeOf(const JSONValue j)
{
    return j.type == JSONType.integer || j.type == JSONType.uinteger ? cast(size_t) j.integer : 0;
}

private string asStr(const JSONValue j, string key, string dflt = "")
{
    if (j.type == JSONType.object)
        if (auto v = key in j)
            return v.type == JSONType.string ? v.str : dflt;
    return dflt;
}

private size_t asSize(const JSONValue j, string key, size_t dflt = 0)
{
    if (j.type == JSONType.object)
        if (auto v = key in j)
            return v.type == JSONType.integer || v.type == JSONType.uinteger
                ? cast(size_t) v.integer : dflt;
    return dflt;
}

private bool asBool(const JSONValue j, string key, bool dflt)
{
    if (j.type == JSONType.object)
        if (auto v = key in j)
            return v.type == JSONType.true_ ? true : (v.type == JSONType.false_ ? false : dflt);
    return dflt;
}

private dchar firstDchar(string s)
{
    import std.range : front, empty;

    return s.empty ? ' ' : s.front;
}

private Align toAlign(string s)
{
    switch (s)
    {
        case "left":    return Align.left;
        case "center":  return Align.center;
        case "right":   return Align.right;
        case "decimal": return Align.decimal;
        default:        return Align.inherit;
    }
}

private VAlign toVAlign(string s)
{
    switch (s)
    {
        case "top":    return VAlign.top;
        case "middle": return VAlign.middle;
        case "bottom": return VAlign.bottom;
        default:       return VAlign.inherit;
    }
}

// Apply per-field glyph overrides (each value a one-glyph string) onto a base set.
// Supports the flat frame/interior fields plus nested emphasis objects.
private void applyGlyphs(ref TableGlyphs g, const JSONValue j)
{
    if (j.type != JSONType.object)
        return;
    foreach (string k, v; j.objectNoRef)
    {
        switch (k)
        {
            case "topLeft":        g.topLeft = firstDchar(strOf(v));        break;
            case "topRight":       g.topRight = firstDchar(strOf(v));       break;
            case "bottomLeft":     g.bottomLeft = firstDchar(strOf(v));     break;
            case "bottomRight":    g.bottomRight = firstDchar(strOf(v));    break;
            case "horizontalLine": g.horizontalLine = firstDchar(strOf(v)); break;
            case "verticalLine":   g.verticalLine = firstDchar(strOf(v));   break;
            case "teeDown":        g.teeDown = firstDchar(strOf(v));        break;
            case "teeUp":          g.teeUp = firstDchar(strOf(v));          break;
            case "teeRight":       g.teeRight = firstDchar(strOf(v));       break;
            case "teeLeft":        g.teeLeft = firstDchar(strOf(v));        break;
            case "cross":          g.cross = firstDchar(strOf(v));          break;
            case "cornerTL":       g.cornerTL = firstDchar(strOf(v));       break;
            case "cornerTR":       g.cornerTR = firstDchar(strOf(v));       break;
            case "cornerBL":       g.cornerBL = firstDchar(strOf(v));       break;
            case "cornerBR":       g.cornerBR = firstDchar(strOf(v));       break;
            case "headerRow":      applyEmphasis(g.headerRow, v);           break;
            case "headerCol":      applyEmphasis(g.headerCol, v);           break;
            case "headerBoth":     applyEmphasis(g.headerBoth, v);          break;
            default: break;
        }
    }
}

private void applyEmphasis(ref EmphasisGlyphs g, const JSONValue j)
{
    if (j.type != JSONType.object)
        return;
    foreach (string k, v; j.objectNoRef)
    {
        switch (k)
        {
            case "horizontalLine": g.horizontalLine = firstDchar(strOf(v)); break;
            case "verticalLine":   g.verticalLine = firstDchar(strOf(v));   break;
            case "teeDown":        g.teeDown = firstDchar(strOf(v));        break;
            case "teeUp":          g.teeUp = firstDchar(strOf(v));          break;
            case "teeRight":       g.teeRight = firstDchar(strOf(v));       break;
            case "teeLeft":        g.teeLeft = firstDchar(strOf(v));        break;
            case "cross":          g.cross = firstDchar(strOf(v));          break;
            case "cornerTL":       g.cornerTL = firstDchar(strOf(v));       break;
            case "cornerTR":       g.cornerTR = firstDchar(strOf(v));       break;
            case "cornerBL":       g.cornerBL = firstDchar(strOf(v));       break;
            case "cornerBR":       g.cornerBR = firstDchar(strOf(v));       break;
            default: break;
        }
    }
}
