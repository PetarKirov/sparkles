#!/usr/bin/env bash
# F07 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, which negotiates with whatever IM the locale/XMODIFIERS give
# it and times out cleanly). Run it from the repo dev shell (`nix develop`,
# for dub/xvfb-run); xdotool, setxkbmap and fcitx5 are pulled in via
# `nix shell`, and Xvfb gets a real font path (misc-fixed) because
# XIMPreeditPosition requires a working XFontSet.
#
#     ./run.sh        # build, then run all scenarios under one Xvfb
#
# Scenarios (see ../../f07-text-input.md for the findings each produces):
#   builtin-utf8    en_US.UTF-8, XMODIFIERS unset -> the built-in XIM;
#                   de layout dead-key compose through Xutf8LookupString
#   locale-c        LC_ALL=C -> how the IM stack degrades without UTF-8
#   bogus-locale    LC_ALL=xx_YY.nope -> setlocale fails; what remains?
#   nonexistent-im  XMODIFIERS=@im=nosuchim -> XOpenIM behavior, timed
#   fcitx5          a real CJK IME as an XIM server, started AFTER the demo
#                   (instantiate callback), pinyin nihao+space round-trip,
#                   then killed under the demo (destroy callback)
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$dir/build/f07_text_input_x11"

if [[ -z "${WSI_F07_INNER:-}" ]]; then
    dub build --root="$dir"
    fontdir="$(nix build --no-link --print-out-paths nixpkgs#xorg.fontmiscmisc)/share/fonts/X11/misc"
    pinyin="$(nix build --no-link --print-out-paths nixpkgs#qt6Packages.fcitx5-chinese-addons | head -n1)"
    exec nix shell nixpkgs#xdotool nixpkgs#xorg.setxkbmap \
        nixpkgs#fcitx5 --command \
        xvfb-run -a -s "-screen 0 640x480x24 -fp $fontdir" \
        env WSI_F07_INNER=1 WSI_F07_PINYIN="$pinyin" "$0"
fi

# ---- inner: DISPLAY points at a fresh Xvfb ----------------------------------

# Run one demo instance in the background with a scenario-prefixed log.
demo=
start_demo() { # start_demo <name> <duration_ms> [ENV=VAL ...]
    local name=$1 dur=$2
    shift 2
    echo "=== scenario: $name ==="
    (env "$@" WSI_AUTO_EXIT=1 WSI_DURATION_MS="$dur" "$bin" 2>&1 \
        | sed "s/^/[$name] /") &
    demo=$!
    sleep 2 # let it map + self-focus + open the IM
}

# -- builtin-utf8: the built-in XIM and its compose machinery ------------------
setxkbmap de # dead_acute lives on the de layout
start_demo builtin-utf8 9000 -u XMODIFIERS LC_ALL=en_US.UTF-8
xdotool key h
xdotool key i
xdotool key dead_acute # compose starts: what does the lookup report?
xdotool key e          # ... -> é
xdotool key dead_acute
xdotool key dead_acute # ´ ´ composes to the spacing acute character
xdotool key Left Left  # caret into the middle ...
xdotool key x          # ... insert there
xdotool key BackSpace  # ... and delete it again
xdotool key Return     # submit: the log carries the final line
wait "$demo"

# -- locale-c: same keystrokes, C locale ---------------------------------------
start_demo locale-c 6000 -u XMODIFIERS LC_ALL=C
xdotool key h
xdotool key dead_acute
xdotool key e
wait "$demo"

# -- bogus-locale: setlocale("") fails outright --------------------------------
start_demo bogus-locale 4000 -u XMODIFIERS LC_ALL=xx_YY.nope
xdotool key h
wait "$demo"

# -- nonexistent-im: XMODIFIERS names an IM server that is not running ---------
start_demo nonexistent-im 4000 LC_ALL=en_US.UTF-8 XMODIFIERS=@im=nosuchim
xdotool key h
wait "$demo"

