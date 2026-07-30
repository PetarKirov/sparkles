# `legacyPackages.buildAndroidApk` — the generic nix-native APK assembler:
# aapt2 link (resources + manifest against android.jar) → native libs zipped in
# → `zipalign -p` (page-aligns uncompressed .so entries) → `apksigner`. No
# Gradle, no Java sources, no DEX: the manifests here declare
# `android:hasCode="false"` and launch the framework's NativeActivity, which
# loads the app's `lib<name>.so` directly.
#
# The signing keystore is a *checked-in throwaway debug key*
# (apps/hue/android/debug.keystore, storepass/keypass "android" — the same
# convention as Gradle's ~/.android/debug.keystore). Checked in on purpose:
# keytool output is nondeterministic, so a per-build keystore would change the
# signature every rebuild and turn every `adb install -r` into an
# uninstall+reinstall that wipes app data.
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
      sdk = config.legacyPackages.androidSdk;
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      legacyPackages.buildAndroidApk =
        {
          pname,
          version ? "0.1.0",
          # Path to the AndroidManifest.xml.
          manifest,
          # Native libraries per ABI: { "arm64-v8a" = { "libfoo.so" = <path>; … }; … }.
          libs,
          # Optional assets directory (becomes the APK's assets/ tree).
          assetsDir ? null,
          # Signing keystore (storepass/keypass "android").
          keystore,
          description ? "Android package",
        }:
        pkgs.stdenv.mkDerivation {
          inherit pname version;

          dontUnpack = true;

          nativeBuildInputs = [
            pkgs.zip
            pkgs.jdk_headless # apksigner is a Java tool
          ];

          buildPhase = ''
            runHook preBuild

            ${lib.concatStrings (
              lib.mapAttrsToList (
                abi: sos:
                lib.concatStrings (
                  lib.mapAttrsToList (name: path: ''
                    install -Dm644 ${path} apk/lib/${abi}/${name}
                  '') sos
                )
              ) libs
            )}

            ${sdk.buildTools}/aapt2 link -o base.apk \
              --manifest ${manifest} \
              -I ${sdk.androidJar} \
              --min-sdk-version ${config.legacyPackages.androidNdk.minSdk} \
              --target-sdk-version ${sdk.platformVersion} \
              ${lib.optionalString (assetsDir != null) "-A ${assetsDir}"}

            # aapt2 has no flag for native libs; zip the lib/ tree in directly.
            (cd apk && zip -q -r ../base.apk lib)

            # -p page-aligns uncompressed shared objects inside the zip — the
            # install-time mmap requirement; the .so files themselves carry
            # max-page-size=16384 from their links (see ndk.nix).
            ${sdk.buildTools}/zipalign -p -f 4 base.apk aligned.apk

            ${sdk.buildTools}/apksigner sign \
              --ks ${keystore} --ks-pass pass:android \
              --out signed.apk aligned.apk

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 signed.apk $out/${pname}.apk
            runHook postInstall
          '';

          meta = {
            inherit description;
            platforms = [ "x86_64-linux" ];
          };
        };
    };
}
