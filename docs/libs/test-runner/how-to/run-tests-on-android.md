# Run tests on Android

dub cannot cross-compile, so an Android test build skips it: the Nix builder
`legacyPackages.buildDAndroidTests`
(`nix/packages/android/build-d-android-tests.nix`) compiles a package's unittests into one executable per ABI (arm64-v8a and
x86_64) with `ldc2 -i`. The executable runs the tests through this runner, so
it takes the same flags and prints the same report as `dub test`.

## Declare the package

Call the builder from a file under `nix/packages/android/`, as
`font-tests.nix` does for
`sparkles:font`:

```nix
packages.font-android-tests = config.legacyPackages.buildDAndroidTests {
  pname = "font-android-tests";
  exeName = "font-tests";
  testedDirs = [ "libs/font/src" "libs/font/test" ];
  versions = [ "Have_expected" "Have_sparkles_base" ];
  dubDeps = [ { name = "expected"; src = inputs.dub-expected; } ];
};
```

- `testedDirs` are the directories whose modules are tested. The builder writes
  the `dub_test_root` module dub would generate from them: every module except
  `package.d`, which dub omits too.
- `srcDirs` adds `-I` paths for in-tree dependencies. The runner's own
  closure, `sparkles:base` and what it imports, is always added.
- `dubDeps` unzips registry dependencies from their flake inputs. Their own
  unittests are not built.

List the package in `androidPackageNames` and in the `all-android` aggregate
in `nix/packages/android/default.nix`, so CI builds it.

## Build and run

```bash
nix build .#font-android-tests
nix develop .#android -c hue-emulator -no-window &   # or a device on adb
adb push result/bin/x86_64/font-tests /data/local/tmp/
adb shell /data/local/tmp/font-tests -t 1
```

Environment variables the tests read, such as `SPARKLES_FONTS_PATH`, go on the
`adb shell` command line, and the files they name must be pushed too. A test
whose input is missing skips, as on the host.

## What differs from the host

- **Plain-text reports.** `sparkles:ui` stays off the import path, so the live
  progress region and the result tables fall back to plain lines.
- **No `@ctfe` probe.** There is no compiler on the device, so a package
  with `@ctfe` tests gets a "no D compiler found" notice and the probe is
  skipped.
- **Bench and perf modes degrade.** Counters, tracepoints and pressure files
  that Android does not expose are reported as missing capabilities.