# -- fcitx5: a real CJK IME, full lifecycle ------------------------------------
# fcitx5 from `nix shell` needs to be told where its addons (incl. pinyin
# from fcitx5-chinese-addons) and their data files live. CAUTION: fcitx5's
# XIM addon names its server after the XMODIFIERS *it* sees — a leaked host
# value (e.g. @im=ibus) silently registers the wrong server name — so pin it.
fcitx_base="$(dirname "$(dirname "$(command -v fcitx5)")")"
export FCITX_ADDON_DIRS="$fcitx_base/lib/fcitx5:$WSI_F07_PINYIN/lib/fcitx5"
export XDG_DATA_DIRS="$fcitx_base/share:$WSI_F07_PINYIN/share:${XDG_DATA_DIRS:-/run/current-system/sw/share}"
# Profile: pinyin in the default group (contexts still start in the inactive
# keyboard state — the ctrl+space trigger below activates the IME).
cfg="$(mktemp -d)"
mkdir -p "$cfg/fcitx5/conf"
printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=pinyin\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=pinyin\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$cfg/fcitx5/profile"
export XDG_CONFIG_HOME="$cfg"

# Launch fcitx5 directly (the dbus addon is disabled, so no session bus is
# needed) so `kill "$fcitx"` hits fcitx5 itself — killing a dbus-run-session
# wrapper does NOT propagate to fcitx5, which then survives the scenario and
# keeps the XIM selection.
start_fcitx() {
    pkill -x fcitx5 2>/dev/null && sleep 0.5 || true # leftover hygiene
    env XMODIFIERS=@im=fcitx \
        fcitx5 --disable=wayland,waylandim,dbus,notifications \
        >>/tmp/fcitx5.log 2>&1 &
    fcitx=$!
    sleep 4 # fcitx5 up + XIM server registered (XIM_SERVERS on the root)
}

setxkbmap us
start_demo fcitx5 20000 LC_ALL=en_US.UTF-8 XMODIFIERS=@im=fcitx
# The demo is already running and XOpenIM has already FAILED — now start the
# IM server and watch XRegisterIMInstantiateCallback fire + the IM reopen.
start_fcitx
xdotool key ctrl+space # fcitx trigger: activate the pinyin engine
sleep 0.5
xdotool key n i h a o # pre-edit builds up (every press is filtered)
sleep 1
xdotool key space # commit the first candidate: 你好
sleep 1
kill "$fcitx" 2>/dev/null || true # IM server dies under the live IC ...
wait "$fcitx" 2>/dev/null || true # ... -> XNDestroyCallback fires
sleep 1
start_fcitx # ... and a restart re-fires the instantiate callback
xdotool key ctrl+space
sleep 0.5
xdotool key n i space # works again after the reopen
sleep 1
wait "$demo"
kill "$fcitx" 2>/dev/null || true
wait "$fcitx" 2>/dev/null || true

# -- fcitx5-onthespot: same IME, PreeditCallbacks (on-the-spot) style ----------
# fcitx5's XIM addon offers the callbacks style only when configured; the
# demo then receives the pre-edit as preedit_draw deltas and renders it
# itself (underlined gray cells).
printf 'UseOnTheSpot=True\n' > "$cfg/fcitx5/conf/xim.conf"
start_demo fcitx5-onthespot 14000 LC_ALL=en_US.UTF-8 XMODIFIERS=@im=fcitx WSI_XIM_STYLE=callbacks
start_fcitx
xdotool key ctrl+space
sleep 0.5
xdotool key n i h a o
sleep 1
xdotool key space
sleep 1
xdotool key n i
sleep 0.5
xdotool key Escape # cancel mid-composition: preedit must be retracted
sleep 1
wait "$demo"
kill "$fcitx" 2>/dev/null || true
wait "$fcitx" 2>/dev/null || true
echo "=== fcitx5 server log (last lines) ==="
tail -n 6 /tmp/fcitx5.log || true
