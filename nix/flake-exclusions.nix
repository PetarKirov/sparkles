# Central manifest of opt-in / lazy flake inputs and package derivations.
#
# - `excludedFlakeInputs`: omitted from $SPARKLES_FLAKE_INPUT_* in nix/shells/default.nix
#   so `nix develop` and CI shells do not eagerly fetch multi-gigabyte corpora,
#   or inputs only an opt-in output reads.
# - `excludedCiPackages`: omitted from `packages.all-desktop` in nix/packages/all.nix
#   so CI's `nix build .#all-desktop` never builds/fetches opt-in benchmark data or runners.
let
  datasets = import ./packages/wired-bench-datasets.nix;
in
{
  # The external dataset catalog's inputs, and nix-on-droid (read only by the
  # `terminal-nix-*` outputs, nix/packages/android/terminal-nix.nix):
  excludedFlakeInputs = map (d: d.input) (builtins.filter (d: d ? input) datasets.external) ++ [
    "nix-on-droid"
  ];

  # Packages excluded from the desktop CI build aggregate:
  excludedCiPackages = [
    "wired-bench-medium-data"
    "run-wired-bench"
  ];
}
