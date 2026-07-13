# `hue` — the interactive syntax-highlighting viewer / live theme previewer
# (apps/hue), packaged for `nix run .#hue`. Built like the example derivations
# (pkg-config + tree-sitter for the ImportC surface dub#3085 feeds to
# `sparkles:syntax`), then wrapped so the tree-sitter grammar bundle is found
# at runtime without the devshell: `sparkles:tree-sitter` dlopen()s grammars
# from $SPARKLES_TS_GRAMMAR_PATH, so bake the `ts-grammars` linkFarm in.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      fs = lib.fileset;
      root = ../..;
      fromRoot = lib.path.append root;

      isDubManifest =
        file:
        builtins.elem file.name [
          "dub.sdl"
          "dub.selections.json"
        ];

      src = fs.toSource {
        inherit root;
        fileset = fs.unions (
          [
            # Dub validates every sub-package declared in the root dub.sdl, so
            # all sibling manifests must be present even when building only :hue.
            (fs.fileFilter isDubManifest root)
          ]
          # hue's own sources plus the library closure it links against:
          # syntax → {base, tree-sitter}; core-cli → {base, math}; and the impl
          # runner sources base/core-cli import the `@…` attributes from
          # unconditionally. `.c`/`.i` come along for the tree-sitter ImportC shim.
          ++
            map
              (path: fs.fileFilter (file: file.hasExt "d" || file.hasExt "c" || file.hasExt "i") (fromRoot path))
              [
                "apps/hue/src"
                "libs/base/src"
                "libs/core-cli/src"
                "libs/math/src"
                "libs/syntax/src"
                "libs/tree-sitter/src"
                "libs/test-runner/src"
                "libs/test-runner-impl/src"
              ]
        );
      };
    in
    {
      packages.hue = pkgs.buildDubPackage (finalAttrs: {
        pname = "hue";
        version = "0.1.0";

        inherit src;
        sourceRoot = "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

        # Shared with `ci`/`release` and the example derivations (./examples.nix).
        dubLock = fromRoot "nix/dub-lock.json";
        compiler = pkgs.ldc;

        # pkg-config + the C library so dub#3085 feeds -P-I… to ImportC for
        # <tree_sitter/api.h>; makeWrapper to inject the grammar bundle.
        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.makeWrapper
        ];
        buildInputs = [ pkgs.tree-sitter ];

        preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

        # Phobos bakes store paths that must not leak into the runtime closure:
        # ldc's separate `include` output (assert/`__FILE__` strings), the
        # nixpkgs libcurl dlopen path, and tzdata — none reached at runtime. Same
        # discipline as the example derivations (./examples.nix) and `release`.
        disallowedReferences = [
          pkgs.ldc
          pkgs.ldc.include
          pkgs.curl.out
          pkgs.tzdata
        ];

        installPhase = ''
          install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
        '';

        # postFixup (after buildDubPackage's preFixup scrub): strip the baked
        # phobos service paths, then wrap so grammars resolve outside the
        # devshell. $SPARKLES_TS_GRAMMAR_PATH is only a *default* — a caller who
        # exports their own still wins (--set-default).
        postFixup = ''
          find "$out" -type f -exec remove-references-to \
            -t ${pkgs.ldc.include} -t ${pkgs.curl.out} -t ${pkgs.tzdata} '{}' +
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
