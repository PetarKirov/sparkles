// Virtual-pointer injector mode for the F11 demo:
//
//     f11_scroll inject <hold_ms> <steps> <a> <b> <interval_ms> [wheel]
//
// Plugs a `zwlr_virtual_pointer_v1` device in (which is what makes a headless
// wlroots seat gain the pointer capability — the F12 lesson) and keeps it
// alive for `hold_ms` after the steps complete. Two uses here:
//
//   - steps=0: a pure capability HOLD. While the held device is up, the seat
//     keeps its pointer capability, the demo's wl_pointer survives, and the
//     transient `wlrctl pointer scroll` bursts land on a live resource.
//   - mode `wheel`: per step send axis_source(wheel) + axis_discrete(axis=
//     vertical, value=a×15, discrete=a) + frame — a notched-wheel click.
//     wlroots converts the discrete count to wl_pointer.axis_value120
//     (discrete × 120) for v8+ clients, which is the only way to exercise
//     the v120/detent path on a headless host (wlrctl never sends discrete).
//     The 15-units-per-detent value follows the libinput wheel convention.
//
// Without a mode argument, streams `steps` relative motions of (a, b) every
// `interval_ms` (unused by ./run.sh; kept aligned with the F10 injector).
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

int injectMain(int holdMs, int steps, int dx, int dy, int intervalMs, bool wheel)
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
        if (wheel)
        {
            // One notched-wheel click of `dx` detents: 15 axis units per
            // detent (the libinput convention); wlroots turns `discrete`
            // into wl_pointer.axis_value120 = discrete × 120 for v8+ binds.
            wsi_vptr_axis_source(ptr, 0 /* wheel */);
            wsi_vptr_axis_discrete(ptr, 0, 0 /* vertical */, dx * 15 * 256, dx);
        }
        else
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
