#!/bin/sh
# Tier-A driver for the F13 decoration demo (see ./app.d, ./libdecor-variant/
# and ../../f13-decorations.md).
#
#   ./run.sh weston           mode A on headless weston (socket wsi-w7a): is
#                             zxdg_decoration_manager_v1 offered at all? Then
#                             the CSD path (margins + geometry contract) runs
#                             under the auto maximize storm.
#   ./run.sh weston-violate   same, WSI_NO_GEOMETRY=1: margins kept but
#                             set_window_geometry never sent — the maximize
#                             commit is the violation; capture the reaction.
#   ./run.sh sway             mode A on headless sway, tiled AND floating
#                             (per-compositor SSD answer), plus the runtime
#                             set_mode(client_side)/unset_mode storm and a
#                             `swaymsg border` poke.
#   ./run.sh sway-csd         WSI_FORCE_CSD=1 floating window + injected
#                             pointer (wlrctl click) on the title bar and the
#                             bottom-right band: captures move_start /
#                             resize_start with live serials in WAYLAND_DEBUG.
#   ./run.sh libdecor         the libdecor variant on weston, then on sway —
#                             who draws the frame on each.
#
# weston/dub come from the repo dev shell; sway modes need sway+swaymsg(+wlrctl),
# libdecor mode needs nix (fetches nixpkgs#libdecor.dev for pkg-config).
# Each mode is self-contained: private XDG_RUNTIME_DIR, compositor killed on exit.
set -eu
cd "$(dirname "$0")"
mode="${1:-weston}"
demo=./build/f13_decorations
[ -x "$demo" ] || dub build --compiler=ldc2 >&2

rt="$(mktemp -d)"
export XDG_RUNTIME_DIR="$rt"
unset WAYLAND_DISPLAY DISPLAY || true

cleanup()
{
    [ -n "${comp_pid:-}" ] && kill "$comp_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

start_weston() # start_weston <socket>
{
    command -v weston >/dev/null || { echo "SKIP: weston not on PATH"; exit 0; }
    weston --backend=headless --socket="$1" --idle-time=0 > "$rt/weston.log" 2>&1 &
    comp_pid=$!
    sleep 2
}

start_sway()
{
    command -v sway >/dev/null || { echo "SKIP: sway not on PATH"; exit 0; }
    {
        printf 'output HEADLESS-1 resolution 1280x720\n'
        printf 'for_window [app_id="wsi-f13-floating"] floating enable, move position 320 120\n'
    } > "$rt/sway.cfg"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        sway -c "$rt/sway.cfg" > "$rt/sway.log" 2>&1 &
    comp_pid=$!
    sleep 3
    wld="$(cd "$rt" && ls wayland-* 2>/dev/null | grep -v '\.lock$' | head -n 1)"
    [ -n "$wld" ] || { echo "SKIP: sway did not create a wayland socket"; exit 0; }
    SWAYSOCK="$(ls "$rt"/sway-ipc.*.sock | head -n 1)"
    export SWAYSOCK
}

# Warp, then plug a HELD virtual pointer that motions (+1,+1) and presses/
# releases BTN_LEFT (the demo's own `inject` mode, ./inject.d). wlrctl's
# transient per-invocation device cannot deliver a button to the demo's
# freshly created wl_pointer — the press races the capability dance.
click_at() # click_at <x> <y>
{
    swaymsg seat seat0 cursor set "$1" "$2" > /dev/null
    sleep 0.1
    WAYLAND_DISPLAY="$wld" "$demo" inject 500 400 2>/dev/null
    sleep 0.4
}

case "$mode" in
weston)
    start_weston wsi-w7a
    WAYLAND_DISPLAY=wsi-w7a WSI_AUTO_EXIT=1 "$demo"
    ;;
weston-violate)
    start_weston wsi-w7a
    WAYLAND_DISPLAY=wsi-w7a WSI_AUTO_EXIT=1 WSI_NO_GEOMETRY=1 "$demo"
    ;;
sway)
    start_sway
    echo "--- tiled (default app_id) ---"
    WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=4500 "$demo" &
    demo_pid=$!
    sleep 2
    # cheap interaction probe: does `border` re-negotiate the decoration mode?
    swaymsg '[app_id=wsi-f13-decorations] border none' > /dev/null || true
    sleep 0.5
    swaymsg '[app_id=wsi-f13-decorations] border normal' > /dev/null || true
    wait "$demo_pid"
    echo "--- floating (for_window rule; storm probes set_mode while floating) ---"
    WAYLAND_DISPLAY="$wld" WSI_APP_ID=wsi-f13-floating WSI_AUTO_EXIT=1 \
        WSI_RUN_MS=4500 "$demo"
    ;;
sway-csd)
    start_sway
    env WAYLAND_DISPLAY="$wld" WSI_APP_ID=wsi-f13-floating WSI_FORCE_CSD=1 \
        WSI_AUTO_EXIT=1 WSI_NO_STORM=1 WSI_RUN_MS=12000 \
        ${WSI_DEMO_DEBUG:+WAYLAND_DEBUG=1} "$demo" &
    demo_pid=$!
    sleep 2
    # Window floats at (320,120), geometry 640x480, margin 12 → buffer origin
    # (308,108). Title bar: global y ≈ 120+14; bottom-right band: ≈ (959,599).
    click_at 500 134      # title bar → move_start
    click_at 955 595      # bottom-right band → resize_start edge=10
    click_at 640 350      # content → no request (control)
    click_at 938 134      # close box → csd_close, client shutdown
    wait "$demo_pid" || true
    ;;
libdecor)
    ldemo=./libdecor-variant/build/f13_libdecor
    libdecor_dev="$(nix build --no-link --print-out-paths nixpkgs#libdecor.dev)"
    libdecor_lib="$(nix build --no-link --print-out-paths nixpkgs#libdecor)"
    export PKG_CONFIG_PATH="$libdecor_dev/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$libdecor_lib/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Force the cairo plugin: libdecor prefers libdecor-gtk.so, whose gtk_init
    # stalls ~50 s on D-Bus timeouts in a headless/no-session environment and
    # then never delivers a configure. The cairo plugin has no session deps.
    mkdir -p "$rt/ld-plugins"
    ln -sf "$libdecor_lib/lib/libdecor/plugins-1/libdecor-cairo.so" "$rt/ld-plugins/"
    export LIBDECOR_PLUGIN_DIR="$rt/ld-plugins"
    # …and the cairo plugin itself blocks ~25 s on a session-bus cursor-theme
    # query when a real bus exists but no settings portal answers. A dead bus
    # address makes the D-Bus connect fail instantly and the plugin proceeds.
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent"
    [ -x "$ldemo" ] || (cd libdecor-variant && dub build --compiler=ldc2 >&2)
    echo "--- libdecor on weston ---"
    start_weston wsi-w7a
    WAYLAND_DISPLAY=wsi-w7a WSI_AUTO_EXIT=1 WSI_RUN_MS=3000 "$ldemo"
    kill "$comp_pid" 2>/dev/null || true
    comp_pid=
    if command -v sway >/dev/null; then
        echo "--- libdecor on sway ---"
        start_sway
        WAYLAND_DISPLAY="$wld" WSI_AUTO_EXIT=1 WSI_RUN_MS=3000 "$ldemo"
    fi
    ;;
*)
    echo "usage: $0 [weston|weston-violate|sway|sway-csd|libdecor]" >&2
    exit 2
    ;;
esac
