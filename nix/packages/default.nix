{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.dedup_md_reference_links = pkgs.stdenv.mkDerivation {
        pname = "dedup_md_reference_links";
        version = "0.1.0";

        src = ../../scripts/dedup_md_reference_links.d;
        dontUnpack = true;

        nativeBuildInputs = [ pkgs.ldc ];

        buildPhase = ''
          cp $src dedup_md_reference_links.d
          ldc2 -of=dedup_md_reference_links dedup_md_reference_links.d
        '';

        installPhase = ''
          mkdir -p $out/bin
          mv dedup_md_reference_links $out/bin/
        '';

        meta = {
          description = "Find and fix duplicate markdown reference definitions pointing to the same URL";
          mainProgram = "dedup_md_reference_links";
        };
      };
    };
}
