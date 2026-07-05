# Pinned benchmark corpora for the wired runtime JSON bench
# (libs/wired/bench/runtime). The canonical nativejson-benchmark trio —
# twitter.json (string-heavy), canada.json (float-heavy), citm_catalog.json
# (structure-heavy) — plus simdjson's github_events.json for the small-document
# regime. Fetched by hash, never checked into the repo; the devshell exposes
# the farm as $WIRED_BENCH_DATA (the harness's --data-dir overrides it).
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # miloyip/nativejson-benchmark master
      njbRev = "478d5727c2a4048e835a29c65adecc7d795360d5";
      # simdjson, last commit before PR #1582 deleted most of jsonexamples/
      simdjsonRev = "19c3b1315a2a6b8ab0a6b7335bb97269cbd0a448";

      fromNjb =
        name: hash:
        pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/${njbRev}/data/${name}";
          inherit hash;
        };
      fromSimdjson =
        name: hash:
        pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/simdjson/simdjson/${simdjsonRev}/jsonexamples/${name}";
          inherit hash;
        };
    in
    {
      packages.wired-bench-data = pkgs.linkFarm "wired-bench-data" [
        {
          name = "twitter.json";
          path = fromNjb "twitter.json" "sha256-oIt2nzK5X0JsvDq6/OxlwaGdPrVE1N3zIOrhQsme/F0=";
        }
        {
          name = "citm_catalog.json";
          path = fromNjb "citm_catalog.json" "sha256-pz56iD9uqN4RPf9ZcCl15gEZtLWNRR1RipKfMckuIFk=";
        }
        {
          name = "canada.json";
          path = fromNjb "canada.json" "sha256-+Ds7NUAw1d1YdAxorE/s72TLcwoNEqkDYqfyMHf1DXg=";
        }
        {
          name = "github_events.json";
          path = fromSimdjson "github_events.json" "sha256-ye67LPLUZkkFnp1IcAkZuss+jg+1hFIGWhqd53eP0i4=";
        }
      ];
    };
}
