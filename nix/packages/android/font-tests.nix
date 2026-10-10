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
        versions = [
          "Have_expected"
          "Have_sparkles_base"
        ];
        dubDeps = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "sparkles:font unit tests as Android executables, per ABI";
      };
    };
}
