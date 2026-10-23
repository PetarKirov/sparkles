/**
libghostty's PNG decoder for kitty graphics: `sparkles.ui.png`, the
toolkit's codec, behind the callback libghostty calls. It needs no window,
so every pane that draws pixels installs it, on either arm.
*/
module sparkles.terminal_view.png_decoder;

import sparkles.ghostty.c : GHOSTTY_SUCCESS, GHOSTTY_SYS_OPT_DECODE_PNG, GhosttyAllocator,
    GhosttySysImage, ghostty_alloc, ghostty_free, ghostty_sys_set;
import sparkles.ui.png : decodePngInto, pngHeader;

/// Installs the decoder as libghostty's: process-global, before any
/// terminal exists, idempotent.
void installPngDecoder() @system nothrow @nogc
{
    // A failed install would silently break every kitty PNG; it is asserted
    // rather than reported because this runs before any terminal (and its
    // error surface) exists.
    const res = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, cast(const(void)*) &decodePng);
    assert(res == GHOSTTY_SUCCESS, "installing the PNG decoder failed");
}

/**
The callback: decodes into a buffer from the allocator libghostty hands
over, which then owns it. The header sizes the buffer, so a file never
allocates more than the image it declares.
*/
extern (C) private bool decodePng(void*, GhosttyAllocator* allocator, const(ubyte)* data,
    size_t dataLength, GhosttySysImage* image) nothrow
{
    if (data is null || image is null || allocator is null)
        return false;
    const png = data[0 .. dataLength];
    const header = pngHeader(png);
    if (!header.valid)
        return false;
    const length = header.rgbaLength;
    auto pixels = ghostty_alloc(allocator, length);
    if (pixels is null)
        return false;
    if (!decodePngInto(png, pixels[0 .. length]))
    {
        ghostty_free(allocator, pixels, length);
        return false;
    }
    image.width = header.width;
    image.height = header.height;
    image.data = pixels;
    image.data_len = length;
    return true;
}
