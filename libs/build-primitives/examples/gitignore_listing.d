#!/usr/bin/env dub
/+ dub.sdl:
    name "gitignore_listing"
    dependency "sparkles:build-primitives" path="../../../"
    dependency "sparkles:core-cli" path="../../../"
    targetPath "build"
+/

// `sparkles.build_primitives` walking a directory with nested-`.gitignore`
// awareness: a custom DbI hook (`enterDir`/`leaveDir`/`includeFile`/`onFile`)
// maintains a `GitIgnoreStack` so deeper `.gitignore` files override shallower
// ones, and can list either side of the split (ignored / not ignored). The
// matched paths then render both flat and as a `renderTree` view.

import std.algorithm.searching : startsWith;
import std.array : split;
import std.exception : enforce;
import std.file : exists, isDir;
import std.path : buildPath;
import std.stdio : writeln;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.build_primitives.dir_walk : readRepositoryGitIgnore, walkDir;
import sparkles.build_primitives.gitignore : GitIgnore, GitIgnoreStack;
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;
import sparkles.core_cli.ui.tree : renderTree, TreeNode;

enum ListingMode
{
    ignored,
    notIgnored,
}

struct CliParams
{
    @CliOption("m|mode", "Listing mode: ignored or notIgnored (default: notIgnored)")
    ListingMode mode = ListingMode.notIgnored;

    @CliOption("r|root", "Directory root to scan (default: .)")
    string root = ".";
}

/// Walk hook selecting one side of the gitignore split. Unlike
/// `GitRepositoryFilter` it never prunes ignored directories — it must descend
/// into them to list their files under `--mode=ignored`.
struct ListingHook
{
    string root;
    ListingMode mode;
    GitIgnoreStack stack;
    bool[] dirIgnored; // one entry per entered directory (parallels the stack)
    string[] matches;

    bool enterDir(const(char)[] relativePath) @safe
    {
        if (isGitMetadataPath(relativePath))
            return false;

        // Once a directory is ignored its whole subtree is: a deeper
        // `.gitignore` cannot re-include below an excluded directory.
        const ignored = insideIgnoredDir || stack.isIgnored(relativePath, true);
        dirIgnored ~= ignored;

        const dirPrefix = relativePath.idup;
        stack.push(dirPrefix, GitIgnore.fromFile(buildPath(root, dirPrefix, ".gitignore")));
        return true;
    }

    void leaveDir(const(char)[] relativePath) @safe pure
    {
        stack.pop();
        dirIgnored = dirIgnored[0 .. $ - 1];
    }

    bool includeFile(const(char)[] relativePath) const @safe pure
    {
        if (isGitMetadataPath(relativePath))
            return false;

        const ignored = insideIgnoredDir || stack.isIgnored(relativePath, false);
        return mode == ListingMode.ignored ? ignored : !ignored;
    }

    void onFile(const(char)[] relativePath) @safe pure
    {
        matches ~= relativePath.idup;
    }

private:

    bool insideIgnoredDir() const @safe pure nothrow @nogc
    {
        return dirIgnored.length > 0 && dirIgnored[$ - 1];
    }

    bool isGitMetadataPath(const(char)[] relativePath) const @safe pure nothrow @nogc
    {
        return relativePath == ".git" || relativePath.startsWith(".git/");
    }
}

void main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(HelpInfo(
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

    enforce(cli.root.exists, "Directory does not exist: " ~ cli.root);
    enforce(cli.root.isDir, "Path is not a directory: " ~ cli.root);

    auto hook = ListingHook(
        root: cli.root,
        mode: cli.mode,
    );
    hook.stack.push("", readRepositoryGitIgnore(cli.root));
    walkDir(cli.root, hook);

    writeln(cli.prettyPrint(PrettyPrintOptions!void(softMaxWidth: 0)));

    writeln("\nFlat List:");
    if (hook.matches.length == 0)
        writeln("(no files)");
    else
        foreach (path; hook.matches)
            writeln(path);

    writeln("\nTree View:");
    if (hook.matches.length == 0)
    {
        writeln("(no files)");
        return;
    }

    foreach (line; renderTree(toTreeNodes(hook.matches)))
        writeln(line);
}

/// Converts walk-ordered relative paths into the flat pre-ordered
/// `(label, depth)` nodes `renderTree` consumes, emitting each shared
/// directory segment once (the walk keeps a directory's subtree contiguous).
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
