# Which Nix systems can BUILD the Android artifacts — the one answer every
# module in this directory (and nix/shells/android.nix) gates on.
#
# Three platforms meet in an Android build, and only one of them varies here:
#
#   build host  the machine running Nix: this file's question.
#   target      the device ABI (arm64-v8a, x86_64): `androidNdk.targets` in
#               ndk.nix, the same on every build host.
#   emulator    the ABI of the system image a host can boot, which follows the
#               host CPU: `androidSdk.emulatorAbi` in sdk.nix.
#
# A host can build Android exactly when the toolchain exists there, so the
# answer is read from dlang.nix, never restated: `ldc-android` is defined on
# the hosts the NDK ships a prebuilt LLVM for (x86_64-linux, and both Macs
# through one universal binary), and it carries that host's NDK paths. A list
# kept here would drift from the toolchain's — and a host added to the list
# before the toolchain supports it fails at build time instead of simply not
# offering the packages.
#
# A plain function of the flake-level `inputs`, not a perSystem config value:
# the modules gate the *existence* of their outputs on it, and reading `config`
# or `pkgs` for that would recurse (see nix/shells/android.nix).
{ inputs }:
system:
let
  ldcAndroid = (inputs.dlang-nix.packages.${system} or { }).ldc-android or null;
in
{
  supported = ldcAndroid != null;
  inherit ldcAndroid;
  # For `meta.platforms`: every build host, not just this one.
  platforms = if ldcAndroid != null then ldcAndroid.meta.platforms else [ ];
}
