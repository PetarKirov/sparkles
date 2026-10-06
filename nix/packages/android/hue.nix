# The hue Android build: `packages.libhue-android` (the whole app closure as
# one shared library per ABI, via buildDAndroidLib — dub cannot drive cross
# builds) and `packages.hue-apk` (libhue.so + the asset bundle, assembled by
# buildAndroidApk).
#
# The asset bundle mirrors the layout android_paths.d derives under the app's
# data dir: `fonts/*.ttf` with `<file>.ttf.charset` sidecars (fc-query runs
# HERE, at build time — the device has no fontconfig; FontSet reads the
# sidecars), later `grammars/<lang>/queries/` and `docs/`. `asset-manifest.txt`
# lists every file (AAssetDir cannot enumerate subdirectories, so the manifest
# IS the directory listing android_glue.d extracts from), and `bundle-hash`
# keys the idempotent first-run extraction.
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

      # The dub-registry dependencies compiled into the closure (same pins as
      # nix/dub-lock.json / the `dub-*` flake inputs; `-i` compiles their
      # modules like the in-tree ones).
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
        # NOTE: `during` (event-horizon's io_uring binding) is deliberately
        # absent: the uring backend is version-gated OFF the Android triple
        # (app seccomp denies io_uring_setup), and the triple selects the
        # kqueue backend over the statically linked libkqueue-android
        # instead — see backend/select.d and libkqueue.nix.
      ];

      # The version identifiers dub would define for the android configuration
      # (HueGui + the Have_* set of the dependency graph).
      versions = [
        "HueGui"
        # hue selects sparkles:ui-app's `gui` configuration on Android (dub sets
        # these version identifiers for dependents — UIAPP-O2). Deliberately NOT
        # `UiAppTui`: APP3 keeps the terminal out of an Android closure, and the
        # host's terminal arm has no business being compiled for a phone.
        "UiAppGui"
        # The built-in effects' GPU halves (sparkles:ui's `gpu-effects`
        # configuration, which dub would select through ui-raylib): the GLSL
        # comes prebuilt from `ui-shaders`, on the `-J` path below.
        "SparklesUiGpuEffects"
        "Have_sparkles_hue"
        "Have_sparkles_ghostty"
        "Have_sparkles_syntax"
        "Have_sparkles_tree_sitter"
        "Have_sparkles_twoslash"
        "Have_sparkles_docs"
        "Have_sparkles_core_cli"
        "Have_sparkles_raylib_text"
        "Have_expected"
        "Have_sparkles_base"
        "Have_sparkles_ui"
        "Have_sparkles_tui"
        "Have_sparkles_wired"
        "Have_sparkles_ui_raylib"
        "Have_sparkles_ui_tui"
        "Have_sparkles_ui_app"
        "Have_sparkles_android"
        "Have_sparkles_event_horizon"
        "Have_sparkles_input"
        "Have_raylib_d"
        "Have_optional"
        "Have_bolts"
        "Have_during"
      ];

      # Raw ldc2 -i follows imports, but cannot discover unimported C bodies.
      # The JNI shim additionally lives outside the normal app source closure.
      srcDirs = sources.srcClosure "apps/hue" ++ [ "libs/android/c" ];

      libhue = config.legacyPackages.buildDAndroidLib {
        pname = "libhue-android";
        libName = "hue";
        mainFile = "apps/hue/src/app.d";
        inherit srcDirs versions dubDeps;
        cFiles = [
          "libs/android/c/jni_c.c"
          "libs/ghostty/src/sparkles/ghostty/ghostty_modes.c"
          "libs/raylib-text/src/sparkles/raylib_text/shaping_c.c"
        ];
        stringImportDirs = [
          "apps/hue/src"
          "libs/twoslash/src/sparkles/twoslash/views"
          "${config.packages.ui-shaders}"
        ];
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
        description = "hue (full GUI closure) as an Android shared library, per ABI";
      };

      # The font set is defined once, in nix/packages/fonts.nix, and shared
      # with the desktop bundle — nothing about it is Android-specific.
      fonts = config.legacyPackages.sparklesFonts;
      credits = config.legacyPackages.sparklesCredits;

      # The APK asset bundle, parameterized over the docs/ tree (the
      # explorer's browse surface — `stageDocs` fills $out/docs). Fonts +
      # charset sidecars and grammar queries are common to every variant;
      # fc-query runs here, at build time, to write the coverage sidecars
      # FontSet reads instead of shelling out on-device.
      mkAssets =
        name: stageDocs:
        pkgs.runCommand name
          {
            # No fontconfig: the shared bundle already ran fc-query to write
            # the .charset sidecars.
          }
          ''
            # `runCommand` does not create $out — the builder must, and this
            # copy is the first thing that touches it.
            mkdir -p $out

            # The shared bundle already carries every font plus its
            # `.charset` sidecar (fc-query ran at ITS build time), so this is a
            # copy, not a second recipe to keep in sync.
            cp -rL ${fonts.fontBundle}/fonts $out/fonts

            # Grammar queries — the desktop bundle's normalized queries/ dirs
            # verbatim (parsers ship separately as native libs; the registry's
            # soname layout reads <root>/<lang>/queries/*.scm from here).
            mkdir -p $out/grammars
            for langDir in ${config.packages.ts-grammars}/*/; do
              lang=$(basename "$langDir")
              if [ -d "$langDir/queries" ]; then
                mkdir -p "$out/grammars/$lang"
                cp -rL "$langDir/queries" "$out/grammars/$lang/queries"
              fi
            done

            mkdir -p $out/docs
            ${stageDocs}

            # The credits document with its licence texts — the files the
            # documentation site renders, from the same derivation (TPG16) —
            # and the plain NOTICE generated from the parts hue ships.
            cp -r ${credits.bundle} $out/credits
            cp ${credits.notice "hue"} $out/NOTICE

            # The manifest lists itself (the redirect creates the empty file
            # before `find` walks) and omits bundle-hash (written after). Both
            # are what android_glue.d wants — it extracts every listed path and
            # reads bundle-hash separately — but state it rather than leaving
            # it as an accident of ordering.
            (cd $out && find . -type f ! -name bundle-hash -printf '%P\n' \
              | sort > asset-manifest.txt)
            (cd $out && find . -type f ! -name bundle-hash -print0 | sort -z \
              | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > bundle-hash)
          '';

      # Sample documents (the default hue-apk) — one exhibit of each render
      # path: markdown incl. ` ```ansi ` fences (prettyprint-values.md carries
      # real SGR escapes, so the libghostty-vt path renders visibly), a D
      # source, and a twoslash payload.
      hueAssets = mkAssets "hue-android-assets" ''
        cp ${../../../docs/libs/base/tutorial/getting-started.md} \
          $out/docs/getting-started.md
        cp ${../../../docs/libs/base/how-to/prettyprint-values.md} \
          $out/docs/prettyprint-values.md
        cp ${../../../libs/input/src/sparkles/input/gesture.d} $out/docs/gesture.d
        cp ${../../../libs/twoslash/examples/fixtures/12-async.twoslash.json} \
          $out/docs/async-example.twoslash.json
      '';

      # The whole repository as the browse surface (hue-apk-repo): every
      # tracked text file — sources, markdown, and aux files — minus
      # docs/.vitepress (site tooling) and binaries (fonts, images, the
      # keystore), which hue cannot render. Dotfiles stay out too:
      # aapt2 silently excludes them from assets, so a manifest entry for a
      # .gitignore could never be extracted on-device. ~1.5k files / ~29 MB of text;
      # the flake source is the tracked tree, so untracked build junk is
      # absent by construction.
      repoTextExts = [
        "bazel"
        "c"
        "cc"
        "cpp"
        "css"
        "csv"
        "d"
        "go"
        "h"
        "html"
        "i"
        "ini"
        "js"
        "json"
        "lock"
        "md"
        "mjs"
        "nix"
        "patch"
        "py"
        "rs"
        "scm"
        "sdl"
        "sh"
        "svg"
        "toml"
        "ts"
        "tsx"
        "txt"
        "vue"
        "xml"
        "yaml"
        "yml"
        "zig"
      ];
      repoDocsTree = lib.fileset.toSource {
        root = ../../..;
        fileset = lib.fileset.difference (lib.fileset.fileFilter (
          file:
          lib.any file.hasExt repoTextExts
          || lib.elem file.name [
            "LICENSE"
            "Makefile"
          ]
        ) ../../..) ../../../docs/.vitepress;
      };
      hueAssetsRepo = mkAssets "hue-android-assets-repo" ''
        cp -r ${repoDocsTree}/. $out/docs/
        # aapt2 silently excludes dot-entries (files AND directories) from
        # assets — prune them so the manifest never lists what can't ship.
        chmod -R u+w $out/docs
        find $out/docs -depth -name '.*' -exec rm -rf {} +
      '';

      # The native-lib set both APK variants share: libhue.so + every grammar
      # parser (dlopen'd by bare soname from the app's linker namespace — see
      # ts-grammars.nix).
      apkLibs = lib.mapAttrs' (name: t: {
        name = t.abi;
        value = {
          "libhue.so" = "${libhue}/lib/${t.abi}/libhue.so";
        }
        // (
          let
            grammarLibDir = "${config.packages.ts-grammars-android}/lib/${t.abi}";
          in
          # The soname list comes from ts-grammars.nix as data, NOT from
          # reading the built tree: `builtins.readDir` on a path carrying
          # derivation context is import-from-derivation, and would force the
          # entire grammar closure to build during evaluation (breaking
          # `nix flake check`, which the desktop `test` job runs).
          lib.listToAttrs (
            map (so: {
              name = so;
              value = "${grammarLibDir}/${so}";
            }) config.legacyPackages.tsGrammarsAndroid.sonames
          )
        );
      }) ndk.targets;
    in
    lib.optionalAttrs (androidHost system).supported {
      packages.libhue-android = libhue;
      packages.hue-android-assets = hueAssets;
      packages.hue-apk = config.legacyPackages.buildAndroidApk {
        pname = "hue";
        manifest = ../../../apps/hue/android/AndroidManifest.xml;
        resDir = "${config.packages.hue-icon}/res";
        libs = apkLibs;
        assetsDir = hueAssets;
        description = "hue — syntax-highlighting viewer (Android NativeActivity APK)";
      };
      # Same app, the whole sparkles repository embedded as the browse surface
      # (dogfooding: hue reading its own codebase on-device).
      #
      # Distinct package id and pname: sharing `dev.petar_kirov.sparkles.hue`
      # meant installing one silently REPLACED the other, and both derivations
      # emitted `$out/hue.apk` from a store path named `hue-…`, so nothing
      # on disk distinguished them and `hue-adb-install`'s default picked
      # whichever landed on ./result.
      packages.hue-apk-repo = config.legacyPackages.buildAndroidApk {
        pname = "hue-repo";
        manifest = ../../../apps/hue/android/AndroidManifest.xml;
        renamePackage = "dev.petar_kirov.sparkles.hue.repo";
        resDir = "${config.packages.hue-icon}/res";
        libs = apkLibs;
        assetsDir = hueAssetsRepo;
        description = "hue — syntax-highlighting viewer with the sparkles repo embedded (Android APK)";
      };

      # The publication artifact (FDR1): a RELEASE APK — no
      # android:debuggable — that nix deliberately does not sign, because a
      # distribution key handed to a derivation is a key published to
      # /nix/store and the binary cache. apps/fdroid signs the result.
      #
      # Parameterized on the version because the tag is the only place a
      # version lives (docs/guidelines/release.md) and nix cannot read a tag
      # without import-from-derivation. The publisher derives both fields from
      # the tag through sparkles:versions — versionName is the SemVer string,
      # versionCode is `Tiny.orderKey` (major:16|minor:8|patch:8), which is
      # exactly the monotonic ordering key Android wants — and calls this.
      # See docs/specs/hue/fdroid.md § Version mapping.
      #
      # Sample assets, not the repo-embedded ones: hue-apk-repo is a dogfooding
      # variant with its own package id and is not published.
      legacyPackages.mkHueApk =
        {
          versionName,
          versionCode,
        }:
        config.legacyPackages.buildAndroidApk {
          pname = "hue";
          inherit versionName versionCode;
          version = versionName;
          manifest = ../../../apps/hue/android/AndroidManifest.xml;
          resDir = "${config.packages.hue-icon}/res";
          libs = apkLibs;
          assetsDir = hueAssets;
          debug = false;
          sign = false;
          description = "hue — release APK, unsigned (signed outside nix for F-Droid)";
        };

      # The Play channel's artifact. Same payload, bundle container: Play has
      # required App Bundles for new apps since 2021, so it cannot take the APK.
      legacyPackages.mkHueAab =
        {
          versionName,
          versionCode,
        }:
        config.legacyPackages.buildAndroidAab {
          pname = "hue";
          inherit versionName versionCode;
          manifest = ../../../apps/hue/android/AndroidManifest.xml;
          resDir = "${config.packages.hue-icon}/res";
          libs = apkLibs;
          assetsDir = hueAssets;
          description = "hue — release App Bundle, unsigned (signed outside nix for Play)";
        };

      packages.hue-aab-unsigned = config.legacyPackages.mkHueAab {
        versionName = "0.0.0";
        versionCode = 1;
      };

      # The same artifact at the development stamp, so `nix build` and CI can
      # exercise the unsigned path without a tag. Never published: the
      # publisher always goes through mkHueApk with a real version.
      packages.hue-apk-unsigned = config.legacyPackages.buildAndroidApk {
        pname = "hue";
        manifest = ../../../apps/hue/android/AndroidManifest.xml;
        resDir = "${config.packages.hue-icon}/res";
        libs = apkLibs;
        assetsDir = hueAssets;
        debug = false;
        sign = false;
        description = "hue — release APK, unsigned (development stamp; see mkHueApk)";
      };
    };
}
