/**
The editor's Android entry: the activity's `sparkles_wsi_onCreate`. Its own
module, not app.d's: dub leaves a library's `app.d` out as a program's main,
and on Android the editor is the shared library a NativeActivity loads.

The APK's fonts are extracted into the app's data directory on the first
launch (and again when they change); session recovery keeps its archives
there too, which Android keeps across launches and removes with the app
(`EAP26`).
*/
module android_entry;

version (Android):

import cli : run;
import sparkles.wsi.platform.android : AndroidWsiMain;

mixin AndroidWsiMain!androidMain;

void androidMain()
{
    import std.file : exists, readText, remove;
    import std.path : buildPath;
    import std.string : splitLines;
    import sparkles.android.activity : internalDataPath;
    import sparkles.android.assets : extractAssetBundle;
    import sparkles.wsi.platform.android : logFailure;

    const data = internalDataPath;
    if (!extractAssetBundle(data, ["fonts"], buildPath(data, "assets-ready")))
        logFailure("editor: the APK's fonts could not be extracted");
    const fonts = buildPath(data, "fonts");
    // Android sets no HOME; the recovery namespace root is the app's private
    // directory, the only tree it may open (the filesystem root is denied).
    import std.process : environment;
    environment["HOME"] = data;
    // App-private, one-shot arguments (an example, a screenshot) make device
    // checks reproducible without rebuilding the APK; consumed before launch.
    const next = buildPath(data, "next-launch.args");
    string[] args;
    if (next.exists)
    {
        args = next.readText.splitLines;
        next.remove();
    }
    cast(void) run(["editor", "--gui", "--font-dir", fonts, "--font", buildPath(fonts, "DejaVuSansMono.ttf"),
        "--state-dir", buildPath(data, "sessions")] ~ args);
}
