# `hue` — the interactive syntax-highlighting viewer / live theme previewer
# (apps/hue), packaged for `nix run .#hue`. Built with `buildSparklesApp`
# (./build-sparkles-app.nix), which handles the in-tree source closure, the
# reference scrub, and the app boilerplate; only the hue-specific bits stay
# here: pkg-config + tree-sitter for the ImportC surface (dub#3085 feeds it to
# `sparkles:syntax`), and a wrapper baking in the grammar bundle so
# `sparkles:tree-sitter` dlopen()s grammars from $SPARKLES_TS_GRAMMAR_PATH
# without the devshell.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    {
      packages.hue = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "hue";
        version = "0.1.0";

        # Shared with `ci`/`release` and the example derivations (./examples.nix).
        dubLock = ../../nix/dub-lock.json;
        compiler = pkgs.ldc;

        # pkg-config + the C library so dub#3085 feeds -P-I… to ImportC for
        # <tree_sitter/api.h>.
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.tree-sitter ];

        # Phobos bakes store paths that must not leak into the runtime closure:
        # ldc's separate `include` output (assert/`__FILE__` strings), the
        # nixpkgs libcurl dlopen path, and tzdata — none reached at runtime. The
        # scrub is derived from this list by buildSparklesApp. Same discipline
        # as the example derivations (./examples.nix) and `release`.
        disallowedReferences = [
          pkgs.ldc
          pkgs.ldc.include
          pkgs.curl.out
          pkgs.tzdata
        ];

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
