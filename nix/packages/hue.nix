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
      inherit (config.legacyPackages) d-toolchain;
    in
    {
      # The default build is GUI-enabled (BLD1): it compiles the raylib backend
      # (src/gui*.d) and the markdown preview in, so the installed binary has
      # `--gui`. That pulls raylib + libghostty-vt as build inputs and needs
      # fontconfig at runtime (FontSet resolves fonts via fc-match), exactly like
      # apps/terminal. A raylib-free binary is `dub build :hue -c no-gui` (BLD2).
      packages.hue = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "hue";
        version = "0.1.0";

        nativeBuildInputs = [ pkgs.pkg-config ];

        buildInputs = [
          pkgs.tree-sitter
          pkgs.raylib
          # DPR1: the forge client fetches over libcurl (std.net.curl). The
          # `application`/`no-gui` dub configurations declare `libs "curl"`;
          # the Android build does not, and links none.
          #
          # `lib.getLib`, not a bare `pkgs.curl`: curl's default output is
          # `bin`, which carries no `lib/` — so the plain spelling links (from
          # some other input's closure) and then fails at RUN time with
          # "libcurl.so.4: cannot open shared object file".
          (lib.getLib pkgs.curl)
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        env = d-toolchain.env;

        # Wrap so grammars resolve outside the devshell ($SPARKLES_TS_GRAMMAR_PATH
        # is only a *default* — a caller who exports their own still wins), so the
        # GUI's fontconfig lookups (fc-match) work under `nix run`, and so live D
        # types (LIV1-LIV4) work out of the box: opening a `.d` file spawns
        # `twoslash-extract --dub --serve`, which hue finds via
        # $SPARKLES_TWOSLASH_EXTRACT before falling back to PATH. hue never links
        # the analyzer (PRJ13) — the flake-built extractor carries its own
        # druntime/phobos import paths and `dub`, so the pair composes.
        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --set-default SPARKLES_TS_GRAMMAR_PATH ${config.packages.ts-grammars} \
            --set-default SPARKLES_TWOSLASH_EXTRACT ${lib.getExe config.packages.twoslash-extract} \
            --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
        '';

        meta = {
          description = "Interactive syntax-highlighting viewer and live theme previewer";
          mainProgram = finalAttrs.pname;
        };
      });

      apps.hue = {
        type = "app";
        program = lib.getExe config.packages.hue;
      };
    };
}
