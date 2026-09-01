# Pinned benchmark corpora and runner for the wired runtime JSON benchmark
# (libs/wired/bench/runtime).
#
# Datasets are declared in nix/packages/wired-bench-datasets.nix.
# - Bundled datasets are pinned by packages.wired-bench-data (exposed to devshell as $WIRED_BENCH_DATA)
# - External datasets are pinned by packages.wired-bench-external-data (opt-in; excluded from devshell)
# - run-wired-bench provides a unified wrapper script for running benchmarks.
{ inputs, ... }:
let
  datasets = import ./wired-bench-datasets.nix;
in
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (pkgs) lib;

      resolvePath =
        d: if d.subpath != "" then "${inputs.${d.input}}/${d.subpath}" else "${inputs.${d.input}}";

      bundledList = map (d: {
        inherit (d) name;
        path = resolvePath d;
      }) datasets.bundled;

      externalList = map (d: {
        inherit (d) name;
        path = resolvePath d;
      }) datasets.external;

      bundledSelectors = map (d: d.selector) datasets.bundled;
      externalSelectors = map (d: d.selector) datasets.external;
      allSelectors = bundledSelectors ++ externalSelectors;

      bundledListStr = lib.concatStringsSep "," bundledSelectors;
      allListStr = lib.concatStringsSep "," allSelectors;
    in
    {
      packages.wired-bench-data = pkgs.linkFarm "wired-bench-data" bundledList;
      packages.wired-bench-external-data = pkgs.linkFarm "wired-bench-external-data" externalList;

      packages.run-wired-bench = pkgs.writeShellApplication {
        name = "run-wired-bench";
        runtimeInputs = [
          pkgs.dub
          pkgs.ldc
          pkgs.pkg-config
        ];
        text = ''
          export WIRED_BENCH_DATA="${config.packages.wired-bench-data}"

          full_mode=0
          if [ "''${1:-}" = "--full" ] || [ "''${1:-}" = "--external" ]; then
            full_mode=1
            shift
          fi

          if [ "$full_mode" -eq 1 ]; then
            export WIRED_BENCH_EXTERNAL_DATA="${config.packages.wired-bench-external-data}"
            export WIRED_BENCH_DATASETS="''${WIRED_BENCH_DATASETS:-${allListStr}}"
            echo "==> Running full wired benchmark (bundled + external datasets)"
          else
            export WIRED_BENCH_DATASETS="''${WIRED_BENCH_DATASETS:-${bundledListStr}}"
            echo "==> Running standard wired benchmark (bundled datasets)"
          fi

          REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
          cd "$REPO_ROOT/libs/wired/bench/runtime"
          dub test -b bench -- --bench --perf --group-by=dataset,operation "$@"
        '';
      };

      apps.run-wired-bench = {
        type = "app";
        program = lib.getExe config.packages.run-wired-bench;
      };
      apps.wired-bench = {
        type = "app";
        program = lib.getExe config.packages.run-wired-bench;
      };
    };
}
