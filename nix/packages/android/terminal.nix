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
      credits = config.legacyPackages.sparklesCredits;

      # One unstamped library. The `{}` section is stable, so a commit
      # change does not rebuild it. Each APK packs a patched copy.
      mkLibterminal = config.legacyPackages.buildDAndroidLib {
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
          "TerminalViewRaylib"
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
          "${config.packages.ui-shaders}"
          # The document viewer (sparkles:doc-view) renders twoslash payloads.
          "libs/twoslash/src/sparkles/twoslash/views"
        ];
        emptyBuildInfo = true;
        cIncludes = [
          "${config.packages.tree-sitter-android}/include"
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
          "${config.packages.tree-sitter-android}/lib/${abi}/libtree-sitter.a"
          "${config.packages.libghostty-vt-android}/lib/${abi}/libghostty-vt.a"
          "${config.packages.libkqueue-android}/lib/${abi}/libkqueue.a"
        ];
        description = "apps/terminal as an Android shared library, per ABI";
      };
      libterminal = mkLibterminal;

      # Patched per ABI. The unstamped library stays shared.
      libterminalStamped = config.legacyPackages.stampAndroidLib {
        unstamped = libterminal;
        libName = "terminal";
        app = "terminal";
        links = config.legacyPackages.terminalLinks;
        check = config.legacyPackages.checkTerminalBuildInfo;
      };

      # Nerd-icon coverage and a classic fallback; Maple Mono NF CN (hue's
      # face) is left out — its CJK glyphs are most of the bundle's 61 MB.
      bundledFonts = [
        "FiraCodeNerdFontMono-Regular.ttf"
        "FiraCodeNerdFontMono-Bold.ttf"
        # The interface face chrome text draws in (`GLY10`).
        "Roboto-Regular.ttf"
        "Roboto-Bold.ttf"
        "DejaVuSansMono.ttf"
        "DejaVuSansMono-Bold.ttf"
        "DejaVuSansMono-Oblique.ttf"
        "DejaVuSansMono-BoldOblique.ttf"
      ];

      # The grammars the document viewer gets on the phone (`TDV1`, OQ6): a
      # common subset rather than hue's every one — markdown (the credits
      # page and README previews need its parser) and the languages a
      # nix-on-droid user opens most. Each costs a parser `.so` per ABI.
      viewerGrammars = lib.filter (l: lib.elem l config.legacyPackages.tsGrammarsAndroid.languages) [
        "markdown"
        "markdown-inline"
        "d"
        "c"
        "bash"
        "nix"
        "json"
        "yaml"
        "toml"
        "python"
      ];

      # `session.conf` (session.d parses it): KEY=VALUE lines.
      sessionConf =
        session:
        pkgs.writeText "session.conf" (
          lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${toString v}\n") session)
        );

      # The asset bundle: fonts with their charset sidecars — the only part
      # `sparkles.android.assets` extracts, with the viewer's grammar queries (the
      # manifest lists fonts/ and grammars/ alone,
      # so nothing else lands beside the user's home) — plus session.conf,
      # NOTICE and the credits/ document, read in place from the APK.
      mkAssets =
        session: bootstraps: fontFiles:
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
          '') fontFiles}
          # All script fallbacks and emoji are shared with the desktop bundle.
          cp ${fonts.fontBundle}/fonts/Noto* $out/fonts/
          # The credits document with its licence texts — the files the
          # documentation site renders, from the same derivation (TPG16) —
          # and the plain NOTICE generated from the parts this app ships.
          cp -r ${credits.bundle} $out/credits
          cp ${credits.notice "terminal"} $out/NOTICE
          cp ${sessionConf session} $out/session.conf
          # The viewer's grammar queries, extracted beside the fonts (the
          # registry's soname layout reads <root>/<lang>/queries/*.scm).
          ${lib.concatMapStrings (lang: ''
            if [ -d ${config.packages.ts-grammars}/${lang}/queries ]; then
              mkdir -p $out/grammars/${lang}
              cp -rL ${config.packages.ts-grammars}/${lang}/queries $out/grammars/${lang}/queries
            fi
          '') viewerGrammars}

          (cd $out && find fonts grammars -type f | sort > asset-manifest.txt)
          (cd $out && find fonts grammars -type f -print0 | sort -z \
            | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > bundle-hash)
        '';

      apkLibs =
        library:
        lib.mapAttrs' (name: t: {
          name = t.abi;
          value = {
            "libterminal.so" = "${library}/lib/${t.abi}/libterminal.so";
          }
          # The viewer's parsers, dlopen'd by bare soname (ts-grammars.nix).
          // lib.listToAttrs (
            map (
              lang:
              let
                so = config.legacyPackages.tsGrammarsAndroid.soname lang;
              in
              {
                name = so;
                value = "${config.packages.ts-grammars-android}/lib/${t.abi}/${so}";
              }
            ) viewerGrammars
          );
        }) ndk.targets;
    in
    lib.optionalAttrs (androidHost system).supported {
      packages.libterminal-android = libterminal;

      /**
        The terminal APK. Every argument but `session` is packaging; `session`
        is the `session.conf` the app reads at start (`mode = "shell"`,
        `"bootstrap"`, or experimental `"bootstrap-shell"`, with `bootstrapUrl`).
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
          # Extra APK-shipped executables/loaders, using Android's native-library
          # naming convention: { "arm64-v8a" = { "libproot.so" = <path>; }; }.
          # These must not replace the terminal or its bundled parsers.
          extraNativeLibs ? { },
          versionName ? null,
          versionCode ? null,
          # The bundle's font files (with their charset sidecars) the APK
          # ships beside the shared script fallbacks and emoji.
          fonts ? bundledFonts,
          # The default theme's background (ChromeTheme), shown before the
          # first frame.
          windowBackground ? "#ff1e1e2e",
          debug ? true,
          sign ? true,
          # 28 keeps app-data files executable (NOD3); a higher value is for
          # measuring the target-SDK exec restriction (android-dev-env E1).
          targetSdk ? 28,
        }:
        let
          baseLibs = apkLibs libterminalStamped;
          validExtras = lib.all (
            abi:
            builtins.hasAttr abi baseLibs
            && lib.all (
              name:
              builtins.match "lib[A-Za-z0-9_.+-]+\\.so" name != null && !(builtins.hasAttr name baseLibs.${abi})
            ) (builtins.attrNames extraNativeLibs.${abi})
          ) (builtins.attrNames extraNativeLibs);
          manifest = pkgs.replaceVars ../../../apps/terminal/android/AndroidManifest.xml {
            inherit label;
          };
          icon = config.legacyPackages.mkAndroidIcon {
            name = "${pname}-icon";
            source = iconSvg;
          };
          # The icon, and the activity's theme: the window, and Android 12's
          # launch splash, in the terminal's background colour — what shows
          # from the tap until the first frame, instead of black.
          themeXml =
            splash:
            pkgs.writeText "theme.xml" ''
              <resources>
                  <style name="Terminal" parent="@android:style/Theme.DeviceDefault.NoActionBar">
                      <item name="android:windowBackground">${windowBackground}</item>
              ${lib.optionalString splash ''
                <item name="android:windowSplashScreenBackground">${windowBackground}</item>
              ''}    </style>
              </resources>
            '';
          res = pkgs.runCommand "${pname}-res" { } ''
            cp -r ${icon}/res $out
            chmod -R u+w $out
            install -Dm644 ${themeXml false} $out/values/theme.xml
            install -Dm644 ${themeXml true} $out/values-v31/theme.xml
          '';
        in
        assert lib.assertMsg validExtras
          "mkTerminalApk: extraNativeLibs needs supported ABIs and non-conflicting lib*.so names";
        (config.legacyPackages.buildAndroidApk (
          {
            inherit
              pname
              manifest
              debug
              sign
              ;
            renamePackage = appId;
            resDir = "${res}";
            # The patched libraries carry the build-info section (`TPG2`).
            # Debug and release share the one unstamped `.so`.
            libs = lib.mapAttrs (abi: libs: libs // (extraNativeLibs.${abi} or { })) baseLibs;
            assetsDir = mkAssets session bootstraps fonts;
            inherit targetSdk;
            description = "${label} — sparkles:terminal (Android NativeActivity APK)";
          }
          // lib.optionalAttrs (versionName != null) { inherit versionName; }
          // lib.optionalAttrs (versionCode != null) { inherit versionCode; }
        )).overrideAttrs
          (old: {
            nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.unzip ];
            passthru = (old.passthru or { }) // {
              buildInfo = libterminalStamped.passthru.buildInfo;
            };
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
