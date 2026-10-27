/**
The SDL rows of the runtime benchmark (`docs/specs/wired/sdl/performance.md`,
SDP1): `sdl.parse`, `sdl.decode` and `sdl.encode`, each over the pinned SDL
datasets that `nix/packages/wired-bench-data.nix` places under
`$WIRED_BENCH_DATA/sdl`.

$(UL
$(LI `parse` — bytes → `SdlDocument` (`parseSdlDocument`). The `dub-sdlang`
    row times DUB's own pinned SDLang parser on the same bytes, as an external
    reference point, when the build enables `BenchDubSdlang`.)
$(LI `decode` — bytes → the `dub.sdl` schema of
    `sparkles.build_primitives.dub_manifest` (`parseDubManifest`, the reader
    every recipe tool in the repository uses), parse included.)
$(LI `encode` — a parsed document → canonical SDL text
    (`writeSdlDocument`), the canonical writer of SPEC §9.)
)

Every row verifies itself once, untimed, against the $(LREF SdlFingerprint)
committed with its dataset below: the SHA-256 of the canonical writer's
output for the parsed document, plus the tag, value and attribute counts the
DUB reference row is held to. A row that parses, decodes or writes anything
else becomes an error row.

`decode` is held to a digest of the decoded values themselves, not to their
canonical text: `writeSDL` cannot write the `dub.sdl` schema back (it rejects
`DubBuildType` with "positional slots must be contiguous"), and would spell
every absent optional field as an empty string if it could. For the same
reason there is no typed `encode` row yet.

Only the public `sparkles.wired.sdl` API is used, so the rows measure the
same calls before and after the backend's internal representation changes.

`edit` resolves and writes one lossless change per document through
`SdlEditor` — setting a `probe` attribute on its first tag, or appending a tag
to an empty document — re-parse included, and is held to the SHA-256 of the
edited texts.
*/
module sparkles.wired_bench.sdl;

import std.algorithm.iteration : map;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;
import std.experimental.allocator.mallocator : Mallocator;
import std.file : dirEntries, readText, SpanMode;
import std.path : buildPath, relativePath;

import expected : err, ok;

import sparkles.build_primitives.dub_manifest : DubManifest, parseDubManifest;
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, Metric, Unit;
import sparkles.wired : WireName, WireOptional;
import sparkles.wired.sdl : fromSDL, parseSdlDocument, Sdl, sdlEditor, SdlExpected, SdlNode,
    SdlParseResult, SdlQualifiedName, SdlScalar, SdlString, sdlDubRecipe, sdlFull,
    writeSdlDocument;
import sparkles.wired_bench.data : resolveDataDir;

/// How an SDL dataset is laid out and which schema decodes it.
enum SdlDatasetKind
{
    recipes,   /// a directory of `dub.sdl` files, one document each
    recipeSet, /// one recipe whose inline subpackages are recipes
    document,  /// one document with no schema (parsed under `sdlFull`)
}

/// What a correct run must reproduce for one dataset.
struct SdlFingerprint
{
    ulong tags;       /// every tag below the root, in every document
    ulong values;     /// every positional value
    ulong attributes; /// every attribute
    /// Hex SHA-256 of the canonical writer's output for each parsed
    /// document, each preceded by its file name and an LF.
    string canonical;
    /// Hex SHA-256 of each decoded value, field by field in declaration
    /// order, lengths before contents ($(LREF digestValue)); empty for a
    /// dataset with no schema.
    string typed;
    /// Hex SHA-256 of each document after the `edit` row's change, each
    /// preceded by its file name and an LF.
    string edited;
}

/// One pinned SDL dataset: where it lives under `$WIRED_BENCH_DATA` and what
/// it must fingerprint to.
struct SdlDatasetSource
{
    string name;           /// selector, for `--datasets` / `$WIRED_BENCH_DATASETS`
    string path;           /// relative to `$WIRED_BENCH_DATA`
    SdlDatasetKind kind;   ///
    SdlFingerprint expected; ///
    /// Whether DUB's parser can read it: its pull parser recurses on a
    /// fiber's 16 KiB default stack (`dub.internal.libInputVisitor`) and
    /// overflows past about ten nested blocks.
    bool dubReadable = true;
}

