# `legacyPackages.buildAndroidApk` — the generic nix-native APK assembler:
# aapt2 link (resources + manifest against android.jar) → native libs zipped in
# → `zipalign -p` (page-aligns uncompressed .so entries) → `apksigner`. No
# Gradle, no Java sources, no DEX: the manifests here declare
# `android:hasCode="false"` and launch the framework's NativeActivity, which
# loads the app's `lib<name>.so` directly.
#
# Debug vs release (`debug ? true`):
#
#   debug    android:debuggable="true" injected by aapt2 --debug-mode, signed
#            with the checked-in throwaway key. What `adb shell run-as` and the
#            on-device golden workflow (AND9) need.
#   release  no debuggable flag, and the keystore MUST come from outside the
#            tree — passing `debug = false` without one is an eval error, not a
#            silent fall back to the public key.
#
# The checked-in key (apps/hue/android/debug-only.keystore, storepass/keypass
# "android") is a *freshly generated throwaway*, not a well-known one — there
# is no universal Android debug private key; Gradle generates ~/.android/
# debug.keystore per machine and never commits it. It is checked in on purpose:
# keytool output is nondeterministic, so a per-build keystore would change the
# signature every rebuild and turn every `adb install -r` into an
# uninstall+reinstall that wipes app data.
#
# Because it is public, anything signed with it can be impersonated: an APK
# built by anyone with this repo satisfies Android's "same package name + same
# certificate" update rule and can replace an installed hue in place. That is
# acceptable for dogfooding and unacceptable for distribution, which is what
# the `release` path exists to enforce.
{ inputs, lib, ... }:
let
  # The ONE place APK version metadata is decided.
  #
  # docs/guidelines/release.md makes the git tag the only place a version
  # lives, and nix cannot read tags without import-from-derivation — so there
  # is deliberately nothing in-tree to read. What the flake does expose is its
  # own `lastModifiedDate` (YYYYMMDDhhmmss), which is monotonic and
  # deterministic, so the *code* comes from its date part.
  #
  # `versionCode` is what every distribution channel orders builds by, and it
  # must never go backwards; a date is monotonic by construction and stays
  # inside the int32 ceiling until the year 2147. `versionName` is the
  # human-facing string, and carries the same date so an installed build can
  # be traced back to a tree state without a tag lookup.
  #
  # A dirty tree has no `lastModifiedDate`; the fallback keeps eval working
  # and is obviously not a real build.
  stamp = inputs.self.lastModifiedDate or "19700101000000";
  apkVersion = {
    code = lib.toInt (builtins.substring 0 8 stamp);
    name = "0.0.0+${builtins.substring 0 8 stamp}";
  };
in
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
      inTreeDebugKeystore = ../../../apps/hue/android/debug-only.keystore;
      inTreeDebugKeystoreName = baseNameOf (toString inTreeDebugKeystore);
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      legacyPackages.buildAndroidApk =
        {
          pname,
          version ? apkVersion.name,
          # User-visible version string, and the monotonic integer every
          # distribution channel orders builds by. Both are injected by aapt2
          # (`--replace-version`), so no manifest declares them — see
          # `apkVersion` for where they come from.
          versionName ? version,
          versionCode ? apkVersion.code,
          # Path to the AndroidManifest.xml.
          manifest,
          # Native libraries per ABI: { "arm64-v8a" = { "libfoo.so" = <path>; … }; … }.
          libs,
          # Optional assets directory (becomes the APK's assets/ tree).
          assetsDir ? null,
          # Debug builds get android:debuggable="true"; release builds do not.
          debug ? true,
          # Signing keystore (storepass/keypass "android"). Defaults to the
          # checked-in throwaway key for DEBUG builds only — a release build
          # has no default and must be given a key from outside this
          # repository, so the public one cannot be reached by omission.
          keystore ? (if debug then inTreeDebugKeystore else null),
          # Overrides the manifest's package id, so two variants of the same
          # app can be installed side by side.
          renamePackage ? null,
          description ? "Android package",
        }:
        # Two independent guards, because the failure they prevent is
        # "a distributed APK signed with a public key":
        #   * omission — a release build has no default keystore at all;
        #   * explicit passing — refused by name, which (unlike comparing path
        #     identity) also catches a string built from `self.outPath`.
        assert lib.assertMsg (keystore != null) ''
          buildAndroidApk: a release APK (debug = false) needs a signing key
          from outside this repository. The checked-in key is public — anyone
          could publish an update over the result — so there is no default.
        '';
        assert lib.assertMsg (debug || builtins.baseNameOf keystore != inTreeDebugKeystoreName) ''
          buildAndroidApk: a release APK (debug = false) cannot be signed with
          ${inTreeDebugKeystoreName} — that key is checked in, and therefore
          public. Pass a key held outside this repository.
        '';
        pkgs.stdenv.mkDerivation {
          inherit pname version;

          dontUnpack = true;

          nativeBuildInputs = [
            pkgs.zip
            pkgs.jdk_headless # apksigner is a Java tool
            pkgs.strip-nondeterminism
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

            # --min/--target-sdk-version are *defaults* aapt2 applies only when
            # the manifest declares no <uses-sdk>. Ours deliberately does not,
            # so these are the single source of truth and cannot drift from the
            # API level the native code was actually compiled against.
            ${sdk.buildTools}/aapt2 link -o base.apk \
              --manifest ${manifest} \
              -I ${sdk.androidJar} \
              --min-sdk-version ${config.legacyPackages.androidNdk.minSdk} \
              --target-sdk-version ${sdk.platformVersion} \
              --version-code ${toString versionCode} \
              --version-name ${lib.escapeShellArg versionName} \
              --replace-version \
              ${lib.optionalString debug "--debug-mode"} \
              ${lib.optionalString (renamePackage != null) "--rename-manifest-package ${renamePackage}"} \
              ${lib.optionalString (assetsDir != null) "-A ${assetsDir}"}

            # `install` without -p stamps the destination with the CURRENT
            # time, and zip records that mtime in every local file header — so
            # the APK differed on every rebuild and `nix build --rebuild`
            # reported the derivation as non-deterministic. Clamp to
            # SOURCE_DATE_EPOCH (nixpkgs sets it to 1980-01-01, which is also
            # zip's own floor, so nothing is silently rounded).
            find apk -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

            # aapt2 has no flag for native libs; zip the lib/ tree in directly.
            (cd apk && zip -q -r -X ../base.apk lib)

            # Normalizes what neither of the above controls: aapt2's own entry
            # timestamps, and zip's extra fields. Must run BEFORE signing — the
            # v2 signature covers the whole archive, so rewriting entries after
            # apksigner would invalidate it.
            strip-nondeterminism --type zip base.apk

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
