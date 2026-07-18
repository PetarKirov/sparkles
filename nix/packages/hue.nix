{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    {
      packages.hue = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "hue";
        version = "0.1.0";

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.tree-sitter ];

        # Wrap so grammars resolve outside the devshell. $SPARKLES_TS_GRAMMAR_PATH
        # is only a *default* — a caller who exports their own still wins.
        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --set-default SPARKLES_TS_GRAMMAR_PATH ${config.packages.ts-grammars}
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
