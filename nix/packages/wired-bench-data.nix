# Pinned benchmark corpora and runner for the wired runtime JSON benchmark
# (libs/wired/bench/runtime).
#
# Datasets are declared in nix/packages/wired-bench-datasets.nix.
# - Light datasets (< 5 MB) are pinned by packages.wired-bench-data (exposed to devshell as $WIRED_BENCH_DATA)
# - Medium (10 MB - 200 MB) and Huge (> 1 GB) corpora are opt-in (excluded from devshell).
# - run-wired-bench provides a unified wrapper script supporting --light, --medium, and --huge.
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
        d:
        let
          src =
            if d ? input then
              if d.subpath != "" then "${inputs.${d.input}}/${d.subpath}" else "${inputs.${d.input}}"
            else
              pkgs.emptyFile;
        in
        if d ? decompress && d.decompress == "gz" then
          pkgs.runCommand d.name { } "${pkgs.gzip}/bin/gunzip -c ${src} > $out"
        else if d ? decompress && d.decompress == "zstd" then
          pkgs.runCommand d.name { } "${pkgs.zstd}/bin/zstd -d -c ${src} > $out"
        else
          src;

      mapList =
        list:
        map (d: {
          inherit (d) name;
          path = resolvePath d;
        }) list;

      lightList = mapList datasets.light;
      mediumList = mapList datasets.medium;

      lightSelectors = map (d: d.selector) datasets.light;
      mediumSelectors = map (d: d.selector) datasets.medium;
      hugeSelectors = map (d: d.selector) datasets.huge;
      mediumPlusLightSelectors = lightSelectors ++ mediumSelectors;
      allSelectors = lightSelectors ++ mediumSelectors ++ hugeSelectors;

      lightListStr = lib.concatStringsSep "," lightSelectors;
      mediumPlusLightListStr = lib.concatStringsSep "," mediumPlusLightSelectors;
      allListStr = lib.concatStringsSep "," allSelectors;

      hugeFetchScript = lib.concatStringsSep "\n" (
        map (d: ''
          if [ ! -s "$CACHE_DIR/${d.name}" ]; then
            echo "==> Fetching ${d.selector} dataset (${d.url})..."
            curl -f -L --progress-bar -C - "${d.url}" -o "$CACHE_DIR/${d.downloadName}"
            ${
              if d ? decompress && d.decompress == "gz" then
                ''
                  echo "==> Decompressing ${d.downloadName} -> ${d.name}..."
                  gzip -dc "$CACHE_DIR/${d.downloadName}" > "$CACHE_DIR/${d.name}.tmp"
                  mv "$CACHE_DIR/${d.name}.tmp" "$CACHE_DIR/${d.name}"
                ''
              else if d ? decompress && d.decompress == "zstd" then
                ''
                  echo "==> Decompressing ${d.downloadName} -> ${d.name}..."
                  zstd -d -c "$CACHE_DIR/${d.downloadName}" > "$CACHE_DIR/${d.name}.tmp"
                  mv "$CACHE_DIR/${d.name}.tmp" "$CACHE_DIR/${d.name}"
                ''
              else if d.name != d.downloadName then
                ''
                  mv "$CACHE_DIR/${d.downloadName}" "$CACHE_DIR/${d.name}"
                ''
              else
                ""
            }
          fi
        '') datasets.huge
      );
    in
    {
      packages.wired-bench-data = pkgs.linkFarm "wired-bench-data" lightList;
      packages.wired-bench-light-data = config.packages.wired-bench-data;
      packages.wired-bench-medium-data = pkgs.linkFarm "wired-bench-medium-data" mediumList;

      packages.run-wired-bench = pkgs.writeShellApplication {
        name = "run-wired-bench";
        runtimeInputs = [
          pkgs.curl
          pkgs.gzip
          pkgs.zstd
          pkgs.dub
          pkgs.ldc
          pkgs.pkg-config
        ];
        text = ''
          export WIRED_BENCH_DATA="${config.packages.wired-bench-data}"

          tier="light"
          if [ "''${1:-}" = "--huge" ] || [ "''${1:-}" = "--full" ] || [ "''${1:-}" = "--external" ]; then
            tier="huge"
            shift
          elif [ "''${1:-}" = "--medium" ]; then
            tier="medium"
            shift
          elif [ "''${1:-}" = "--light" ]; then
            tier="light"
            shift
          fi

          if [ "$tier" = "huge" ]; then
            CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/sparkles/wired-bench-data"
            mkdir -p "$CACHE_DIR"
            ${hugeFetchScript}
            export WIRED_BENCH_EXTERNAL_DATA="$CACHE_DIR"
            export WIRED_BENCH_DATASETS="''${WIRED_BENCH_DATASETS:-${allListStr}}"
            echo "==> Running huge wired benchmark (light + medium + huge datasets)"
          elif [ "$tier" = "medium" ]; then
            export WIRED_BENCH_EXTERNAL_DATA="${config.packages.wired-bench-medium-data}"
            export WIRED_BENCH_DATASETS="''${WIRED_BENCH_DATASETS:-${mediumPlusLightListStr}}"
            echo "==> Running medium wired benchmark (light + medium datasets)"
          else
            export WIRED_BENCH_DATASETS="''${WIRED_BENCH_DATASETS:-${lightListStr}}"
            echo "==> Running light wired benchmark (< 5 MB datasets)"
          fi

          REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
          cd "$REPO_ROOT/libs/wired/bench/runtime"
          dub test -b bench -c unittest-foreign -- --bench --perf --group-by=dataset,operation "$@"
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
