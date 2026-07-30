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
# `src = pkgs.raylib.src` pins the exact 5.5-unstable snapshot the raylib-d
# 6.0.1 D bindings target (raylib.h RAYLIB_VERSION "6.0") — zero drift with
# the desktop build, which links nixpkgs' compiled `pkgs.raylib`.
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

      raylib-android = pkgs.stdenv.mkDerivation {
        pname = "raylib-android";
        version = pkgs.raylib.version;
        src = pkgs.raylib.src;

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
