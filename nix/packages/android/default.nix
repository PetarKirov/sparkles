# The Android packaging tree for the hue port: SDK tooling (sdk.nix), the
# per-ABI NDK cross-compilation table (ndk.nix), and — as the port progresses —
# the cross-built native dependencies (raylib, tree-sitter, grammar parsers,
# libghostty-vt), the `libhue.so` build, and the nix-native APK assembly
# (aapt2 + zipalign + apksigner; no Gradle, no Java — a pure NativeActivity
# APK with `hasCode="false"`).
#
# Everything in here is opt-in, x86_64-linux-only (the NDK/SDK ship prebuilt
# for that host alone), and pulls *unfree* Android SDK components through a
# scoped nixpkgs import — nothing in the default package set references it.
{
  imports = [
    ./build-apk.nix
    ./hello.nix
    ./ndk.nix
    ./raylib.nix
    ./sdk.nix
  ];
}
