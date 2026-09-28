/**
hue's half of the Android glue: the app-specific layout and policies over the
NDK/JNI plumbing in `sparkles:android` (activity handle, logcat, asset bundle,
clipboard). The pure path derivations live in `android_paths.d`, host-tested.
*/
module android_glue;

version (Android):

import android_paths;
import sparkles.base.logger : LogLevel, warning;

/// The logcat tag every hue log line carries (matches the `hue-logcat` filter).
enum logTag = "hue";

/// The app's private data directory — the root of the extracted asset bundle
/// and all writable state.
string androidDataDir() @safe nothrow @nogc
{
    import sparkles.android.activity : internalDataPath;

    return internalDataPath;
}

/// Replace the process loggers with the logcat sink, tag "hue". Call after
/// `runCli`'s `initLogger` (this overrides that sink).
void installLogcatSink(LogLevel level) @safe
{
    import sparkles.android.log : install = installLogcatSink;

    install(level, logTag);
}

/// Copy `text` to the system clipboard (`false` when the JNI bridge failed).
bool setClipboardText(scope const(char)[] text) @safe nothrow
{
    import sparkles.android.clipboard : set = setClipboardText;

    return set(text, logTag);
}

/// Load `<dataDir>/hue-debug.env` into the process environment, re-enabling
/// the `HUE_GUI_*` golden/debug hooks on-device (an activity has no shell to
/// export them; push the file via `adb shell run-as`). Missing file = no-op.
void loadDebugEnv() @safe
{
    import std.file : exists, readText;
    import std.process : environment;

    import sparkles.android.bundle : parseEnvFile;

    const path = debugEnvPath(androidDataDir());
    if (!path.exists)
        return;
    try
        foreach (pair; parseEnvFile(readText(path)))
            environment[pair.key] = pair.value;
    catch (Exception e)
        warning(i"hue: unreadable hue-debug.env: $(e.msg)");
}

/**
Extract the APK asset bundle (fonts + charset sidecars, grammar queries,
sample docs) into the data dir when the bundle changed. Returns `true` when
the assets are present; `false` (after a warning) leaves hue on its built-in
degradations — plain-text rendering, default document only.
*/
bool extractAssetsIfNeeded() @safe
{
    import sparkles.android.assets : extractAssetBundle;

    const dataDir = androidDataDir();
    // Only the directories the bundle owns — never the whole data dir, which
    // also holds hue-debug.env, config.json and the marker.
    static immutable owned = ["fonts", "grammars", "docs"];
    return extractAssetBundle(dataDir, owned, assetsReadyPath(dataDir));
}
