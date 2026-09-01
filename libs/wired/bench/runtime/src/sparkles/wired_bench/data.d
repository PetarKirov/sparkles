/**
Benchmark corpus loading.

Small datasets are pinned by `nix/packages/wired-bench-data.nix` and exposed
to the devshell as `$WIRED_BENCH_DATA`. Multi-gigabyte corpora are deliberately
not copied into every developer's Nix store: put their normalized files in
`$WIRED_BENCH_EXTERNAL_DATA` and select them explicitly with
`$WIRED_BENCH_DATASETS` (see $(MREF sparkles,wired_bench,runner)).
*/
module sparkles.wired_bench.data;

import std.algorithm.iteration : filter, map, splitter;
import std.array : array;
import std.exception : enforce;
import std.file : exists, readText;
import std.mmfile : MmFile;
import std.path : buildPath;
import std.process : environment;
import std.string : strip;

/// How one corpus is divided into JSON documents.
enum DatasetFormat
{
    document,       /// one RFC 8259 JSON text
    ndjson,         /// one complete JSON text per non-empty line
    jsonArrayLines, /// `[`/`]` plus one comma-terminated value per line
}

/// Scale tier of a dataset: light (< 5 MB), medium (10 MB – 200 MB), huge (> 1 GB).
enum DatasetTier
{
    light,
    medium,
    huge,
}

/// One known corpus and its on-disk convention.
struct DatasetSource
{
    string name;
    string fileName;
    DatasetFormat format;
    DatasetTier tier;
    bool bundled;
}

/// The normal, reproducible benchmark matrix. External corpora are opt-in.
immutable string[] defaultDatasetNames =
    ["twitter", "citm_catalog", "canada", "github_events", "mesh",
        "mesh_pretty", "wikidata", "osm", "cloudtrail", "elasticsearch"];

