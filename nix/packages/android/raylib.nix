# raylib cross-built for Android (`PLATFORM_ANDROID`), one static archive per
# ABI. This is the rendering backend decision of the hue Android port: raylib's
# own Android platform (src/platforms/rcore_android.c) wraps
# android_native_app_glue + EGL/GLES2 and *owns* `android_main()`, calling the
# app's `main()` — so the whole desktop RaylibCanvas/FontSet stack carries over.
#
# Built straight from compiler invocations (the way raylib's own
# `src/Makefile PLATFORM=PLATFORM_ANDROID` does, minus make): nix's cmake cross
# hooks buy nothing here and the unit list is stable. Two facts the consumers
# (hello.nix, hue.nix) must honor, both from raylib's Android link recipe:
#
#   - the glue's `ANativeActivity_onCreate` is referenced only by the Android
#     framework, so final links need `-Wl,-u,ANativeActivity_onCreate` or the
#     archive member is never pulled in;
#   - rcore_android.c routes read-mode `fopen` through the APK asset manager
#     via a linker wrap — final links need `-Wl,--wrap=fopen` (it also
#     provides the `__real_fopen` the wrap calls through to).
#
# `src = pkgs.raylib.src` deliberately FOLLOWS the flake-pinned nixpkgs (raylib
# 6.0, a released tag) rather than pinning a rev of its own: the desktop build
# links nixpkgs' compiled `pkgs.raylib`, so taking the source from anywhere
# else would let the two raylibs drift apart —
# a worse failure than the one pinning would prevent, because the D bindings
# (raylib-d 6.0.1, hash-pinned) are shared by both.
#
# What that costs is a version assertion, below. Following an input means a
# routine `nix flake update` can move the source under a hand-written patch
# with per-file offsets, and under bindings whose struct layouts are fixed. The
# assert turns both into a loud eval failure with somewhere to start, instead
# of a confusing patch reject or — worse — an API-compatible bump that only
# shows up as a layout bug on-device.
{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      ndk = config.legacyPackages.androidNdk;

      # The snapshot this build's patch and the raylib-d 6.0.1 bindings were
      # both written against. Bump deliberately: re-check that
      # raylib-android-in-place-resize.patch still applies to rcore_android.c,
      # and that raylib.h's RAYLIB_VERSION still matches the bindings.
      expectedRaylib = "6.0";

      raylib-android =
        assert lib.assertMsg (pkgs.raylib.version == expectedRaylib) ''
          nix/packages/android/raylib.nix expects nixpkgs raylib
          ${expectedRaylib}, found ${pkgs.raylib.version}.

          The Android build patches rcore_android.c by offset and shares
          hash-pinned raylib-d 6.0.1 bindings with the desktop build, so a
          raylib bump needs both re-checked. Update `expectedRaylib` once it is.
        '';
        pkgs.stdenv.mkDerivation {
          pname = "raylib-android";
          version = pkgs.raylib.version;
          src = pkgs.raylib.src;

          # Upstream raylib — the 6.0 line, verified identical in the released 6.0
          # tag — never resizes on Android: APP_CMD_CONFIG_CHANGED is an
          # empty stub ("Check screen orientation here!"), APP_CMD_WINDOW_RESIZED
          # is unhandled, and the pause/resume rebind pins the buffer geometry to
          # the old size — so an in-place rotation keeps rendering the stale
          # orientation, compositor-scaled. The patch refreshes every
          # size-derived dimension (display/screen/render/fbo, buffers follow
          # the window, viewport, IsWindowResized) on
          # WINDOW_RESIZED/CONTENT_RECT_CHANGED/CONFIG_CHANGED and after a
          # context rebind, letting hue keep orientation|screenSize in
          # configChanges and rotate without an activity restart.
          patches = [ ./raylib-android-in-place-resize.patch ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            ${lib.concatMapStrings (t: ''
              mkdir -p out-${t.abi}
              for unit in rcore rshapes rtextures rtext rmodels raudio; do
                ${t.cc} -c src/$unit.c -o out-${t.abi}/$unit.o \
                  -DPLATFORM_ANDROID -DGRAPHICS_API_OPENGL_ES2 \
                  -Isrc -I${ndk.nativeAppGlue} \
                  -std=c99 -O2 -fPIC -ffunction-sections -fdata-sections
              done
              ${t.cc} -c ${ndk.nativeAppGlue}/android_native_app_glue.c \
                -o out-${t.abi}/android_native_app_glue.o -O2 -fPIC
              ${ndk.ar} rcs out-${t.abi}/libraylib.a out-${t.abi}/*.o
            '') (lib.attrValues ndk.targets)}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            ${lib.concatMapStrings (t: ''
              install -Dm644 out-${t.abi}/libraylib.a $out/lib/${t.abi}/libraylib.a
            '') (lib.attrValues ndk.targets)}
            install -Dm644 src/raylib.h src/raymath.h src/rlgl.h -t $out/include/

            runHook postInstall
          '';

          meta = {
            description = "raylib static library cross-built for Android (PLATFORM_ANDROID, GLES2), per ABI";
            homepage = "https://www.raylib.com";
            license = lib.licenses.zlib;
            platforms = [ "x86_64-linux" ];
          };
        };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.raylib-android = raylib-android;
    };
}
