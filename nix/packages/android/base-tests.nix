# `packages.base-android-tests`: sparkles:base's unit tests per ABI, run by
# sparkles:test-runner (build-d-android-tests.nix). This is where base's
# Bionic code paths — `sparkles.base.sync`'s parker, the text stack — are
# compiled and run against the real C library instead of glibc.
#
# The tests are linked as `libbase-tests.so` and started by a launcher that
# `dlopen`s it, as the terminal and hue APKs load theirs: druntime's TLS
# range for a loaded module is what `base.tlsGcScan.coversModuleThreadLocals`
# checks (ldc-developers/ldc#5311), and an executable would not exercise it.
#
# Five tests fail on both ABIs: four `float_conv` tests and
# `layout_units.physical.tiesAndRange`. Android's `real` is IEEE binary128
# (quad), a width those modules do not handle yet. Run them with
#   adb push result/bin/arm64-v8a/. /data/local/tmp/base-tests/ && \
#   adb shell /data/local/tmp/base-tests/base-tests
# (`x86_64` for the emulator).
{ inputs, lib, ... }:
let
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    { config, system, ... }:
    lib.optionalAttrs (androidHost system).supported {
      packages.base-android-tests = config.legacyPackages.buildDAndroidTests {
        pname = "base-android-tests";
        exeName = "base-tests";
        sharedLibrary = true;
        testedDirs = [
          "libs/base/src"
        ];
        versions = [
          "Have_expected"
          "Have_sparkles_base"
          "Have_sparkles_metadata"
          "Have_sparkles_reflection"
        ];
        dubDeps = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "sparkles:base unit tests as Android executables, per ABI";
      };
    };
}
