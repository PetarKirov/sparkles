/**
 * `text-conformance` — differential-testing harness for `sparkles.base.text`.
 *
 * Cross-checks the library's terminal cell-width and UAX#29 grapheme
 * segmentation against independent Unicode oracles, in four selectable layers:
 *
 *   0  segmentation vs the official `GraphemeBreakTest.txt`
 *   1  per-code-point width: a clean-room raw-UCD oracle vs `codepointWidth`
 *   2  cluster width over the official `emoji-test.txt`
 *   3  vs kitty's reference `wcswidth` (same Text Sizing Protocol spec)
 *
 * Only *new* divergences fail; known ones live in a checked-in allowlist
 * (`known-divergences.md`), so the harness is a ratchet robust to Unicode
 * version drift between the pinned width tables (17.0) and Phobos's `std.uni`
 * grapheme tables.
 *
 * Run:  dub run --root=libs/base/tools/text-conformance -- --layers all
 */
module sparkles.text_conformance.app;

import std.algorithm : canFind, map, filter, splitter;
import std.array : array;
import std.path : buildNormalizedPath, dirName;
import std.stdio : writeln, stderr;
import std.string : strip;

import sparkles.base.styled_template : styledText;
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;

import sparkles.text_conformance.allowlist : Allowlist, loadAllowlist, renderAllowlist;
import sparkles.text_conformance.config : Config, pinnedUnicodeVersion,
    phobosGraphemeUnicodeVersion;
import sparkles.text_conformance.layer0_segmentation : runLayer0;
import sparkles.text_conformance.layer1_width : runLayer1;
import sparkles.text_conformance.layer2_emoji : runLayer2;
import sparkles.text_conformance.layer3_kitty : runLayer3;
import sparkles.text_conformance.layer4_ghostty : runLayer4;
import sparkles.text_conformance.layer5_utf8proc : runLayer5;
import sparkles.text_conformance.layer6_utf8proc_seg : runLayer6;
import sparkles.text_conformance.layer7_icu_seg : runLayer7;
import sparkles.text_conformance.layer8_notcurses : runLayer8;
import sparkles.text_conformance.layer9_rust_uwidth : runLayer9;
import sparkles.text_conformance.report : Divergence, LayerOutcome, LayerResult,
    anyNewFailures, renderSummary;

/// Default allowlist path: the ledger checked in beside this tool.
enum string defaultAllowlistPath = __FILE_FULL_PATH__
    .dirName
    .buildNormalizedPath("../known-divergences.md");

struct CliParams
{
    @CliOption(`l|layers`, "Comma-separated layers to run: any of 0,1,2,3,4,5,6,7,8,9, or 'all' (default).")
    string layers = "all";

    @CliOption(`u|ucd-dir`, "Read Unicode data from this directory instead of downloading (offline).")
    string ucdDir;

    @CliOption(`V|unicode-version`, "Set both --width-unicode-version and --segmentation-unicode-version.")
    string unicodeVersion;

    @CliOption(`width-unicode-version`, "Unicode version for the Layer-1 width oracle's UCD files (matches the pinned width tables).")
    string widthVersion = pinnedUnicodeVersion;

    @CliOption(`segmentation-unicode-version`, "Unicode version for the Layer-0/2 grapheme corpora (should match Phobos's std.uni tables).")
    string segVersion = phobosGraphemeUnicodeVersion;

    @CliOption(`require-kitty`, "Fail (instead of skip) Layer 3 when the kitty width oracle is unavailable.")
    bool requireKitty;

    @CliOption(`n|no-network`, "Never download; fail on a cache miss.")
    bool noNetwork;

    @CliOption(`update-allowlist`, "Rewrite known-divergences.md from the current run's divergences (operator-only).")
    bool updateAllowlist;
}

