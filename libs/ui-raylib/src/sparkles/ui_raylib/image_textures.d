/**
The GPU side of `IMG`: raylib textures for the images
$(REF ImageRegistry, sparkles,ui,image) holds.

The toolkit registers decoded RGBA and hands out handles; it has no device and
never uploads anything. This is the one place that does — a cache keyed by
handle, revalidated against the registry's generation counter, so replacing an
image (a hot-reloaded asset, a re-rendered chart) re-uploads exactly once and
no toolkit type ever learns what a texture is.
*/
module sparkles.ui_raylib.image_textures;

import raylib;

import sparkles.ui.image : ImageData, ImageHandle, ImageRegistry;

/**
Uploaded textures for a registry, revalidated by generation.

Borrows the registry: an application owns both, and this must not outlive it.
$(LREF release) frees every upload and must run while the GL context is still
alive — a `~this` would run at an unspecified point after `CloseWindow`.
*/
struct ImageTextures
{
    private
    {
        struct Entry
        {
            Texture2D texture;
            uint generation;
            bool uploaded;
        }

        const(ImageRegistry)* _registry;
        Entry[uint] _cache;
    }

    /// Binds this cache to `registry`. Borrowed, not owned.
    void attach(const(ImageRegistry)* registry) @safe nothrow @nogc
    {
        _registry = registry;
    }

    /**
    The texture for `handle`, uploading it if absent or stale, or `null` when
    the handle names nothing or carries no pixels to upload.

    A `null` return is the caller's cue to paint `IMG4`'s placeholder — which
    is why a missing image is not an error here. An image registered without
    `rgba` (a backend that loaded it by itself and registered only the extent)
    also returns `null`; there is nothing for this cache to do with it.
    */
    Texture2D* resolve(ImageHandle handle) @system
    {
        if (_registry is null || !handle.valid)
            return null;
        const data = _registry.lookup(handle);
        if (data is null || data.rgba.length == 0
            || data.size.width <= 0 || data.size.height <= 0)
            return null;

        if (auto e = handle.value in _cache)
        {
            if (e.uploaded && e.generation == data.generation)
                return &e.texture;
            // Stale: the registry replaced the pixels under this handle.
            if (e.uploaded)
                UnloadTexture(e.texture);
            _cache.remove(handle.value);
        }

        auto entry = Entry(generation: data.generation);
        if (upload(*data, entry.texture))
            entry.uploaded = true;
        _cache[handle.value] = entry;
        auto stored = handle.value in _cache;
        return stored.uploaded ? &stored.texture : null;
    }

    /// Frees every upload. Call while the GL context is alive.
    void release() @system
    {
        foreach (ref e; _cache)
            if (e.uploaded)
                UnloadTexture(e.texture);
        _cache = null;
    }

    /// How many handles this cache currently holds an entry for.
    size_t length() const @safe pure nothrow @nogc => _cache.length;
}

// The registry's `rgba` is borrowed and may be transient, so the upload copies
// through raylib's own Image — which owns its bytes until `UnloadImage`.
private bool upload(in ImageData data, out Texture2D texture) @system
{
    const w = data.size.width, h = data.size.height;
    const needed = cast(size_t) w * h * 4;
    if (data.rgba.length < needed)
        return false; // a truncated buffer would upload uninitialised memory

    Image img;
    img.data = cast(void*) data.rgba.ptr;
    img.width = w;
    img.height = h;
    img.mipmaps = 1;
    img.format = PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;

    // `LoadTextureFromImage` copies into GPU memory and does not retain the
    // pointer, so aliasing the caller's slice here is sound and saves a copy.
    texture = LoadTextureFromImage(img);
    return texture.id != 0;
}