/**
The SDL datasets. Their recipe source is the repository at commit
`020926d5c76a43b786f3b81658338a3b224393c6` (`nix/packages/wired-bench-datasets.nix`,
`sdlRecipes`); `tools/gen-sdl-datasets.d` derives the other two. Moving the
pin or changing the generator changes these fingerprints; so does a change to
the canonical writer's output, which the SPEC does not expect.
*/
immutable SdlDatasetSource[] sdlDatasetSources = [
    SdlDatasetSource("dub_recipes", "sdl/dub-recipes", SdlDatasetKind.recipes,
        SdlFingerprint(8966, 13_281, 4816,
            "12940eda2aa15e31d5561cea33b3e9fe7942e5db95d4d6e1185485dc357006a7",
            "71a3534e57d6ae2923ecd6ef9b802c7344a9013b6b9e3fb66f39218a2a10be6d",
            "baa3aaa4e3ea34906a657285d3e67a4be79a7fb8dde97cd3b6bd93ae4a33f59b")),
    SdlDatasetSource("dub_recipes_concat", "sdl/dub-recipes-concat.sdl",
        SdlDatasetKind.recipeSet, SdlFingerprint(9119, 13_283, 4816,
            "a86bbeadfad542854d17b93acf76e7cbcc3343fbe1ebe7c978a8b1e889129574",
            "e11a8b2ee662fac2c83b5d403777362b60fd76a7d8e9786a010cd7c312261a70",
            "d59fdc99b303343fe8fdf05ed9093de0b5fc667350375371df7ea2a729f84737")),
    SdlDatasetSource("deep_wide", "sdl/deep-wide.sdl", SdlDatasetKind.document,
        SdlFingerprint(6329, 16_601, 23_463,
            "ae04b1de64b7eed6a1d5f49bdaf7ebfebe4eb5ebd98c3374376982e4643c86b8", null,
            "3e42a0fc43425de73e9212935d82dbf6095cbcfa16a72fdd4a6ce320f4258911"),
        dubReadable: false),
];

/// The concatenated dataset's schema: a root recipe whose inline
/// `subPackage { … }` blocks are each a whole `dub.sdl` recipe, as DUB reads
/// them.
struct DubRecipeSet
{
    @WireOptional():
    string name;        ///
    string description; ///
    @WireName!Sdl("subPackage") DubManifest[] subPackages; ///
}

/// One loaded SDL dataset: its documents, in a fixed order.
struct SdlCorpus
{
    string name;          ///
    SdlDatasetKind kind;  ///
    bool dubReadable;     /// see $(LREF SdlDatasetSource.dubReadable)
    string[] files;       /// each document's file name, relative to the dataset
    string[] texts;       /// each document's bytes
    size_t bytes;         /// total input bytes
    SdlFingerprint expected; ///
}

/// Loads one dataset from the corpus directory.
SdlCorpus loadSdlCorpus(const SdlDatasetSource source, string dataDir) @safe
{
    auto corpus = SdlCorpus(source.name, source.kind);
    corpus.expected = source.expected;
    corpus.dubReadable = source.dubReadable;
    const root = dataDir.buildPath(source.path);
    if (source.kind == SdlDatasetKind.recipes)
    {
        corpus.files = () @trusted {
            return dirEntries(root, "dub.sdl", SpanMode.depth, true)
                .map!(e => e.name.relativePath(root))
                .array;
        }();
        corpus.files.sort();
    }
    else
        corpus.files = [""];
    foreach (file; corpus.files)
    {
        corpus.texts ~= readText(file.length ? root.buildPath(file) : root);
        corpus.bytes += corpus.texts[$ - 1].length;
    }
    return corpus;
}

/// Accumulates the canonical text of one document into a dataset hash.
private void putDocument(ref SHA256 sha, string file, scope const(char)[] text) @safe
{
    sha.put(cast(const(ubyte)[]) file);
    sha.put('\n');
    sha.put(cast(const(ubyte)[]) text);
}

