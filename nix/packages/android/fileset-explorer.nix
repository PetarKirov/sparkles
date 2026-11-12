# The fileset explorer on Android (docs/specs/fileset-explorer/SPEC.md, FXA):
# apps/fileset-explorer on the native `sparkles:wsi` Android backend and the
# Vulkan canvas, with the sparkles repository embedded as its fileset root —
# what `hue-apk-repo` does for hue.
#
#   packages.libfileset-explorer-android   apps/fileset-explorer as
#                                          lib<abi>/libfilesetexplorer.so,
#                                          its `android` dub configuration
#   packages.fileset-explorer-android-assets
#                                          the repository, the fonts and the
#                                          grammar queries, as an extractable
#                                          asset bundle
#   packages.fileset-explorer-apk          the APK, debuggable and signed with
#                                          the in-tree debug key, like every
#                                          development APK here
#
# The activity is sparkles:wsi's (`AndroidWsiMain`, mixed in by
# apps/fileset-explorer/src/android_entry.d), so nothing of raylib's
# `native_app_glue` is linked.
{ inputs, lib, ... }:
let
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
      fonts = config.legacyPackages.sparklesFonts;
      credits = config.legacyPackages.sparklesCredits;
      # `shared`: the examples' debug id, one for every development APK, so a
      # device that asks before each new package (MIUI's "Install via USB")
      # asks once; each install replaces whichever was there.
      applicationIdOf =
        shared:
        if shared then
          "dev.petar_kirov.sparkles.example.debug"
        else
          "dev.petar_kirov.sparkles.fileset_explorer";

      # dub builds the explorer for Android from its recipes (`android`
      # configuration); pkg-config resolves tree-sitter for sparkles:syntax.
      library = config.legacyPackages.buildSparklesAndroidLib {
        pname = "libfileset-explorer-android";
        appDir = "apps/fileset-explorer";
        libName = "filesetexplorer";
        inherit ((androidHost system)) ldcAndroid;
        # The help is the docs page, compiled in (`FXU7`).
        extraSources = [ "docs/apps/fileset-explorer/index.md" ];
      };

      # The grammars it highlights with: the query's own, the help's markdown,
      # and each Export target's language (export_tab.d `languageOf`).
      grammars = lib.filter (l: lib.elem l config.legacyPackages.tsGrammarsAndroid.languages) [
        "fileset"
        "markdown"
        "markdown-inline"
        "nix"
        "bash"
        "gitignore"
        "toml"
        "starlark"
        "sdl"
      ];

      # The cell face (`defaultGuiFont` resolves FiraCode Nerd Font Mono, whose
      # icons the tree's file glyphs are), the interface face (`GLY10`) and a
      # fallback, each with its `.charset` sidecar.
      bundledFonts = [
        "FiraCodeNerdFontMono-Regular.ttf"
        "FiraCodeNerdFontMono-Bold.ttf"
        "Roboto-Regular.ttf"
        "Roboto-Bold.ttf"
        "DejaVuSansMono.ttf"
      ];

      # `repo/`: every tracked file of the flake source, the fileset root
      # (`FXA2`). The flake source is the tracked tree, so untracked build
      # junk is absent by construction. Dot-entries are left out: aapt2
      # silently drops them from assets, so a manifest entry for
      # `.gitignore` could never be extracted on the device.
      assets = pkgs.runCommand "fileset-explorer-android-assets" { } ''
        mkdir -p $out/fonts $out/repo
        ${lib.concatMapStrings (f: ''
          cp ${fonts.fontBundle}/fonts/${f} ${fonts.fontBundle}/fonts/${f}.charset $out/fonts/
        '') bundledFonts}

        # The grammar queries; the parsers ship as native libraries below
        # (the registry's soname layout reads <root>/<lang>/queries/*.scm).
        ${lib.concatMapStrings (lang: ''
          if [ -d ${config.packages.ts-grammars}/${lang}/queries ]; then
            mkdir -p $out/grammars/${lang}
            cp -rL ${config.packages.ts-grammars}/${lang}/queries $out/grammars/${lang}/queries
          fi
        '') grammars}

        cp -r --no-preserve=mode ${inputs.self}/. $out/repo/
        find $out/repo -depth -name '.*' -exec rm -rf {} +

        # The credits document with its licence texts, and the plain NOTICE
        # generated from the parts this app ships (TPG16); read in place.
        cp -r ${credits.bundle} $out/credits
        cp ${credits.notice "fileset-explorer"} $out/NOTICE

        # Everything above is extracted: the manifest lists it, and
        # `bundle-hash` keys the extraction (`sparkles.android.assets`).
        (cd $out && find fonts grammars repo -type f | sort > asset-manifest.txt)
        (cd $out && find fonts grammars repo -type f -print0 | sort -z \
          | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > bundle-hash)
      '';

      manifest =
        shared:
        pkgs.writeText "AndroidManifest.xml" ''
          <?xml version="1.0" encoding="utf-8"?>
          <!-- Generated by nix/packages/android/fileset-explorer.nix. -->
          <manifest xmlns:android="http://schemas.android.com/apk/res/android"
              package="${applicationIdOf shared}">
              <uses-feature android:name="android.hardware.vulkan.version" android:version="0x400003" android:required="true" />
              <!-- Send (FXS9): iroh's connections, and the network state it watches. -->
              <uses-permission android:name="android.permission.INTERNET" />
              <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
              <application
                  android:label="fileset explorer${lib.optionalString shared " (debug)"}"
                  android:theme="@android:style/Theme.DeviceDefault.NoActionBar"
                  android:hasCode="false"
                  android:allowBackup="false"
                  android:extractNativeLibs="true">
                  <activity
                      android:name="android.app.NativeActivity"
                      android:exported="true"
                      android:launchMode="singleTask"
                      android:configChanges="orientation|screenSize|screenLayout|smallestScreenSize|keyboard|keyboardHidden|navigation|density|uiMode"
                      android:windowSoftInputMode="adjustResize|stateAlwaysHidden">
                      <meta-data android:name="android.app.lib_name" android:value="filesetexplorer" />
                      <meta-data android:name="android.app.func_name" android:value="sparkles_wsi_onCreate" />
                      <intent-filter>
                          <action android:name="android.intent.action.MAIN" />
                          <category android:name="android.intent.category.LAUNCHER" />
                      </intent-filter>
                  </activity>
              </application>
          </manifest>
        '';

      apk =
        shared:
        config.legacyPackages.buildAndroidApk {
          pname = "fileset-explorer${lib.optionalString shared "-debug"}";
          manifest = manifest shared;
          assetsDir = assets;
          # The library, and each grammar's parser, dlopen'd by bare soname
          # from the app's linker namespace (ts-grammars.nix); so is the iroh
          # bridge, Send's (`FXS9`).
          libs = lib.mapAttrs' (_: t: {
            name = t.abi;
            value = {
              "libfilesetexplorer.so" = "${library}/lib/${t.abi}/libfilesetexplorer.so";
              "libsparkles_iroh_send.so" =
                "${config.legacyPackages.irohSendAndroid}/lib/${t.abi}/libsparkles_iroh_send.so";
            }
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
              ) grammars
            );
          }) ndk.targets;
          targetSdk = 29;
          description = "The fileset explorer, the sparkles repository as its root (Android APK)";
        }
        // {
          applicationId = applicationIdOf shared;
        };
    in
    lib.optionalAttrs (androidHost system).supported {
      androidPackages = {
        libfileset-explorer-android = library;
        fileset-explorer-android-assets = assets;
        fileset-explorer-apk = apk false;
        fileset-explorer-apk-debug = apk true;
      };
    };
}
