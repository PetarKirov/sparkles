# Central manifest of opt-in / lazy flake inputs and package derivations.
#
# - `excludedFlakeInputs`: omitted from $SPARKLES_FLAKE_INPUT_* in nix/shells/default.nix
#   so `nix develop` and CI shells do not eagerly fetch multi-gigabyte corpora.
# - `excludedCiPackages`: omitted from `packages.all-desktop` in nix/packages/all.nix
#   so CI's `nix build .#all-desktop` never builds/fetches opt-in benchmark data or runners.
let
  datasets = import ./packages/wired-bench-datasets.nix;
in
{
  # Programmatically derived from the external dataset catalog:
  excludedFlakeInputs = map (d: d.input) (builtins.filter (d: d ? input) datasets.external);

  # Packages excluded from the desktop CI build aggregate:
  excludedCiPackages = [
    "wired-bench-medium-data"
    "run-wired-bench"
  ];
}
