/**
 * Markdown conformance and compatibility testing helpers.
 *
 * This module implements the deterministic fixture pipeline described in
 * `libs/markdown/TESTING.md` and provides shared functionality for tier runners,
 * ingestion adapters, and differential reporting tools.
 */
module sparkles.markdown.testing;

import core.time : Duration, MonoTime, dur;

import std.algorithm.sorting : sort;
import std.array : appender;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.string : lineSplitter, strip, stripRight;

import sparkles.markdown :
    DiagnosticLevel,
    MarkdownOptions,
    ParseResult,
    Profile,
    RenderOptions,
    parse,
    toHtml;

/// Fixture flags used by the normalized schema.
struct FixtureFlags
{
    bool unsafe_ = false;
    bool requiresIO = false;
    bool requiresMDX = false;
    bool slow = false;
}

/// Normalized fixture schema entry.
///
/// Provenance fields are intentionally absent here. Source pinning and provenance
/// are tracked at corpus-level via `tests/corpus/sources.json` + flake lock data.
struct FixtureCase
{
    string id;
    string sourceUrl;
    string license;

    string dialect;
    Profile profile;
    string phase;

    string markdown;
    string expectedHtml;
    string expectedAst;

    string[] tags;
    FixtureFlags flags;
}

/// One execution mismatch.
struct FixtureFailure
{
    string id;
    string reason;
    string expected;
    string actual;
}

/// Test suite summary.
struct SuiteSummary
{
    string tier;
    size_t total;
    size_t run;
    size_t passed;
    size_t failed;
    size_t skipped;
    Duration elapsed;
    FixtureFailure[] failures;
}

/// Runner options.
struct FixtureRunOptions
{
    string tierName;
    string[] fixturePaths;
    bool includeSlow = false;
    bool includeMDX = false;
    bool allowUnsafeHtml = false;
    bool failFast = false;
    bool hasProfileFilter = false;
    Profile profileFilter = Profile.commonmark_strict;
    Duration perFixtureTimeout = dur!"msecs"(250);
    string summaryJsonPath;
}

/// Convert profile enum to normalized profile name.
string profileToString(Profile profile)
{
    final switch (profile)
    {
        case Profile.commonmark_strict:
            return "commonmark_strict";
        case Profile.gfm:
            return "gfm";
        case Profile.vitepress_compatible:
            return "vitepress_compatible";
        case Profile.nextra_compatible:
            return "nextra_compatible";
        case Profile.custom:
            return "custom";
    }
}

/// Convert normalized profile name to profile enum.
Profile profileFromString(const(char)[] value)
in (value.length > 0, "Profile string cannot be empty")
{
    switch (value)
    {
        case "commonmark_strict":
            return Profile.commonmark_strict;
        case "gfm":
            return Profile.gfm;
        case "vitepress_compatible":
            return Profile.vitepress_compatible;
        case "nextra_compatible":
            return Profile.nextra_compatible;
        case "custom":
            return Profile.custom;
        default:
            assert(0, "Unsupported profile value in fixture JSONL.");
    }
}

/// Load fixtures from a JSONL file.
FixtureCase[] loadFixtureJsonl(string path)
in (path.length > 0, "Fixture path cannot be empty")
{
    if (!exists(path))
        return [];

    FixtureCase[] fixtures;
    foreach (line; readText(path).lineSplitter)
    {
        auto trimmed = line.strip;
        if (trimmed.length == 0)
            continue;

        auto value = parseJSON(trimmed);
        fixtures ~= fixtureFromJson(value);
    }

    return fixtures;
}

/// Write fixtures to a JSONL file using deterministic ID ordering.
void writeFixtureJsonl(string path, FixtureCase[] fixtures)
in (path.length > 0, "Fixture path cannot be empty")
{
    auto sorted = fixtures.dup;
    sorted.sort!((a, b) => a.id < b.id);

    string payload;
    foreach (fixture; sorted)
        payload ~= fixtureToJsonLine(fixture) ~ "\n";

    auto parent = path.dirName;
    if (parent.length > 0)
        mkdirRecurse(parent);

    write(path, payload);
}

