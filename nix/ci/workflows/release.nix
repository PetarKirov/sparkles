# `.github/workflows/release.yml` — on a published release: tell the DUB
# registry, and build, push and pin the release closure per desktop system.
{ lib, ... }:
let
  cachixEnv = {
    CACHIX_CACHE = "sparkles";
    CACHIX_AUTH_TOKEN = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
  };
in
{
  ci.workflows.release = {
    name = "Release";
    on = {
      release.types = [ "published" ];
      workflow_dispatch = { };
    };
    concurrency = {
      group = "release-\${{ github.ref }}";
      cancel-in-progress = false;
    };
    jobs = {
      notify-dub-registry = {
        name = "notify the DUB registry";
        timeout-minutes = 10;
        cachix.push = false;
        steps = t: [
          {
            name = "Trigger the code.dlang.org update";
            run = t.ciScript "notify-dub-registry.sh" [ t.pkgs.curl ];
            env.DUB_REGISTRY_SECRET = "\${{ secrets.DUB_REGISTRY_SECRET }}";
          }
        ];
      };
    }
    // lib.listToAttrs (
      map
        (
          system:
          lib.nameValuePair "nix-build-pin-${system}" {
            name = "Nix build, push & pin (${system})";
            inherit system;
            timeout-minutes = 30;
            # `release-pin.sh` compares the tag with the highest one.
            checkout.fetch-depth = 0;
            env = cachixEnv;
            steps = t: [
              {
                name = "Build devShells.full, all packages, and all examples";
                run = t.ciScript "with-cachix.sh" [
                  t.pkgs.cachix
                  t.nix
                  t.pkgs.gitMinimal
                ];
                args = [
                  "nix"
                  "build"
                  "--print-build-logs"
                  ".#all-desktop"
                ];
              }
              {
                name = "Push & pin the release closure";
                run = t.ciScript "release-pin.sh" [
                  t.pkgs.cachix
                  t.nix
                  t.pkgs.gitMinimal
                ];
                env.CI_SYSTEM = system;
              }
            ];
          }
        )
        [
          "x86_64-linux"
          "aarch64-darwin"
        ]
    );
  };
}
