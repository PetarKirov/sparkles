{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      ...
    }:
    let
      # The default build is GUI-enabled (BLD1): the native window
      # (`sparkles:wsi` drawn by `sparkles:ui-vulkan`, through MoltenVK on
      # macOS) and the markdown preview, so the installed binary has `--gui`.
      # That pulls libghostty-vt and needs fontconfig at runtime (the cell
      # font is resolved via fc-match), exactly like apps/terminal. The
      # `raylib` configuration is the raylib window, kept until it is retired;
      # a window-free binary is `dub build :hue -c no-gui` (BLD2).
      huePackage =
        {
          pname,
          configuration,
          raylib ? false,
          description,
        }:
        config.legacyPackages.buildSparklesApp (finalAttrs: {
          inherit pname;
          version = "0.1.0";
          appDir = "apps/hue";
          dubBuildFlags = [ "--config=${configuration}" ];

          # `hue --version` reports the commit (`TPG2`), so this package is
          # rebuilt (step 2 only) on every commit.
          stampBuildInfo = true;
          checkBuildInfo =
            if raylib then
              config.legacyPackages.checkHueRaylibBuildInfo
            else
              config.legacyPackages.checkHueBuildInfo;

          # `gitMinimal` for the same reason as apps/twoslash-extract: the format
          # preview (`FPR2`) links `sparkles:dmd-fmt`, so `dmd:frontend`'s
          # pre-generate step (`config.d`) runs here — and it shells out to
          # `git describe` for the compiler version string. It falls back to the
          # checked-in VERSION file when git *fails*, but throws outright when the
          # binary is missing, so git must exist at build time even though the
          # fetched source has no `.git`. No runtime wrap is needed: unlike the
          # semantic consumers, the formatter is lex/parse-only and never reads
          # `SPARKLES_DMD_IMPORT_PATH`.
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.gitMinimal
          ];

          buildInputs = [
            pkgs.tree-sitter
            inputs'.ghostty.packages.libghostty-vt
            inputs'.ghostty.packages.libghostty-vt.dev
          ]
          ++ lib.optional raylib pkgs.raylib;

          # `hue credits` (`TPG17`): the credits document and its staged
          # licence texts, beside the executable — the docs site's files (`TPG16`).
          installPhase = ''
            install -Dm755 build/hue $out/bin/${finalAttrs.pname}
            mkdir -p $out/share/hue
            cp -r ${config.legacyPackages.sparklesCredits.bundle} $out/share/hue/credits
          '';

          # Wrap so grammars resolve outside the devshell ($SPARKLES_TS_GRAMMAR_PATH
          # is only a *default* — a caller who exports their own still wins), so the
          # GUI's fontconfig lookups (fc-match) work under `nix run`, so live D
          # types (LIV1-LIV4) work out of the box: opening a `.d` file spawns
          # `twoslash-extract --dub --serve`, which hue finds via
          # $SPARKLES_TWOSLASH_EXTRACT before falling back to PATH. hue never links
          # the analyzer (PRJ13). Its extractor carries its own druntime/phobos
          # import paths but no toolchain (TC13): `--dub` runs the `dub` and
          # compiler on the user's PATH, and without them says why (PRJ7).
          # `curlMinimal` provides `libcurl.so.4` for runtime dlopen by Phobos
          # `std.net.curl` without linking it into DT_NEEDED or pulling full curl.
          postFixup = ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --set-default SPARKLES_TS_GRAMMAR_PATH ${config.packages.ts-grammars} \
              --set-default SPARKLES_TWOSLASH_EXTRACT ${lib.getExe config.packages.twoslash-extract.oracle} \
              --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]} \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.curlMinimal ]}
          '';

          meta = {
            inherit description;
            mainProgram = finalAttrs.pname;
          };
        });
    in
    {
      packages.hue = huePackage {
        pname = "hue";
        configuration = "application";
        description = "Interactive syntax-highlighting viewer and live theme previewer";
      };

      packages.hue-raylib = huePackage {
        pname = "hue-raylib";
        configuration = "raylib";
        raylib = true;
        description = "hue in its raylib window (with the CRT), kept until the raylib arm is retired";
      };
    };
}
