# The hue Android build: `packages.libhue-android` (the whole app closure as
# one shared library per ABI, raw-ldc2 like nix/packages/build-d-wasm-module.nix
# — dub cannot drive cross builds) and `packages.hue-apk` (libhue.so + the
# asset bundle, assembled by buildAndroidApk).
#
# The asset bundle mirrors the layout android_paths.d derives under the app's
# data dir: `fonts/*.ttf` with `<file>.ttf.charset` sidecars (fc-query runs
# HERE, at build time — the device has no fontconfig; FontSet reads the
# sidecars), later `grammars/<lang>/queries/` and `docs/`. `asset-manifest.txt`
# lists every file (AAssetDir cannot enumerate subdirectories, so the manifest
# IS the directory listing android_glue.d extracts from), and `bundle-hash`
# keys the idempotent first-run extraction.
{ inputs, lib, ... }:
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
      # nix/dub-lock.json; `-i` compiles their modules like the in-tree ones).
      dubDeps = [
        {
          name = "raylib-d";
          version = "6.0.1";
          sha256 = "1v2fkdf4lgh055667nkfmwpnkmrvmyiwrqnh4ypsfw8ifyxn3rib";
        }
        {
          name = "expected";
          version = "0.4.1";
          sha256 = "1ahr7gbjl6dgw1qs9x5yzcwhbzfg7ygdlsm9gw4hgmm1xrfcpri0";
        }
        {
          name = "optional";
          version = "1.3.1";
          sha256 = "1ab3x96ax5jsb4zayfw3akppqp3mg42p2d847p3ahrj1zmn3hid9";
        }
        {
          name = "bolts";
          version = "1.3.1";
          sha256 = "1klz02r13r3yq8vcw1gkv39r02vpnv7wlhhb5kkjnybc3s86w1q8";
        }
        # NOTE: `during` (event-horizon's io_uring binding) is deliberately
        # absent: the uring backend is version-gated OFF the Android triple
        # (app seccomp denies io_uring_setup), and the triple selects the
        # kqueue backend over the statically linked libkqueue-android
        # instead — see backend/select.d and libkqueue.nix.
      ];

      dubZip =
        d:
        pkgs.fetchurl {
          name = "dub-${d.name}-${d.version}.zip";
          url = "mirror://dub/${d.name}/${d.version}.zip";
          inherit (d) sha256;
        };

      # The version identifiers dub would define for the android configuration
      # (HueGui + the Have_* set of the dependency graph).
      versions = [
        "HueGui"
        # hue selects sparkles:ui-app's `tui` configuration (dub sets this
        # version identifier for dependents — UIAPP-O2).
        "UiAppTui"
        "Have_sparkles_hue"
        "Have_sparkles_ghostty"
        "Have_sparkles_syntax"
        "Have_sparkles_tree_sitter"
        "Have_sparkles_twoslash"
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
        "Have_sparkles_event_horizon"
        "Have_sparkles_input"
        "Have_raylib_d"
        "Have_optional"
        "Have_bolts"
        "Have_during"
      ];

      # The app closure + apps/hue/android, which `sourceFor` turns into this
      # derivation's src. The JNI bridge's ImportC shim (jni_c.c) lives there
      # rather than under apps/hue/src precisely so dub never scans it — a
      # desktop host has no NDK <jni.h> — and it is passed to ldc2 by explicit
      # path below.
      srcDirs = sources.srcClosure "apps/hue" ++ [ "apps/hue/android" ];

      libhue = pkgs.stdenv.mkDerivation {
        pname = "libhue-android";
        version = "0.1.0";
        src = sources.sourceFor srcDirs;

        nativeBuildInputs = [
          inputs.dlang-nix.packages.${system}.ldc-android
          pkgs.unzip
        ];

        buildPhase = ''
          runHook preBuild

          ${lib.concatMapStrings (d: ''
            mkdir -p dub-imports/${d.name}
            (cd dub-imports/${d.name} && unzip -q ${dubZip d})
          '') dubDeps}

          ${lib.concatMapStrings (t: ''
            ldc2 -mtriple=${t.triple} -relocation-model=pic -O2 \
              -preview=in -preview=dip1000 \
              ${toString (map (v: "-d-version=${v}") versions)} \
              -J=apps/hue/src -J=libs/twoslash/src/sparkles/twoslash/views \
              ${toString (map (dir: "-I=${dir}") srcDirs)} \
              ${toString (map (d: ''-I="$(echo dub-imports/${d.name}/*/source)"'') dubDeps)} \
              -P-U__SIZEOF_INT128__ \
              -P-I${config.packages.tree-sitter-android}/include \
              -P-I${config.packages.libghostty-vt-android}/include \
              -P-I${ndk.sysrootInclude} \
              -i \
              apps/hue/src/app.d \
              apps/hue/android/jni_c.c \
              ${config.packages.raylib-android}/lib/${t.abi}/libraylib.a \
              ${config.packages.tree-sitter-android}/lib/${t.abi}/libtree-sitter.a \
              ${config.packages.libghostty-vt-android}/lib/${t.abi}/libghostty-vt.a \
              ${config.packages.libkqueue-android}/lib/${t.abi}/libkqueue.a \
              -shared -link-defaultlib-shared=false \
              -L-Wl,-u,ANativeActivity_onCreate \
              -L-Wl,--wrap=fopen \
              -L-llog -L-landroid -L-lEGL -L-lGLESv2 -L-lOpenSLES -L-lm -L-ldl \
              -L${ndk.pageAlignFlags} \
              -of=libhue-${t.abi}.so
          '') (lib.attrValues ndk.targets)}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          ${lib.concatMapStrings (t: ''
            install -Dm644 libhue-${t.abi}.so $out/lib/${t.abi}/libhue.so
          '') (lib.attrValues ndk.targets)}
          runHook postInstall
        '';

        # Unstripped for ndk-stack; the APK carries the same bytes so a device
        # tombstone symbolizes against this output directly.
        dontStrip = true;

        meta = {
          description = "hue (full GUI closure) as an Android shared library, per ABI";
          platforms = [ "x86_64-linux" ];
        };
      };

      # The font set is defined once, in nix/packages/fonts.nix, and shared
      # with the desktop bundle — nothing about it is Android-specific.
      fonts = config.legacyPackages.sparklesFonts;
      mapleMono = fonts.maple-mono;

      # Attribution for everything third-party the APK ships. OFL (the fonts)
      # and Bitstream Vera (DejaVu) require the notice to accompany the fonts;
      # zlib (raylib) and MIT (tree-sitter, libghostty-vt, Uiua386) require it
      # in binary distributions. Nothing carried one before this.
      #
      # Generated from each package's `meta.license` rather than hand-listed,
      # so it cannot drift from what is actually bundled — nixpkgs is the
      # authority on the licence, and the font packages ship no LICENSE file
      # in their outputs to copy.
      licenseOf =
        c:
        if c ? licence then
          c.licence # nixpkgs metadata too vague to attribute with
        else
          let
            l = c.pkg.meta.license;
            ls = if builtins.isList l then l else [ l ];
          in
          lib.concatMapStringsSep ", " (m: m.spdxId or m.shortName or "unknown") ls;

      noticedComponents = [
        {
          what = "Maple Mono NF CN (bundled font)";
          pkg = mapleMono;
          home = "https://github.com/subframe7536/maple-font";
        }
        {
          what = "FiraCode Nerd Font Mono (bundled font)";
          pkg = pkgs.nerd-fonts.fira-code;
          home = "https://github.com/ryanoasis/nerd-fonts";
        }
        {
          what = "DejaVu Sans Mono (bundled font)";
          pkg = pkgs.dejavu_fonts;
          # nixpkgs records only `free`, which attributes nothing; DejaVu is
          # Bitstream Vera plus the Arev additions.
          licence = "Bitstream-Vera + Arev";
          home = "https://dejavu-fonts.github.io";
        }
        {
          what = "Uiua386 (bundled font)";
          pkg = pkgs.uiua386;
          home = "https://www.uiua.org";
        }
        {
          what = "raylib (statically linked)";
          pkg = pkgs.raylib;
          home = "https://www.raylib.com";
        }
        {
          what = "tree-sitter + grammars (statically linked / shipped as .so)";
          pkg = pkgs.tree-sitter;
          home = "https://tree-sitter.github.io";
        }
      ];

      noticeFile = pkgs.writeText "hue-android-NOTICE" ''
        hue for Android bundles the following third-party components.
        Licence identifiers are SPDX, taken from each component's nixpkgs
        metadata at build time.

        ${lib.concatMapStringsSep "\n" (c: ''
          ${c.what}
            licence: ${licenseOf c}
            home:    ${c.home}
        '') noticedComponents}
        libghostty-vt (statically linked)
          licence: MIT
          home:    https://ghostty.org

        hue itself and the sparkles libraries are part of this repository; see
        its LICENSE.
      '';

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

            cp ${noticeFile} $out/NOTICE

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
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.libhue-android = libhue;
      packages.hue-android-assets = hueAssets;
      packages.hue-apk = config.legacyPackages.buildAndroidApk {
        pname = "hue";
        manifest = ../../../apps/hue/android/AndroidManifest.xml;
        libs = apkLibs;
        assetsDir = hueAssets;
        description = "hue — syntax-highlighting viewer (Android NativeActivity APK)";
      };
      # Same app, the whole sparkles repository embedded as the browse surface
      # (dogfooding: hue reading its own codebase on-device).
      #
      # Distinct package id and pname: sharing `dev.sparkles.hue` meant
      # installing one silently REPLACED the other, and both derivations
      # emitted `$out/hue.apk` from a store path named `hue-…`, so nothing
      # on disk distinguished them and `hue-adb-install`'s default picked
      # whichever landed on ./result.
      packages.hue-apk-repo = config.legacyPackages.buildAndroidApk {
        pname = "hue-repo";
        manifest = ../../../apps/hue/android/AndroidManifest.xml;
        renamePackage = "dev.sparkles.hue.repo";
        libs = apkLibs;
        assetsDir = hueAssetsRepo;
        description = "hue — syntax-highlighting viewer with the sparkles repo embedded (Android APK)";
      };
    };
}
