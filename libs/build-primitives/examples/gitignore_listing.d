#!/usr/bin/env dub
/+ dub.sdl:
    name "gitignore_listing"
    dependency "sparkles:build-primitives" path="../../../"
    dependency "sparkles:core-cli" path="../../../"
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

// Either side of a directory's `.gitignore` split, as a fileset: the files git
// keeps (`everything - gitignored - /.git`) or the ones it ignores
// (`gitignored - /.git`). `listRepository` resolves the fileset at the
// enclosing repository's root, so the `.gitignore` files above the directory
// apply too, and a deeper one overrides a shallower one, as in git. The
// matched paths then render both flat and as a `renderTree` view.

import std.array : split;
import std.exception : enforce;
import std.file : exists, isDir;
import std.stdio : writeln;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.build_primitives.fileset.listing : listRepository, workTree;
import sparkles.build_primitives.fileset.value : Fileset, Filesets;
import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;
import sparkles.ui.components.tree : renderTree, TreeNode;

enum ListingMode
{
    ignored,
    notIgnored,
}

struct CliParams
{
    @(Option("m|mode", description:
        "Listing mode: ignored or notIgnored (default: notIgnored)"))
    ListingMode mode = ListingMode.notIgnored;

    @(Option("r|root", description: "Directory root to scan (default: .)"))
    string root = ".";
}

int main(string[] args)
{
    auto parsed = parseCli!CliParams(args, HelpInfo(
        "gitignore-listing",
        "List ignored or non-ignored files from a directory",
        [
            "description": [
                "Print matching files in two formats: a flat list and a tree view.",
                "Use --mode=ignored to list ignored files.",
                "Use --mode=notIgnored (default) to list non-ignored files.",
            ],
        ],
    ));
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

    enforce(cli.root.exists, "Directory does not exist: " ~ cli.root);
    enforce(cli.root.isDir, "Path is not a directory: " ~ cli.root);

    // Once a directory is ignored its whole subtree is, which the fileset's
    // `gitignored` leaf already says: a deeper `.gitignore` cannot re-include
    // below an excluded directory.
    const mode = cli.mode;
    auto listed = listRepository(cli.root, (ref Filesets s) @safe => mode == ListingMode.ignored
        ? s.difference(s.gitignored, s.glob("/.git").value) : workTree(s));
    enforce(!listed.hasError, listed.hasError ? listed.error : "");
    const matches = listed.value.files;

    writeln(cli.prettyPrint(PrettyPrintOptions!void(softMaxWidth: 0)));

    writeln("\nFlat List:");
    if (matches.length == 0)
        writeln("(no files)");
    else
        foreach (path; matches)
            writeln(path);

    writeln("\nTree View:");
    if (matches.length == 0)
    {
        writeln("(no files)");
        return 0;
    }

    foreach (line; renderTree(toTreeNodes(matches)))
        writeln(line);

    return 0;
}

/// Converts sorted relative paths into the flat pre-ordered `(label, depth)`
/// nodes `renderTree` consumes, emitting each shared directory segment once
/// (sorting keeps a directory's subtree contiguous).
private TreeNode[] toTreeNodes(in string[] walkOrderedPaths) @safe pure
{
    TreeNode[] nodes;
    const(string)[] openDirs;

    foreach (path; walkOrderedPaths)
    {
        auto segments = path.split('/');
        const dirs = segments[0 .. $ - 1];

        size_t common = 0;
        while (common < openDirs.length && common < dirs.length
            && openDirs[common] == dirs[common])
            common++;

        foreach (depth; common .. dirs.length)
            nodes ~= TreeNode(dirs[depth] ~ "/", depth);
        nodes ~= TreeNode(segments[$ - 1], dirs.length);

        openDirs = dirs;
    }

    return nodes;
}
