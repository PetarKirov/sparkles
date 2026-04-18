#!/usr/bin/env dub
/+ dub.sdl:
    name "tree_view"
    dependency "sparkles:core-cli" path="../../../"
    targetPath "build"
+/

import sparkles.core_cli.ui.demo : Section, runDemo;
import sparkles.core_cli.ui.tree_view : drawTree, TreeViewProps;

struct FileNode
{
    string label;
    const(FileNode)[] children;
}

struct Dep
{
    string name;
    string ver;
    const(Dep)[] children;
}

struct DepHook
{
    string label(in Dep d) const
    {
        return d.name ~ " " ~ d.ver;
    }
}

void main()
{
    runDemo(
        header: "drawTree Demo - Tree View",
        content: [
            Section(
                header: "File System Tree",
                content: drawTree(FileNode("sparkles/", [
                    FileNode("libs/", [
                        FileNode("core-cli/", [
                            FileNode("src/"),
                            FileNode("dub.sdl"),
                        ]),
                        FileNode("test-utils/", [
                            FileNode("src/"),
                            FileNode("dub.sdl"),
                        ]),
                    ]),
                    FileNode("scripts/", [
                        FileNode("run-tests.sh"),
                    ]),
                    FileNode("README.md"),
                    FileNode("dub.sdl"),
                ]), TreeViewProps!void(useColors: false)),
            ),
            Section(
                header: "Multiple Roots",
                content: drawTree([
                    FileNode("src/", [
                        FileNode("main.d"),
                        FileNode("util.d"),
                    ]),
                    FileNode("tests/", [
                        FileNode("test_main.d"),
                    ]),
                    FileNode("README.md"),
                ], TreeViewProps!void(useColors: false)),
            ),
            Section(
                header: "Dependency Tree (Custom Hook)",
                content: drawTree([
                    Dep("sparkles", "0.0.1", [
                        Dep("silly", "1.1.1", []),
                        Dep("delta", "0.3.0", []),
                    ]),
                    Dep("my-app", "1.0.0", [
                        Dep("sparkles", "0.0.1", []),
                        Dep("vibe-d", "0.9.5", [
                            Dep("openssl", "1.1.1", []),
                        ]),
                    ]),
                ], TreeViewProps!DepHook(useColors: false)),
            ),
            Section(
                header: "Hidden Root",
                content: drawTree(FileNode("hidden/", [
                    FileNode("visible1.d"),
                    FileNode("visible2.d"),
                    FileNode("subdir/", [
                        FileNode("nested.d"),
                    ]),
                ]), TreeViewProps!void(useColors: false, showRoot: false)),
            ),
        ],
    );
}
