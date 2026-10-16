# The sparkles:wsi Android smoke (libs/wsi/examples/android-hosted-smoke.d): the
# native backend owning the activity with no raylib glue, driven through the
# shared conformance and clipboard suites. Its results go to logcat under the
# tag `sparkles-wsi`; libs/wsi/scripts/verify-android-emulator.sh runs it.
{
  lib,
  inputs,
  ...
}:
let
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    {
      config,
      system,
      ...
    }:
    let
      ndk = config.legacyPackages.androidNdk;
      sources = config.legacyPackages.sparklesSources;
      smokeLib = config.legacyPackages.buildDAndroidLib {
        pname = "libwsismoke-android";
        libName = "wsismoke";
        mainFile = "libs/wsi/examples/android-hosted-smoke.d";
        srcDirs = sources.libsClosure [ "wsi" ] ++ [
          "libs/android/c"
          "libs/wsi/examples"
        ];
        staticLibs = abi: [ "${config.packages.libkqueue-android}/lib/${abi}/libkqueue.a" ];
        raylibGlue = false;
        versions = [
          "Have_expected"
          "Have_sparkles_android"
          "Have_sparkles_base"
          "Have_sparkles_event_horizon"
          "Have_sparkles_input"
          "Have_sparkles_metadata"
          "Have_sparkles_reflection"
          "Have_sparkles_wsi"
        ];
        dubDeps = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "the sparkles:wsi Android smoke as a shared library";
      };
    in
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages.wsi-android-smoke-apk = config.legacyPackages.buildAndroidApk {
        pname = "wsi-android-smoke";
        manifest = ../../../libs/wsi/examples/android/AndroidManifest.xml;
        libs = lib.mapAttrs' (name: t: {
          name = t.abi;
          value."libwsismoke.so" = "${smokeLib}/lib/${t.abi}/libwsismoke.so";
        }) ndk.targets;
        targetSdk = 29;
        description = "sparkles:wsi Android backend smoke (conformance + clipboard)";
      };
    };
}
