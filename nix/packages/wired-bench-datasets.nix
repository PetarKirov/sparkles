# Pinned benchmark dataset catalog for the wired runtime JSON benchmark.
#
# Single source of truth for:
# 1. Scale tiers: light (< 5 MB), medium (10 MB - 200 MB), huge (> 1 GB)
# 2. Package derivations (packages.wired-bench-light-data, medium, huge)
# 3. Flake input exclusions in nix/flake-exclusions.nix
# 4. Programmatic selector lists in packages.run-wired-bench
let
  light = [
    {
      name = "twitter.json";
      selector = "twitter";
      tier = "light";
      input = "nativejson-benchmark";
      subpath = "data/twitter.json";
    }
    {
      name = "citm_catalog.json";
      selector = "citm_catalog";
      tier = "light";
      input = "nativejson-benchmark";
      subpath = "data/citm_catalog.json";
    }
    {
      name = "canada.json";
      selector = "canada";
      tier = "light";
      input = "nativejson-benchmark";
      subpath = "data/canada.json";
    }
    {
      name = "github_events.json";
      selector = "github_events";
      tier = "light";
      input = "simdjson-src";
      subpath = "jsonexamples/github_events.json";
    }
    {
      name = "mesh.json";
      selector = "mesh";
      tier = "light";
      input = "simdjson-src";
      subpath = "jsonexamples/mesh.json";
    }
    {
      name = "mesh.pretty.json";
      selector = "mesh_pretty";
      tier = "light";
      input = "simdjson-src";
      subpath = "jsonexamples/mesh.pretty.json";
    }
    {
      name = "wikidata.json";
      selector = "wikidata";
      tier = "light";
      input = "wired-bench-external-wikidata";
      subpath = "";
    }
    {
      name = "osm.json";
      selector = "osm";
      tier = "light";
      input = "wired-bench-external-osm";
      subpath = "";
    }
    {
      name = "cloudtrail.ndjson";
      selector = "cloudtrail";
      tier = "light";
      input = "wired-bench-external-cloudtrail";
      subpath = "";
    }
    {
      name = "elasticsearch.ndjson";
      selector = "elasticsearch";
      tier = "light";
      input = "wired-bench-external-elasticsearch";
      subpath = "";
    }
  ];

  medium = [
  ];

  huge = [
    {
      name = "gharchive.ndjson";
      selector = "gharchive";
      tier = "huge";
      input = "wired-bench-external-gharchive";
      subpath = "";
    }
    {
      name = "amazon_reviews.ndjson";
      selector = "amazon_reviews";
      tier = "huge";
      input = "wired-bench-external-amazon-reviews";
      subpath = "";
    }
    {
      name = "osm_large.json";
      selector = "osm_large";
      tier = "huge";
      input = "wired-bench-external-osm-large";
      subpath = "";
    }
    {
      name = "wikidata_full.json";
      selector = "wikidata_full";
      tier = "huge";
      input = "wired-bench-external-wikidata-full";
      subpath = "";
    }
    {
      name = "openalex.ndjson";
      selector = "openalex";
      tier = "huge";
      input = "wired-bench-external-openalex";
      subpath = "";
    }
  ];
in
{
  inherit light medium huge;
  bundled = light;
  external = medium ++ huge;
  all = light ++ medium ++ huge;
}
