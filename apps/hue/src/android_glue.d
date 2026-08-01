/**
The platform glue of the Android build: the one module that talks to the NDK
surface. Everything else receives plain paths and values (the pure derivations
live in `android_paths.d`, host-tested).

What lives here:
$(LIST
    * hand-declared `extern(C)` mirrors of the stable head of
        `android_app`/`ANativeActivity` — ImportC cannot parse
        `android_native_app_glue.h` (its kernel-header closure trips on
        `__int128`/`__alignof__`), and only these leading fields are touched;
    * `GetAndroidApp()` — defined by raylib's rcore_android.c (not bound by
        raylib-d), valid from `android_main` on, i.e. before `main()` runs;
    * the logcat logger (stdout/stderr go nowhere in a NativeActivity);
    * the first-run asset extraction via `AAssetManager` — `hasCode="false"`
        means there is no Java to do it. `AAssetDir` cannot enumerate
        subdirectories, so the nix build writes `assets/asset-manifest.txt`
        (one relative path per line): the manifest IS the directory listing.
)
*/
module android_glue;

version (Android):

import std.logger : Logger;
import std.string : fromStringz, splitLines, strip, toStringz;

import sparkles.base.logger : CoreLogEntry, CoreLogger, LogLevel, sharedCoreLog,
    warning;
import sparkles.base.smallbuffer : SmallBuffer;

import android_paths;

// ── NDK mirrors ──────────────────────────────────────────────────────────────

// The leading fields of <android/native_activity.h>'s ANativeActivity; the
// tail is never touched here.
private struct ANativeActivity
{
    void* callbacks;
    void* vm;
    void* env;
    void* clazz;
    const(char)* internalDataPath;
    const(char)* externalDataPath;
    int sdkVersion;
    void* instance;
    void* assetManager; // AAssetManager*
    const(char)* obbPath;
}

// The leading fields of native_app_glue's android_app.
private struct AndroidApp
{
    void* userData;
    void* onAppCmd;
    void* onInputEvent;
    ANativeActivity* activity;
}

// Defined by raylib's rcore_android.c; set before it calls our main().
private extern (C) AndroidApp* GetAndroidApp() @nogc nothrow;

// <android/log.h>
private extern (C) int __android_log_write(
    int prio, const(char)* tag, const(char)* text) @nogc nothrow;

// <android/asset_manager.h> — just the calls the extractor needs.
private extern (C) void* AAssetManager_open(
    void* mgr, const(char)* filename, int mode) @nogc nothrow;
private extern (C) int AAsset_read(void* asset, void* buf, size_t count) @nogc nothrow;
private extern (C) long AAsset_getLength64(void* asset) @nogc nothrow;
private extern (C) void AAsset_close(void* asset) @nogc nothrow;

private enum aassetModeStreaming = 2;

private enum int logPrioInfo = 4;
private enum int logPrioWarn = 5;
private enum int logPrioError = 6;

/// The logcat tag every hue log line carries (matches the `hue-logcat` filter).
enum logTag = "hue";

// ── data dir ─────────────────────────────────────────────────────────────────

private __gshared string cachedDataDir;

/// The app's private data directory (`ANativeActivity.internalDataPath`) —
/// the root of the extracted asset bundle and all writable state.
string androidDataDir() @trusted
{
    if (cachedDataDir.length == 0)
        cachedDataDir = GetAndroidApp().activity.internalDataPath.fromStringz.idup;
    return cachedDataDir;
}

// ── logcat sink ──────────────────────────────────────────────────────────────

/// Replace the process loggers with the logcat sink, tag "hue". Call after
/// `initLogger` (which it overrides): in a NativeActivity, stderr — where the
/// default DeltaTimeLogger writes — goes nowhere.
void installLogcatSink(LogLevel level) @safe
{
    import std.logger : globalLogLevel, sharedLog;
    import sparkles.base.logger : coreGlobalLogLevel;

    globalLogLevel = level;
    coreGlobalLogLevel = level; // the IES wrappers filter on the core level
    auto logger = new shared LogcatLogger(level);
    sharedLog = logger;
    sharedCoreLog = logger;
}

private final class LogcatLogger : CoreLogger
{
    this(this Q)(LogLevel level) @safe
    {
        super(level);
    }

    override protected void writeLogMsg(ref Logger.LogEntry payload) @safe
    {
        const entry = CoreLogEntry(level: payload.logLevel, file: payload.file,
            line: payload.line);
        writeCoreLog(entry, payload.msg);
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        const prio = entry.level >= LogLevel.error ? logPrioError
            : entry.level >= LogLevel.warning ? logPrioWarn : logPrioInfo;

        // logcat wants one NUL-terminated line; file:line preserves the
        // DeltaTimeLogger's most useful context.
        SmallBuffer!(char, 512) buf;
        buf ~= entry.file;
        buf ~= ':';
        writeUint(buf, entry.line);
        buf ~= ": ";
        buf ~= message;
        buf ~= '\0';
        (() @trusted => __android_log_write(prio, logTag.ptr, buf[].ptr))();
    }

