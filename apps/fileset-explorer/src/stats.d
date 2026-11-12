/**
The Stats tab's lines (`FXU1`, `FXS1`), shared by the tab and by the `stats`
subcommand (`FXC2`): what a resolution found, its names, and its commonest
extensions.
*/
module stats;

import std.algorithm.comparison : max, min;
import std.conv : text;
import std.format : format;

import sparkles.build_primitives.fileset.fso : FsoKind;

import evaluate : autoIdBytes, humanBytes, Outcome;

/// The names a Stats line shows and copies (`FXS1`), in order.
static immutable string[] nameKeys = ["castore", "NarHash", "store path", "git tree", "git (Nix)", "SWHID",
    "iroh"];

/// Name `i` of `o`, as shown and copied; why not, where it has none.
string nameValueOf(ref const Outcome o, size_t i) @safe pure nothrow
{
    final switch (i)
    {
        case 0: return o.castore;
        case 1: return o.narHash;
        case 2: return o.storePath;
        case 3: return o.gitTree;
        case 4: return o.gitSri;
        case 5: return o.swhid;
        case 6: return o.collectionError.length ? o.collectionError : o.collection;
    }
}

/**
The Stats lines of `shown`, `[key, value]`, an empty key a heading: or, when
nothing resolved yet, the state of `latest`. `idsHint` follows the limit
above which the ids wait to be asked for; `section` goes before the
extensions (the tab's Send section).
*/
string[2][] statsRows(ref const Outcome shown, ref const Outcome latest, string idsHint,
    const(string[2])[] section = null) @safe
{
    string[2][] rows;
    const o = shown;
    if (!o.resolved)
        return [["state", latest.failed ? latest.error.message : "no result yet"]];
    size_t files, links, exes;
    foreach (ref m; o.found.members)
    {
        files += m.kind == FsoKind.regular;
        links += m.kind == FsoKind.symlink;
        exes += m.executable;
    }
    rows ~= ["members", text(o.found.members.length)];
    rows ~= ["files", text(files, exes ? text(" (", exes, " executable)") : "")];
    rows ~= ["symlinks", text(links)];
    rows ~= ["size", humanBytes(o.bytes)];
    rows ~= ["dirs walked", text(o.found.directories)];
    rows ~= ["empty dirs", text(o.found.empty.length)];
    rows ~= ["unreadable", text(o.found.unreadable.length)];
    rows ~= ["resolved in", format!"%.2f ms"(o.millis)];
    rows ~= ["", ""];
    if (o.hasIds)
    {
        // Every name, each copied by choosing it (`FXS1`, `FXS2`).
        foreach (i, key; nameKeys)
        {
            rows ~= [key, nameValueOf(o, i)];
            if (key == "NarHash")
                rows ~= ["NarSize", humanBytes(o.narSize)];
        }
        if (o.collectionLinks)
            rows ~= ["iroh skips", text(o.collectionLinks, o.collectionLinks == 1 ? " link" : " links")];
    }
    else
        rows ~= ["ids", "over " ~ humanBytes(autoIdBytes) ~ idsHint];
    rows ~= section;
    rows ~= ["", ""];
    rows ~= ["", "by extension"];
    foreach (e; o.extensions[0 .. min(8, o.extensions.length)])
        rows ~= ["  " ~ e[0], e[1]];
    return rows;
}

/// The width of a Stats key, its leading space included.
enum int statsKeyWidth = 13;

/**
`rows` as text (`FXC2`): each key padded to the column the tab draws it in,
each heading on a line of its own, an empty heading an empty line.
*/
string formatStats(in string[2][] rows) @safe
{
    import sparkles.base.text.grapheme : visibleWidth;

    string s;
    foreach (ref kv; rows)
    {
        if (kv[0].length == 0)
            s ~= (kv[1].length ? kv[1] : "") ~ "\n";
        else
        {
            const pad = max(1, statsKeyWidth - 1 - cast(int) visibleWidth(kv[0]));
            char[] gap = new char[pad];
            gap[] = ' ';
            s ~= kv[0] ~ gap ~ kv[1] ~ "\n";
        }
    }
    return s;
}

///
@("fileset_explorer.formatStats")
@safe unittest
{
    assert(formatStats([["members", "3"], ["", ""], ["", "by extension"], ["  .d", "2"]])
        == "members     3\n\nby extension\n  .d        2\n");
}