private string hexOf(ref SHA256 sha) @safe
    => sha.finish.toHexString!(LetterCase.lower).idup;

/// Counts the tags, values and attributes below `node`.
private void countInto(scope SdlNode node, ref SdlFingerprint f) @safe
{
    foreach (child; node.byChild)
    {
        f.tags++;
        f.values += child.valueCount;
        f.attributes += child.attributeCount;
        countInto(child, f);
    }
}

/// The differences between an expected and an actual fingerprint, as
/// one-line `field: expected E, got A;` list (a row error keeps one line);
/// empty when they agree.
private string diffSdl(in SdlFingerprint expected, in SdlFingerprint actual,
    bool structure, bool canonical, bool typed) @safe
{
    string s;
    void field(string name, string e, string a)
    {
        if (e != a)
            s ~= " " ~ name ~ ": expected " ~ e ~ ", got " ~ a ~ ";";
    }

    if (structure)
    {
        field("tags", expected.tags.to!string, actual.tags.to!string);
        field("values", expected.values.to!string, actual.values.to!string);
        field("attributes", expected.attributes.to!string, actual.attributes.to!string);
    }
    if (canonical)
        field("canonical", expected.canonical, actual.canonical);
    if (typed)
        field("typed", expected.typed, actual.typed);
    if (actual.edited.length)
        field("edited", expected.edited, actual.edited);
    return s;
}

/// The parsed documents of one dataset, held between the timed parse and the
/// untimed check that releases them.
private alias Doc = SdlParseResult!Mallocator;

/// Parses `text` under the dataset's profile.
private Doc parseFor(SdlDatasetKind kind, scope const(char)[] text)
{
    if (kind == SdlDatasetKind.document)
        return parseSdlDocument!sdlFull(text);
    return parseSdlDocument!sdlDubRecipe(text);
}

/// The structure and canonical hash of a dataset's parsed documents; a
/// document that failed to parse leaves the hash with its error message.
private SdlFingerprint fingerprintDocs(in SdlCorpus corpus, scope Doc[] docs)
{
    SdlFingerprint f;
    SHA256 sha;
    sha.start();
    SdlString text;
    foreach (i, ref doc; docs)
    {
        if (doc.hasError)
        {
            f.canonical = corpus.files[i] ~ ": parse failed: " ~ doc.error.reason[].idup;
            return f;
        }
        countInto(doc.document.root, f);
        text.clear(releaseStorage: false);
        const written = writeSdlDocument(doc.document, text);
        if (written.hasError)
        {
            f.canonical = corpus.files[i] ~ ": write failed: " ~ written.error.reason[].idup;
            return f;
        }
        putDocument(sha, corpus.files[i], text[]);
    }
    f.canonical = hexOf(sha);
    return f;
}

/// Decodes one document of a dataset into its schema.
private SdlExpected!DubManifest decodeRecipe(scope const(char)[] text)
    => parseDubManifest(text);

/// ditto
private SdlExpected!DubRecipeSet decodeRecipeSet(scope const(char)[] text)
    => fromSDL!(DubRecipeSet, sdlDubRecipe)(text);

/**
Feeds a decoded value into `sha`: strings and arrays as their length (eight
bytes, little-endian) then their elements, booleans as one byte, aggregates
field by field in declaration order. Two values digest equal exactly when
every field is equal.
*/
private void digestValue(T)(ref SHA256 sha, scope const ref T value)
{
    import std.bitmanip : nativeToLittleEndian;

    static if (is(T : const(char)[]))
    {
        sha.put(nativeToLittleEndian(ulong(value.length))[]);
        sha.put(cast(const(ubyte)[]) value);
    }
    else static if (is(T == bool))
        sha.put(ubyte(value));
    else static if (is(T : const(E)[], E))
    {
        sha.put(nativeToLittleEndian(ulong(value.length))[]);
        foreach (ref element; value)
            digestValue(sha, element);
    }
    else static if (is(T == struct))
    {
        foreach (ref field; value.tupleof)
            digestValue(sha, field);
    }
    else
        static assert(false, "no digest for " ~ T.stringof);
}

