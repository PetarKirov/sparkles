#!/usr/bin/env bash
# F06 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, which times out cleanly with zero key events). Run it from the
# repo dev shell (`nix develop`, for dub/xvfb-run); xdotool and setxkbmap are
# pulled in via `nix shell`.
#
#     ./run.sh        # build, then run the scripted injection under Xvfb
#
# Sequence (see ../../f06-keyboard.md for the findings it produces):
#   us layout : a · shift+2 -> @ · s held 0.7 s -> server auto-repeat in the
#               detectable wire pattern (KeyPress repeats, no KeyRelease)
#   setxkbmap de mid-run -> the server broadcasts XkbNewKeyboardNotify /
#               XkbMapNotify and the demo rebuilds its keymap (keymap_event)
#   de layout : z (y/z position swap) · shift+7 -> / · dead_acute e -> é
#               (xkb_compose dead-key sequence)
#
# Focus: the demo XSetInputFocus()es itself after MapNotify, so the XTEST
# events xdotool synthesizes land on it even on bare Xvfb (no WM, where the
# default focus is PointerRoot). No icewm needed for keyboard injection.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WSI_F06_INNER:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xdotool nixpkgs#xorg.setxkbmap --command \
        xvfb-run -a env WSI_F06_INNER=1 "$0"
fi

# ---- inner: DISPLAY points at a fresh Xvfb ----------------------------------
setxkbmap us
WSI_AUTO_EXIT=1 WSI_DURATION_MS=${WSI_DURATION_MS:-12000} \
    "$dir/build/f06_keyboard_x11" &
demo=$!
sleep 2 # let the demo map + self-focus

xdotool key a       # plain letter
xdotool key shift+2 # us shifted symbol: @

# Server-side auto-repeat: hold the key down via XTEST. With detectable
# auto-repeat enabled the demo sees KeyPress repeats and no KeyRelease
# until the real release.
xdotool keydown s
sleep 0.7
xdotool keyup s

setxkbmap de # live keymap replacement, mid-run
sleep 1

xdotool key z          # de: y/z swap — same request, different keycode+text
xdotool key shift+7    # de shifted symbol: /
xdotool key dead_acute # dead key ...
xdotool key e          # ... + e -> é via xkb_compose

wait "$demo"
