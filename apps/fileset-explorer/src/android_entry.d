/**
The explorer's Android entry (`FXA1`): the activity's `sparkles_wsi_onCreate`.
Its own module, not app.d's: dub leaves a library's `app.d` out as a
program's main, and on Android the explorer is the shared library a
NativeActivity loads.
*/
module android_entry;

version (Android):

import std.path : buildPath;

import sparkles.android.activity : internalDataPath;
import sparkles.android.assets : extractAssetBundle;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.wsi.platform.android : AndroidWsiMain, logFailure;

import evaluate : Root;
import launch : defaultQuery, launch, sonameQueriesRoot;

/*
The APK carries the sparkles repository, the fonts and the grammar queries
(nix/packages/android/fileset-explorer.nix); they are extracted into the
app's data directory on the first launch, and again when they change. The
repository there is the fileset root (`FXA2`).
*/
mixin AndroidWsiMain!androidMain;

void androidMain()
{
    const data = internalDataPath;
    if (!extractAssetBundle(data, ["fonts", "grammars", "repo"], buildPath(data, "assets-ready")))
        logFailure("fileset-explorer: the APK's assets could not be extracted");
    sonameQueriesRoot = buildPath(data, "grammars");
    GuiOptions gui;
    gui.gui = true;
    gui.fontDir = [buildPath(data, "fonts")];
    cast(void) launch(Root(dir: buildPath(data, "repo")), defaultQuery, gui);
}
