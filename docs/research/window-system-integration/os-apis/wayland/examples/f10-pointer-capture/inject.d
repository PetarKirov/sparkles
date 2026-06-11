// Virtual-pointer injector mode for the F10 demo:
//
//     f10_pointer_capture inject <hold_ms> <steps> <dx> <dy> <interval_ms>
//
// Plugs a `zwlr_virtual_pointer_v1` device in (which is what makes a headless
// wlroots seat gain the pointer capability — the F12 lesson), streams `steps`
// relative motions of (dx, dy) every `interval_ms`, keeps the device alive
// for another `hold_ms`, then destroys it (capability drop). One invocation
// is one plug/unplug cycle — but unlike `wlrctl pointer move`, whose device
// lives only long enough for a single motion (the motion is consumed
// establishing pointer focus, so the client under test never sees a motion
// stream at all), the held device delivers real `wl_pointer.motion` /
// `zwp_relative_pointer_v1.relative_motion` streams while focused.
// ./run.sh composes the F10 phase choreography out of these invocations.
module inject;

import c; // ImportC shim — wsi_vpm_* / wsi_vptr_* are hand-marshalled (see ./c.c)
import core.stdc.stdio : fprintf, printf, stderr;
import core.stdc.string : strcmp;

__gshared wl_proxy* gi_mgr;
__gshared wl_seat* gi_seat;

extern (C) void injGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    if (strcmp(iface, "zwlr_virtual_pointer_manager_v1") == 0)
        gi_mgr = cast(wl_proxy*) wsi_registry_bind(reg, name,
            &wsi_virtual_pointer_manager_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && gi_seat is null)
        gi_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, 1);
}

extern (C) void injGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc {}

__gshared wl_registry_listener gi_registryListener = {&injGlobal, &injGlobalRemove};

int injectMain(int holdMs, int steps, int dx, int dy, int intervalMs)
{
    wl_display* dpy = wl_display_connect(null);
    if (dpy is null)
    {
        printf("SKIP: inject: no Wayland compositor\n");
        return 0;
    }
    wl_registry* reg = wsi_display_get_registry(dpy);
    wsi_registry_add_listener(reg, &gi_registryListener, null);
    wl_display_roundtrip(dpy);
    if (gi_mgr is null)
    {
        printf("SKIP: inject: no zwlr_virtual_pointer_manager_v1\n");
        wl_display_disconnect(dpy);
        return 0;
    }
    wl_proxy* ptr = wsi_vpm_create_virtual_pointer(gi_mgr, gi_seat);
    wl_display_roundtrip(dpy); // device plugged → seat gains the pointer capability
    foreach (i; 0 .. steps)
    {
        wsi_vptr_motion(ptr, 0, dx * 256, dy * 256);
        wsi_vptr_frame(ptr);
        wl_display_flush(dpy);
        usleep(intervalMs * 1000);
    }
    usleep(holdMs * 1000);
    wsi_vptr_destroy(ptr); // device unplugged → capability drop on the seat
    wsi_vpm_destroy(gi_mgr);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    fprintf(stderr, "inject: done steps=%d delta=%d,%d interval_ms=%d hold_ms=%d\n",
        steps, dx, dy, intervalMs, holdMs);
    return 0;
}
