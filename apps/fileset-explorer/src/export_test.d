/// The Export tab (`FXE12`), driven through recorded runs.
module export_test;

import std.algorithm.searching : canFind;

import sparkles.build_primitives.fileset.emit : NixGlobs, Target;
import sparkles.ui.geometry : Size;

import sparkles.fileset_tools.evaluate : Root;
import explorer : ExplorerApp;
import render : renderFrame;

private enum literal = "src/app.d = a\nsrc/lib_test.d = t\nREADME.md = r\nbin/run +x = go\n";

/// FXE12: the tab shows the selected target's code for the current query, `t`
/// changes the target, `g` Nix's glob mode, and a refusal names its reason
/// and marks the refused bytes in the query.
@("fileset_explorer.FXE12.exportTab")
@system unittest
{
    auto app = new ExplorerApp(Root(literal: literal, name: "t"), "src/** - **/*_test.d");
    // Tab twice to the right group; Right twice to Export.
    const nix = renderFrame(*app, "<Tab><Tab><Right><Right>", Size(150, 44));
    assert(app.exportShown && app.exportTarget == Target.nix);
    assert(nix.canFind("fs.toSource") && nix.canFind("glob = dirOnly: re:"), nix);

    const expanded = renderFrame(*app, "g", Size(150, 44));
    assert(app.nixGlobs == NixGlobs.expand && expanded.canFind("snapshot"), expanded);

    const git = renderFrame(*app, "t", Size(150, 44));
    assert(app.exportTarget == Target.gitPathspec && git.canFind("git ls-files"), git);

    // A query rsync cannot hold: the reason, and the bytes, in the tab.
    auto refused = new ExplorerApp(Root(literal: literal, name: "t"), "src/** & exec()");
    const r = renderFrame(*refused, "<Tab><Tab><Right><Right>ttt", Size(150, 44));
    assert(refused.exportTarget == Target.rsync && !refused.currentExport.ok);
    assert(r.canFind("✗ rsync's first-match filter list cannot express an intersection"), r);
    assert(r.canFind("in the query: src/** & exec"), r);
}
