# Opt-in Android cross-compilation + APK dev shell.
#
# Kept separate from the default shell on purpose: it pulls in the *unfree*
# Android SDK/NDK and it is large. It serves the hue Android port (see
# nix/packages/android/) and the mobile-targeted research examples under
# `docs/research/window-system-integration/os-apis/android/`; both are out of
# CI scope. Enter it with:
#
#     nix develop .#android
#
# It provides the `ldc-android` cross-compiler (from dlang.nix; aarch64 +
# x86_64 Android targets and the host), the rest of the host D toolchain, the
# SDK tooling the APK workflow needs (adb from platform-tools, aapt2/zipalign/
# apksigner from build-tools — via nix/packages/android/sdk.nix), and the env
# vars the build commands expect (`NDK`, `ANDROID_NDK_ROOT`, `ANDROID_CC*`).
#
# The NDK itself is *not* re-derived here: we reuse the exact NDK that
# `ldc-android` links its runtimes against (exposed via its `ndkRoot`
# passthru), so the headers/sysroot used to compile match the one used to
# link. The SDK-side tooling comes from the scoped androidenv composition in
# nix/packages/android/sdk.nix — the NDK deliberately never comes from there.
#
# `lib` is taken from the flake-level module args (nixpkgs.lib), NOT `pkgs.lib`:
# gating the *existence* of `devShells.android` on `pkgs.lib` would make the
# module's option structure depend on `pkgs`, which depends back on this module
# (infinite recursion).
{ lib, ... }:
{
  perSystem =
    {
      system,
      pkgs,
      inputs',
      config,
      ...
    }:
    let
      # `ldc-android` is a complete LDC (it cross-compiles for Android aarch64
      # + x86_64 *and* builds for the host), so it replaces the plain host
      # `ldc` here — both provide `bin/ldc2`, and we want the cross-capable
      # one to win.
      ldcAndroid = inputs'.dlang-nix.packages.ldc-android;

      ndkRoot = ldcAndroid.ndkRoot;
      ndkClangBin = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64/bin";

      androidSdk = config.legacyPackages.androidSdk;

      # The same per-ABI cross table the package derivations compile against
      # (nix/packages/android/ndk.nix), so the shell's ANDROID_CC* cannot
      # target a different API level than the artifacts do.
      androidNdk = config.legacyPackages.androidNdk;

      # Workflow helpers (thin glue over adb/emulator; anything with real
      # logic belongs in apps/ci per the repo rule).
      hueAdbInstall = pkgs.writeShellApplication {
        name = "hue-adb-install";
        text = ''
          # usage: hue-adb-install [app.apk] [package/activity]
          apk="''${1:-result/hue.apk}"
          component="''${2:-dev.sparkles.hue/android.app.NativeActivity}"
          adb install -r "$apk"
          adb shell am start -n "$component"
        '';
      };
      hueLogcat = pkgs.writeShellApplication {
        name = "hue-logcat";
        text = ''
          # The port's log surface: D code logs under tag "hue", raylib under
          # "raylib"; AndroidRuntime/DEBUG carry crashes and tombstones.
          exec adb logcat -v color -s hue raylib AndroidRuntime DEBUG "$@"
        '';
      };
      hueEmulator = pkgs.writeShellApplication {
        name = "hue-emulator";
        text = ''
          # Boots the x86_64 API-35 AVD (created on first run). AVD state
          # lives under ~/.android-sparkles, off the default ~/.android.
          export ANDROID_SDK_ROOT=${androidSdk.devSdkRoot}
          : "''${ANDROID_USER_HOME:=$HOME/.android-sparkles}"
          export ANDROID_USER_HOME
          export ANDROID_AVD_HOME="$ANDROID_USER_HOME/avd"
          export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
          mkdir -p "$ANDROID_AVD_HOME"
          if [ ! -d "$ANDROID_AVD_HOME/hue.avd" ]; then
            avdmanager=("$ANDROID_SDK_ROOT"/cmdline-tools/*/bin/avdmanager)
            echo no | "''${avdmanager[0]}" create avd -n hue \
              -k "system-images;android-35;google_apis;x86_64"
          fi
          exec "$ANDROID_SDK_ROOT"/emulator/emulator -avd hue "$@"
        '';
      };

      androidShell = pkgs.mkShell {
        packages = [
          pkgs.pkg-config
          # Cross-capable LDC (Android aarch64/x86_64 + host), plus the rest
          # of the D toolchain. `ldc-android` stands in for the host `ldc`.
          ldcAndroid
          pkgs.dub
          pkgs.dtools
          hueAdbInstall
          hueLogcat
          hueEmulator
        ];

        shellHook = ''
          export ANDROID_NDK_ROOT=${ndkRoot}
          export ANDROID_NDK_HOME=${ndkRoot}
          export NDK=${ndkRoot}
          export ANDROID_CC=${androidNdk.targets."arm64-v8a".cc}
          export ANDROID_CC_ARM64=${androidNdk.targets."arm64-v8a".cc}
          export ANDROID_CC_X86_64=${androidNdk.targets."x86_64".cc}
          export ANDROID_SDK_ROOT=${androidSdk.devSdkRoot}
          export PATH=${ndkClangBin}:${androidSdk.platformTools}:${androidSdk.buildTools}:$PATH
        '';
      };
    in
    # The NDK ships prebuilt for an x86_64-linux host only.
    lib.optionalAttrs (system == "x86_64-linux") {
      devShells.android = androidShell;
    };
}
