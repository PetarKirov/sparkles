/**
Software pixels for a Wayland window: a shared-memory (`wl_shm`) buffer,
filled on the CPU, attached and committed.

A Wayland toplevel maps — becomes visible, gets keyboard focus — only once a
buffer is committed to its surface, so a program that draws nothing still
needs one. This is that buffer, for examples and conformance drivers that
have no renderer; a real program presents through `sparkles:vulkan-wsi`.

Every request runs on the backend's shared display under the native-I/O
borrow (`WaylandWsi.beginNativeIo`), which $(LREF ShmPainter.paint) and
$(LREF ShmPainter.release) take themselves.
*/
module sparkles.wsi.platform.wayland_shm;

version (linux):

import core.stdc.string : strcmp;
import core.sys.posix.stdlib : mkstemp;
import core.sys.posix.sys.mman : MAP_FAILED, MAP_SHARED, PROT_READ, PROT_WRITE,
    mmap, munmap;
import core.sys.posix.unistd : ftruncate, posixClose = close, unlink;
import std.sumtype : match;

import sparkles.wsi.handles : WaylandDisplayHandle, WaylandWindowHandle;
import sparkles.wsi.platform.wayland : WaylandWsi;
import sparkles.wsi.types : WindowId;

import wayland_native;

/// What $(LREF ShmPainter.paint) waits for after the commit.
enum ShmSync
{
    /// Flush the requests and return.
    flush,
    /// A display round trip: the compositor has seen the commit on return.
    roundtrip,
}

/**
Paints a window with `wl_shm` buffers, one per paint. The previous buffer is
destroyed on the next paint, when the compositor has long since attached its
replacement.
*/
struct ShmPainter
{
    private wl_shm* shm;
    private wl_buffer* previous;

    @disable this(this);

    /**
    Paints `id` at `width` × `height` buffer pixels: `fill(pixels, width,
    height)` writes the `XRGB8888` pixels, row-major (a buffer starts black),
    and the buffer is attached, damaged and committed. False when the
    window has no Wayland surface or any request fails.
    */
    bool paint(alias fill)(ref WaylandWsi wsi, WindowId id, int width, int height,
        ShmSync sync = ShmSync.flush)
    {
        if (width <= 0 || height <= 0)
            return false;
        auto queried = wsi.nativeHandles(id);
        if (queried.hasError)
            return false;
        auto display = queried.value.display.match!(
            (in WaylandDisplayHandle handle) => cast(wl_display*) handle.display,
            (_) => null);
        auto surface = queried.value.window.match!(
            (in WaylandWindowHandle handle) => cast(wl_surface*) handle.surface,
            (_) => null);
        if (display is null || surface is null || wsi.beginNativeIo().hasError)
            return false;
        scope (exit) cast(void) wsi.endNativeIo();
        if (shm is null && !bind(display))
            return false;

        char[22] path = "/tmp/wsi-shm-XXXXXX\0\0\0";
        const fd = mkstemp(path.ptr);
        if (fd < 0)
            return false;
        scope (exit) posixClose(fd);
        unlink(path.ptr);
        const stride = width * 4;
        const size = stride * height;
        if (ftruncate(fd, size) != 0)
            return false;
        auto mapped = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapped is MAP_FAILED)
            return false;
        fill((cast(uint*) mapped)[0 .. width * height], width, height);
        munmap(mapped, size);

        auto pool = wl_shm_create_pool(shm, fd, size);
        if (pool is null)
            return false;
        scope (exit) wl_shm_pool_destroy(pool);
        auto buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride,
            WL_SHM_FORMAT_XRGB8888);
        if (buffer is null)
            return false;
        wl_surface_attach(surface, buffer, 0, 0);
        wl_surface_damage(surface, 0, 0, width, height);
        wl_surface_commit(surface);
        if (previous !is null)
            wl_buffer_destroy(previous);
        previous = buffer;
        return sync == ShmSync.roundtrip
            ? wl_display_roundtrip(display) >= 0
            : wl_display_flush(display) >= 0;
    }

    /// Destroys the last buffer and the `wl_shm` binding; call it before the
    /// backend closes.
    void release(ref WaylandWsi wsi)
    {
        if (shm is null && previous is null)
            return;
        if (wsi.beginNativeIo().hasError)
            return;
        scope (exit) cast(void) wsi.endNativeIo();
        if (previous !is null)
            wl_buffer_destroy(previous);
        if (shm !is null)
            wl_proxy_destroy(cast(wl_proxy*) shm);
        previous = null;
        shm = null;
    }

    private bool bind(wl_display* display)
    {
        auto registry = wl_display_get_registry(display);
        if (registry is null)
            return false;
        scope (exit) wl_proxy_destroy(cast(wl_proxy*) registry);
        if (wl_registry_add_listener(registry,
                cast(wl_registry_listener*) &shmListener, &shm) != 0
            || wl_display_roundtrip(display) < 0)
            return false;
        return shm !is null;
    }
}

private extern (C) void onShmGlobal(void* data, wl_registry* registry,
    uint name, const(char)* interfaceName, uint) nothrow @nogc
{
    auto shm = cast(wl_shm**) data;
    if (strcmp(interfaceName, wl_shm_interface.name) == 0 && *shm is null)
        *shm = cast(wl_shm*) wl_registry_bind(registry, name, &wl_shm_interface, 1);
}

private extern (C) void onShmGlobalRemove(void*, wl_registry*, uint) nothrow @nogc
{
}

// ImportC drops the C const from the add_listener parameter; the protocol
// never writes through a listener table.
private immutable wl_registry_listener shmListener = {
    &onShmGlobal, &onShmGlobalRemove
};