/// Validate fixture IDs are globally unique.
bool validateUniqueIds(in FixtureCase[] fixtures, ref string[] duplicates)
{
    bool[string] seen;
    duplicates.length = 0;

    foreach (fixture; fixtures)
    {
        if (auto state = fixture.id in seen)
        {
            if (!*state)
            {
                duplicates ~= fixture.id;
                *state = true;
            }
        }
        else
            seen[fixture.id] = false;
    }

    return duplicates.length == 0;
}

/// Canonicalize HTML for robust fixture comparison.
string canonicalizeHtml(string html)
{
    auto normalized = normalizeNewlines(html);
    auto outv = appender!string();

    foreach (line; normalized.lineSplitter)
    {
        auto trimmedRight = line.stripRight;
        if (trimmedRight.strip.length == 0)
            continue;

        outv.put(trimmedRight);
        outv.put('\n');
    }

    return outv.data;
}

/// Execute fixtures and return a suite summary.
SuiteSummary runFixtureSuite(in FixtureRunOptions options)
{
    SuiteSummary summary;
    summary.tier = options.tierName.length > 0 ? options.tierName : "unknown";

    FixtureCase[] fixtures;
    foreach (path; options.fixturePaths)
        fixtures ~= loadFixtureJsonl(path);

    fixtures.sort!((a, b) => a.id < b.id);
    summary.total = fixtures.length;

    auto started = MonoTime.currTime;

    foreach (fixture; fixtures)
    {
        if (options.hasProfileFilter && fixture.profile != options.profileFilter)
        {
            ++summary.skipped;
            continue;
        }

        if (!options.includeSlow && fixture.flags.slow)
        {
            ++summary.skipped;
            continue;
        }

        if (fixture.flags.requiresIO)
        {
            ++summary.skipped;
            continue;
        }

        if (fixture.flags.requiresMDX && !options.includeMDX)
        {
            ++summary.skipped;
            continue;
        }

        ++summary.run;
        auto fixtureStart = MonoTime.currTime;

        auto parseOptions = MarkdownOptions!void(
            profile: fixture.profile,
        );

        ParseResult parsed = parse(fixture.markdown, parseOptions);

        bool fixtureFailed = false;

        if (hasErrorDiagnostic(parsed))
        {
            fixtureFailed = true;
            summary.failures ~= FixtureFailure(
                id: fixture.id,
                reason: "Parse diagnostics contain errors.",
            );
        }

        auto elapsed = MonoTime.currTime - fixtureStart;
        if (elapsed > options.perFixtureTimeout)
        {
            fixtureFailed = true;
            summary.failures ~= FixtureFailure(
                id: fixture.id,
                reason: "Fixture exceeded per-fixture timeout.",
                expected: options.perFixtureTimeout.to!string,
                actual: elapsed.to!string,
            );
        }

        if (fixture.expectedHtml.length > 0)
        {
            auto renderOptions = RenderOptions(
                unsafeHtml: options.allowUnsafeHtml || fixture.flags.unsafe_,
            );
            auto actual = parsed.toHtml(renderOptions);

            auto expectedCanonical = canonicalizeHtml(fixture.expectedHtml);
            auto actualCanonical = canonicalizeHtml(actual);

            if (expectedCanonical != actualCanonical)
            {
                fixtureFailed = true;
                summary.failures ~= FixtureFailure(
                    id: fixture.id,
                    reason: "HTML mismatch after canonicalization.",
                    expected: expectedCanonical,
                    actual: actualCanonical,
                );
            }
        }

        if (fixtureFailed)
            ++summary.failed;
        else
            ++summary.passed;

        if (fixtureFailed && options.failFast)
            break;
    }

    summary.elapsed = MonoTime.currTime - started;

    if (options.summaryJsonPath.length > 0)
        writeSuiteSummaryJson(options.summaryJsonPath, summary);

    return summary;
}

