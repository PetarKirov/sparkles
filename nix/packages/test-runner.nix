# The test runner executable, `sparkles-test-runner`, built from the pinned
# revision of this repository in nix/test-runner-pin.json (test-runner
# process-model §9, TRN1). Test binaries never link it: they find it through
# `$SPARKLES_TEST_RUNNER`, which the dev shell and the `ci` wrapper export
# (TRN2), so a change to the working tree's runner reaches only its own
# package's tests until the pin moves.
#
# A pin file that names no revision builds the runner from the flake's own
# source: the bootstrap, until a revision of `main` carries the runner. To
# move the pin, set `rev` to a commit of `main` and `hash` to the output of
#
#   nix flake prefetch --json github:PetarKirov/sparkles/<rev> | jq -r .hash
#
# then check `nix build .#test-runner` and pin it in the cache
# (nix/pin-targets.nix).
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      pin = lib.importJSON ../test-runner-pin.json;
      pinned = pin.rev != null;
      src = pkgs.fetchFromGitHub {
        owner = "PetarKirov";
        repo = "sparkles";
        inherit (pin) rev hash;
      };
    in
    {
      packages.test-runner = config.legacyPackages.buildSparklesApp (
        finalAttrs:
        {
          pname = "sparkles-test-runner";
          version = if pinned then "pin-${builtins.substring 0 12 pin.rev}" else "bootstrap";
          appDir = "libs/test-runner-impl";
          # dub names the binary after `targetName`, not the package.
          installPhase = ''
            install -Dm755 build/sparkles-test-runner $out/bin/sparkles-test-runner
          '';
          meta = {
            description = "The sparkles:test-runner runner executable, built from a pinned revision";
            mainProgram = "sparkles-test-runner";
          };
        }
        // lib.optionalAttrs pinned {
          inherit src;
          sourceRoot = "${src.name}/libs/test-runner-impl";
          dubLock = "${src}/nix/dub-lock.json";
        }
      );
    };
}
