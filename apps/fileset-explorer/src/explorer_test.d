/// The explorer's screen, driven through recorded runs (`FXU1`–`FXU9`).
module explorer_test;

import std.algorithm.searching : canFind, countUntil;
import std.array : split;
import std.conv : text;

import sparkles.input : charEvent, Event, Key, keyEvent;
import sparkles.ui.components.file_icons : fileIcon, folderGlyph;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;

import evaluate : Root;
import explorer : ExplorerApp, Focus;
import render : renderFrame;

private enum literal = "src/app.d = module app;\nsrc/lib.d = module lib;\nsrc/lib_test.d = test\n"
    ~ "docs/guide.md = # Guide\nREADME.md = hello\ndub.sdl = name \"x\"\nbin/run +x = #!\n";

private ExplorerApp* make(string query)
{
    return new ExplorerApp(Root(literal: literal, name: "t"), query);
}

/// FXU1: every edit re-resolves; the frame after a keystroke shows it.
@("fileset_explorer.FXU1.live")
@system unittest
{
    auto app = make("src/*.d");
    assert(app.shown.found.members.length == 3);
    const frame = renderFrame(*app, " - **/*_test.d", Size(100, 24));
    assert(app.shown.found.members.length == 2, text(app.shown.found.members.length));
    assert(frame.canFind(" 2 members"), frame);
    assert(!frame.canFind("lib_test.d"), frame);
}

/// Invariant 3: a query that stops parsing leaves the last result on screen.
@("fileset_explorer.lastGoodResult")
@system unittest
{
    auto app = make("src/*.d");
    const frame = renderFrame(*app, " | (", Size(100, 24));
    assert(app.outcome.failed && app.shown.found.members.length == 3);
    assert(frame.canFind("lib.d") && frame.canFind("^ expected"), frame);
}

/// FXU3: the caret is the host's cursor; no glyph of the query moves with it.
@("fileset_explorer.FXU3.hostCursor")
@system unittest
{
    auto app = make("src/*.d");
    auto rec = runAppRecorded(*app, RunConfig.init, [keyEvent(Key.left), keyEvent(Key.left),
        keyEvent(Key.tab)], (ref RecordingHost h) @safe { h.size = Size(100, 24); });
    const first = rec.frames[0].cursor, moved = rec.frames[2].cursor;
    assert(first.visible && moved.visible && moved.x == first.x - 2 && moved.y == first.y,
        text(first, " ", moved));
    assert(first.y == 2 && first.x == 2 + 2 + "src/*.d".length, text("after the border, padding and prompt: ", first));
    assert(!rec.frames[3].cursor.visible, "the tree has focus: no cursor");
}

/// FXU5: the stats column is as wide as its widest line when the tree fits,
/// so the full ids show; on a narrow screen the tree keeps half.
@("fileset_explorer.FXU5.statsWidth")
@system unittest
{
    auto wide = make("**");
    const w = renderFrame(*wide, "", Size(160, 30));
    assert(w.canFind(wide.shown.castore), w);
    auto narrow = make("**");
    const n = renderFrame(*narrow, "", Size(60, 30));
    foreach (line; n.split('\n'))
        if (line.canFind("README.md"))
            assert(line.countUntil("README.md") < 30);
}

/// FXU6 and FXU9: the tree is the members, with hue's icons; a directory
/// closed by the user stays closed across an edit that keeps it.
@("fileset_explorer.FXU6.treeAndIcons")
@system unittest
{
    auto app = make("src/** | README.md | dub.sdl");
    string[] leaves;
    foreach (ref n; app.tree.nodes)
        if (!n.value.isDir)
            leaves ~= n.value.path;
    assert(leaves == ["README.md", "dub.sdl", "src/app.d", "src/lib.d", "src/lib_test.d"], text(leaves));
    const frame = renderFrame(*app, "", Size(100, 24));
    assert(frame.canFind(fileIcon("README.md").glyph ~ "README.md"), frame);
    assert(frame.canFind(fileIcon("dub.sdl").glyph ~ "dub.sdl"), frame);
    assert(frame.canFind(folderGlyph(true) ~ "src"), frame);

    // Close `src`, then edit: it stays closed, and its folder shows closed.
    app.tv.open = app.tv.open.closed("src");
    app.refresh();
    const after = renderFrame(*app, " | docs/**", Size(100, 24));
    assert(after.canFind(folderGlyph(false) ~ "src") && !after.canFind("lib.d"), after);
    assert(after.canFind("guide.md"), after);
}

/// FXU8: a plain frame has the title, the query, the tree and the hints.
@("fileset_explorer.FXU8.plainFrame")
@system unittest
{
    auto app = make("bin/*");
    const frame = renderFrame(*app, "", Size(80, 16));
    const lines = frame.split('\n');
    assert(lines[0].canFind("tutorial tree `t`"), lines[0]);
    assert(frame.canFind("❯ bin/*") && frame.canFind("run (executable, 2 B)"),
        text(frame.canFind("❯ bin/*"), " ", frame.canFind("run ("), " ", frame.split('\n')[6 .. 9]));
    assert(lines[$ - 2].canFind("Tab"), lines[$ - 2]);
}

/// FXU21: in a window, Ctrl+V asks the host for the clipboard, and its answer
/// lands in the query at the caret.
@("fileset_explorer.FXU21.pasteReadsTheClipboard")
@system unittest
{
    import std.range.primitives : put;
    import sparkles.input : Mods, PasteEvent;
    import sparkles.ui_app.backend : Backend;

    auto app = make("src/*.d");
    auto gui = delegate(ref RecordingHost h) @safe {
        h.size = Size(100, 24);
        h.backend = Backend.gui;
        h.capabilities.clipboardRead = true;
    };

    auto asked = runAppRecorded(*app, RunConfig.init, [charEvent('v', Mods(ctrl: true))], gui);
    assert(asked.clipboardReads.length == 1, text(asked.clipboardReads));
    assert(app.query.text == "src/*.d", "nothing is pasted before the answer");

    PasteEvent answer;
    cast(void) answer.text.tryWrite((ref s) { put(s, " | *.md"); });
    answer.last = true;
    answer.request = asked.clipboardReads[0];
    cast(void) runAppRecorded(*app, RunConfig.init, [Event(answer)], gui);
    assert(app.query.text == "src/*.d | *.md", app.query.text);
    assert(app.shown.found.members.length == 5, text(app.shown.found.members.length));
}
