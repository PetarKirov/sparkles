/// The help and its try blocks (`FXU7`, `FXT1`–`FXT5`). The page is parsed
/// with the markdown grammar, so these skip without the grammar bundle.
module help_test;

import std.algorithm.searching : canFind;
import std.conv : text;

import sparkles.ui.geometry : Size;

import evaluate : Root;
import explorer : ExplorerApp, Focus;
import help : runFileset, TryBlock;
import render : renderFrame;

private bool haveGrammars()
{
    import std.process : environment;

    return environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length != 0;
}

/// FXT5: every try block's expected result is what its runner gives.
@("fileset_explorer.FXT5.tutorialChecksItself")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
    auto app = new ExplorerApp(Root(dir: "."), "none");
    assert(app.trees.length == 1 && "tutorial" in app.trees, text(app.trees.keys));
    size_t checked;
    foreach (ref t; app.tries)
    {
        assert(t.runner == "fileset");
        if (t.expected is null)
            continue;
        const r = runFileset(t, app.trees, app.dir);
        assert(r.ok, t.input ~ ": " ~ r.error);
        assert(r.trace == t.expected, text("`", t.input, "` gives\n", r.trace, "but the page expects\n", t.expected));
        ++checked;
    }
    assert(checked >= 7, text(checked, " blocks checked"));
}

/// FXU7: F1 shows the help beside the tree, and F1 again goes back.
@("fileset_explorer.FXU7.helpBesideTheTree")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
    auto app = new ExplorerApp(Root(literal: "src/a.d = a\nREADME.md = r\n", name: "t"), "**");
    const shown = renderFrame(*app, "<F1>", Size(140, 40));
    assert(app.helpShown && app.focus == Focus.side);
    assert(shown.canFind("Fileset explorer") && shown.canFind("README.md"), shown);
    const back = renderFrame(*app, "<F1>", Size(140, 40));
    assert(!app.helpShown && app.focus == Focus.query);
    assert(back.canFind("members ") && !back.canFind("Cheat sheet"), back);
}

/// FXT3: running a block puts its query in the editor, resolves it against
/// its tree, and shows its result under the block, against the expected.
@("fileset_explorer.FXT3.runningABlock")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
    auto app = new ExplorerApp(Root(dir: "."), "none");
    app.runTry(1);
    assert(app.query.text == app.tries[1].input[0 .. $ - 1], app.query.text);
    assert(app.root.inMemory && app.root.name == "tutorial");
    assert(app.shown.found.members.length == 3, text(app.shown.found.members.length));
    // The result shows under the block, once the help scrolls to it (`n`
    // then `p` selects the block again and reveals it).
    app.toggleHelp();
    cast(void) renderFrame(*app, "", Size(140, 40)); // lays the help out
    const frame = renderFrame(*app, "np", Size(140, 40));
    assert(app.trySel == 1 && frame.canFind("✓ result, as expected"), frame);
    // Esc leaves the tutorial tree for the directory.
    auto again = new ExplorerApp(Root(dir: "."), "none");
    again.runTry(0);
    cast(void) renderFrame(*again, "<Tab><Tab><Esc>", Size(100, 30));
    assert(!again.root.inMemory);
}

/// FXT4: a block naming a tree the page does not declare says so.
@("fileset_explorer.FXT4.unknownTree")
@system unittest
{
    string[string] trees = ["t": "a = 1\n"];
    const ok = runFileset(TryBlock("fileset", "t", "a\n", null, 0), trees, Root(dir: "."));
    assert(ok.ok && ok.trace == "a\n");
    const missing = runFileset(TryBlock("fileset", "nope", "a\n", null, 0), trees, Root(dir: "."));
    assert(!missing.ok && missing.error == "no tree `nope` on this page");
}