/// Render suite summary as markdown.
string summaryToMarkdown(in SuiteSummary summary)
{
    auto outv = appender!string();

    outv.put("## Markdown Test Summary\n\n");
    outv.put("| Field | Value |\n");
    outv.put("| --- | --- |\n");
    outv.put("| Tier | " ~ summary.tier ~ " |\n");
    outv.put("| Total | " ~ summary.total.to!string ~ " |\n");
    outv.put("| Run | " ~ summary.run.to!string ~ " |\n");
    outv.put("| Passed | " ~ summary.passed.to!string ~ " |\n");
    outv.put("| Failed | " ~ summary.failed.to!string ~ " |\n");
    outv.put("| Skipped | " ~ summary.skipped.to!string ~ " |\n");
    outv.put("| Elapsed | " ~ summary.elapsed.to!string ~ " |\n");

    if (summary.failures.length > 0)
    {
        outv.put("\n### Failures\n\n");
        foreach (failure; summary.failures)
            outv.put("- `" ~ failure.id ~ "`: " ~ failure.reason ~ "\n");
    }

    return outv.data;
}

/// Returns `true` when a suite has zero failures.
bool isSuitePassing(in SuiteSummary summary)
{
    return summary.failed == 0;
}

/// Write machine-readable JSON suite summary.
void writeSuiteSummaryJson(string path, in SuiteSummary summary)
in (path.length > 0, "Summary JSON path cannot be empty")
{
    auto parent = path.dirName;
    if (parent.length > 0)
        mkdirRecurse(parent);

    JSONValue root = JSONValue.init;
    JSONValue[string] rootObject;
    root.object = rootObject;

    root.object["tier"] = summary.tier;
    root.object["total"] = cast(long) summary.total;
    root.object["run"] = cast(long) summary.run;
    root.object["passed"] = cast(long) summary.passed;
    root.object["failed"] = cast(long) summary.failed;
    root.object["skipped"] = cast(long) summary.skipped;
    root.object["elapsed"] = summary.elapsed.to!string;

    JSONValue failures = JSONValue.init;
    failures.array = [];

    foreach (failure; summary.failures)
    {
        JSONValue item = JSONValue.init;
        JSONValue[string] itemObject;
        item.object = itemObject;
        item.object["id"] = failure.id;
        item.object["reason"] = failure.reason;
        item.object["expected"] = failure.expected;
        item.object["actual"] = failure.actual;
        failures.array ~= item;
    }

    root.object["failures"] = failures;
    write(path, root.toString ~ "\n");
}

private bool hasErrorDiagnostic(in ParseResult result)
{
    foreach (diag; result.diagnostics)
    {
        if (diag.level == DiagnosticLevel.error)
            return true;
    }

    return false;
}

private string normalizeNewlines(string text)
{
    auto outv = appender!string();
    size_t i = 0;

    while (i < text.length)
    {
        if (text[i] == '\r')
        {
            outv.put('\n');
            ++i;
            if (i < text.length && text[i] == '\n')
                ++i;
            continue;
        }

        outv.put(text[i]);
        ++i;
    }

    return outv.data;
}

private FixtureCase fixtureFromJson(in JSONValue value)
{
    FixtureCase fixture;

    fixture.id = jsonString(value, "id");
    fixture.sourceUrl = jsonString(value, "sourceUrl");
    fixture.license = jsonString(value, "license");

    fixture.dialect = jsonString(value, "dialect");
    fixture.profile = profileFromString(jsonString(value, "profile"));
    fixture.phase = jsonString(value, "phase");

    fixture.markdown = jsonString(value, "markdown");
    fixture.expectedHtml = jsonString(value, "expectedHtml");
    fixture.expectedAst = jsonString(value, "expectedAst", "");

    auto tags = jsonArray(value, "tags");
    foreach (tag; tags)
        fixture.tags ~= tag.str;

    auto flags = jsonObject(value, "flags");
    fixture.flags = FixtureFlags(
        unsafe_: jsonBool(flags, "unsafe", false),
        requiresIO: jsonBool(flags, "requiresIO", false),
        requiresMDX: jsonBool(flags, "requiresMDX", false),
        slow: jsonBool(flags, "slow", false),
    );

    return fixture;
}

