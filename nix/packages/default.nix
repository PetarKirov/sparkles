{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      root = ../..;
      fs = lib.fileset;
      dToolchain = import ../d-toolchain.nix { inherit pkgs; };

      src = fs.toSource {
        inherit root;
        fileset = fs.unions [
          ../../scripts/ci.d
          ../../libs/core-cli/src
        ];
      };

      wrapEnvArgs = lib.concatStringsSep " \\\n        " (
        lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") dToolchain.env
      );
    in
    {
      packages.ci = pkgs.stdenv.mkDerivation (final: {
        pname = "ci";
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
            scripts/${final.pname}.d \
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
          description = "Repository CI helper for markdown examples, standalone examples, and markdown link maintenance";
          mainProgram = final.pname;
        };
      });

      apps.ci = {
        type = "app";
        program = lib.getExe config.packages.ci;
      };

    };
}
