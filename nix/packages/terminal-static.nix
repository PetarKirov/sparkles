# The terminal's `vulkan` configuration as a self-contained program
# (toolchain specification TC20): built by dlang.nix's
# `ldc-vulkan-llvm-runtimes` (TC18), with every D, C and C++ dependency linked
# statically and compiled by the same `clang-sparkles` against LLVM's runtimes.
# Dynamic remain only the C library and what the platform loads at run time:
# the Vulkan loader, which loads the graphics drivers, and the window system
# (Wayland, XCB, xkbcommon). Linux only.
#
# The bundled libraries:
#
# - HarfBuzz, the release sparkles:font pins (./harfbuzz.nix), with FreeType,
#   libpng and zlib beneath it, and no GLib, Graphite2 or ICU. It needs no C++
#   runtime, so the terminal links no libc++ at all.
# - tree-sitter's runtime (sparkles:doc-view's highlighting), one C file.
#   Grammars stay plugins, loaded from `SPARKLES_TS_GRAMMAR_PATH`.
# - raylib with its own GLFW, which loads GL and the X libraries at run time.
#   It draws the selection handles alone, until the terminal leaves
#   sparkles:raylib-text's `library` configuration (ui-vulkan PLAN, V7); that
#   move drops raylib, FreeType and libpng from this list.
# - libghostty-vt's own static archive (zig-built, with simdutf and highway
#   inside), less two things: the debug info that names zig's store paths,
#   and zig's `compiler_rt.o`, whose weak `memcpy`, `memset` and `memmove`
#   would otherwise replace glibc's for the whole program. Everything that
#   object provides comes from glibc, libm or compiler-rt's builtins.
#
# dub asks pkg-config for every library in one call; `bundledPkgConfig` asks
# for the bundled ones with `--static` (their private dependencies) and for
# the platform's without (wayland's private libffi has no `.pc` here).
#
# `checks.terminal-static` asserts the result: its `NEEDED` entries are all
# platform interfaces, none is a GCC or LLVM runtime, and it starts.
{ inputs, lib, ... }:
let
  # The libraries this package links statically, by pkg-config name.
  bundled = [
    "harfbuzz"
    "freetype2"
    "raylib"
    "tree-sitter"
    "libghostty-vt"
  ];

  # The shared libraries a self-contained program may need (TC20): the C
  # library, the Vulkan loader and the window system.
  platformInterfaces = [
    "libc\\.so\\.6"
    "libm\\.so\\.6"
    "libdl\\.so\\.2"
    "librt\\.so\\.1"
    "libpthread\\.so\\.0"
    "ld-linux-[a-z0-9_-]+\\.so\\.[0-9]+"
    "libvulkan\\.so\\.1"
    "libwayland-client\\.so\\.0"
    "libxcb(-[a-z]+)?\\.so\\.[0-9]+"
    "libxkbcommon(-x11)?\\.so\\.0"
  ];
