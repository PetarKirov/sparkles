/**
 * Known-divergence allowlist (the ratchet).
 *
 * `known-divergences.md` is a markdown table — same spirit as
 * `docs/specs/base/text/test-cases.md` — whose rows record divergences that
 * have been reviewed and accepted (typically Phobos-vs-UCD Unicode version
 * skew). A run's divergence matching a row is reported as *known* and does not
 * fail the build; an unmatched one is *new* and does. `--update-allowlist`
 * rewrites the file from the current run.
 *
 * Row schema:  `| layer | key | observed | expected | reason |`
 */
module sparkles.text_conformance.allowlist;

import std.algorithm : map, filter, startsWith, all, splitter;
import std.array : array, join;
import std.conv : to;
import std.file : exists, readText, write;
import std.string : strip, lineSplitter;

import sparkles.text_conformance.report : Divergence;

/// Parsed allowlist: a set of normalized entry keys.
struct Allowlist
{
    private bool[string] _known;

    bool isKnown(in Divergence d) const
        => (entryKey(d) in _known) !is null;

    size_t length() const => _known.length;
}

/// Stable key identifying a divergence for allowlist matching (reason excluded).
string entryKey(in Divergence d)
    => d.layer.to!string ~ "\t" ~ d.key ~ "\t" ~ d.observed ~ "\t" ~ d.expected;

/// Load the allowlist from `path`. A missing file is an empty allowlist.
Allowlist loadAllowlist(string path)
{
    Allowlist a;
    if (!path.length || !path.exists)
        return a;

    foreach (line; path.readText.lineSplitter)
    {
        auto t = line.strip;
        if (!t.startsWith("|"))
            continue;
        auto cells = t.splitter('|').map!strip.array;
        // splitter on a "|...|" line yields leading/trailing empty cells.
        if (cells.length < 6)
            continue;
        const layer = cells[1];
        const key = cells[2];
        // Skip the header row and the `---` separator row.
        if (layer == "layer" || layer.all!(c => c == '-' || c == ':') )
            continue;
        const observed = cells[3];
        const expected = cells[4];
        a._known[layer ~ "\t" ~ key ~ "\t" ~ observed ~ "\t" ~ expected] = true;
    }
    return a;
}

/// Serialize divergences to the markdown ledger format (for `--update-allowlist`).
string renderAllowlist(in Divergence[] divs)
{
    string[] lines = [
        "# Known divergences",
        "",
        "Reviewed, accepted divergences between `sparkles.base.text` and the",
        "conformance oracles. Only divergences **absent** from this table fail the",
        "run, so the harness is a ratchet.",
        "",
        "The common, expected cause is **Unicode version skew**: the width tables",
        "are pinned to a fixed UCD release (see `gen_unicode_tables.d`), but the",
        "library's general-category and grapheme data come from the toolchain's",
        "Phobos `std.uni`, which may lag. A newly-assigned combining mark therefore",
        "reads as width 1 (impl) vs 0 (oracle, current UCD) until the compiler",
        "catches up. Re-review and regenerate with `text-conformance --update-allowlist`",
        "after a toolchain bump.",
        "",
        "| layer | key | observed | expected | reason |",
        "| ----- | --- | -------- | -------- | ------ |",
    ];
    foreach (d; divs)
        lines ~= "| " ~ [d.layer.to!string, d.key, d.observed, d.expected, d.note].join(" | ") ~ " |";
    return lines.join("\n") ~ "\n";
}