int main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "text-conformance",
            "Differentially test sparkles.base.text width & segmentation against independent Unicode oracles",
        ),
    );

    Config cfg;
    cfg.layers = parseLayers(cli.layers);
    cfg.ucdDir = cli.ucdDir;
    cfg.noNetwork = cli.noNetwork;
    cfg.widthVersion = cli.unicodeVersion.length ? cli.unicodeVersion : cli.widthVersion;
    cfg.segVersion = cli.unicodeVersion.length ? cli.unicodeVersion : cli.segVersion;
    cfg.requireKitty = cli.requireKitty;
    cfg.updateAllowlist = cli.updateAllowlist;
    cfg.allowlistPath = defaultAllowlistPath;

    LayerResult[] results;
    if (cfg.layers[0]) results ~= run("Layer 0", () => runLayer0(cfg));
    if (cfg.layers[1]) results ~= run("Layer 1", () => runLayer1(cfg));
    if (cfg.layers[2]) results ~= run("Layer 2", () => runLayer2(cfg));
    if (cfg.layers[3]) results ~= run("Layer 3", () => runLayer3(cfg));
    if (cfg.layers[4]) results ~= run("Layer 4", () => runLayer4(cfg));
    if (cfg.layers[5]) results ~= run("Layer 5", () => runLayer5(cfg));
    if (cfg.layers[6]) results ~= run("Layer 6", () => runLayer6(cfg));
    if (cfg.layers[7]) results ~= run("Layer 7", () => runLayer7(cfg));
    if (cfg.layers[8]) results ~= run("Layer 8", () => runLayer8(cfg));
    if (cfg.layers[9]) results ~= run("Layer 9", () => runLayer9(cfg));

    if (cfg.updateAllowlist)
    {
        Divergence[] all;
        foreach (r; results)
            all ~= r.divergences;
        import std.file : write;
        write(cfg.allowlistPath, renderAllowlist(all));
        stderr.writeln("wrote ", cfg.allowlistPath, " (", all.length, " divergence(s))");
    }

    const allow = loadAllowlist(cfg.allowlistPath);
    auto outcomes = results.map!(r => classify(r, allow)).array;

    writeln(renderSummary(outcomes));
    printDivergences(results, allow);

    return anyNewFailures(outcomes) ? 1 : 0;
}

/// Run one layer, converting a thrown exception into a hard error result (so a
/// broken layer fails the run rather than passing silently) without aborting
/// the other layers. A layer that means to *skip* (e.g. an optional oracle is
/// absent) returns `skipped` itself instead of throwing.
private LayerResult run(string label, LayerResult delegate() body_)
{
    try
        return body_();
    catch (Exception e)
    {
        LayerResult r;
        r.name = label;
        r.errored = true;
        r.errorMsg = e.msg;
        stderr.writeln(label, " error: ", e.msg);
        return r;
    }
}

/// Classify a layer's raw divergences against the allowlist into known/new.
private LayerOutcome classify(in LayerResult r, in Allowlist allow)
{
    LayerOutcome o;
    o.name = r.name;
    o.skipped = r.skipped;
    o.skipReason = r.skipReason;
    o.errored = r.errored;
    o.passed = r.passed;
    foreach (d; r.divergences)
    {
        if (allow.isKnown(d))
            o.known++;
        else
            o.newFail++;
    }
    return o;
}

/// Print divergence detail (notes + a capped list of new failures) below the table.
private void printDivergences(in LayerResult[] results, in Allowlist allow)
{
    enum size_t cap = 20;
    foreach (r; results)
    {
        if (r.notes.length)
        {
            writeln();
            writeln(styledText(i"{dim $(r.name) notes:}"));
            foreach (n; r.notes)
                writeln("  ", n);
        }
        auto news = r.divergences.filter!(d => !allow.isKnown(d)).array;
        if (news.length == 0)
            continue;
        writeln();
        writeln(styledText(i"{red $(r.name): $(news.length) new divergence(s)}"));
        foreach (i, d; news)
        {
            if (i >= cap)
            {
                writeln("  … and ", news.length - cap, " more");
                break;
            }
            writeln("  ", d.key, "  observed=", d.observed, " expected=", d.expected, "  ", d.note);
        }
    }
}

/// Parse the `--layers` selector into a run mask.
private bool[10] parseLayers(string spec)
{
    if (spec == "all" || spec.length == 0)
        return [true, true, true, true, true, true, true, true, true, true];

    bool[10] mask;
    foreach (tok; spec.splitter(','))
    {
        switch (tok.strip)
        {
            case "0": mask[0] = true; break;
            case "1": mask[1] = true; break;
            case "2": mask[2] = true; break;
            case "3": mask[3] = true; break;
            case "4": mask[4] = true; break;
            case "5": mask[5] = true; break;
            case "6": mask[6] = true; break;
            case "7": mask[7] = true; break;
            case "8": mask[8] = true; break;
            case "9": mask[9] = true; break;
            default: throw new Exception("unknown layer in --layers: " ~ tok);
        }
    }
    return mask;
}