/// Every dataset name accepted by `$WIRED_BENCH_DATASETS`.
immutable DatasetSource[] datasetSources =
[
    DatasetSource("twitter", "twitter.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("citm_catalog", "citm_catalog.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("canada", "canada.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("github_events", "github_events.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("mesh", "mesh.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("mesh_pretty", "mesh.pretty.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("wikidata", "wikidata.json", DatasetFormat.jsonArrayLines, DatasetTier.light, true),
    DatasetSource("osm", "osm.json", DatasetFormat.document, DatasetTier.light, true),
    DatasetSource("cloudtrail", "cloudtrail.ndjson", DatasetFormat.ndjson, DatasetTier.light, true),
    DatasetSource("elasticsearch", "elasticsearch.ndjson", DatasetFormat.ndjson, DatasetTier.light, true),

    DatasetSource("gharchive", "gharchive.ndjson", DatasetFormat.ndjson, DatasetTier.huge, false),
    DatasetSource("amazon_reviews", "amazon_reviews.ndjson", DatasetFormat.ndjson, DatasetTier.huge, false),
    DatasetSource("osm_large", "osm_large.json", DatasetFormat.document, DatasetTier.huge, false),
    DatasetSource("wikidata_full", "wikidata_full.json", DatasetFormat.jsonArrayLines, DatasetTier.huge, false),
    DatasetSource("openalex", "openalex.ndjson", DatasetFormat.ndjson, DatasetTier.huge, false),
];

/// One loaded benchmark corpus.
struct Dataset
{
    string name;            /// dataset name, e.g. `twitter`
    const(char)[] text;      /// the raw corpus text
    DatasetFormat format;   /// document framing
    DatasetTier tier;       /// scale tier
    private MmFile mapping; /// keeps an external corpus's read-only map alive

    /// A lazy range of JSON texts in a line-oriented corpus.
    auto records() const @safe
    in (format != DatasetFormat.document)
    {
        const framing = format;
        return text.splitter('\n')
            .map!(line => recordLine(line, framing))
            .filter!(line => line.length);
    }
}

/// The corpus directory: the explicit value if given, else `$WIRED_BENCH_DATA`.
string resolveDataDir(string explicitDir) @safe
{
    if (explicitDir.length)
        return explicitDir;
    const env = environment.get("WIRED_BENCH_DATA");
    enforce(env !is null && env.length,
        "no data directory: export WIRED_BENCH_DATA to point at the benchmark "
        ~ "corpora (the devshell sets it)");
    return env;
}

/// The external-corpus directory: explicit value, else the environment.
string resolveExternalDataDir(string explicitDir) @safe
{
    if (explicitDir.length)
        return explicitDir;
    return environment.get("WIRED_BENCH_EXTERNAL_DATA", "");
}

/// Looks up one catalog entry, rejecting typos before touching the filesystem.
DatasetSource datasetSource(scope const(char)[] name) @safe
{
    foreach (source; datasetSources)
        if (source.name == name)
            return source;
    enforce(false, "unknown dataset '" ~ name ~ "'");
    assert(false);
}

/// Loads the selected catalog entries from their bundled or external root.
Dataset[] loadDatasets(const string[] names, string dataDir,
    string externalDataDir = null) @safe
{
    Dataset[] result;
    result.reserve(names.length);
    foreach (name; names)
    {
        const source = datasetSource(name);
        const root = source.bundled
            ? dataDir
            : resolveExternalDataDir(externalDataDir);
        if (source.bundled)
            enforce(root.length, "dataset '" ~ name
                ~ "' is bundled: export WIRED_BENCH_DATA");
        else
            enforce(root.length, "dataset '" ~ name ~ "' is external: export "
                ~ "WIRED_BENCH_EXTERNAL_DATA to the directory containing "
                ~ source.fileName);
        const path = root.buildPath(source.fileName);
        enforce(path.exists, "dataset not found: " ~ path);
        result ~= source.bundled
            ? Dataset(name, readText(path), source.format, source.tier)
            : mapDataset(name, path, source.format, source.tier);
    }
    return result;
}

/// Maps a potentially enormous external corpus without a heap-sized input copy.
private Dataset mapDataset(string name, string path, DatasetFormat format,
    DatasetTier tier) @trusted
{
    auto mapping = new MmFile(path);
    return Dataset(name, cast(const(char)[]) mapping[], format, tier, mapping);
}

/// Normalizes one physical line into a JSON record view.
private const(char)[] recordLine(return scope const(char)[] raw,
    DatasetFormat format) @safe pure nothrow
{
    auto line = raw.strip;
    if (format == DatasetFormat.jsonArrayLines)
    {
        if (line == "[" || line == "]")
            return null;
        if (line.length && line[$ - 1] == ',')
            line = line[0 .. $ - 1].strip;
    }
    return line;
}

@("data.resolveDataDir.cliWins")
@safe unittest
{
    assert(resolveDataDir("/some/dir") == "/some/dir");
}

@("data.catalog.formatsAndDefaults")
@safe unittest
{
    assert(datasetSource("mesh_pretty").fileName == "mesh.pretty.json");
    assert(datasetSource("wikidata").format == DatasetFormat.jsonArrayLines);
    assert(datasetSource("wikidata").bundled == false);
    assert(defaultDatasetNames.length == 6);
}

@("data.records.ndjsonAndWikidataArray")
@safe unittest
{
    auto ndjson = Dataset("logs", " {\"a\":1}\n\n{\"b\":2}\r\n",
        DatasetFormat.ndjson);
    assert(ndjson.records.array == [`{"a":1}`, `{"b":2}`]);

    auto wikidata = Dataset("wikidata",
        "[\n{\"id\":\"Q1\"},\n {\"id\":\"Q2\"}\n]\n",
        DatasetFormat.jsonArrayLines);
    assert(wikidata.records.array ==
        [`{"id":"Q1"}`, `{"id":"Q2"}`]);
}