    private static void writeUint(ref SmallBuffer!(char, 512) buf, ulong v)
        @safe nothrow @nogc
    {
        char[20] tmp;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(char) ('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        buf ~= tmp[i .. $];
    }
}

// ── clipboard ────────────────────────────────────────────────────────────────

/**
Copy `text` to the system clipboard through the activity's `ClipboardManager`
(the JNI dance itself lives in `android_clipboard.d`, over an ImportC'd
`<jni.h>`). Returns `false` when any JNI step failed.

Takes a slice, not a `const(char)*`: a raw pointer made this an unchecked
NUL-termination precondition laundered into `@safe` (any `@safe` caller may
legally pass `someSlice.ptr`), and the bridge wants a length anyway.
*/
bool setClipboardText(scope const(char)[] text) @safe nothrow
{
    import std.utf : toUTF16;

    import android_clipboard : jniSetClipboardText = setClipboardText;

    try
    {
        // Java strings are UTF-16; transcoding here is what lets the bridge
        // use NewString and sidestep modified-UTF-8 entirely (astral scalars
        // — emoji in a copied selection — are the case that breaks).
        const wstring utf16 = () @trusted { return text.toUTF16; }();
        return (() @trusted {
            auto activity = GetAndroidApp().activity;
            return jniSetClipboardText(activity.vm, activity.clazz, utf16);
        })();
    }
    catch (Exception)
        return false; // invalid UTF in the selection → report the failure
}

// ── debug environment ────────────────────────────────────────────────────────

/// Load `<dataDir>/hue-debug.env` into the process environment, re-enabling
/// the `HUE_GUI_*` golden/debug hooks on-device (an activity has no shell to
/// export them; push the file via `adb shell run-as`). Missing file = no-op.
void loadDebugEnv() @safe
{
    import std.file : exists, readText;
    import std.process : environment;

    const path = debugEnvPath(androidDataDir());
    if (!path.exists)
        return;
    try
        foreach (pair; parseDebugEnv(readText(path)))
            environment[pair.key] = pair.value;
    catch (Exception e)
        warning(i"hue: unreadable hue-debug.env: $(e.msg)");
}

// ── asset extraction ─────────────────────────────────────────────────────────

/**
Extract the APK asset bundle (fonts + charset sidecars, grammar queries,
sample docs) into the data dir — on first run, or again whenever the APK's
`bundle-hash` asset differs from the `assets-ready` marker of the last
completed extraction. The marker is written $(I last), so a torn extraction
re-runs. Returns `true` when the assets are present (current or just
extracted); `false` (after a warning) leaves hue on its built-in degradations
— plain-text rendering, default document only.
*/
bool extractAssetsIfNeeded() @trusted
{
    import std.file : exists, mkdirRecurse, readText, write;
    import std.path : buildPath, dirName;

    const dataDir = androidDataDir();
    const hash = readAssetText("bundle-hash");
    if (hash is null)
    {
        warning(i"hue: no asset bundle in this APK (bundle-hash missing)");
        return false;
    }

    const marker = assetsReadyPath(dataDir);
    try
        if (marker.exists && assetsUpToDate(readText(marker), hash))
            return true;
    catch (Exception) { /* unreadable marker → re-extract */ }

    const manifest = readAssetText("asset-manifest.txt");
    if (manifest is null)
    {
        warning(i"hue: asset bundle has no asset-manifest.txt");
        return false;
    }

    // Every listed asset must land before the marker is written. Skipping one
    // and marking the bundle ready anyway made the degradation PERMANENT: the
    // next launch sees a current marker, skips extraction, and the missing
    // font face or query file never returns until the APK's hash changes.
    bool allOk = true;
    try
    {
        foreach (line; manifest.splitLines)
        {
            const rel = line.strip;
            if (rel.length == 0)
                continue;
            if (!isSafeAssetRel(rel))
            {
                warning(i"hue: refusing unsafe manifest entry: $(rel)");
                allOk = false;
                continue;
            }
            auto bytes = readAssetBytes(rel);
            if (bytes is null)
            {
                warning(i"hue: asset listed but unreadable: $(rel)");
                allOk = false;
                continue;
            }
            const dest = buildPath(dataDir, rel);
            mkdirRecurse(dest.dirName);
            write(dest, bytes);
        }
        if (allOk)
            write(marker, hash);
        else
            warning(i"hue: incomplete asset extraction — will retry next launch");
    }
    catch (Exception e)
    {
        warning(i"hue: asset extraction failed: $(e.msg)");
        return false;
    }
    return allOk;
}

// Read one asset fully; null when absent/unreadable.
private ubyte[] readAssetBytes(scope const(char)[] name) @trusted
{
    auto mgr = GetAndroidApp().activity.assetManager;
    auto asset = AAssetManager_open(mgr, name.toStringz, aassetModeStreaming);
    if (asset is null)
        return null;
    scope (exit) AAsset_close(asset);

    const len = AAsset_getLength64(asset);
    if (len < 0)
        return null;
    auto buf = new ubyte[cast(size_t) len];
    size_t got;
    while (got < buf.length)
    {
        const n = AAsset_read(asset, buf.ptr + got, buf.length - got);
        if (n <= 0)
            return null; // truncated read → treat as unreadable
        got += n;
    }
    return buf;
}

private string readAssetText(scope const(char)[] name) @trusted
{
    auto bytes = readAssetBytes(name);
    return bytes is null ? null : cast(string) bytes;
}
