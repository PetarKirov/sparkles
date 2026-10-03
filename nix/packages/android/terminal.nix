# The terminal's Android build (docs/specs/terminal/android.md):
#
#   packages.libterminal-android   apps/terminal as lib<abi>/libterminal.so
#   legacyPackages.mkTerminalApk   the APK, parameterized by app id, label,
#                                  icon and session (the D5 data-driven APK)
#   packages.terminal-apk          the plain terminal: /system/bin/sh
#
# The nix-on-droid app is a `mkTerminalApk` call in the nix-on-droid flake,
# with its own app id, label, icon and bootstrap URL — nothing in sparkles
# knows those values.
{ inputs, lib, ... }:
let
  # Whether this system can build Android at all (./host.nix).
  androidHost = import ./host.nix { inherit inputs; };
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
      ndk = config.legacyPackages.androidNdk;
      sources = config.legacyPackages.sparklesSources;
      fonts = config.legacyPackages.sparklesFonts;

      libterminal = config.legacyPackages.buildDAndroidLib {
        pname = "libterminal-android";
        libName = "terminal";
        mainFile = "apps/terminal/src/app.d";
        srcDirs = sources.srcClosure "apps/terminal" ++ [ "libs/android/c" ];
        cFiles = [
          "libs/android/c/jni_c.c"
          "libs/ghostty/src/sparkles/ghostty/ghostty_modes.c"
          "libs/raylib-text/src/sparkles/raylib_text/shaping_c.c"
        ];
        # dub's version set for `:terminal`'s `application` configuration
        # (`dub describe :terminal --data=versions`), plus sparkles:android.
        versions = [
          "UiAppGui"
          # sparkles:ui's `gpu-effects` configuration, which dub would select
          # through ui-raylib; its GLSL comes prebuilt from `ui-shaders`.
          "SparklesUiGpuEffects"
          "Have_bolts"
          "Have_expected"
          "Have_optional"
          "Have_raylib_d"
          "Have_sparkles_android"
          "Have_sparkles_base"
          "Have_sparkles_core_cli"
          "Have_sparkles_event_horizon"
          "Have_sparkles_fuzzy"
          "Have_sparkles_ghostty"
          "Have_sparkles_input"
          "Have_sparkles_metadata"
          "Have_sparkles_raylib_text"
          "Have_sparkles_reflection"
          "Have_sparkles_shader"
          "Have_sparkles_terminal"
          "Have_sparkles_terminal_view"
          "Have_sparkles_ui"
          "Have_sparkles_ui_app"
          "Have_sparkles_ui_raylib"
          "Have_sparkles_wired"
        ];
        dubDeps = [
          {
            name = "raylib-d";
            src = inputs.dub-raylib-d;
          }
          {
            name = "expected";
            src = inputs.dub-expected;
          }
          {
            name = "optional";
            src = inputs.dub-optional;
          }
          {
            name = "bolts";
            src = inputs.dub-bolts;
          }
        ];
        stringImportDirs = [
          "libs/ui/src/sparkles/ui/shaders"
          "${config.packages.ui-shaders}"
        ];
        cIncludes = [
          "${config.packages.libghostty-vt-android}/include"
          "${config.packages.freetype-android}/include/freetype2"
          "${config.packages.harfbuzz-android}/include/harfbuzz"
        ];
        staticLibs = abi: [
          "${config.packages.raylib-android}/lib/${abi}/libraylib.a"
          "${config.packages.harfbuzz-android}/lib/${abi}/libharfbuzz.a"
          "${config.packages.freetype-android}/lib/${abi}/libfreetype.a"
          "${config.packages.freetype-android}/lib/${abi}/libpng16.a"
          "${config.packages.freetype-android}/lib/${abi}/libz.a"
          "${config.packages.libghostty-vt-android}/lib/${abi}/libghostty-vt.a"
          "${config.packages.libkqueue-android}/lib/${abi}/libkqueue.a"
        ];
        description = "apps/terminal as an Android shared library, per ABI";
      };

      # Nerd-icon coverage and a classic fallback; Maple Mono NF CN (hue's
      # face) is left out — its CJK glyphs are most of the bundle's 61 MB.
      bundledFonts = [
        "FiraCodeNerdFontMono-Regular.ttf"
        "FiraCodeNerdFontMono-Bold.ttf"
        "DejaVuSansMono.ttf"
        "DejaVuSansMono-Bold.ttf"
        "DejaVuSansMono-Oblique.ttf"
        "DejaVuSansMono-BoldOblique.ttf"
      ];

      # `session.conf` (session.d parses it): KEY=VALUE lines.
      sessionConf =
        session:
        pkgs.writeText "session.conf" (
          lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${toString v}\n") session)
        );

      # The asset bundle: fonts with their charset sidecars — the only part
      # `sparkles.android.assets` extracts (the manifest lists fonts/ alone,
      # so nothing else lands beside the user's home) — plus session.conf and
      # NOTICE, read in place from the APK.
      mkAssets =
        session: bootstraps:
        pkgs.runCommand "terminal-android-assets" { } ''
          mkdir -p $out/fonts
          ${lib.concatStrings (
            lib.mapAttrsToList (arch: zip: ''
              mkdir -p $out/bootstrap
              cp ${zip} $out/bootstrap/bootstrap-${arch}.zip
            '') bootstraps
          )}
          ${lib.concatMapStrings (f: ''
            cp ${fonts.fontBundle}/fonts/${f} ${fonts.fontBundle}/fonts/${f}.charset $out/fonts/
          '') bundledFonts}
          # All script fallbacks and emoji are shared with the desktop bundle.
          cp ${fonts.fontBundle}/fonts/Noto* $out/fonts/
          cp -r ${fonts.fontBundle}/licenses $out/licenses
          # The copied Nix-store directory is read-only; allow sibling licenses.
          chmod u+w $out/licenses
          cp -r ${config.packages.freetype-android}/share/licenses/* $out/licenses/
          cp -r ${config.packages.harfbuzz-android}/share/licenses/* $out/licenses/
          cp ${sessionConf session} $out/session.conf

          cat > $out/NOTICE <<'EOF'
          The terminal bundles the following third-party components.

          FiraCode Nerd Font Mono (bundled font)     OFL-1.1   https://github.com/ryanoasis/nerd-fonts
          DejaVu Sans Mono (bundled font)            Bitstream-Vera + Arev   https://dejavu-fonts.github.io
          Noto Sans (Unicode fallback fonts)         OFL-1.1   https://notofonts.github.io
          Noto Color Emoji (bundled font)            OFL-1.1   https://github.com/googlefonts/noto-emoji
          FreeType (statically linked)               FTL       https://freetype.org
          HarfBuzz (statically linked)               MIT       https://harfbuzz.github.io
          libpng (statically linked)                 libpng-2.0 https://www.libpng.org
          zlib (statically linked)                   Zlib      https://zlib.net
          raylib (statically linked)                 Zlib      https://www.raylib.com
          libghostty-vt (statically linked)          MIT       https://ghostty.org
          libkqueue (statically linked)              BSD-2-Clause   https://github.com/mheily/libkqueue
          This software is based in part on the work of the FreeType Team.
          EOF

          (cd $out && find fonts -type f | sort > asset-manifest.txt)
          (cd $out && find fonts -type f -print0 | sort -z \
            | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > bundle-hash)
        '';

      apkLibs = lib.mapAttrs' (name: t: {
        name = t.abi;
        value."libterminal.so" = "${libterminal}/lib/${t.abi}/libterminal.so";
      }) ndk.targets;
    in
    lib.optionalAttrs (androidHost system).supported {
      packages.libterminal-android = libterminal;

      /**
        The terminal APK. Every argument but `session` is packaging; `session`
        is the `session.conf` the app reads at start (`mode = "shell"` or
        `"bootstrap"`, with `bootstrapUrl`).
      */
      legacyPackages.mkTerminalApk =
        {
          appId ? "dev.petar_kirov.sparkles.terminal",
          label ? "sparkles:terminal",
          pname ? "terminal",
          iconSvg ? ../../../apps/terminal/android/icon/ic_launcher.svg,
          session ? {
            mode = "shell";
          },
          # Bootstrap zips to bundle, by Nix CPU name (`aarch64`, `x86_64`):
          # the installer then offers them offline as its default. Each is
          # tens of megabytes, so a published APK usually bundles none and a
          # self-built one only its device's.
          bootstraps ? { },
          versionName ? null,
          versionCode ? null,
          debug ? true,
          sign ? true,
        }:
        let
          manifest = pkgs.replaceVars ../../../apps/terminal/android/AndroidManifest.xml {
            inherit label;
          };
          icon = config.legacyPackages.mkAndroidIcon {
            name = "${pname}-icon";
            source = iconSvg;
          };
        in
        (config.legacyPackages.buildAndroidApk (
          {
            inherit
              pname
              manifest
              debug
              sign
              ;
            renamePackage = appId;
            resDir = "${icon}/res";
            libs = apkLibs;
            assetsDir = mkAssets session bootstraps;
            targetSdk = 28;
            description = "${label} — sparkles:terminal (Android NativeActivity APK)";
          }
          // lib.optionalAttrs (versionName != null) { inherit versionName; }
          // lib.optionalAttrs (versionCode != null) { inherit versionCode; }
        )).overrideAttrs
          (old: {
            nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.unzip ];
            # NOD1: the app ships no code for the VM — not by review, by
            # construction. A dependency that smuggled in a classes.dex (or a
            # manifest that grew hasCode="true") fails the build here.
            postInstall = (old.postInstall or "") + ''
              if unzip -l $out/*.apk | grep -q '\.dex$'; then
                echo "NOD1: the terminal APK must not contain DEX" >&2
                exit 1
              fi
            '';
          });

      packages.terminal-apk = config.legacyPackages.mkTerminalApk { };
    };
}
