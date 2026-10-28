/**
The catalog over real files (FTD16–FTD24): the bundle through the blocking
VFS backend, its cache round trip, and the platform source.
*/
module sparkles.font.catalog_files_test;

import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.process : environment, thisProcessID;
import std.stdio : stderr;

import sparkles.base.vfs : ambientAuthority;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.test_runner.skip : skipTest;

import sparkles.font.catalog;
import sparkles.font.corpus : fontsPath;
import sparkles.font.platform_fonts : PlatformOptions;

@("catalog.files.bundleAndCache")
@system unittest
{
    if (fontsPath is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    auto vfs = new BlockingVfs;
    const cacheDir = buildPath(tempDir, "sparkles-font-catalog-" ~ thisProcessID.to!string);
    mkdirRecurse(cacheDir);
    scope (exit)
        rmdirRecurse(cacheDir);
    BuildOptions o;
    o.cacheDirectory = cacheDir;
    const sources = [FontSource.bundle("bundle", fontsPath)];

    auto cold = new Catalog, coldReport = new BuildReport;
    auto sw = StopWatch(AutoStart.yes);
    assert(!buildCatalog(vfs, sources, o, ambientAuthority(), *cold, *coldReport).hasError);
    const coldTime = sw.peek;
    assert(coldReport.listed >= 180 && coldReport.failed == 0 && coldReport.outcomes.length == 0,
        coldReport.outcomes.length.to!string);
    foreach (ref r; cold.records)
        assert(cold.text(r.family).length, cold.text(r.identity));
    uint[64] found;
    assert(cold.family("noto sans", found[]) > 0);

    auto warm = new Catalog, warmReport = new BuildReport;
    sw.reset();
    assert(!buildCatalog(vfs, sources, o, ambientAuthority(), *warm, *warmReport).hasError);
    const warmTime = sw.peek;
    assert(warmReport.reused == coldReport.listed && warmReport.described == 0);
    assert(warm.records.length == cold.records.length);
    foreach (i, ref r; warm.records)
    {
        const c = cold.records[i];
        assert(warm.text(r.family) == cold.text(c.family) && r.weightMin == c.weightMin
            && warm.pools.coverageOf(r) == cold.pools.coverageOf(c));
    }
    stderr.writefln("catalog.files: %s bundled files, %s records; built in %s, from the cache in %s",
        coldReport.listed, cold.records.length, coldTime, warmTime);
}

@("catalog.files.platform")
@system unittest
{
    version (Android)
    {
        // The platform source is `/system/fonts`, through the blocking backend and mappings.
        auto vfs = new BlockingVfs;
        auto c = new Catalog, r = new BuildReport;
        assert(!buildCatalog(vfs, [FontSource.platform("system")], BuildOptions.init, ambientAuthority(), *c, *r)
            .hasError);
        foreach (o; r.outcomes[])
            stderr.writefln("  %s %s: io %s, font %s at %s", o.kind, r.text(o.subject), o.io.kind, o.font.kind,
                o.font.offset);
        assert(c.records.length > 0);
        uint[8] found;
        assert(c.family("Roboto", found[]) > 0);
        stderr.writefln("catalog.files.platform: %s files listed, %s records, %s skipped, %s failed",
            r.listed, c.records.length, r.skipped, r.failed);
    }
    else version (linux)
    {
        const lib = environment.get("SPARKLES_FONTCONFIG_LIB");
        if (lib is null)
            skipTest("SPARKLES_FONTCONFIG_LIB is unset");
        auto vfs = new BlockingVfs;
        auto c = new Catalog, r = new BuildReport;
        const sources = [FontSource.platform("system", PlatformOptions(lib)),
            FontSource.platform("broken", PlatformOptions("/nonexistent/libfontconfig.so.1"))];
        assert(!buildCatalog(vfs, sources, BuildOptions.init, ambientAuthority(), *c, *r).hasError);
        bool unavailable;
        foreach (o; r.outcomes[])
            unavailable |= o.kind == OutcomeKind.libraryUnavailable && o.source == 1;
        assert(unavailable && c.records.length > 0);
        stderr.writefln("catalog.files.platform: %s files listed, %s records, %s skipped, %s failed",
            r.listed, c.records.length, r.skipped, r.failed);
    }
    else
        skipTest("the fontconfig listing is checked on Linux");
}
