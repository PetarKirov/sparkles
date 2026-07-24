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
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        env = d-toolchain.env;

        # Wrap so grammars resolve outside the devshell ($SPARKLES_TS_GRAMMAR_PATH
        # is only a *default* — a caller who exports their own still wins), and so
        # the GUI's fontconfig lookups (fc-match) work under `nix run`.
        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --set-default SPARKLES_TS_GRAMMAR_PATH ${config.packages.ts-grammars} \
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
