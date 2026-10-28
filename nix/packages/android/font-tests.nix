# `packages.font-android-tests`: sparkles:font's unit tests as an Android
# executable per ABI (docs/specs/font, FTA7: the pure-D `library`
# configuration builds and passes its tests on Android), run by
# sparkles:test-runner (build-d-android-tests.nix).
#
# The link line holds only the NDK's libc, libm, libdl and liblog, which the
# static druntime needs — no font, shaping or graphics library. Run one with
#   adb push result/bin/x86_64/font-tests /data/local/tmp/ && \
#   adb shell /data/local/tmp/font-tests
{ inputs, lib, ... }:
let
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    { config, system, ... }:
    lib.optionalAttrs (androidHost system).supported {
      packages.font-android-tests = config.legacyPackages.buildDAndroidTests {
        pname = "font-android-tests";
        exeName = "font-tests";
        testedDirs = [
          "libs/font/src"
          "libs/font/test"
        ];
        # The catalog's tests read real files through the VFS's blocking backend.
        srcDirs = [
          "libs/image/src"
          "libs/event-horizon-sys/src"
        ];
        versions = [
          "Have_expected"
          "Have_sparkles_base"
          "Have_sparkles_event_horizon_sys"
          "Have_sparkles_image"
        ];
        dubDeps = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "sparkles:font unit tests as Android executables, per ABI";
      };

      # The `engine-unittest` configuration: the shaper and its tests, linked
      # against the pinned, patched HarfBuzz built for Android (shaping.nix),
      # whose FreeType, PNG and zlib follow it on the static link line. Run
      # with the bundle pushed, as SPARKLES_FONTS_PATH names it.
      packages.font-engine-android-tests = config.legacyPackages.buildDAndroidTests {
        pname = "font-engine-android-tests";
        exeName = "font-engine-tests";
        testedDirs = [
          "libs/font/src"
          "libs/font/src-engine"
          "libs/font/test"
          "libs/font/test-engine"
        ];
        srcDirs = [
          "libs/image/src"
          "libs/event-horizon-sys/src"
        ];
        versions = [
          "Have_expected"
          "Have_sparkles_base"
          "Have_sparkles_event_horizon_sys"
          "Have_sparkles_image"
          "SparklesFontEngine"
        ];
        dubDeps = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        extraLinkFlags =
          t:
          let
            hb = config.packages.harfbuzz-android;
            ft = config.packages.freetype-android;
          in
          map (lib: "-L${lib}") [
            "${hb}/lib/${t.abi}/libharfbuzz.a"
            "${ft}/lib/${t.abi}/libfreetype.a"
            "${ft}/lib/${t.abi}/libpng16.a"
            "${ft}/lib/${t.abi}/libz.a"
          ];
        description = "sparkles:font engine unit tests as Android executables, per ABI";
      };
    };
}
