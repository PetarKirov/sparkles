/**
Kitty images for a Vulkan painter (`UVX11`): a terminal-owned
$(MREF sparkles,ui,image,ImageRegistry) the canvas uploads within its
budget. The bytes are ours — the registry only borrows them — so a row
update patches the copy and $(LREF ImageRegistry.replace) bumps the
generation the canvas re-uploads from.
*/
module sparkles.terminal_view.vulkan_images;

import sparkles.ui.geometry : Size;
import sparkles.ui.image : ImageData, ImageHandle, ImageRegistry;
import sparkles.terminal_view.painter : channels, ImagePixels, ImageRect, PixelLayout,
    TextureId;

/**
The terminal's image residency. `TextureId.value` is the registry handle.
Not a second GPU cache: the canvas uploads and retires these entries.
*/
struct VulkanImages
{
    /// Per-pane fallback registry, used unless a shared one is bound.
    ImageRegistry ownRegistry;
    /// Registry shared by all panes (a `TerminalView` static), or null.
    ImageRegistry* sharedRegistry;
    private ubyte[][] owned;

    @safe pure nothrow:

    /// The registry the canvas borrows: the shared one when set.
    ImageRegistry* registryRef() return
        => sharedRegistry !is null ? sharedRegistry : &ownRegistry;

    TextureId createTexture(in ImagePixels image)
    {
        if (image.width == 0 || image.height == 0 || image.pixels.length == 0)
            return TextureId.init;
        auto rgba = toRgba(image);
        if (rgba.length == 0)
            return TextureId.init;
        const handle = registryRef.register(rgba, Size(image.width, image.height));
        if (handle.value > owned.length)
            owned.length = handle.value;
        owned[handle.value - 1] = rgba;
        return TextureId(handle.value, image.width, image.height, image.layout);
    }

    void updateTextureRows(TextureId t, in ImagePixels image, size_t first, size_t count)
    {
        auto buf = bytesOf(t);
        if (buf is null || (*buf).length == 0 || image.width != t.width
                || t.width == 0 || count == 0)
            return;
        const ulong dstRow = cast(ulong) t.width * 4;
        const ulong srcRow = cast(ulong) image.width * channels(image.layout);
        const ulong last = cast(ulong) first + count;
        if (last > t.height || last * srcRow > image.pixels.length || last * dstRow > (*buf).length)
            return;
        foreach (row; first .. first + count)
        {
            const dstOff = cast(size_t)(row * dstRow);
            const srcOff = cast(size_t)(row * srcRow);
            auto dst = (*buf)[dstOff .. dstOff + cast(size_t) dstRow];
            const src = image.pixels[srcOff .. srcOff + cast(size_t) srcRow];
            writeRow(dst, src, image.layout);
        }
        registryRef.replace(ImageHandle(t.value), ImageData((*buf)[], Size(t.width, t.height)));
    }
    void releaseTexture(TextureId t)
    {
        if (!t.valid)
            return;
        // Only the pane that owns the bytes may retire the handle: with a
        // shared registry, another pane's handle is meaningful here, and
        // removing it would kill that pane's live image.
        auto buf = bytesOf(t);
        if (buf is null || (*buf).length == 0)
            return;
        registryRef.remove(ImageHandle(t.value));
        *buf = null;
    }

    void drawTexture(TextureId, in ImageRect, in ImageRect) const @safe pure nothrow @nogc
    {
    }

    private ubyte[]* bytesOf(TextureId t) @safe pure nothrow return
        => t.valid && t.value <= owned.length ? &owned[t.value - 1] : null;
}

private ubyte[] toRgba(in ImagePixels image) @safe pure nothrow
{
    if (image.width == 0 || image.height == 0)
        return null;
    const ulong n = cast(ulong) image.width * image.height;
    const ulong need = n * channels(image.layout);
    const ulong need4 = n * 4;
    if (need > image.pixels.length || need4 > size_t.max)
        return null;
    auto rgba = new ubyte[cast(size_t) need4];
    writeRow(rgba, image.pixels[0 .. cast(size_t) need], image.layout);
    return rgba;
}

