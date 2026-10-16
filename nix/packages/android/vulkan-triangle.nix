# The sparkles:vulkan-wsi Android triangle (libs/vulkan-wsi/examples/android-triangle.d):
# the shared Vulkan renderer presenting on the native sparkles:wsi Android
# backend through `VK_KHR_android_surface`. Its verdict goes to logcat under
# the tag `sparkles-wsi`; libs/wsi/scripts/verify-android-emulator.sh runs it
# after the WSI smoke.
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
      triangleLib = config.legacyPackages.buildDAndroidLib {
        pname = "libvktriangle-android";
        libName = "vktriangle";
        mainFile = "libs/vulkan-wsi/examples/android-triangle.d";
        srcDirs = sources.libsClosure [ "vulkan-wsi" ] ++ [
          "libs/android/c"
          "libs/vulkan-wsi/examples"
          "libs/vulkan-wsi/src/shaders"
        ];
        stringImportDirs = [ "libs/vulkan-wsi/src/shaders" ];
        # `-i` reaches the Vulkan ImportC module through its D importers; its
        # header comes from the NDK sysroot, and `libvulkan.so` is loaded at
        # run time (`sparkles.vulkan.loader`), so nothing links it.
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
          "Have_sparkles_vulkan"
          "Have_sparkles_vulkan_wsi"
          "Have_sparkles_wsi"
        ];
        dubDeps = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "the sparkles:vulkan-wsi Android triangle as a shared library";
      };
    in
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages.vulkan-wsi-android-triangle-apk = config.legacyPackages.buildAndroidApk {
        pname = "vulkan-wsi-android-triangle";
        manifest = ../../../libs/vulkan-wsi/examples/android/AndroidManifest.xml;
        libs = lib.mapAttrs' (name: t: {
          name = t.abi;
          value."libvktriangle.so" = "${triangleLib}/lib/${t.abi}/libvktriangle.so";
        }) ndk.targets;
        targetSdk = 29;
        description = "sparkles:vulkan-wsi triangle on the native Android backend";
      };
    };
}
