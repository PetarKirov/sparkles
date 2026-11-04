/**
The text lab's Android entry: the activity's `sparkles_wsi_onCreate`. Its own
module, not app.d's: dub leaves a library's `app.d` out as a program's main,
and on Android the lab is the shared library a NativeActivity loads.
*/
module android_entry;

version (Android):

import cli : run;
import sparkles.wsi.platform.android : AndroidWsiMain;

/*
The APK's fonts, extracted into the app's data directory on the first launch
(and again when they change), are the only ones the lab draws with — the same
specimen face and fallbacks as on the desktop, not whatever the phone ships.
*/
mixin AndroidWsiMain!androidMain;

void androidMain()
{
    import std.path : buildPath;
    import sparkles.android.activity : internalDataPath;
    import sparkles.android.assets : extractAssetBundle;
    import sparkles.wsi.platform.android : logFailure;

    const data = internalDataPath;
    if (!extractAssetBundle(data, ["fonts"], buildPath(data, "assets-ready")))
        logFailure("text-lab: the APK's fonts could not be extracted");
    const fonts = buildPath(data, "fonts");
    import std.file : exists, readText, remove;
    import std.string : splitLines;

    // App-private, one-shot arguments make device traces reproducible without
    // rebuilding the APK. Consume before launch so an interrupted sweep cannot
    // trap subsequent interactive launches in the profiling workload.
    const next = buildPath(data, "next-launch.args");
    string[] args;
    if (next.exists)
    {
        args = next.readText.splitLines;
        next.remove();
    }
    else args = ["--font", buildPath(fonts, "DejaVuSansMono.ttf")];
    cast(void) run(["text-lab", "--font-dir", fonts] ~ args);
}
