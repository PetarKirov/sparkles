# `packages.hello-apk` — the M1 smoke-test APK (apps/hue/android/hello/): a
# raylib clear-color loop in D, cross-compiled per ABI with `ldc-android` and
# linked against `raylib-android`. Boots on a device/emulator to prove the
# entire risky spine (static druntime in a .so, android_main → D main handoff,
# EGL/GLES2, aapt2/zipalign/apksigner output, 16 KB page alignment) before any
# hue code rides on it.
#
# The D `import raylib;` resolves against the raylib-d 6.0.1 bindings fetched
# straight from the dub registry (same coordinates + sha as nix/dub-lock.json)
# — compiled in via `-i=raylib`, the same way the wasm builder handles
# registry deps.
{ inputs, lib, ... }:
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
      ldcAndroid = inputs.dlang-nix.packages.${system}.ldc-android;

      raylibDZip = inputs.dub-raylib-d;

      fs = lib.fileset;
      root = ../../..;
      src = fs.toSource {
        inherit root;
        fileset = root + "/apps/hue/android/hello";
      };

      libhello = pkgs.stdenv.mkDerivation {
        pname = "libhello-android";
        version = "0.1.0";
        inherit src;

        nativeBuildInputs = [
          ldcAndroid
          pkgs.unzip
        ];

        buildPhase = ''
          runHook preBuild

          mkdir -p dub-imports/raylib-d
          (cd dub-imports/raylib-d && unzip -q ${raylibDZip})
          # The direct source/ child of the unzipped package root (NOT `find
          # -name source`, which can surface example/source first).
          raylibDSrc="$(echo dub-imports/raylib-d/*/source)"

          ${lib.concatMapStrings (t: ''
            ldc2 -mtriple=${t.triple} -relocation-model=pic -O2 \
              -I="$raylibDSrc" -i=raylib \
              apps/hue/android/hello/main.d \
              ${config.packages.raylib-android}/lib/${t.abi}/libraylib.a \
              -shared -link-defaultlib-shared=false \
              -L-Wl,-u,ANativeActivity_onCreate \
              -L-Wl,--wrap=fopen \
              -L-llog -L-landroid -L-lEGL -L-lGLESv2 -L-lOpenSLES -L-lm -L-ldl \
              -L${ndk.pageAlignFlags} \
              -of=libhello-${t.abi}.so
          '') (lib.attrValues ndk.targets)}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          ${lib.concatMapStrings (t: ''
            install -Dm644 libhello-${t.abi}.so $out/lib/${t.abi}/libhello.so
          '') (lib.attrValues ndk.targets)}
          runHook postInstall
        '';

        # Keep the unstripped libraries: ndk-stack needs the symbols, and the
        # APK assembler below is the shipping artifact anyway.
        dontStrip = true;

        meta = {
          description = "M1 Android smoke-test shared library (D + raylib), per ABI";
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.libhello-android = libhello;
      packages.hello-apk = config.legacyPackages.buildAndroidApk {
        pname = "hello";
        manifest = ../../../apps/hue/android/hello/AndroidManifest.xml;
        libs = lib.mapAttrs' (name: t: {
          name = t.abi;
          value = {
            "libhello.so" = "${libhello}/lib/${t.abi}/libhello.so";
          };
        }) ndk.targets;
        description = "hue Android M1 smoke-test APK (D + raylib NativeActivity)";
      };
    };
}
