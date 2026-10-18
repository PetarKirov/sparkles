#!/usr/bin/env bash
# Build the sparkles:wsi Android smoke, run it on an emulator and check the
# lines it writes to logcat, then run the sparkles:vulkan-wsi test pattern
# (libs/vulkan-wsi/scripts/verify-android-test-pattern.sh). Run from the
# repository root inside the Android shell, with an emulator already booted:
#
#   nix develop .#android -c hue-emulator -no-window &
#   nix develop .#android -c libs/wsi/scripts/verify-android-emulator.sh
#
# It targets the first `emulator-*` device; ANDROID_SERIAL names another. Keys
# are injected as evdev events, which needs an emulator's root adbd.
set -euo pipefail

system="$(nix eval --raw --impure --expr builtins.currentSystem)"
smoke_attr=".#legacyPackages.${system}.androidExamples.wsi.android-hosted-smoke${APK_VARIANT:+.$APK_VARIANT}"
smoke="$(echo "$(nix build --no-link --print-out-paths "$smoke_attr")"/*.apk)"
smoke_package="$(nix eval --raw "$smoke_attr.applicationId")"

if [ -z "${ANDROID_SERIAL:-}" ]; then
  ANDROID_SERIAL="$(adb devices | awk '/^emulator-[0-9]+\tdevice$/ {print $1; exit}')"
  if [ -z "$ANDROID_SERIAL" ]; then
    echo "no booted emulator; start one with: nix develop .#android -c hue-emulator -no-window &" >&2
    exit 2
  fi
fi
export ANDROID_SERIAL
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 2; done

# Writing evdev events needs a root adbd: an emulator's `userdebug` image.
adb root >/dev/null
adb wait-for-device
keyboard="$(adb shell getevent -p | tr -d '\r' \
  | awk '/^add device/ { dev = $4 } /name: *"AT Translated Set 2 keyboard"/ { print dev }')"
[ -n "$keyboard" ] || { echo "the emulator has no AT keyboard device" >&2; exit 2; }

# The runs change the density and the rotation; both are put back on exit.
density="$(adb shell wm density | tr -d '\r' | sed -n 's/^Override density: //p')"
auto_rotate="$(adb shell settings get system accelerometer_rotation | tr -d '\r')"
rotation="$(adb shell settings get system user_rotation | tr -d '\r')"
restore_density() {
  if [ -n "$density" ]; then adb shell wm density "$density"; else adb shell wm density reset; fi
}
log="$(mktemp)"
cleanup() {
  rm -f "$log"
  restore_density
  [ "$rotation" = null ] || adb shell settings put system user_rotation "$rotation"
  [ "$auto_rotate" = null ] || adb shell settings put system accelerometer_rotation "$auto_rotate"
}
trap cleanup EXIT
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0

# An app cannot inject into its own window (`INJECT_EVENTS`), so the APKs log
# what they need and `run` injects each request once: keys as evdev events on
# the emulator's keyboard (real scan codes, and trusted, so a held key
# repeats), pointers through `input`, and display changes through `wm` and
# the rotation settings.
key() { adb shell "sendevent $keyboard 1 $1 $2; sendevent $keyboard 0 0 0"; }
inject() {
  case "$1" in
    chord) key 42 1; key 30 1; key 30 0; key 42 0 ;; # KEY_LEFTSHIFT, KEY_A
    hold) key 48 1 ;; # KEY_B
    release) key 48 0 ;;
    click) adb shell input mouse tap 120 400 ;;
    scroll) adb shell input mouse scroll 120 400 --axis VSCROLL,-1 ;;
    drag) adb shell input touchscreen swipe 100 400 500 800 400 ;;
    density) adb shell wm density 480 ;;
    densityreset) restore_density ;;
    landscape) adb shell settings put system user_rotation 1 ;;
    portrait) adb shell settings put system user_rotation 0 ;;
    *) echo "unknown injection request: $1" >&2; exit 1 ;;
  esac
}

# run APK PACKAGE DONE: installs and starts one APK, serves its requests until
# it logs DONE or an error, and leaves its log lines in "$log".
run() {
  echo ">> running $2 on $ANDROID_SERIAL ..."
  adb install -r "$1" >/dev/null
  adb shell am force-stop "$2"
  adb logcat -c
  adb shell am start -W -n "$2/android.app.NativeActivity" >/dev/null
  local served=" "
  for _ in $(seq 1 480); do
    adb logcat -d -s sparkles-wsi:V > "$log"
    while read -r what serial; do
      case "$served" in *" $serial "*) continue ;; esac
      served="$served$serial "
      inject "$what"
    done < <(sed -n 's/.*sparkles-wsi *: inject: \([a-z]*\) \([0-9]*\).*/\1 \2/p' "$log")
    if grep -q "$3" "$log" || grep -q ' E sparkles-wsi' "$log"; then
      break
    fi
    sleep 0.5
  done
  sed -n 's/.*sparkles-wsi *: //p' "$log"
}

run "$smoke" "$smoke_package" 'ok: Android smoke complete'
grep -q 'ok: Android WSI conformance (12 checked, 9 skipped)' "$log"
grep -q 'ok: Android touch drag with history' "$log"
grep -q 'ok: Android scale and insets' "$log"
grep -q 'ok: Android clipboard conformance (4 checked' "$log"
grep -q 'ok: Android refuses a 4 MiB clip with capacity' "$log"
grep -q 'ok: Android smoke complete' "$log"

echo ">> sparkles:wsi Android smoke verified on $ANDROID_SERIAL."

# The Vulkan test pattern, checked on screen in both orientations.
cleanup
trap - EXIT
"$(dirname "${BASH_SOURCE[0]}")/../../vulkan-wsi/scripts/verify-android-test-pattern.sh"
