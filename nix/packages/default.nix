{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      root = ../..;
      fs = lib.fileset;
      dToolchain = import ../d-toolchain.nix { inherit pkgs; };

      src = fs.toSource {
        inherit root;
        fileset = fs.unions [
          ../../scripts/run_md_examples.d
          ../../libs/core-cli/src
        ];
      };

      wrapEnvArgs = lib.concatStringsSep " \\\n        " (
        lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") dToolchain.env
      );
    in
    {
      packages.run_md_examples = pkgs.stdenv.mkDerivation (final: {
        pname = "run_md_examples";
        version = "0.1.0";

        inherit src;
        strictDeps = true;

        nativeBuildInputs = [
          pkgs.makeWrapper
        ]
        ++ [ dToolchain.ldc ];

        buildPhase = ''
          srcs=$(find libs/core-cli/src -name '*.d' ! -name 'app.d' ! -name 'test_utils.d')

          ldc2 \
            -preview=in -preview=dip1000 \
            -I libs/core-cli/src \
            -J libs/core-cli/src \
            -of=${final.pname} \
            scripts/run_md_examples.d \
            $srcs
        '';

        installPhase = ''
          install -Dm755 ${final.pname} $out/bin/${final.pname}

          wrapProgram $out/bin/${final.pname} \
            --prefix PATH : ${
              lib.makeBinPath ([
                pkgs.dub
                pkgs.git
                dToolchain.ldc
              ])
            } \
            ${wrapEnvArgs} \
            --run 'ulimit -n ${toString dToolchain.nofileLimit} 2>/dev/null || true'
        '';

        meta = {
          description = "Extract and run dub single-file examples from markdown files";
          mainProgram = final.pname;
        };
      });

    };
}
