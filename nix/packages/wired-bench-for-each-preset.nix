# `forEachPreset prefix mk`: one package per ISA preset of the wired runtime
# JSON bench (./wired-bench-isa-presets.nix), named `<prefix>-<preset.attr>`.
# Not a flake-parts module: a plain function from `pkgs`.
pkgs: prefix: mk:
pkgs.lib.listToAttrs (
  map (preset: pkgs.lib.nameValuePair "${prefix}-${preset.attr}" (mk preset)) (
    import ./wired-bench-isa-presets.nix pkgs
  )
)
