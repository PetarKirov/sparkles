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
        "Have_sparkles_input"
        "Have_raylib_d"
        "Have_optional"
        "Have_bolts"
      ];

      srcDirs = sources.srcClosure "apps/hue";

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
              -i \
              apps/hue/src/app.d \
              ${config.packages.raylib-android}/lib/${t.abi}/libraylib.a \
              ${config.packages.tree-sitter-android}/lib/${t.abi}/libtree-sitter.a \
              ${config.packages.libghostty-vt-android}/lib/${t.abi}/libghostty-vt.a \
              -shared -link-defaultlib-shared=false \
              -L-Wl,-u,ANativeActivity_onCreate \
              -L-Wl,--wrap=fopen \
              -L-llog -L-landroid -L-lEGL -L-lGLESv2 -L-lOpenSLES -L-lm -L-ldl \
              -L-Wl,-z,max-page-size=16384 \
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

      # The APK asset bundle. fc-query runs here, at build time, to write the
      # coverage sidecars FontSet reads instead of shelling out on-device.
      hueAssets =
        pkgs.runCommand "hue-android-assets"
          {
            nativeBuildInputs = [ pkgs.fontconfig ];
          }
          ''
            mkdir -p $out/fonts

            # Primary family: FiraCode Nerd Font Mono (the head of hue's
            # defaultGuiFont preference list; FiraCode ships no italics —
            # italic text renders upright, same as the desktop default).
            for f in FiraCodeNerdFontMono-Regular.ttf FiraCodeNerdFontMono-Bold.ttf; do
              cp ${pkgs.nerd-fonts.fira-code}/share/fonts/truetype/NerdFonts/FiraCode/$f \
                $out/fonts/
            done
            # Regular fallback with full styling: DejaVu Sans Mono.
            for f in DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf \
                DejaVuSansMono-Oblique.ttf DejaVuSansMono-BoldOblique.ttf; do
              cp ${pkgs.dejavu_fonts}/share/fonts/truetype/$f $out/fonts/
            done

            for font in $out/fonts/*.ttf; do
              fc-query --format=%{charset} "$font" > "$font.charset"
            done

            (cd $out && find . -type f -printf '%P\n' | sort > asset-manifest.txt)
            (cd $out && find . -type f ! -name bundle-hash -print0 | sort -z \
              | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > bundle-hash)
          '';
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.libhue-android = libhue;
      packages.hue-android-assets = hueAssets;
      packages.hue-apk = config.legacyPackages.buildAndroidApk {
        pname = "hue";
        manifest = ../../../apps/hue/android/AndroidManifest.xml;
        libs = lib.mapAttrs' (name: t: {
          name = t.abi;
          value = {
            "libhue.so" = "${libhue}/lib/${t.abi}/libhue.so";
          };
        }) ndk.targets;
        assetsDir = hueAssets;
        keystore = ../../../apps/hue/android/debug.keystore;
        description = "hue — syntax-highlighting viewer (Android NativeActivity APK)";
      };
    };
}
