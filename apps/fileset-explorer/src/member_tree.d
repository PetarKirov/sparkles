/**
The member tree (`FXU6`, `FXU9`): the resolved members as a tree whose inner
nodes are only the directories on the way to them, drawn as
`lib.fileset.trace` describes them, with hue's file-type icons.
*/
module member_tree;

import std.conv : text;

import sparkles.base.term_color : RgbColor;
import sparkles.build_primitives.fileset.fso : FsoKind;
import sparkles.ui.components.file_icons : fileIcon, folderFg, folderGlyph;
import sparkles.ui.components.tree_widget : TreeData;
import sparkles.ui.style : Slot;

import evaluate : humanBytes, Member;

/// A node of the member tree, with the capabilities the tree view looks for.
struct Item
{
    string label;             ///
    string icon;              /// the Nerd glyph and its space (`FXU9`)
    RgbColor iconFg;          /// its brand colour
    bool hasIconFg = true;    ///
    Slot slot = Slot.inherit; ///
    string badge;             /// what `lib.fileset.trace` says beside a path
    Slot badgeSlot = Slot.muted; ///
    string path;              /// the disclosure key
    bool isDir;               ///

    /// A directory toggles even when its children are hidden.
    bool expandable() const @safe pure nothrow @nogc => isDir;
}

/**
The members as a tree. Directories come into being as a member beneath them
does, so only the directories on the way to one appear (`FXU6`).
*/
TreeData!Item buildTree(in Member[] members) @safe
{
    TreeData!Item data;
    uint[string] dirs;
    size_t[uint] files;
    ulong[uint] bytes;

    uint dirNode(string path)
    {
        if (auto n = path in dirs)
            return *n;
        size_t cut = 0;
        bool nested;
        foreach (i, c; path)
            if (c == '/')
            {
                cut = i;
                nested = true;
            }
        const parent = nested ? dirNode(path[0 .. cut]) : uint.max;
        const name = nested ? path[cut + 1 .. $] : path;
        const n = data.add(Item(label: name, icon: folderGlyph(true), iconFg: folderFg,
            slot: Slot.accentPrimary, path: path, isDir: true), parent);
        dirs[path] = n;
        return n;
    }

    foreach (ref m; members)
    {
        size_t cut = 0;
        bool nested;
        foreach (i, c; m.path)
            if (c == '/')
            {
                cut = i;
                nested = true;
            }
        const parent = nested ? dirNode(m.path[0 .. cut]) : uint.max;
        Item it;
        it.label = nested ? m.path[cut + 1 .. $] : m.path;
        it.path = m.path;
        const icon = fileIcon(it.label);
        it.icon = icon.glyph;
        it.iconFg = icon.fg;
        final switch (m.kind)
        {
            case FsoKind.regular:
                it.slot = m.executable ? Slot.success : Slot.inherit;
                it.badge = text("(", m.executable ? "executable" : "regular", ", ", humanBytes(m.size), ")");
                break;
            case FsoKind.symlink:
                it.slot = Slot.info;
                it.badge = text("(symlink → ", m.target, ")");
                break;
            case FsoKind.directory:
                break;
        }
        data.add(it, parent);
        for (uint p = parent; p != uint.max; p = data.nodes[p].parent)
        {
            files[p] = files.get(p, 0) + 1;
            bytes[p] = bytes.get(p, 0) + m.size;
        }
    }
    foreach (n, count; files)
        data.nodes[n].value.badge = text("(", count, count == 1 ? " member, " : " members, ",
            humanBytes(bytes[n]), ")");
    return data;
}

/// Shows each directory's folder glyph open or closed as `isOpen` says.
void syncFolders(ref TreeData!Item data, scope bool delegate(string) @safe isOpen) @safe
{
    foreach (ref n; data.nodes)
        if (n.value.isDir)
            n.value.icon = folderGlyph(isOpen(n.value.path));
}

/// FXU6: the leaves are the members, the inner nodes only the directories on
/// the way; FXU9: each row carries hue's icon for its name.
@("fileset_explorer.memberTree")
@safe unittest
{
    const members = [
        Member("README.md", FsoKind.regular, false, null, 10),
        Member("src/app/x.d", FsoKind.regular, false, null, 3),
        Member("src/run", FsoKind.regular, true, null, 4),
        Member("l", FsoKind.symlink, false, "src", 0),
    ];
    auto t = buildTree(members);
    string[] leaves, dirs;
    foreach (ref n; t.nodes)
        (n.value.isDir ? dirs : leaves) ~= n.value.path;
    assert(leaves == ["README.md", "src/app/x.d", "src/run", "l"]);
    assert(dirs == ["src", "src/app"]);
    foreach (ref n; t.nodes)
        if (n.value.path == "README.md")
            assert(n.value.icon == fileIcon("README.md").glyph && n.value.iconFg == fileIcon("x.md").fg);
        else if (n.value.path == "src")
            assert(n.value.badge == "(2 members, 7 B)" && n.value.iconFg == folderFg);
    syncFolders(t, (string p) => false);
    assert(t.nodes[1].value.icon == folderGlyph(false));
}
