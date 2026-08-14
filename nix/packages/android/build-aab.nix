# `legacyPackages.buildAndroidAab` — the Android App Bundle assembler, peer to
# `buildAndroidApk`.
#
# Google Play has required the bundle format for new apps since 2021, so the
# Play channel cannot take the APK. Same inputs, different container:
#
#   APK   aapt2 link            → binary resources.arsc, zip, zipalign
#   AAB   aapt2 link --proto-format → resources.pb, module layout, bundletool
#
# Play generates per-device APKs from the bundle, which is where the format
# pays for itself: a device downloads one ABI instead of both.
#
# Nothing here signs, for the same reason `buildAndroidApk` does not: every
# input a derivation references lands in /nix/store, which is world-readable
# and pushed to a public cache. An AAB is JAR-signed with the *upload* key
# (which Play lets you reset, unlike the app signing key it holds itself), and
# that happens outside nix — see docs/specs/hue/fdroid.md.
#
# Two findings from getting this working, both non-obvious:
#
#   * A bundle with NO `dex/` directory is accepted. hue is a pure
#     NativeActivity app — `hasCode="false"`, no bytecode anywhere — which is
#     unusual enough that it was the main risk in the Play path. bundletool
#     1.18.2 builds it and generates installable splits from it.
#   * bundletool ships its own aapt2 and extracts it to /tmp, where a
#     dynamically linked binary cannot run on NixOS (exit 127, reported as an
#     opaque "Stream closed"). `--aapt2` must point at the nixpkgs one.
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
      legacyPackages.buildAndroidAab =
        {
          pname,
          versionName,
          versionCode,
          manifest,
          libs,
          assetsDir ? null,
          resDir ? null,
          # A bundle is only ever a published artifact, so it always strips —
          # see the note in build-apk.nix for why this is the artifact's
          # property and not the library's.
          stripLibs ? true,
          description ? "Android App Bundle",
        }:
        pkgs.stdenv.mkDerivation {
          pname = "${pname}-unsigned";
          version = versionName;

          dontUnpack = true;

          nativeBuildInputs = [
            pkgs.zip
            pkgs.unzip
            pkgs.jdk_headless # bundletool is a Java tool
            pkgs.bundletool
            pkgs.strip-nondeterminism
          ];

          buildPhase = ''
            runHook preBuild

            ${lib.optionalString (resDir != null) ''
              # Same explicitly sorted input list as the APK path: aapt2 assigns
              # resource IDs in input order, and `--dir` walks the filesystem.
              mkdir -p compiled
              find ${resDir} -type f | LC_ALL=C sort > res-inputs.txt
              xargs -a res-inputs.txt ${sdk.buildTools}/aapt2 compile --no-crunch -o compiled/
              LC_ALL=C ls compiled/*.flat | LC_ALL=C sort > res-flats.txt
            ''}

            # `--proto-format` is what makes this a bundle rather than an APK:
            # the manifest and resource table come out as protobuf, which is
            # what bundletool consumes.
            ${sdk.buildTools}/aapt2 link --proto-format -o linked.apk \
              --manifest ${manifest} \
              -I ${sdk.androidJar} \
              --min-sdk-version ${config.legacyPackages.androidNdk.minSdk} \
              --target-sdk-version ${sdk.platformVersion} \
              --version-code ${toString versionCode} \
              --version-name ${lib.escapeShellArg versionName} \
              --replace-version \
              --no-compile-sdk-metadata \
              ${lib.optionalString (resDir != null) "$(cat res-flats.txt)"}

            # Rearrange aapt2's output into the module layout bundletool wants.
            # Note there is deliberately no dex/ — see the header.
            mkdir -p module/manifest
            unzip -q linked.apk -d linked
            mv linked/AndroidManifest.xml module/manifest/AndroidManifest.xml
            mv linked/resources.pb module/resources.pb
            if [ -d linked/res ]; then mv linked/res module/res; fi

            ${lib.optionalString (assetsDir != null) ''
              mkdir -p module/assets
              cp -r ${assetsDir}/. module/assets/
            ''}

            ${lib.concatStrings (
              lib.mapAttrsToList (
                abi: sos:
                lib.concatStrings (
                  lib.mapAttrsToList (name: path: ''
                    install -Dm644 ${path} module/lib/${abi}/${name}
                    ${lib.optionalString stripLibs "${config.legacyPackages.androidNdk.strip} --strip-unneeded module/lib/${abi}/${name}"}
                  '') sos
                )
              ) libs
            )}

            # Store native libraries COMPRESSED. bundletool's default is
            # uncompressed so the loader can mmap them in place, which is better
            # for installed footprint and much worse for download: measured on
            # this app, the arm64 split goes 10.3 MB → 65.9 MB, taking the
            # per-device download from 54 MB to 105 MB and making the bundle
            # *worse* than the single fat APK it replaces. These libraries
            # compress unusually well, so the default is the wrong trade here.
            cat > bundle-config.json <<'EOF'
            {
              "optimizations": {
                "uncompressNativeLibraries": { "enabled": false }
              }
            }
            EOF

            find module -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
            (cd module && zip -q -r -X ../base.zip .)
            strip-nondeterminism --type zip base.zip

            bundletool build-bundle \
              --modules=base.zip \
              --config=bundle-config.json \
              --output=out.aab

            strip-nondeterminism --type zip out.aab

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 out.aab $out/${pname}-unsigned.aab
            runHook postInstall
          '';

          passthru = {
            inherit versionCode versionName;
            aabFileName = "${pname}-unsigned.aab";
          };

          meta = {
            inherit description;
            platforms = [ "x86_64-linux" ];
          };
        };
    };
}
