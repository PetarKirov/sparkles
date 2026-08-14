# Pinned benchmark corpora for the wired runtime JSON bench
# (libs/wired/bench/runtime). The canonical nativejson-benchmark trio —
# twitter.json (string-heavy), canada.json (float-heavy), citm_catalog.json
# (structure-heavy) — plus simdjson's github_events.json for the small-document
# regime and mesh compact/pretty for dense numeric arrays and whitespace.
# Pulled from the nativejson-benchmark and simdjson flake inputs (never
# checked into the repo); the devshell exposes the farm as $WIRED_BENCH_DATA.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.wired-bench-data = pkgs.linkFarm "wired-bench-data" [
        {
          name = "twitter.json";
          path = "${inputs.nativejson-benchmark}/data/twitter.json";
        }
        {
          name = "citm_catalog.json";
          path = "${inputs.nativejson-benchmark}/data/citm_catalog.json";
        }
        {
          name = "canada.json";
          path = "${inputs.nativejson-benchmark}/data/canada.json";
        }
        {
          name = "github_events.json";
          path = "${inputs.simdjson-src}/jsonexamples/github_events.json";
        }
        {
          name = "mesh.json";
          path = "${inputs.simdjson-src}/jsonexamples/mesh.json";
        }
        {
          name = "mesh.pretty.json";
          path = "${inputs.simdjson-src}/jsonexamples/mesh.pretty.json";
        }
      ];
    };
}
