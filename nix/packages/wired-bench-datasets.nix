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
      downloadName = "gharchive.json.gz";
      selector = "gharchive";
      tier = "huge";
      url = "https://data.gharchive.org/2024-01-01-15.json.gz";
      sha256 = "1l43pibhi1jwy1f22zz6n0s96fnjn08vgn3ij0ipns9q6r0khwkf";
      decompress = "gz";
    }
    {
      name = "amazon_reviews.ndjson";
      downloadName = "amazon_reviews.ndjson";
      selector = "amazon_reviews";
      tier = "huge";
      url = "https://huggingface.co/datasets/McAuley-Lab/Amazon-Reviews-2023/resolve/main/raw/review_categories/Software.jsonl";
      sha256 = "";
      decompress = "none";
    }
    {
      name = "osm_large.json";
      downloadName = "osm_large.geojson";
      selector = "osm_large";
      tier = "huge";
      url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries.geojson";
      sha256 = "0mgjx16anypz304mnxmfa25k2b3mavycydi53shh1w8pmibyr7i3";
      decompress = "none";
    }
    {
      name = "wikidata_full.json";
      downloadName = "wikidata_full.json.gz";
      selector = "wikidata_full";
      tier = "huge";
      url = "https://dumps.wikimedia.org/wikidatawiki/entities/latest-lexemes.json.gz";
      sha256 = "";
      decompress = "gz";
    }
    {
      name = "openalex.ndjson";
      downloadName = "openalex.ndjson";
      selector = "openalex";
      tier = "huge";
      url = "https://huggingface.co/datasets/UniverseTBD/arxiv-abstracts-large/resolve/main/arxiv-metadata-oai-snapshot.json";
      sha256 = "";
      decompress = "none";
    }
  ];
in
{
  inherit light medium huge;
  bundled = light;
  external = medium ++ huge;
  all = light ++ medium ++ huge;
}
