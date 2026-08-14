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
          # Optional resource directory (a res/ tree: mipmap-*/, values/, …).
          # Compiled by aapt2 into a resources.arsc — see the buildPhase for the
          # two traps that come with having one at all.
          resDir ? null,
          # Debug builds get android:debuggable="true"; release builds do not.
          debug ? true,
          # Whether NIX signs the result. There are exactly three reachable
          # states, and the assertions below make that literal:
          #
          #   signed-debug    debug = true                the checked-in throwaway key
          #   signed-release  debug = false + keystore    a key from outside this repo
          #   unsigned        sign  = false               no signature at all
          #
          # The third exists because a *distribution* key cannot come near a
          # derivation: every input one references is copied into /nix/store,
          # which is world-readable and pushed to a public binary cache, so a
          # keystore handed to nix is a published private key. The F-Droid path
          # therefore stops after zipalign and apps/fdroid signs outside the
          # store — which is also the order apksigner wants, since it preserves
          # an already-aligned input's alignment. See docs/specs/hue/fdroid.md
          # (FDR1, FDR2).
          sign ? true,
          # Signing keystore (storepass/keypass "android"). Defaults to the
          # checked-in throwaway key for signed DEBUG builds only — a release
          # build has no default and must be given a key from outside this
          # repository, so the public one cannot be reached by omission.
          keystore ? (if debug && sign then inTreeDebugKeystore else null),
          # Overrides the manifest's package id, so two variants of the same
          # app can be installed side by side.
          renamePackage ? null,
          description ? "Android package",
        }:
        # Four guards. The first two keep `sign = false` an honest third state
        # rather than a fourth, overlapping one; the last two are the original
        # pair, now scoped to builds that actually sign. Together the failure
        # they prevent is "something distributable that nobody meant to
        # distribute" — signed with a public key, or unsigned by accident.
        #
        # Order matters: the third establishes `keystore != null` before the
        # fourth calls baseNameOf on it.
        assert lib.assertMsg (sign || !debug) ''
          buildAndroidApk: sign = false is only meaningful for a release build
          (debug = false). An unsigned APK cannot be installed, and a debuggable
          one must never be published, so the combination has no use.
        '';
        assert lib.assertMsg (sign || keystore == null) ''
          buildAndroidApk: sign = false takes no keystore. Nix must not see the
          signing key at all — /nix/store is world-readable and is pushed to a
          public binary cache. Sign the `-unsigned.apk` output outside nix; see
          apps/fdroid and docs/specs/hue/fdroid.md.
        '';
        assert lib.assertMsg (!sign || keystore != null) ''
          buildAndroidApk: a release APK (debug = false) needs a signing key
          from outside this repository. The checked-in key is public — anyone
          could publish an update over the result — so there is no default.
          To build one for signing elsewhere, pass sign = false instead.
        '';
        # Refused by NAME, which (unlike comparing path identity) also catches a
        # string built from `self.outPath`.
        assert lib.assertMsg (!sign || debug || builtins.baseNameOf keystore != inTreeDebugKeystoreName) ''
          buildAndroidApk: a release APK (debug = false) cannot be signed with
          ${inTreeDebugKeystoreName} — that key is checked in, and therefore
          public. Pass a key held outside this repository.
        '';
        let
          # An unsigned APK says so in BOTH names it has — the derivation's and
          # the file's — so nothing on disk can be mistaken for something
          # installable. (The same complaint the hue-apk-repo comment records:
          # two derivations that both emit `$out/hue.apk` are indistinguishable
          # once they reach ./result.)
          artifactName = pname + lib.optionalString (!sign) "-unsigned";
        in
        pkgs.stdenv.mkDerivation {
          pname = artifactName;
          inherit version;

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

            ${lib.optionalString (resDir != null) ''
              # NOT `aapt2 compile --dir`: aapt2 assigns resource IDs in input
              # order, and --dir's order is a filesystem walk. An explicit
              # LC_ALL=C-sorted list makes the resource table — and so the whole
              # APK — reproducible.
              mkdir -p compiled
              find ${resDir} -type f | LC_ALL=C sort > res-inputs.txt
              xargs -a res-inputs.txt ${sdk.buildTools}/aapt2 compile --no-crunch -o compiled/
              LC_ALL=C ls compiled/*.flat | LC_ALL=C sort > res-flats.txt
            ''}

            # --min/--target-sdk-version are *defaults* aapt2 applies only when
            # the manifest declares no <uses-sdk>. Ours deliberately does not,
            # so these are the single source of truth and cannot drift from the
            # API level the native code was actually compiled against.
            #
            # Two flags below exist only because we link a res/ tree:
            #
            #   -0 arsc   MANDATORY. An app targeting API 30+ must ship an
            #             UNCOMPRESSED resources.arsc or Android 11+ refuses to
            #             install it. aapt2 only stores it by default when
            #             minSdk >= 30, and ours is 26 — so without this the APK
            #             builds, signs, verifies, and then cannot be installed.
            #   --no-crunch
            #             skips aapt2's PNG re-encode. The rasters come from
            #             resvg already at their final size, so this only
            #             removes a transform from the reproducibility surface.
            #
            # Compiled resources are POSITIONAL arguments; `-R` is the *overlay*
            # form (last conflicting resource wins), which is not what we want.
            ${sdk.buildTools}/aapt2 link -o base.apk \
              --manifest ${manifest} \
              -I ${sdk.androidJar} \
              --min-sdk-version ${config.legacyPackages.androidNdk.minSdk} \
              --target-sdk-version ${sdk.platformVersion} \
              --version-code ${toString versionCode} \
              --version-name ${lib.escapeShellArg versionName} \
              --replace-version \
              --no-compile-sdk-metadata \
              ${lib.optionalString debug "--debug-mode"} \
              ${lib.optionalString (renamePackage != null) "--rename-manifest-package ${renamePackage}"} \
              ${lib.optionalString (assetsDir != null) "-A ${assetsDir}"} \
              ${lib.optionalString (resDir != null) "-0 arsc $(cat res-flats.txt)"}

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

            # -p page-aligns *uncompressed* shared objects inside the zip. The
            # libs above are deflated, so today this aligns nothing — which is
            # correct, because extractNativeLibs="true" means nothing is mmap'd
            # out of the APK in the first place; the 16 KB-page requirement is
            # met by max-page-size on each link (ndk.nix).
            #
            # The trap to remember: flipping extractNativeLibs to "false" (the
            # modern Play default) makes the alignment load-bearing, and this
            # line would STILL be a no-op until `zip` also gets `-0` for
            # lib/**/*.so. The APK would then fail to install on 16 KB devices.
            ${sdk.buildTools}/zipalign -p -f 4 base.apk aligned.apk

            ${
              if sign then
                ''
                  ${sdk.buildTools}/apksigner sign \
                    --ks ${keystore} --ks-pass pass:android \
                    --out out.apk aligned.apk
                ''
              else
                ''
                  # Deliberately no apksigner: see `sign` above. zipalign has
                  # already run and apksigner preserves an aligned input's
                  # alignment, so signing this later — outside nix, with a key
                  # nix never sees — is the documented order, not a shortcut.
                  mv aligned.apk out.apk
                ''
            }

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 out.apk $out/${artifactName}.apk
            runHook postInstall
          '';

          # What the artifact IS, so consumers (apps/fdroid, CI) read it off the
          # derivation instead of re-deriving it from a filename.
          passthru = {
            inherit
              versionCode
              versionName
              sign
              debug
              ;
            apkFileName = "${artifactName}.apk";
          };

          meta = {
            inherit description;
            platforms = [ "x86_64-linux" ];
          };
        };
    };
}