private string fixtureToJsonLine(in FixtureCase fixture)
{
    JSONValue root = JSONValue.init;
    JSONValue[string] rootObject;
    root.object = rootObject;

    root.object["id"] = fixture.id;
    root.object["sourceUrl"] = fixture.sourceUrl;
    root.object["license"] = fixture.license;
    root.object["dialect"] = fixture.dialect;
    root.object["profile"] = profileToString(fixture.profile);
    root.object["phase"] = fixture.phase;
    root.object["markdown"] = fixture.markdown;
    root.object["expectedHtml"] = fixture.expectedHtml;

    if (fixture.expectedAst.length > 0)
        root.object["expectedAst"] = fixture.expectedAst;
    else
        root.object["expectedAst"] = JSONValue(null);

    JSONValue tags = JSONValue.init;
    tags.array = [];
    foreach (tag; fixture.tags)
        tags.array ~= JSONValue(tag);
    root.object["tags"] = tags;

    JSONValue flags = JSONValue.init;
    JSONValue[string] flagsObject;
    flags.object = flagsObject;
    flags.object["unsafe"] = fixture.flags.unsafe_;
    flags.object["requiresIO"] = fixture.flags.requiresIO;
    flags.object["requiresMDX"] = fixture.flags.requiresMDX;
    flags.object["slow"] = fixture.flags.slow;
    root.object["flags"] = flags;

    return root.toString;
}

private string jsonString(in JSONValue root, string key, string fallback = "")
{
    if (key !in root.object)
        return fallback;

    auto value = root.object[key];
    if (value.type == JSONType.null_)
        return fallback;

    return value.str;
}

private bool jsonBool(in JSONValue root, string key, bool fallback)
{
    if (key !in root.object)
        return fallback;

    auto value = root.object[key];
    return value.type == JSONType.true_;
}

private JSONValue jsonObject(in JSONValue root, string key)
{
    if (key !in root.object)
    {
        JSONValue empty = JSONValue.init;
        JSONValue[string] emptyObject;
        empty.object = emptyObject;
        return empty;
    }

    return root.object[key];
}

private JSONValue[] jsonArray(in JSONValue root, string key)
{
    if (key !in root.object)
        return [];

    auto value = root.object[key];
    if (value.type != JSONType.array)
        return [];

    return value.array.dup;
}

@("markdown.testing.canonicalizeHtml")
@system unittest
{
    auto html = "<h1>Hello</h1>\r\n\r\n<p>x</p>   \n";
    auto canonical = canonicalizeHtml(html);
    assert(canonical == "<h1>Hello</h1>\n<p>x</p>\n");
}

@("markdown.testing.fixtureRoundtrip")
@system unittest
{
    auto fixture = FixtureCase(
        id: "seed:1",
        sourceUrl: "https://example.invalid",
        license: "MIT",
        dialect: "commonmark",
        profile: Profile.commonmark_strict,
        phase: "render",
        markdown: "# Title\n",
        expectedHtml: "<h1>Title</h1>\n",
        tags: ["heading"],
    );

    auto path = "libs/markdown/tests/corpus/generated/.fixture_roundtrip.jsonl";
    scope (exit)
    {
        if (exists(path))
            remove(path);
    }

    writeFixtureJsonl(path, [fixture]);
    auto loaded = loadFixtureJsonl(path);

    assert(loaded.length == 1);
    assert(loaded[0].id == fixture.id);
    assert(loaded[0].expectedHtml == fixture.expectedHtml);
}