/// The typed hash over a dataset's decoded values.
private string typedHash(T)(in SdlCorpus corpus, scope const(T)[] values)
{
    SHA256 sha;
    sha.start();
    foreach (i, ref value; values)
    {
        sha.put(cast(const(ubyte)[]) corpus.files[i]);
        sha.put('\n');
        digestValue(sha, value);
    }
    return hexOf(sha);
}

/// The value type `decode` yields.
private template DecodedOf(alias decode)
{
    import std.traits : Unqual;

    alias DecodedOf = Unqual!(typeof(decode("").value));
}

/// Decodes every document of `corpus` into `values`, returning the first
/// failure's message (empty on success).
private string decodeAll(alias decode, T)(in SdlCorpus corpus, T[] values)
{
    string failure;
    foreach (i, text; corpus.texts)
    {
        auto result = decode(text);
        if (result.hasValue)
            values[i] = result.value;
        else if (!failure.length)
            failure = corpus.files[i] ~ ": decode failed: " ~ result.error.reason[].idup;
    }
    return failure;
}

/// A `B/s` throughput metric over a dataset's input bytes.
private Metric inputBytes(size_t n) @safe pure nothrow
    => Metric(unit: Unit("B"), amount: double(n), mode: Metric.Mode.rate);

private string[string] labelsFor(const SdlCorpus corpus, string operation) @safe pure
    => ["dataset": corpus.name, "tier": "light", "operation": operation];

private auto verdict(string error)
    => error.length ? err!bool(error) : ok!string(true);

// ── Selection ────────────────────────────────────────────────────────────────

/// The selected SDL datasets: `--datasets=` or `$WIRED_BENCH_DATASETS` globs,
/// as for the JSON rows; none given selects them all.
private SdlCorpus[] selectedCorpora()
{
    import core.runtime : Runtime;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : any, startsWith;
    import std.process : environment;
    import sparkles.test_runner.metrics : matchesMetricGlob;

    string selected;
    foreach (arg; Runtime.args)
        if (arg.startsWith("--datasets="))
            selected = arg["--datasets=".length .. $];
    if (!selected.length)
        selected = environment.get("WIRED_BENCH_DATASETS", "");
    const all = !selected.length || selected == "all";

    SdlCorpus[] result;
    string dataDir;
    foreach (source; sdlDatasetSources)
        if (all || selected.splitter(',').any!(p => matchesMetricGlob(source.name, p)))
        {
            if (!dataDir.length)
                dataDir = resolveDataDir(null);
            result ~= loadSdlCorpus(source, dataDir);
        }
    return result;
}

/// Whether `$WIRED_BENCH_ENGINES` (a comma list; empty allows all) allows
/// the row named `name`.
private bool sdlEngineEnabled(string name) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.process : environment;

    const list = environment.get("WIRED_BENCH_ENGINES", "");
    return !list.length || list.splitter(',').canFind(name);
}

private void skipIfEmpty(size_t registered, string operation)
{
    import sparkles.test_runner.skip : skipTest;

    if (!registered)
        skipTest("no matching SDL datasets or engines enabled for " ~ operation);
}

// ── Rows ─────────────────────────────────────────────────────────────────────

@("sdl.parse")
@benchmark
@system
unittest
{
    size_t registered;
    foreach (corpus; selectedCorpora)
    {
        if (sdlEngineEnabled("wired"))
        {
            registerParse(corpus);
            registered++;
        }
        version (BenchDubSdlang)
            if (corpus.dubReadable && sdlEngineEnabled("dub-sdlang"))
            {
                registerDubParse(corpus);
                registered++;
            }
    }
    skipIfEmpty(registered, "parse");
}

@("sdl.decode")
@benchmark
@system
unittest
{
    size_t registered;
    if (sdlEngineEnabled("wired"))
        foreach (corpus; selectedCorpora)
        {
            if (corpus.kind == SdlDatasetKind.recipes)
                registerDecode!decodeRecipe(corpus);
            else if (corpus.kind == SdlDatasetKind.recipeSet)
                registerDecode!decodeRecipeSet(corpus);
            else
                continue;
            registered++;
        }
    skipIfEmpty(registered, "decode");
}

