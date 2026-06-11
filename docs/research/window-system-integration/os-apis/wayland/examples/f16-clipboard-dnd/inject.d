// Virtual-pointer injector mode for the F16 demo:
//
//     f16_clipboard_dnd inject click <x> <y> <btn>      one click (btn is the
//                                                       evdev code: 272 left,
//                                                       273 right)
//     f16_clipboard_dnd inject drag  <x1> <y1> <x2> <y2>
//
// `drag` plugs ONE `zwlr_virtual_pointer_v1` device in, presses BTN_LEFT at
// (x1,y1) and HOLDS it through an 8-step motion_absolute sweep to (x2,y2)
// before releasing — wl_data_device.start_drag is only valid against the
// serial of an implicit (button-down) grab, so the press, the demo's
// start_drag, the sweep and the drop all have to live inside one device
// session. Coordinates are global against ./run.sh's 1280x720 sway layout
// (window A at (0,120), window B at (640,120), both 640x480).
module inject;

import c; // ImportC shim — wsi_vpm_* / wsi_vptr_* are hand-marshalled (see ./c.c)
import core.stdc.stdio : fprintf, printf, stderr;
import core.stdc.string : strcmp;

__gshared wl_proxy* gi_mgr;
__gshared wl_seat* gi_seat;
__gshared wl_display* gi_dpy;
__gshared wl_proxy* gi_ptr;

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

void absMove(uint x, uint y) nothrow @nogc
{
    wsi_vptr_motion_absolute(gi_ptr, 0, x, y, 1280, 720);
    wsi_vptr_frame(gi_ptr);
    wl_display_flush(gi_dpy);
}

void btn(uint button, uint state) nothrow @nogc
{
    wsi_vptr_button(gi_ptr, 0, button, state);
    wsi_vptr_frame(gi_ptr);
    wl_display_flush(gi_dpy);
}

void pause(uint ms) nothrow @nogc
{
    usleep(ms * 1000);
}

int devicePlug() // returns 0 on success
{
    gi_dpy = wl_display_connect(null);
    if (gi_dpy is null)
    {
        printf("SKIP: inject: no Wayland compositor\n");
        return 1;
    }
    wl_registry* reg = wsi_display_get_registry(gi_dpy);
    wsi_registry_add_listener(reg, &gi_registryListener, null);
    wl_display_roundtrip(gi_dpy);
    if (gi_mgr is null)
    {
        printf("SKIP: inject: no zwlr_virtual_pointer_manager_v1\n");
        wl_display_disconnect(gi_dpy);
        return 1;
    }
    gi_ptr = wsi_vpm_create_virtual_pointer(gi_mgr, gi_seat);
    wl_display_roundtrip(gi_dpy); // device plugged → seat gains the capability
    pause(400); // demo (re)creates its wl_pointer
    return 0;
}

void deviceUnplug()
{
    wsi_vptr_destroy(gi_ptr);
    wsi_vpm_destroy(gi_mgr);
    wl_display_roundtrip(gi_dpy);
    wl_display_disconnect(gi_dpy);
}

int injectClick(int x, int y, int button)
{
    if (devicePlug() != 0)
        return 0;
    absMove(x, y);
    pause(250);
    btn(button, 1);
    pause(100);
    btn(button, 0);
    pause(400);
    deviceUnplug();
    fprintf(stderr, "inject: click done x=%d y=%d btn=0x%x\n", x, y, button);
    return 0;
}

int injectDrag(int x1, int y1, int x2, int y2)
{
    if (devicePlug() != 0)
        return 0;
    absMove(x1, y1);
    pause(300);
    btn(BTN_LEFT, 1); // implicit grab — the demo's start_drag serial
    pause(400); // the demo calls start_drag inside this hold
    foreach (i; 1 .. 9)
    {
        absMove(x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8);
        pause(90);
    }
    pause(300);
    btn(BTN_LEFT, 0); // drop
    pause(800); // receive pipe + finish round-trips
    deviceUnplug();
    fprintf(stderr, "inject: drag done %d,%d -> %d,%d\n", x1, y1, x2, y2);
    return 0;
}
