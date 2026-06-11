// Virtual-pointer injector mode for the F15 demo:
//
//     f15_popup inject <menu|edge>
//
// Plugs ONE `zwlr_virtual_pointer_v1` device in and scripts a whole popup
// scenario inside that single device session (motion_absolute against the
// 1280x720 headless output). A per-gesture plug/unplug (the wlrctl model)
// would flap the seat's pointer capability mid-grab — whether THAT dismisses
// a grab popup must stay a deliberate measurement, not an accident of the
// test driver. Coordinates are baked against ./run.sh's sway layout:
//
//   menu  window wsi-f15-popup floats at (320,120) 640x480. Right-click at
//         global (500,300) = surface (180,180) opens the menu; after the
//         demo's reposition probe (+24,+16 offset) the popup's expected
//         global origin is (525,317) — the hover/click coordinates target
//         the REPOSITIONED items; a final click at (150,650) lands outside
//         the window (compositor-side dismissal → popup_done chain).
//   edge  window wsi-f15-edge floats at (632,232); right-click at global
//         (1232,682) = surface (600,450) — the 160x96 popup cannot fit
//         down-right (output is 1280x720), the compositor must constrain.
//         The device is then HELD ~4 s while ./run.sh delivers Esc via a
//         wtype virtual keyboard.
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

enum uint BTN_LEFT = 0x110, BTN_RIGHT = 0x111;

void absMove(uint x, uint y) nothrow @nogc
{
    wsi_vptr_motion_absolute(gi_ptr, 0, x, y, 1280, 720);
    wsi_vptr_frame(gi_ptr);
    wl_display_flush(gi_dpy);
}

void click(uint button, uint holdMs = 80) nothrow @nogc
{
    wsi_vptr_button(gi_ptr, 0, button, 1);
    wsi_vptr_frame(gi_ptr);
    wl_display_flush(gi_dpy);
    usleep(holdMs * 1000);
    wsi_vptr_button(gi_ptr, 0, button, 0);
    wsi_vptr_frame(gi_ptr);
    wl_display_flush(gi_dpy);
}

void pause(uint ms) nothrow @nogc
{
    usleep(ms * 1000);
}

int injectMain(const(char)[] scenario)
{
    gi_dpy = wl_display_connect(null);
    if (gi_dpy is null)
    {
        printf("SKIP: inject: no Wayland compositor\n");
        return 0;
    }
    wl_registry* reg = wsi_display_get_registry(gi_dpy);
    wsi_registry_add_listener(reg, &gi_registryListener, null);
    wl_display_roundtrip(gi_dpy);
    if (gi_mgr is null)
    {
        printf("SKIP: inject: no zwlr_virtual_pointer_manager_v1\n");
        wl_display_disconnect(gi_dpy);
        return 0;
    }
    gi_ptr = wsi_vpm_create_virtual_pointer(gi_mgr, gi_seat);
    wl_display_roundtrip(gi_dpy); // device plugged → seat gains the capability
    pause(400); // demo creates its wl_pointer

    if (scenario.length >= 4 && scenario[0 .. 4] == "edge")
    {
        absMove(1232, 682); // inside wsi-f15-edge, near the output corner
        pause(400);
        click(BTN_RIGHT); // → constrained popup + grab
        pause(4000); // hold the device while run.sh sends Esc via wtype
    }
    else // menu
    {
        absMove(500, 300); // inside wsi-f15-popup
        pause(400);
        click(BTN_RIGHT); // → popup1 + grab(press serial)
        pause(1700); // popup maps; demo fires the reposition probe (+24,+16)
        absMove(595, 336); // hover item 0 (repositioned popup)
        pause(250);
        absMove(595, 364); // hover item 1
        pause(250);
        absMove(595, 392); // hover item 2 ("submenu >")
        pause(300);
        click(BTN_LEFT); // → popup2 (nested, grabbed) parented on popup1
        pause(800);
        absMove(150, 650); // outside the window entirely
        pause(300);
        click(BTN_LEFT); // → compositor dismisses: popup_done chain
        pause(600);
    }

    wsi_vptr_destroy(gi_ptr); // device unplugged → capability drop
    wsi_vpm_destroy(gi_mgr);
    wl_display_roundtrip(gi_dpy);
    wl_display_disconnect(gi_dpy);
    fprintf(stderr, "inject: done scenario=%.*s\n", cast(int) scenario.length, scenario.ptr);
    return 0;
}
