#!/usr/bin/env dub
/+ dub.sdl:
    name "tree"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// A miniature `tree(1)`: lists the directory given as the first argument
// (default: the current directory) with `sparkles.core_cli.ui.tree` guides.
//
//     dub run --single libs/core-cli/examples/tree.d -- [path]
//
// The walk mirrors `tree --gitignore`: `sparkles.build_primitives`'s
// `GitRepositoryFilter` applies nested `.gitignore` rules, dotfiles are
// skipped (tree's default), symlinks render as `name -> target` and are never
// followed. The walker's pre-order `enterDir`/`onFile` events map directly
// onto the flat `(label, depth)` nodes `renderTree` consumes — no intermediate
// tree objects. (For non-UTF-8 terminals, pass `treeGlyphs(false)` as
// `renderTree`'s second argument to get the ASCII guide charset.)

module tree_example;

import std.algorithm.searching : startsWith;
import std.file : exists, isDir, isSymlink, readLink;
import std.path : baseName, buildPath;
import std.stdio : stderr, writefln, writeln;

import sparkles.build_primitives.dir_walk :
    GitRepositoryFilter, repositoryGitIgnoreStack, walkDir;
import sparkles.core_cli.ui.tree : renderTree, TreeNode;

/// Wraps `GitRepositoryFilter` (nested-`.gitignore` pruning) with tree's own
/// policies — skip dotfiles, record every shown entry as a `TreeNode`, and
/// keep the directory/file tallies for the summary line.
struct TreeListingHook
{
    GitRepositoryFilter filter;
    string root;
    TreeNode[] nodes;
    size_t dirs, files;

    bool enterDir(const(char)[] relativePath) @safe
    {
        // Hidden directories are rejected before the filter sees them, so the
        // filter's gitignore stack only tracks directories actually entered.
        if (isHidden(relativePath) || !filter.enterDir(relativePath))
            return false;

        nodes ~= TreeNode(relativePath.baseName.idup, depthOf(relativePath));
        dirs++;
        return true;
    }

    void leaveDir(const(char)[] relativePath) @safe pure
    {
        filter.leaveDir(relativePath);
    }

    bool includeFile(const(char)[] relativePath) const @safe pure
    {
        return !isHidden(relativePath) && filter.includeFile(relativePath);
    }

    void onFile(const(char)[] relativePath) @safe
    {
        auto label = relativePath.baseName.idup;

        bool isDirLink;
        const absolutePath = buildPath(root, relativePath);
        if (absolutePath.isSymlink)
        {
            label ~= " -> " ~ absolutePath.readLink;
            // tree(1) tallies a symlink by its target's type (still without
            // following it into the listing).
            isDirLink = absolutePath.exists && absolutePath.isDir;
        }

        nodes ~= TreeNode(label, depthOf(relativePath));
        if (isDirLink)
            dirs++;
        else
            files++;
    }
}

int main(string[] args)
{
    const root = args.length > 1 ? args[1] : ".";
    if (!root.exists || !root.isDir)
    {
        stderr.writefln!"tree: %s: not a directory"(root);
        return 1;
    }

    auto hook = TreeListingHook(
        filter: GitRepositoryFilter(root, repositoryGitIgnoreStack(root)),
        root: root,
        nodes: [TreeNode(root, 0)],
        dirs: 1, // like tree(1), the summary counts the root itself
    );
    walkDir(root, hook);

    foreach (line; renderTree(hook.nodes))
        writeln(line);

    writefln!"\n%s %s, %s %s"(
        hook.dirs, hook.dirs == 1 ? "directory" : "directories",
        hook.files, hook.files == 1 ? "file" : "files");
    return 0;
}

private bool isHidden(in const(char)[] relativePath) @safe pure nothrow @nogc
{
    return relativePath.baseName.startsWith('.');
}

private size_t depthOf(in const(char)[] relativePath) @safe pure nothrow @nogc
{
    size_t depth = 1; // the walk root sits at depth 0
    foreach (c; relativePath)
        depth += c == '/';
    return depth;
}
