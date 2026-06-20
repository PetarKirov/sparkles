/**
 * WebAssembly export surface for `sparkles.base.text`, powering the interactive
 * cell-explorer widget in docs/specs/base/text/. Compiled to a wasm32-wasip1
 * module by `nix build .#text-wasm` (which uses dlang.nix's `ldc-wasm`), then
 * loaded in the browser: the JS side writes a UTF-8 string into the exported
 * buffer and calls `spk_visible_width` / `spk_segment`.
 *
 * The exported compute path is `@nogc`/pure (no GC, no real WASI calls), so the
 * widget instantiates the module with no-op WASI stubs and never runs `_start`.
 */
module spk_text_wasm;

import sparkles.base.text.grapheme : visibleWidth, byGraphemeCluster;

// Input scratch buffer; the JS side writes UTF-8 here (address + capacity below).
private __gshared ubyte[65536] g_buf;

/// Address of the shared scratch buffer in linear memory.
extern (C) export uint spk_buf_ptr()
{
    return cast(uint) cast(size_t)&g_buf[0];
}

/// Capacity of the scratch buffer, in bytes.
extern (C) export uint spk_buf_cap()
{
    return cast(uint) g_buf.length;
}

/// Visible width (in terminal cells) of the `len` UTF-8 bytes at `ptr`.
extern (C) export int spk_visible_width(uint ptr, uint len)
{
    auto s = (cast(const(char)*) cast(size_t) ptr)[0 .. len];
    return cast(int) visibleWidth(s);
}

/// Segment the `len` UTF-8 bytes at `ptr` into grapheme clusters / escapes,
/// writing `(byteOffset, byteLen, width)` triples into the `outCapTriples`-slot
/// buffer at `outPtr`. Returns the number of units written.
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

// Dummy entry point: lets the WASI crt1 `_start`/`_Dmain` resolve at link time.
// The widget never calls it — it invokes the exports above directly.
void main()
{
}
