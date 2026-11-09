#!/usr/bin/env dub
/+ dub.sdl:
    name "tree"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

// A miniature `tree(1)`: lists the directory given as the first argument
// (default: the current directory) with `sparkles.ui.components.tree` guides.
//
//     dub run --single libs/core-cli/examples/tree.d -- [path]
//
// The listing mirrors `tree --gitignore`, as one fileset: the work tree git
// sees (nested `.gitignore` rules, and those above the directory) minus every
// dotfile, `.*` at any depth (tree's default). `listRepository` resolves it;
// symlinks render as `name -> target` and are never followed. The sorted paths,
// and the directories the listing found nothing in, become the flat
// `(label, depth)` nodes `renderTree` consumes — no intermediate tree objects.
// (For non-UTF-8 terminals, pass `treeGlyphs(false)` as `renderTree`'s second
// argument to get the ASCII guide charset.)

module tree_example;

import std.algorithm.sorting : sort;
import std.array : join, split;
import std.file : exists, isDir, isSymlink, readLink;
import std.path : buildPath;
import std.stdio : stderr, writefln, writeln;

import sparkles.build_primitives.fileset.listing : listRepository, workTree;
import sparkles.build_primitives.fileset.value : Filesets;
import sparkles.ui.components.tree : renderTree, TreeNode;

int main(string[] args)
{
    const root = args.length > 1 ? args[1] : ".";
    if (!root.exists || !root.isDir)
    {
        stderr.writefln!"tree: %s: not a directory"(root);
        return 1;
    }

    auto listed = listRepository(root, (ref Filesets s) @safe
        => s.difference(workTree(s), s.glob(".*").value));
    if (listed.hasError)
    {
        stderr.writefln!"tree: %s: %s"(root, listed.error);
        return 1;
    }

    // Every path to show: the files and links, and the directories, each a
    // trailing `/` so it sorts before the entries beneath it.
    bool[string] dirs;
    void addDirsOf(string path)
    {
        const parts = path.split('/');
        foreach (i; 1 .. parts.length)
            dirs[parts[0 .. i].join("/")] = true;
    }
    foreach (p; listed.value.files)
        addDirsOf(p);
    foreach (d; listed.value.emptyDirs)
        if (d.length)
        {
            dirs[d] = true;
            addDirsOf(d);
        }
    string[] paths = listed.value.files.dup;
    foreach (d; dirs.byKey)
        paths ~= d ~ "/";
    paths.sort!((a, b) => treeOrder(a) < treeOrder(b));

    auto nodes = [TreeNode(root, 0)];
    size_t dirCount = 1, fileCount; // like tree(1), the summary counts the root itself
    foreach (p; paths)
    {
        const isDirEntry = p[$ - 1] == '/';
        const rel = isDirEntry ? p[0 .. $ - 1] : p;
        const parts = rel.split('/');
        string label = parts[$ - 1];
        if (isDirEntry)
            ++dirCount;
        else
        {
            const abs = buildPath(root, rel);
            if (abs.isSymlink)
            {
                label ~= " -> " ~ abs.readLink;
                // tree(1) tallies a symlink by its target's type (still
                // without following it into the listing).
                if (abs.exists && abs.isDir)
                {
                    ++dirCount;
                    nodes ~= TreeNode(label, parts.length);
                    continue;
                }
            }
            ++fileCount;
        }
        nodes ~= TreeNode(label, parts.length);
    }

    foreach (line; renderTree(nodes))
        writeln(line);

    writefln!"\n%s %s, %s %s"(
        dirCount, dirCount == 1 ? "directory" : "directories",
        fileCount, fileCount == 1 ? "file" : "files");
    return 0;
}

// A path as tree(1) orders it: component by component, so `a/x` comes
// before `a-b` and a directory before what lies beneath it.
private string[] treeOrder(string path) @safe pure
{
    return path[$ - 1] == '/' ? path[0 .. $ - 1].split('/') : path.split('/');
}