in
{
  perSystem =
    {
      config,
      inputs',
      pkgs,
      ...
    }:
    # `mkIf`, not `optionalAttrs`: the condition reads `pkgs`, a module argument.
    lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
      let
        dlang = inputs'.dlang-nix;

        # Static libraries, by the profile's `clang-sparkles`.
        staticStdenv = pkgs.stdenvAdapters.makeStaticLibraries dlang.legacyPackages.clangStdenv-sparkles-llvm-runtimes;

        zlib = pkgs.zlib.override {
          stdenv = staticStdenv;
          shared = false;
        };
        libpng = pkgs.libpng.override {
          stdenv = staticStdenv;
          inherit zlib;
        };
        freetype =
          (pkgs.freetype.override {
            stdenv = staticStdenv;
            inherit zlib libpng;
          }).overrideAttrs
            (old: {
              buildInputs = [ ];
              propagatedBuildInputs = [
                zlib
                libpng
              ];
              configureFlags = old.configureFlags ++ [
                "--without-bzip2"
                "--without-brotli"
                "--without-harfbuzz"
              ];
              # nixpkgs' installs `freetype-config` against the shared library.
              postInstall = "";
              doCheck = false;
            });
        harfbuzz =
          (config.packages.harfbuzz.override {
            stdenv = staticStdenv;
            inherit freetype;
            withIntrospection = false;
            withGraphite2 = false;
          }).overrideAttrs
            (old: {
              outputs = [
                "out"
                "dev"
              ];
              buildInputs = [ ];
              propagatedBuildInputs = [ freetype ];
              nativeBuildInputs = [
                pkgs.meson
                pkgs.ninja
                pkgs.pkg-config
                pkgs.python3
              ];
              mesonFlags = [
                "-Ddefault_library=static"
                "-Dfreetype=enabled"
                "-Dglib=disabled"
                "-Dgobject=disabled"
                "-Dintrospection=disabled"
                "-Dgraphite2=disabled"
                "-Dicu=disabled"
                "-Dcairo=disabled"
                "-Dchafa=disabled"
                "-Dtests=disabled"
                "-Ddocs=disabled"
                "-Dutilities=disabled"
                "-Dgpu_demo=disabled"
              ];
              postInstall = "";
              postFixup = "";
              doCheck = false;
              doInstallCheck = false;
            });
        tree-sitter = staticStdenv.mkDerivation {
          pname = "tree-sitter-runtime-static";
          inherit (pkgs.tree-sitter) version src;
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            $CC -c lib/src/lib.c -o lib.o -Ilib/include -Ilib/src -O2 -fPIC
            $AR rcs libtree-sitter.a lib.o
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm644 libtree-sitter.a $out/lib/libtree-sitter.a
            cp -r lib/include $out/include
            mkdir -p $out/lib/pkgconfig
            cat > $out/lib/pkgconfig/tree-sitter.pc <<EOF
            Name: tree-sitter
            Description: tree-sitter's runtime
            Version: ${pkgs.tree-sitter.version}
            Cflags: -I$out/include
            Libs: -L$out/lib -ltree-sitter
            EOF
            runHook postInstall
          '';
          meta = {
            description = "tree-sitter's C runtime as a static library";
            inherit (pkgs.tree-sitter.meta) license homepage;
          };
        };
        raylib =
          (pkgs.raylib.override {
            stdenv = staticStdenv;
            sharedLib = false;
          }).overrideAttrs
            (old: {
              # GLFW's X11 and Wayland headers; it loads their libraries itself.
              buildInputs = [
                pkgs.libx11
                pkgs.libxrandr
                pkgs.libxinerama
                pkgs.libxcursor
                pkgs.libxi
                pkgs.libxext
                pkgs.libGL
                pkgs.wayland
                pkgs.libxkbcommon
              ];
              nativeBuildInputs = [
                pkgs.cmake
                pkgs.pkg-config
                pkgs.wayland-scanner
              ];
              propagatedBuildInputs = [ ];
              appendRunpaths = [ ];
              cmakeFlags = [
                "-DCUSTOMIZE_BUILD=ON"
                "-DSUPPORT_CUSTOM_FRAME_CONTROL=OFF"
                "-DPLATFORM=Desktop"
                "-DUSE_EXTERNAL_GLFW=OFF"
                "-DGLFW_BUILD_WAYLAND=OFF"
                "-DINCLUDE_EVERYTHING=ON"
                "-DBUILD_SHARED_LIBS=OFF"
                "-DBUILD_EXAMPLES=OFF"
              ];
            });
        vt = inputs'.ghostty.packages.libghostty-vt;
        ghostty =
          pkgs.runCommand "libghostty-vt-static-${vt.version}" { nativeBuildInputs = [ pkgs.binutils ]; }
            ''
              mkdir -p $out/lib/pkgconfig
              install -m644 ${vt.dev}/lib/libghostty-vt.a $out/lib/
              strip -g $out/lib/libghostty-vt.a
              ar d $out/lib/libghostty-vt.a compiler_rt.o
              cp -r ${vt.dev}/include $out/include
              cat > $out/lib/pkgconfig/libghostty-vt.pc <<EOF
              Name: libghostty-vt
              Description: Ghostty's terminal emulation, as a static library
              Version: ${vt.version}
              Cflags: -I$out/include
              Libs: -L$out/lib -lghostty-vt
              EOF
            '';

        bundledPkgConfig = pkgs.writeShellScriptBin "pkg-config" ''
          opts=() bundled=() platform=()
          for a in "$@"; do
            case "$a" in
              -*) opts+=("$a") ;;
              ${lib.concatStringsSep "|" bundled}) bundled+=("$a") ;;
              *) platform+=("$a") ;;
            esac
          done
          if (( ''${#bundled[@]} + ''${#platform[@]} == 0 )); then
            exec ${lib.getExe' pkgs.pkg-config "pkg-config"} "$@"
          fi
          out=""
          if (( ''${#bundled[@]} )); then
            out+="$(${lib.getExe' pkgs.pkg-config "pkg-config"} --static "''${opts[@]}" "''${bundled[@]}") " || exit
          fi
          if (( ''${#platform[@]} )); then
            out+="$(${lib.getExe' pkgs.pkg-config "pkg-config"} "''${opts[@]}" "''${platform[@]}")" || exit
          fi
          echo "$out"
        '';

        terminal-static = config.legacyPackages.buildSparklesApp (finalAttrs: {
          pname = "terminal-static";
          version = "0.1.0";
          appDir = "apps/terminal";
          dubBuildFlags = [ "--config=vulkan" ];
          compiler = pkgs.ldc-llvm-runtimes.reproducible;

          # Ahead of `pkgs.pkg-config`, which buildSparklesApp adds.
          nativeBuildInputs = [
            bundledPkgConfig
            pkgs.pkg-config
          ];
          # Ahead of the shared HarfBuzz and FreeType buildSparklesApp adds
          # for sparkles:raylib-text: pkg-config finds these first.
          buildInputs = [
            harfbuzz
            harfbuzz.dev
            freetype
            freetype.dev
            libpng
            libpng.dev
            zlib
            zlib.dev
            tree-sitter
            raylib
            raylib.dev
            ghostty
          ];

          installPhase = ''
            install -Dm755 build/terminal $out/bin/${finalAttrs.pname}
          '';

          # As `terminal`: grammars and `fc-match` come from the store.
          postFixup = ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --set-default SPARKLES_TS_GRAMMAR_PATH ${config.packages.ts-grammars} \
              --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
          '';

          passthru.bundled = {
            inherit
              zlib
              libpng
              freetype
              harfbuzz
              tree-sitter
              raylib
              ghostty
              ;
          };

          meta = {
            description = "The terminal on the Vulkan arm, linked self-contained under the all-LLVM runtime profile";
            mainProgram = finalAttrs.pname;
          };
        });
      in
      {
        packages.terminal-static = terminal-static;

        checks.terminal-static =
          pkgs.runCommand "terminal-static-check"
            {
              nativeBuildInputs = [ pkgs.binutils ];
            }
            ''
              exe=${terminal-static}/bin/.terminal-static-wrapped
              readelf -d $exe | tee dynamic.txt
              grep -oP '(?<=Shared library: \[)[^]]+' dynamic.txt > needed.txt
              if grep -vxE '${lib.concatStringsSep "|" platformInterfaces}' needed.txt; then
                echo "needed beyond the platform interfaces (above)"
                exit 1
              fi
              if grep -E 'libgcc_s|libstdc\+\+|libc\+\+|libunwind' needed.txt; then
                echo "a GCC or LLVM runtime is linked dynamically"
                exit 1
              fi
              $exe --help > help.txt
              grep -q 'SYNOPSIS' help.txt
              LD_DEBUG=libs $exe --version 2> loaded.txt > /dev/null
              if grep -E 'libgcc_s|libstdc\+\+' loaded.txt; then
                echo "the program loaded a GCC runtime"
                exit 1
              fi
              touch $out
            '';
      }
    );
}