@("sdl.edit")
@benchmark
@system
unittest
{
    size_t registered;
    if (sdlEngineEnabled("wired"))
        foreach (corpus; selectedCorpora)
        {
            registerEdit(corpus);
            registered++;
        }
    skipIfEmpty(registered, "edit");
}

@("sdl.encode")
@benchmark
@system
unittest
{
    size_t registered;
    if (sdlEngineEnabled("wired"))
        foreach (corpus; selectedCorpora)
        {
            registerEncode(corpus);
            registered++;
        }
    skipIfEmpty(registered, "encode");
}

// Each row is registered from its own helper, so its closures capture their
// own corpus copy and state, never a shared loop variable.

/// parse — every document of the dataset, held until the untimed `after`,
/// which verifies the first iteration's documents and releases them.
private void registerParse(SdlCorpus corpus)
{
    auto docs = new Doc[corpus.texts.length];
    bool verified;
    benchCase(
        name: "wired",
        timed: () {
            foreach (i, text; corpus.texts)
                docs[i] = parseFor(corpus.kind, text);
        },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                const actual = fingerprintDocs(corpus, docs);
                error = diffSdl(corpus.expected, actual, true, true, false);
                if (error.length)
                    error = "parse fingerprint mismatch:" ~ error;
            }
            foreach (ref doc; docs)
                doc = Doc.init;
            return verdict(error);
        },
        metrics: [inputBytes(corpus.bytes)],
        labels: labelsFor(corpus, "parse"),
    );
}

/// decode — bytes → the dataset's schema; the first iteration's values,
/// written back, must hash to the committed typed fingerprint.
private void registerDecode(alias decode)(SdlCorpus corpus)
{
    alias T = DecodedOf!decode;
    auto values = new T[corpus.texts.length];
    string failure;
    bool verified;
    benchCase(
        name: "wired",
        timed: () { failure = decodeAll!decode(corpus, values); },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                SdlFingerprint actual;
                actual.typed = failure.length ? failure : typedHash(corpus, values);
                error = diffSdl(corpus.expected, actual, false, false, true);
                if (error.length)
                    error = "decode fingerprint mismatch:" ~ error;
            }
            return verdict(error);
        },
        metrics: [inputBytes(corpus.bytes)],
        labels: labelsFor(corpus, "decode"),
    );
}

/// encode — parsed documents (untimed `setup`) → canonical text, into one
/// retained buffer per document; the first iteration's output must hash to
/// the committed canonical fingerprint.
private void registerEncode(SdlCorpus corpus)
{
    auto docs = new Doc[corpus.texts.length];
    auto outputs = new SdlString[corpus.texts.length];
    bool verified, failed;
    benchCase(
        name: "wired",
        timed: () {
            foreach (i, ref doc; docs)
            {
                outputs[i].clear(releaseStorage: false);
                if (writeSdlDocument(doc.document, outputs[i]).hasError)
                    failed = true;
            }
        },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                SHA256 sha;
                sha.start();
                foreach (i, ref text; outputs)
                    putDocument(sha, corpus.files[i], text[]);
                SdlFingerprint actual;
                actual.canonical = failed ? "a parse or write failed" : hexOf(sha);
                error = diffSdl(corpus.expected, actual, false, true, false);
                if (error.length)
                    error = "encode fingerprint mismatch:" ~ error;
            }
            return verdict(error);
        },
        metrics: [inputBytes(corpus.bytes)],
        labels: labelsFor(corpus, "encode"),
        setup: () {
            foreach (i, text; corpus.texts)
            {
                docs[i] = parseFor(corpus.kind, text);
                if (docs[i].hasError)
                    failed = true;
            }
        },
        teardown: () {
            foreach (ref doc; docs)
                doc = Doc.init;
        },
    );
}

