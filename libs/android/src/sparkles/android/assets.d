/**
The APK asset bundle, read through `AAssetManager` — with `hasCode="false"`
there is no Java side to do it. See $(MREF sparkles,android,bundle) for the
bundle layout and the pure checks.
*/
module sparkles.android.assets;

version (Android):

import std.string : splitLines, strip, toStringz;

import sparkles.android.activity : nativeActivity;
import sparkles.android.bundle : assetsUpToDate, isSafeAssetRel;
import sparkles.base.logger : warning;

// <android/asset_manager.h> — just the calls the extractor needs.
private extern (C) void* AAssetManager_open(
    void* mgr, const(char)* filename, int mode) @nogc nothrow;
private extern (C) int AAsset_read(void* asset, void* buf, size_t count) @nogc nothrow;
private extern (C) long AAsset_getLength64(void* asset) @nogc nothrow;
private extern (C) void AAsset_close(void* asset) @nogc nothrow;

private enum aassetModeStreaming = 2;

/**
Extract the APK asset bundle into `dataDir` — on first run, or again whenever
the APK's `bundle-hash` asset differs from `markerPath`'s content (the hash of
the last completed extraction). The marker is written $(I last), so a torn
extraction re-runs.

`ownedDirs` are the directories the bundle owns under `dataDir`; they are
removed before a re-extraction, since extraction only ever overwrites and a
changed bundle would otherwise leave orphaned files behind. Never the whole
data dir — it also holds user state and the marker.

Returns `true` when the assets are present (current or just extracted);
`false` (after a warning) otherwise.
*/
bool extractAssetBundle(string dataDir, scope const string[] ownedDirs,
    string markerPath) @safe
{
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
    import std.path : buildPath, dirName;

    const hash = readAssetText("bundle-hash");
    if (hash is null)
    {
        warning(i"android: no asset bundle in this APK (bundle-hash missing)");
        return false;
    }

    try
        if (markerPath.exists && assetsUpToDate(readText(markerPath), hash))
            return true;
    catch (Exception) { /* unreadable marker → re-extract */ }

    foreach (owned; ownedDirs)
    {
        const dir = buildPath(dataDir, owned);
        try
            if (dir.exists)
                rmdirRecurse(dir);
        catch (Exception e)
            warning(i"android: could not clear stale assets in $(dir): $(e.msg)");
    }

    const manifest = readAssetText("asset-manifest.txt");
    if (manifest is null)
    {
        warning(i"android: asset bundle has no asset-manifest.txt");
        return false;
    }

    // Every listed asset must land before the marker is written. Skipping one
    // and marking the bundle ready anyway made the degradation PERMANENT: the
    // next launch sees a current marker, skips extraction, and the missing
    // file never returns until the APK's hash changes.
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
                warning(i"android: refusing unsafe manifest entry: $(rel)");
                allOk = false;
                continue;
            }
            auto bytes = readAssetBytes(rel);
            if (bytes is null)
            {
                warning(i"android: asset listed but unreadable: $(rel)");
                allOk = false;
                continue;
            }
            const dest = buildPath(dataDir, rel);
            mkdirRecurse(dest.dirName);
            write(dest, bytes);
        }
        if (allOk)
            write(markerPath, hash);
        else
            warning(i"android: incomplete asset extraction — will retry next launch");
    }
    catch (Exception e)
    {
        warning(i"android: asset extraction failed: $(e.msg)");
        return false;
    }
    return allOk;
}

/// Whether the APK carries the asset `name`.
bool hasAsset(scope const(char)[] name) @trusted
{
    auto mgr = nativeActivity().assetManager;
    auto asset = AAssetManager_open(mgr, name.toStringz, aassetModeStreaming);
    if (asset is null)
        return false;
    AAsset_close(asset);
    return true;
}

/**
Stream the asset `name` into the file `dest` (created or truncated), reporting
`progress(copied, total)`; `null` on success, else the reason. For assets too
large to hold in memory at once — a bundled bootstrap is tens of megabytes. A
failed copy removes `dest`.
*/
string copyAssetToFile(scope const(char)[] name, string dest,
    scope void delegate(long copied, long total) nothrow progress = null) @trusted
{
    import std.file : remove;
    import std.stdio : File;

    auto mgr = nativeActivity().assetManager;
    auto asset = AAssetManager_open(mgr, name.toStringz, aassetModeStreaming);
    if (asset is null)
        return "the APK has no asset " ~ name.idup;
    scope (exit) AAsset_close(asset);

    const total = AAsset_getLength64(asset);
    try
    {
        auto file = File(dest, "wb");
        ubyte[64 * 1024] buf = void;
        long copied;
        for (;;)
        {
            const n = AAsset_read(asset, buf.ptr, buf.length);
            if (n < 0)
            {
                file.close();
                remove(dest);
                return "reading the asset failed";
            }
            if (n == 0)
                break;
            file.rawWrite(buf[0 .. n]);
            copied += n;
            if (progress !is null)
                progress(copied, total);
        }
        file.close();
    }
    catch (Exception e)
    {
        try
            remove(dest);
        catch (Exception) {}
        return e.msg;
    }
    return null;
}

/// Read one asset fully; `null` when absent, unreadable or empty.
ubyte[] readAssetBytes(scope const(char)[] name) @trusted
{
    auto mgr = nativeActivity().assetManager;
    auto asset = AAssetManager_open(mgr, name.toStringz, aassetModeStreaming);
    if (asset is null)
        return null;
    scope (exit) AAsset_close(asset);

    const len = AAsset_getLength64(asset);
    // A zero-length asset would allocate a null-pointer empty slice, which the
    // callers' `is null` test reads as "unreadable" — so it is rejected here
    // explicitly rather than being silently conflated.
    if (len <= 0)
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

/// Read one asset as text; `null` when $(LREF readAssetBytes) would be.
string readAssetText(scope const(char)[] name) @safe
{
    auto bytes = readAssetBytes(name);
    // `bytes` is freshly allocated by readAssetBytes and never escapes it, so
    // this is the one place that knows the buffer is unaliased.
    return bytes is null ? null : (() @trusted => cast(string) bytes)();
}
