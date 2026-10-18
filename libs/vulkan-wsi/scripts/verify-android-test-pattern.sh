#!/usr/bin/env bash
# Run the Vulkan test pattern (libs/vulkan-wsi/examples/android-test-pattern.d)
# on a device or an emulator and check what reaches the screen: portrait,
# turned to landscape, and back. Each step waits for the app's `pattern:` log
# line for that orientation, lets the rebuilt swapchain present, captures the
# screen with `screencap` and checks it with check-test-pattern.d. Run from the
# repository root inside the Android shell:
#
#   nix develop .#android -c libs/vulkan-wsi/scripts/verify-android-test-pattern.sh
#
# ANDROID_SERIAL names the device (the first `emulator-*` otherwise). It needs
# no root: it turns the display through the rotation settings, which it saves
# first and restores on exit. APK_VARIANT=debug installs the variant whose
# application id every example shares, for a device that asks before each new
# package. KEEP_CAPTURES=<dir> keeps the raw captures.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
system="$(nix eval --raw --impure --expr builtins.currentSystem)"
attr=".#legacyPackages.${system}.androidExamples.vulkan-wsi.android-test-pattern${APK_VARIANT:+.$APK_VARIANT}"
apk="$(echo "$(nix build --no-link --print-out-paths "$attr")"/*.apk)"
package="$(nix eval --raw "$attr.applicationId")"

if [ -z "${ANDROID_SERIAL:-}" ]; then
  ANDROID_SERIAL="$(adb devices | awk '/^emulator-[0-9]+\tdevice$/ {print $1; exit}')"
  [ -n "$ANDROID_SERIAL" ] || { echo "no device: set ANDROID_SERIAL or boot an emulator" >&2; exit 2; }
fi
export ANDROID_SERIAL

echo ">> building the checker ..."
dub build -q --single "$repo/libs/vulkan-wsi/scripts/check-test-pattern.d"
check="$repo/libs/vulkan-wsi/scripts/build/check_test_pattern"

work="$(mktemp -d)"
rotation="$(adb shell settings get system user_rotation | tr -d '\r')"
auto_rotate="$(adb shell settings get system accelerometer_rotation | tr -d '\r')"
cleanup() {
  adb shell am force-stop "$package" || true
  [ "$rotation" = null ] || adb shell settings put system user_rotation "$rotation"
  [ "$auto_rotate" = null ] || adb shell settings put system accelerometer_rotation "$auto_rotate"
  [ -n "${KEEP_CAPTURES:-}" ] && cp "$work"/*.raw "$KEEP_CAPTURES"/ 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0

echo ">> running $package on $ANDROID_SERIAL ..."
adb install -r "$apk" >/dev/null
adb shell am force-stop "$package"
adb logcat -c
adb shell am start -W -n "$package/android.app.NativeActivity" >/dev/null

latest() { adb logcat -d -s sparkles-wsi:V | sed -n 's/.*sparkles-wsi *: \(pattern: .*\)/\1/p' | tail -1; }

# check NAME portrait|landscape
check() {
  local line="" display width height insets
  for _ in $(seq 1 60); do
    if adb logcat -d -s sparkles-wsi:V | grep -q ' E sparkles-wsi'; then
      adb logcat -d -s sparkles-wsi:V | sed -n 's/.*sparkles-wsi *: //p' >&2
      return 1
    fi
    line="$(latest)"
    display="$(sed -n 's/.*display \([0-9]*x[0-9]*\).*/\1/p' <<<"$line")"
    width="${display%x*}" height="${display#*x}"
    if [ -n "$display" ] && { { [ "$2" = portrait ] && [ "$height" -gt "$width" ]; } \
      || { [ "$2" = landscape ] && [ "$width" -gt "$height" ]; }; }; then
      break
    fi
    line=""
    sleep 0.5
  done
  [ -n "$line" ] || { echo "no $2 swapchain was built" >&2; return 1; }
  # Let the new swapchain present, and take the last one built for it.
  sleep 1.5
  line="$(latest)"
  echo "$line"
  display="$(sed -n 's/.*display \([0-9]*x[0-9]*\).*/\1/p' <<<"$line")"
  insets="$(sed -n 's/.* insets \([0-9,]*\) .*/\1/p' <<<"$line")"
  adb exec-out screencap > "$work/$1.raw"
  "$check" "$work/$1.raw" "$display" "$insets"
}

check portrait portrait
adb shell settings put system user_rotation 1
check landscape landscape
adb shell settings put system user_rotation 0
check portrait-again portrait
echo ">> sparkles:vulkan-wsi test pattern verified on $ANDROID_SERIAL."
