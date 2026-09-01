# Pinned benchmark dataset catalog for the wired runtime JSON benchmark.
#
# Single source of truth for:
# 1. Bundled corpora (linked in packages.wired-bench-data)
# 2. External opt-in corpora (linked in packages.wired-bench-external-data)
# 3. Flake input exclusions in nix/flake-exclusions.nix
# 4. Programmatic selector lists in packages.run-wired-bench
{
  bundled = [
    {
      name = "twitter.json";
      selector = "twitter";
      input = "nativejson-benchmark";
      subpath = "data/twitter.json";
    }
    {
      name = "citm_catalog.json";
      selector = "citm_catalog";
      input = "nativejson-benchmark";
      subpath = "data/citm_catalog.json";
    }
    {
      name = "canada.json";
      selector = "canada";
      input = "nativejson-benchmark";
      subpath = "data/canada.json";
    }
    {
      name = "github_events.json";
      selector = "github_events";
      input = "simdjson-src";
      subpath = "jsonexamples/github_events.json";
    }
    {
      name = "mesh.json";
      selector = "mesh";
      input = "simdjson-src";
      subpath = "jsonexamples/mesh.json";
    }
    {
      name = "mesh.pretty.json";
      selector = "mesh_pretty";
      input = "simdjson-src";
      subpath = "jsonexamples/mesh.pretty.json";
    }
  ];

  external = [
    {
      name = "wikidata.json";
      selector = "wikidata";
      input = "wired-bench-external-wikidata";
      subpath = "";
    }
    {
      name = "osm.json";
      selector = "osm";
      input = "wired-bench-external-osm";
      subpath = "";
    }
    {
      name = "cloudtrail.ndjson";
      selector = "cloudtrail";
      input = "wired-bench-external-cloudtrail";
      subpath = "";
    }
    {
      name = "elasticsearch.ndjson";
      selector = "elasticsearch";
      input = "wired-bench-external-elasticsearch";
      subpath = "";
    }
    {
      name = "gharchive.ndjson";
      selector = "gharchive";
      input = "wired-bench-external-gharchive";
      subpath = "";
    }
    {
      name = "amazon_reviews.ndjson";
      selector = "amazon_reviews";
      input = "wired-bench-external-amazon-reviews";
      subpath = "";
    }
    {
      name = "osm_large.json";
      selector = "osm_large";
      input = "wired-bench-external-osm-large";
      subpath = "";
    }
    {
      name = "wikidata_full.json";
      selector = "wikidata_full";
      input = "wired-bench-external-wikidata-full";
      subpath = "";
    }
    {
      name = "openalex.ndjson";
      selector = "openalex";
      input = "wired-bench-external-openalex";
      subpath = "";
    }
  ];
}
