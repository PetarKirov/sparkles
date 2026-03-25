# Sanitizes and formats NVMe SSDs — meant for NixOS USB installer images. It
# drives `nvme` (nvme-cli) as a child process, so the wrapper puts nvme-cli
# and util-linux on PATH rather than trusting the ambient environment.
#
# Linux only: nvme-cli (and the NVMe ioctls it wraps) exist nowhere else, so
# on other systems the output is simply absent — which also keeps it out of
# the macOS `all-desktop` aggregate.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, system, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) {
      packages.nvme-sanitize = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "nvme-sanitize";
        version = "0.1.0";

        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --prefix PATH : ${
              lib.makeBinPath [
                pkgs.nvme-cli
                pkgs.util-linux
              ]
            }
        '';

        meta = {
          description = "Sanitize and format NVMe SSDs";
          platforms = lib.platforms.linux;
          mainProgram = finalAttrs.pname;
        };
      });

      apps.nvme-sanitize = {
        type = "app";
        program = lib.getExe config.packages.nvme-sanitize;
      };
    };
}