/// The `edit` row's change to one document, written into `output`.
private bool editOnce(SdlDatasetKind kind)(ref Doc doc, scope const(char)[] text,
    ref SdlString output)
{
    enum config = kind == SdlDatasetKind.document ? sdlFull : sdlDubRecipe;
    auto editor = sdlEditor!config(doc.document, text);
    auto root = doc.document.root;
    if (root.childCount)
        editor.setAttribute(root.byChild.front, SdlQualifiedName(null, "probe"), SdlScalar("edit"));
    else
        editor.append(root, "probe \"edit\"");
    Mallocator allocator;
    return !editor.write(output, allocator).hasError;
}

/// edit — parsed documents (untimed `setup`) → one lossless change each,
/// resolved, re-parsed and written; the first iteration's output must hash
/// to the committed edited fingerprint.
private void registerEdit(SdlCorpus corpus)
{
    auto docs = new Doc[corpus.texts.length];
    auto outputs = new SdlString[corpus.texts.length];
    bool verified, failed;
    benchCase(
        name: "wired",
        timed: () {
            foreach (i, ref doc; docs)
            {
                outputs[i].clear(releaseStorage: false);
                const done = corpus.kind == SdlDatasetKind.document
                    ? editOnce!(SdlDatasetKind.document)(doc, corpus.texts[i], outputs[i])
                    : editOnce!(SdlDatasetKind.recipes)(doc, corpus.texts[i], outputs[i]);
                if (!done)
                    failed = true;
            }
        },
        after: () {
            string error;
            if (!verified)
            {
                verified = true;
                SHA256 sha;
                sha.start();
                foreach (i, ref text; outputs)
                    putDocument(sha, corpus.files[i], text[]);
                SdlFingerprint actual;
                actual.edited = failed ? "a parse or edit failed" : hexOf(sha);
                error = diffSdl(corpus.expected, actual, false, false, false);
                if (error.length)
                    error = "edit fingerprint mismatch:" ~ error;
            }
            return verdict(error);
        },
        metrics: [inputBytes(corpus.bytes)],
        labels: labelsFor(corpus, "edit"),
        setup: () {
            foreach (i, text; corpus.texts)
            {
                docs[i] = parseFor(corpus.kind, text);
                if (docs[i].hasError)
                    failed = true;
            }
        },
        teardown: () {
            foreach (ref doc; docs)
                doc = Doc.init;
        },
    );
}

version (BenchDubSdlang)
{
    import dub.internal.sdlang.ast : Tag;
    import dub.internal.sdlang.parser : parseSource;

    /// Counts DUB's tree as $(LREF countInto) counts ours.
    private void countDub(Tag tag, ref SdlFingerprint f)
    {
        foreach (child; tag.all.tags)
        {
            f.tags++;
            f.values += child.values.length;
            f.attributes += child.all.attributes.length;
            countDub(child, f);
        }
    }

    /// parse, by DUB's pinned SDLang parser — held to the committed tag,
    /// value and attribute counts, since its tree has no canonical writer
    /// of ours to hash.
    private void registerDubParse(SdlCorpus corpus)
    {
        auto tags = new Tag[corpus.texts.length];
        bool verified;
        benchCase(
            name: "dub-sdlang",
            timed: () {
                foreach (i, text; corpus.texts)
                    tags[i] = parseSource(text, corpus.files[i]);
            },
            after: () {
                string error;
                if (!verified)
                {
                    verified = true;
                    SdlFingerprint actual;
                    foreach (tag; tags)
                        countDub(tag, actual);
                    error = diffSdl(corpus.expected, actual, true, false, false);
                    if (error.length)
                        error = "DUB parse structure mismatch:" ~ error;
                }
                tags[] = null;
                return verdict(error);
            },
            metrics: [inputBytes(corpus.bytes)],
            labels: labelsFor(corpus, "parse"),
        );
    }
}

@("sdl.datasets.catalog")
@safe pure nothrow @nogc
unittest
{
    assert(sdlDatasetSources.length == 3);
    foreach (source; sdlDatasetSources)
    {
        assert(source.expected.canonical.length == 64);
        assert(source.expected.typed.length
            == (source.kind == SdlDatasetKind.document ? 0 : 64));
    }
}
