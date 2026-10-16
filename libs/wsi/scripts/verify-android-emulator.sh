#!/usr/bin/env bash
# Build the sparkles:wsi Android smoke APK, run it on an emulator, and check the
# conformance lines it writes to logcat. Run from the repository root inside the
# Android shell, with an emulator already booted:
#
#   nix develop .#android -c hue-emulator -no-window &
#   nix develop .#android -c libs/wsi/scripts/verify-android-emulator.sh
#
# It targets the first `emulator-*` device; ANDROID_SERIAL names another. The
# keys it injects go through the emulator console, so it needs an emulator.
set -euo pipefail

system="$(nix eval --raw --impure --expr builtins.currentSystem)"
out="$(nix build --no-link --print-out-paths ".#legacyPackages.${system}.wsi-android-smoke-apk")"
apk="$out/wsi-android-smoke.apk"
package=dev.petar_kirov.sparkles.wsismoke

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

# The run changes the density and the rotation, and puts both back on exit.
density="$(adb shell wm density | tr -d '\r' | sed -n 's/^Override density: //p')"
auto_rotate="$(adb shell settings get system accelerometer_rotation | tr -d '\r')"
rotation="$(adb shell settings get system user_rotation | tr -d '\r')"
restore_density() {
  if [ -n "$density" ]; then adb shell wm density "$density"; else adb shell wm density reset; fi
}
restore_settings() {
  restore_density
  [ "$rotation" = null ] || adb shell settings put system user_rotation "$rotation"
  [ "$auto_rotate" = null ] || adb shell settings put system accelerometer_rotation "$auto_rotate"
}
trap restore_settings EXIT
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0

echo ">> installing the smoke on $ANDROID_SERIAL ..."
adb install -r "$apk" >/dev/null
adb shell am force-stop "$package"
adb logcat -c
adb shell am start -W -n "$package/android.app.NativeActivity" >/dev/null

# The smoke cannot inject into its own window (`INJECT_EVENTS`), so it logs
# what it needs and this loop injects each request once: keys as evdev events
# on the emulator's keyboard (real scan codes, and trusted, so a held key
# repeats), and pointers through `input`.
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

echo ">> waiting for the smoke's verdict ..."
log="$(mktemp)"
trap 'rm -f "$log"; restore_settings' EXIT
served=" "
for _ in $(seq 1 480); do
  adb logcat -d -s sparkles-wsi:V > "$log"
  while read -r what serial; do
    case "$served" in *" $serial "*) continue ;; esac
    served="$served$serial "
    inject "$what"
  done < <(sed -n 's/.*sparkles-wsi *: inject: \([a-z]*\) \([0-9]*\).*/\1 \2/p' "$log")
  if grep -q 'ok: Android smoke complete' "$log" || grep -q ' E sparkles-wsi' "$log"; then
    break
  fi
  sleep 0.5
done
sed -n 's/.*sparkles-wsi *: //p' "$log"

grep -q 'ok: Android WSI conformance (12 checked, 9 skipped)' "$log"
grep -q 'ok: Android touch drag with history' "$log"
grep -q 'ok: Android scale and insets' "$log"
grep -q 'ok: Android clipboard conformance (4 checked' "$log"
grep -q 'ok: Android refuses a 4 MiB clip with capacity' "$log"
grep -q 'ok: Android smoke complete' "$log"
echo ">> sparkles:wsi Android smoke verified on $ANDROID_SERIAL."
