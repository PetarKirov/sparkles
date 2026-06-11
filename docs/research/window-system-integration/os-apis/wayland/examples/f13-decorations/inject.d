// Virtual-pointer injector mode for the F13 demo (f10 pattern, plus button):
//
//     f13_decorations inject <pre_ms> <hold_ms>
//
// Plugs a `zwlr_virtual_pointer_v1` device in (the seat gains the pointer
// capability; the demo under test creates its wl_pointer and receives
// `enter` at the previously warped position), waits `pre_ms`, nudges the
// pointer by (1,1) so a real `motion` (→ `csd_hit`) is delivered, presses
// BTN_LEFT, holds `hold_ms` (the demo's button handler issues
// xdg_toplevel.move/resize with the press serial *while the button is
// down*), releases, and unplugs. `wlrctl pointer click` cannot do this: its
// transient device unplugs before the demo's freshly created wl_pointer can
// receive the button event.
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

extern (C) void injGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

__gshared wl_registry_listener gi_registryListener = {&injGlobal, &injGlobalRemove};

enum uint BTN_LEFT = 0x110;

int injectMain(int preMs, int holdMs)
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
    usleep(preMs * 1000); // demo creates its wl_pointer; enter is delivered
    wsi_vptr_motion(ptr, 0, 1 * 256, 1 * 256); // surface-local motion → csd_hit
    wsi_vptr_frame(ptr);
    wl_display_flush(dpy);
    usleep(100_000);
    wsi_vptr_button(ptr, 0, BTN_LEFT, 1); // press: the move/resize serial
    wsi_vptr_frame(ptr);
    wl_display_flush(dpy);
    usleep(holdMs * 1000); // button held: any compositor-side grab may engage
    wsi_vptr_button(ptr, 0, BTN_LEFT, 0);
    wsi_vptr_frame(ptr);
    wl_display_flush(dpy);
    usleep(100_000);
    wsi_vptr_destroy(ptr); // device unplugged → capability drop on the seat
    wsi_vpm_destroy(gi_mgr);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    fprintf(stderr, "inject: done pre_ms=%d hold_ms=%d\n", preMs, holdMs);
    return 0;
}
