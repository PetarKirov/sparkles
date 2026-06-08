// Minimal Wayland client — the irreducible bootstrap that precedes everything on
// Wayland: connect, get the registry, and discover the globals the compositor
// advertises. A window is not a syscall but a tree of protocol objects bound from
// this registry. Core API + the real `wl_registry_interface`/`wl_registry_listener`
// come from <wayland-client.h> via the ImportC shim (`c.c`). See ../index.md.
//
// > [!NOTE] Why this stops at the registry: an actual `xdg_toplevel` window also
// > needs the `xdg-shell` protocol marshalled (`xdg_wm_base` -> `xdg_surface` ->
// > `xdg_toplevel`) plus a `wl_shm` buffer (the no-buffer-no-window rule). That
// > protocol glue is normally *generated* by `wayland-scanner` from XML — which is
// > itself the finding: X11 needs ~80 lines, Wayland effectively needs codegen.
// > The survey walks the full handshake; this program shows the genuinely minimal
// > part. `wl_display_get_registry`/`wl_registry_add_listener` are `static inline`
// > in the header (not importable by ImportC), so we call the underlying
// > `wl_proxy_marshal_flags`/`wl_proxy_add_listener` directly — exactly what those
// > inlines expand to.
//
// Headless-safe: no compositor -> wl_display_connect returns null -> SKIP, exit 0.
module app;

import c; // ImportC: <wayland-client.h>
import core.stdc.stdio : printf;

__gshared int g_globalCount = 0;

// Attributes match the listener's function-pointer fields, which the ImportC
// `#pragma attribute(push, nogc, nothrow)` in `c.c` stamped `nothrow @nogc`.
extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    g_globalCount++;
    printf("  [%2u] %-40s v%u\n", name, iface, ver);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

int main()
{
    // 1. Connect to the compositor named by $WAYLAND_DISPLAY (null = default).
    wl_display* dpy = wl_display_connect(null);
    if (dpy is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }
    scope (exit)
        wl_display_disconnect(dpy);

    // 2. wl_display.get_registry — the hand-expansion of the `static inline`
    //    wl_display_get_registry: marshal the request, naming the new object's
    //    interface (the real exported `wl_registry_interface`).
    auto displayProxy = cast(wl_proxy*) dpy;
    wl_proxy* registry = wl_proxy_marshal_flags(displayProxy, WL_DISPLAY_GET_REGISTRY,
        &wl_registry_interface, wl_proxy_get_version(displayProxy), 0, cast(void*) null);
    if (registry is null)
    {
        printf("SKIP: wl_display.get_registry returned null\n");
        return 0;
    }
    scope (exit)
        wl_proxy_destroy(registry);

    // 3. Listen for `global` events, then round-trip so the compositor sends its
    //    current globals and our callback prints each one.
    static wl_registry_listener listener = {&onGlobal, &onGlobalRemove};
    // wl_proxy_add_listener takes `void (**)(void)`; ImportC types it with the
    // shim's nothrow/@nogc attributes, so cast to that exact pointer type.
    alias ListenerFn = extern (C) void function() nothrow @nogc;
    wl_proxy_add_listener(registry, cast(ListenerFn*)&listener, null);
    printf("Wayland globals advertised by the compositor:\n");
    wl_display_roundtrip(dpy);

    printf("ok: bootstrapped Wayland and enumerated %d globals\n", g_globalCount);
    return 0;
}
