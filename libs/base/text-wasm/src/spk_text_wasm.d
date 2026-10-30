/++
The cell explorer's WebAssembly module (docs/specs/base/text/): the shared
memory interface of $(MREF sparkles, base, wasm) plus `spk_visible_width`, the
width `sparkles.base.text` gives a string in terminal cells. A `wasip1`
reactor built by `dub build :text-wasm --arch=wasm32-unknown-wasip1`
(docs/specs/toolchain/wasm-modules.md).
+/
module spk_text_wasm;

import sparkles.base.text.grapheme : visibleWidth;

/// The width in terminal cells of the UTF-8 text `s`.
int visibleWidthOf(scope const(char)[] s) @safe pure nothrow @nogc
    => cast(int) visibleWidth(s);

///
@("spk_text_wasm.visibleWidthOf")
@safe pure nothrow @nogc
unittest
{
    assert(visibleWidthOf("a漢́") == 3);
    assert(visibleWidthOf("\x1b[31mred\x1b[0m") == 3);
}

version (WASI)
{
    import sparkles.base.wasm : hostSlice, memoryBytes, validRanges;

    /++
    The width in terminal cells of the `len` UTF-8 bytes at `ptr` (`TCM5`), or
    `-1` when the range is outside memory.
    +/
    extern (C) export int spk_visible_width(uint ptr, uint len) @system nothrow @nogc
        => validRanges(memoryBytes, ptr, len, 0, 0) ? visibleWidthOf(hostSlice!char(ptr, len)) : -1;
}
