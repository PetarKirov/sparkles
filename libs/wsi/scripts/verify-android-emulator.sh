#!/usr/bin/env bash
# Build the sparkles:wsi Android smoke APK, run it on an emulator, and check the
# conformance lines it writes to logcat. Run from the repository root inside the
# Android shell, with an emulator already booted:
#
#   nix develop .#android -c hue-emulator -no-window &
#   nix develop .#android -c libs/wsi/scripts/verify-android-emulator.sh
#
# It targets the first `emulator-*` device. A physical device is used only when
# named explicitly through ANDROID_SERIAL.
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

echo ">> installing the smoke on $ANDROID_SERIAL ..."
adb install -r "$apk" >/dev/null
adb shell am force-stop "$package"
adb logcat -c
adb shell am start -W -n "$package/android.app.NativeActivity" >/dev/null

echo ">> waiting for the smoke's verdict ..."
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
for _ in $(seq 1 120); do
  adb logcat -d -s sparkles-wsi:V > "$log"
  if grep -q 'ok: Android smoke complete' "$log" || grep -q ' E sparkles-wsi' "$log"; then
    break
  fi
  sleep 1
done
sed -n 's/.*sparkles-wsi *: //p' "$log"

grep -q 'ok: Android WSI conformance (' "$log"
grep -q 'ok: Android clipboard conformance (4 checked' "$log"
grep -q 'ok: Android refuses a 4 MiB clip with capacity' "$log"
grep -q 'ok: Android smoke complete' "$log"
echo ">> sparkles:wsi Android smoke verified on $ANDROID_SERIAL."
