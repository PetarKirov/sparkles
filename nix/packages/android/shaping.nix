# FreeType and HarfBuzz use the same pinned nixpkgs sources as desktop.
# PNG + zlib are static too: Noto Color Emoji's CBDT strikes need PNG decoding.
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
      targets = lib.attrValues ndk.targets;
      cmakeFlags = t: ''
        -DCMAKE_TOOLCHAIN_FILE=${ndk.ndkRoot}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=${t.abi} -DANDROID_PLATFORM=android-${ndk.minSdk} \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
      '';

      freetype = pkgs.stdenv.mkDerivation {
        pname = "freetype-android";
        inherit (pkgs.freetype) version src patches;
        nativeBuildInputs = [ pkgs.cmake ];
        dontUseCmakeConfigure = true;
        dontStrip = true;
        postUnpack = ''
          mkdir zlib-source png-source
          tar -xf ${pkgs.zlib.src} -C zlib-source --strip-components=1
          tar -xf ${pkgs.libpng.src} -C png-source --strip-components=1
        '';
        buildPhase = ''
          runHook preBuild
          ${lib.concatMapStrings (t: ''
            prefix="$NIX_BUILD_TOP/deps-${t.abi}"
            cmake -S ../zlib-source -B zlib-${t.abi} ${cmakeFlags t} \
              -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
            cmake --build zlib-${t.abi} --target zlibstatic -j$NIX_BUILD_CORES
            mkdir -p "$prefix/lib" "$prefix/include"
            cp zlib-${t.abi}/libz.a "$prefix/lib/"
            cp ../zlib-source/zlib.h zlib-${t.abi}/zconf.h "$prefix/include/"

            cmake -S ../png-source -B png-${t.abi} ${cmakeFlags t} \
              -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
              -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
              -DZLIB_LIBRARY="$prefix/lib/libz.a" -DZLIB_INCLUDE_DIR="$prefix/include"
            cmake --build png-${t.abi} -j$NIX_BUILD_CORES
            cmake --install png-${t.abi}

            cmake -S . -B build-${t.abi} ${cmakeFlags t} \
              -DCMAKE_INSTALL_PREFIX="$NIX_BUILD_TOP/install-${t.abi}" \
              -DCMAKE_INSTALL_LIBDIR=lib \
              -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON \
              -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON \
              -DPNG_LIBRARY="$prefix/lib/libpng16.a" -DPNG_PNG_INCLUDE_DIR="$prefix/include" \
              -DZLIB_LIBRARY="$prefix/lib/libz.a" -DZLIB_INCLUDE_DIR="$prefix/include"
            cmake --build build-${t.abi} -j$NIX_BUILD_CORES
            cmake --install build-${t.abi}
          '') targets}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          ${lib.concatMapStrings (t: ''
            install -Dm644 "$NIX_BUILD_TOP/install-${t.abi}/lib/libfreetype.a" \
              -t "$out/lib/${t.abi}"
            cp "$NIX_BUILD_TOP/deps-${t.abi}/lib/"{libpng16.a,libz.a} "$out/lib/${t.abi}/"
          '') targets}
          # Both supported ABIs are 64-bit; the installed public config agrees.
          cp -r "$NIX_BUILD_TOP/install-${(builtins.head targets).abi}/include" "$out/include"
          install -Dm644 docs/FTL.TXT docs/GPLv2.TXT LICENSE.TXT -t "$out/share/licenses/freetype"
          install -Dm644 ../png-source/LICENSE "$out/share/licenses/libpng/LICENSE"
          install -Dm644 ../zlib-source/README "$out/share/licenses/zlib/README"
          runHook postInstall
        '';
        meta = {
          description = "FreeType with static PNG and zlib for Android, per ABI";
          inherit (pkgs.freetype.meta) license homepage;
          platforms = (androidHost system).platforms;
        };
      };

      harfbuzz = pkgs.stdenv.mkDerivation {
        pname = "harfbuzz-android";
        inherit (pkgs.harfbuzz) version src;
        nativeBuildInputs = [ pkgs.cmake ];
        dontUseCmakeConfigure = true;
        dontStrip = true;
        buildPhase = ''
          runHook preBuild
          ${lib.concatMapStrings (t: ''
            cmake -S . -B build-${t.abi} ${cmakeFlags t} \
              -DCMAKE_INSTALL_PREFIX="$NIX_BUILD_TOP/install-${t.abi}" \
              -DCMAKE_INSTALL_LIBDIR=lib \
              -DHB_HAVE_FREETYPE=ON -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF \
              -DHB_HAVE_GRAPHITE2=OFF -DHB_BUILD_UTILS=OFF \
              -DHB_BUILD_SUBSET=OFF -DHB_BUILD_RASTER=OFF -DHB_BUILD_VECTOR=OFF \
              -DFREETYPE_LIBRARY_RELEASE=${freetype}/lib/${t.abi}/libfreetype.a \
              -DFREETYPE_INCLUDE_DIR_freetype2=${freetype}/include/freetype2 \
              -DFREETYPE_INCLUDE_DIR_ft2build=${freetype}/include/freetype2 \
              -DCMAKE_REQUIRED_LIBRARIES="${freetype}/lib/${t.abi}/libpng16.a;${freetype}/lib/${t.abi}/libz.a;m"
            # Upstream's CMake disables RTTI/exceptions and C++ runtime linkage.
            cmake --build build-${t.abi} -j$NIX_BUILD_CORES
            cmake --install build-${t.abi}
          '') targets}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          ${lib.concatMapStrings (t: ''
            install -Dm644 "$NIX_BUILD_TOP/install-${t.abi}/lib/libharfbuzz.a" \
              -t "$out/lib/${t.abi}"
          '') targets}
          cp -r "$NIX_BUILD_TOP/install-${(builtins.head targets).abi}/include" "$out/include"
          install -Dm644 COPYING "$out/share/licenses/harfbuzz/COPYING"
          runHook postInstall
        '';
        meta = {
          description = "HarfBuzz static shaping library for Android, per ABI";
          inherit (pkgs.harfbuzz.meta) license homepage;
          platforms = (androidHost system).platforms;
        };
      };
    in
    lib.optionalAttrs (androidHost system).supported {
      packages.freetype-android = freetype;
      packages.harfbuzz-android = harfbuzz;
    };
}
