#!/usr/bin/env dub
/+ dub.sdl:
    name "gitignore_listing"
    dependency "sparkles:build-primitives" path="../../../"
    dependency "sparkles:core-cli" path="../../../"
    targetPath "build"
+/

import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.file : exists, isDir;
import std.stdio : writeln;
import std.string : split;

import sparkles.build_primitives.dir_walk : readRepositoryGitIgnore, walkDir;
import sparkles.build_primitives.gitignore : GitIgnore;
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;
import sparkles.core_cli.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.core_cli.ui.tree_view : TreeViewProps, drawTree;

struct FileTreeNode
{
    string label;
    FileTreeNode[] children;
}

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

struct ListingHook
{
    GitIgnore ignore;
    ListingMode mode;
    string[] matches;

    @safe bool enterDir(const(char)[] relativePath) const pure nothrow
    {
        return relativePath != ".git" && !relativePath.startsWith(".git/");
    }

    @safe bool includeFile(const(char)[] relativePath) const
    {
        const ignored = ignore.isIgnored(relativePath);
        return mode == ListingMode.ignored ? ignored : !ignored;
    }

    @safe void onFile(const(char)[] relativePath)
    {
        matches ~= relativePath.idup;
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

    const mode = cli.mode;

    enforce(cli.root.exists, "Directory does not exist: " ~ cli.root);
    enforce(cli.root.isDir, "Path is not a directory: " ~ cli.root);

    auto ignore = readRepositoryGitIgnore(cli.root);
    auto hook = ListingHook(ignore: ignore, mode: mode);
    walkDir(cli.root, hook);
    hook.matches.sort;

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

    auto tree = buildTree(hook.matches);
    const rendered = drawTree(tree, TreeViewProps!void(
        useColors: false,
        showRoot: false,
    ));
    writeln(rendered);
}

private FileTreeNode buildTree(in string[] files)
{
    FileTreeNode root = FileTreeNode(label: ".");

    foreach (path; files)
        insertPath(root, path);

    sortTree(root);
    markDirectories(root);
    return root;
}

private void insertPath(ref FileTreeNode root, string path)
{
    auto current = &root;
    foreach (segment; path.split('/'))
    {
        if (segment.length == 0)
            continue;

        const index = ensureChild(*current, segment);
        current = &current.children[index];
    }
}

private size_t ensureChild(ref FileTreeNode node, string label)
{
    foreach (i, ref child; node.children)
    {
        if (child.label == label)
            return i;
    }

    node.children ~= FileTreeNode(label: label);
    return node.children.length - 1;
}

private void sortTree(ref FileTreeNode node)
{
    node.children.sort!((a, b) => a.label < b.label);
    foreach (ref child; node.children)
        sortTree(child);
}

private void markDirectories(ref FileTreeNode node)
{
    foreach (ref child; node.children)
    {
        markDirectories(child);
        if (child.children.length > 0)
            child.label ~= "/";
    }
}
