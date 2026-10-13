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
        steps = _: [ { task = "notify-dub-registry"; } ];
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
            # A release pins what it built: never skipped as already proven.
            lazy.enable = false;
            env = cachixEnv;
            steps = _: [
              { task = "build-all-desktop"; }
              {
                task = "release-pin";
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
