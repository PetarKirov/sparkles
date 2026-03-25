{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      root = ../..;
      fs = lib.fileset;
      runMdExamplesSrc = fs.toSource {
        inherit root;
        fileset = fs.unions [
          ../../scripts/run_md_examples.d
          ../../libs/core-cli/src
          ../../dub.sdl
        ];
      };
      nvmeSanitizeDeps = with pkgs; [
        nvme-cli
        util-linux
      ];
    in
    {
      packages.run_md_examples = pkgs.stdenv.mkDerivation {
        pname = "run_md_examples";
        version = "0.1.0";

        src = runMdExamplesSrc;

        nativeBuildInputs = [
          pkgs.ldc
          pkgs.makeWrapper
        ];

        buildPhase = ''
          srcs=$(find libs/core-cli/src -name '*.d' ! -name 'app.d' ! -name 'test_utils.d')

          ldc2 \
            -preview=in -preview=dip1000 \
            -I libs/core-cli/src \
            -J libs/core-cli/src \
            -of=run_md_examples \
            scripts/run_md_examples.d \
            $srcs
        '';

        installPhase = ''
          mkdir -p $out/bin
          mv run_md_examples $out/bin/
          wrapProgram $out/bin/run_md_examples \
            --prefix PATH : ${
              lib.makeBinPath [
                pkgs.dub
                pkgs.ldc
                pkgs.git
              ]
            }
        '';

        meta = {
          description = "Extract and run dub single-file examples from markdown files";
          mainProgram = "run_md_examples";
        };
      };

      packages.nvme-sanitize = pkgs.buildDubPackage rec {
        pname = "nvme-sanitize";
        version = "unstable";
        src = fs.toSource {
          inherit root;
          fileset = fs.fileFilter (
            file:
            builtins.any file.hasExt [
              "d"
              "sdl"
            ]
          ) root;
        };
        compiler = pkgs.ldc;
        dubLock = ./dub-lock.json;
        dubBuildFlags = [ ":nvme-sanitize" ];
        nativeBuildInputs = [ pkgs.makeWrapper ] ++ nvmeSanitizeDeps;
        dubBuildType = "debug";
        doCheck = false;
        installPhase = ''
          runHook preInstall
          install -Dm755 ./apps/nvme-sanitize/build/${pname} -t $out/bin/
          runHook postInstall
        '';
        dontStrip = true;
        postFixup = ''
          wrapProgram $out/bin/${pname} \
            --prefix PATH : "${lib.makeBinPath nvmeSanitizeDeps}"
        '';
        meta = {
          description = "Sanitize and format NVMe SSDs";
          platforms = lib.platforms.linux;
          mainProgram = pname;
        };
      };

    };
}
