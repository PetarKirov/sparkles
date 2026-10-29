# `packages.android-pkg-config`: a pkg-config directory per ABI
# (`<abi>/`) describing the Android builds of the C libraries the sparkles
# packages name with `libs` — FreeType, HarfBuzz, raylib, libkqueue,
# libghostty-vt and tree-sitter — so a
# dub cross build (`dub build --arch=aarch64-linux-android`) resolves them
# exactly as a desktop build resolves the host's: dub asks pkg-config, which
# hands ImportC the headers and the linker the static archives. Point
# `PKG_CONFIG_LIBDIR` at one ABI's directory (and nothing else, so no host
# library leaks in). Libraries no file here names (`vulkan`, `log`) are
# NDK system libraries dub links as `-l<name>`.
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
      ft = config.packages.freetype-android;
      hb = config.packages.harfbuzz-android;
      raylib = config.packages.raylib-android;
      kqueue = config.packages.libkqueue-android;
      ghostty = config.packages.libghostty-vt-android;
      treeSitter = config.packages.tree-sitter-android;

      pcFiles =
        abi:
        let
          pc =
            {
              name,
              version,
              cflags ? "",
              libs,
              requires ? "",
            }:
            ''
              cat > $out/${abi}/${name}.pc <<'PC'
              Name: ${name}
              Description: ${name} for Android ${abi}
              Version: ${version}
              ${lib.optionalString (requires != "") "Requires.private: ${requires}"}
              Cflags: ${cflags}
              Libs: ${libs}
              PC
            '';
        in
        ''
          mkdir -p $out/${abi}
          ${pc {
            name = "freetype2";
            inherit (ft) version;
            cflags = "-I${ft}/include/freetype2";
            libs = "${ft}/lib/${abi}/libfreetype.a ${ft}/lib/${abi}/libpng16.a ${ft}/lib/${abi}/libz.a";
          }}
          ${pc {
            name = "harfbuzz";
            inherit (hb) version;
            cflags = "-I${hb}/include/harfbuzz -I${ft}/include/freetype2";
            libs = "${hb}/lib/${abi}/libharfbuzz.a ${ft}/lib/${abi}/libfreetype.a ${ft}/lib/${abi}/libpng16.a ${ft}/lib/${abi}/libz.a";
          }}
          ${pc {
            name = "raylib";
            inherit (raylib) version;
            cflags = "-I${raylib}/include";
            libs = "${raylib}/lib/${abi}/libraylib.a -lEGL -lGLESv2 -lOpenSLES -landroid -llog -lm";
          }}
          ${pc {
            name = "kqueue";
            inherit (kqueue) version;
            libs = "${kqueue}/lib/${abi}/libkqueue.a";
          }}
          ${pc {
            name = "ghostty-vt";
            inherit ((builtins.parseDrvName ghostty.name)) version;
            cflags = "-I${ghostty}/include";
            libs = "${ghostty}/lib/${abi}/libghostty-vt.a";
          }}
          ${pc {
            name = "tree-sitter";
            inherit (treeSitter) version;
            cflags = "-I${treeSitter}/include";
            libs = "${treeSitter}/lib/${abi}/libtree-sitter.a";
          }}
        '';
    in
    lib.optionalAttrs (androidHost system).supported {
      packages.android-pkg-config = pkgs.runCommand "android-pkg-config" { } (
        lib.concatMapStrings (t: pcFiles t.abi) (lib.attrValues ndk.targets)
      );
    };
}