private void writeRow(ubyte[] dst, scope const(ubyte)[] src, PixelLayout layout) @safe pure nothrow @nogc
{
    const ch = channels(layout);
    size_t s, d;
    while (d + 4 <= dst.length && s + ch <= src.length)
    {
        final switch (layout)
        {
            case PixelLayout.gray:
                dst[d] = dst[d + 1] = dst[d + 2] = src[s];
                dst[d + 3] = 255;
                break;
            case PixelLayout.grayAlpha:
                dst[d] = dst[d + 1] = dst[d + 2] = src[s];
                dst[d + 3] = src[s + 1];
                break;
            case PixelLayout.rgb:
                dst[d] = src[s];
                dst[d + 1] = src[s + 1];
                dst[d + 2] = src[s + 2];
                dst[d + 3] = 255;
                break;
            case PixelLayout.rgba:
                dst[d .. d + 4] = src[s .. s + 4];
                break;
        }
        s += ch;
        d += 4;
    }
}

@("terminal_view.vulkan_images.aRowUpdateBumpsTheGeneration")
@safe pure nothrow
unittest
{
    VulkanImages images;
    immutable ubyte[12] pixels = [10, 0, 0, 0, 20, 0, 0, 0, 30, 0, 0, 40];
    const t = images.createTexture(ImagePixels(2, 2, PixelLayout.rgb, pixels));
    assert(t.valid && t.value == 1);
    const stored = images.registryRef.lookup(ImageHandle(t.value));
    assert(stored !is null && stored.rgba[0] == 10 && stored.rgba[3] == 255);
    assert(stored.rgba[4] == 0 && stored.rgba[7] == 255);

    immutable ubyte[12] next = [9, 9, 9, 1, 1, 1, 0, 0, 30, 0, 0, 40];
    images.updateTextureRows(t, ImagePixels(2, 2, PixelLayout.rgb, next), 0, 1);
    const again = images.registryRef.lookup(ImageHandle(t.value));
    assert(again.generation == 1);
    assert(again.rgba[0] == 9 && again.rgba[4] == 1);
    assert(again.rgba[8] == 0);

    images.releaseTexture(t);
    assert(images.registryRef.lookup(ImageHandle(t.value)).rgba.length == 0);
}

@("terminal_view.vulkan_images.mismatchedOrStaleUpdateIsIgnored")
@safe pure nothrow
unittest
{
    VulkanImages images;
    immutable ubyte[12] pixels = [10, 0, 0, 0, 20, 0, 0, 0, 30, 0, 0, 40];
    const t = images.createTexture(ImagePixels(2, 2, PixelLayout.rgb, pixels));
    assert(t.valid && t.value == 1);
    const before = images.registryRef.lookup(ImageHandle(t.value));
    assert(before !is null);
    const beforeRgba = before.rgba.dup;
    const beforeGeneration = before.generation;

    immutable ubyte[24] wide = [
        1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 8
    ];
    images.updateTextureRows(t, ImagePixels(4, 2, PixelLayout.rgb, wide), 0, 1);
    const afterMismatch = images.registryRef.lookup(ImageHandle(t.value));
    assert(afterMismatch !is null && afterMismatch.rgba == beforeRgba);
    assert(afterMismatch.generation == beforeGeneration);

    images.releaseTexture(t);
    const releasedGeneration = images.registryRef.lookup(ImageHandle(t.value)).generation;
    images.updateTextureRows(t, ImagePixels(2, 2, PixelLayout.rgb, pixels), 0, 1);
    const afterRelease = images.registryRef.lookup(ImageHandle(t.value));
    assert(afterRelease !is null && afterRelease.rgba.length == 0);
    assert(afterRelease.generation == releasedGeneration);
}

@("terminal_view.vulkan_images.sharedRegistryKeepsPaneOwnership")
@system pure nothrow
unittest
{
    ImageRegistry registry;
    VulkanImages first, second;
    first.sharedRegistry = &registry;
    second.sharedRegistry = &registry;
    immutable ubyte[4] red = [255, 0, 0, 255];
    immutable ubyte[4] green = [0, 255, 0, 255];
    const a = first.createTexture(ImagePixels(1, 1, PixelLayout.rgba, red));
    const b = second.createTexture(ImagePixels(1, 1, PixelLayout.rgba, green));
    assert(a.valid && b.valid && a.value != b.value);
    first.releaseTexture(b);
    first.updateTextureRows(b, ImagePixels(1, 1, PixelLayout.rgba, red), 0, 1);
    assert(registry.lookup(ImageHandle(b.value)).rgba == green[]);
    first.releaseTexture(a);
    assert(registry.lookup(ImageHandle(a.value)).rgba.length == 0);
    assert(registry.lookup(ImageHandle(b.value)).rgba == green[]);
    second.releaseTexture(b);
    assert(registry.lookup(ImageHandle(b.value)).rgba.length == 0);
}
