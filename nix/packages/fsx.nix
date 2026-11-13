# `fsx` (docs/specs/fsx): apps/fsx/package.nix, the package written as nixpkgs
# writes one, called with the flake's packages. `.#fsx` copies and lists,
# `.#fsx-full` compares too (`fsdiff`); both load the iroh bridge through
# their own run path.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.fsx = pkgs.callPackage ../../apps/fsx/package.nix { };
      packages.fsx-full = pkgs.callPackage ../../apps/fsx/package.nix { withDiff = true; };
    };
}
