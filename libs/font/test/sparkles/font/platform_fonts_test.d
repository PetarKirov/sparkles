/**
The platform listing (FTD18) against each platform's own answer: on Linux
and the BSDs `fc-list` over the fontconfig library the dev shell names; on
macOS, Windows and Android a non-empty listing from the CI runner.
*/
module sparkles.font.platform_fonts_test;

import sparkles.font.platform_fonts;
import sparkles.test_runner.skip : skipTest;

/// A library that cannot be loaded is one issue naming it, and nothing listed.
@("platform_fonts.listPlatformFonts.missingLibrary")
@safe nothrow @nogc
unittest
{
    version (Windows) {}
    else version (Android) {}
    else version (OSX) {}
    else version (Posix)
    {
        enum missing = "/nonexistent/sparkles/libfontconfig-missing.so.1";
        const listing = listPlatformFonts(PlatformOptions(fontconfigLibrary: missing));
        assert(listing.files.empty);
        assert(listing.directories.empty);
        assert(listing.issues.length == 1);
        assert(listing.issues[0].kind == PlatformProblem.libraryUnavailable);
        assert(listing.issues[0].name == missing);
        assert(listing.issues[0].code == 0);
    }
}

version (Windows) {}
else version (Android) {}
else version (OSX) {}
else version (Posix)
{
    /// The listing equals `fc-list`'s distinct files, in byte order.
    @("platform_fonts.listPlatformFonts.fontconfigMatchesFcList")
    @system
    unittest
    {
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array, split;
        import std.process : environment, execute, ProcessException;

        const library = environment.get("SPARKLES_FONTCONFIG_LIB");
        if (library is null)
            return skipTest("SPARKLES_FONTCONFIG_LIB is unset");

        const listing = listPlatformFonts(PlatformOptions(fontconfigLibrary: library));
        assert(listing.issues.empty, listing.issues[0].name.idup);
        assert(listing.directories.empty);

        string[] got;
        foreach (path; listing.files)
            got ~= path.idup;
        assert(got.length > 0, "fontconfig listed no files");

        typeof(execute("")) fcList;
        try
            fcList = execute(["fc-list", "--format", "%{file}\n"]);
        catch (ProcessException)
            return skipTest("fc-list is not on PATH");
        assert(fcList.status == 0, fcList.output);
        auto expected = fcList.output.split('\n').filter!(l => l.length > 0).array;
        expected.sort();
        const want = expected.uniq.array;

        assert(got == want);
    }
}

version (OSX)
{
    /// Core Text lists the system's fonts.
    @("platform_fonts.listPlatformFonts.coreText")
    @safe
    unittest
    {
        const listing = listPlatformFonts(PlatformOptions.init);
        assert(listing.issues.empty, listing.issues[0].name.idup);
        assert(listing.files.length > 0);
        assert(listing.directories.empty);
        foreach (path; listing.files)
            assert(path.length > 0 && path[0] == '/', path.idup);
    }
}

version (Windows)
{
    /// The system font directory exists and is listed first.
    @("platform_fonts.listPlatformFonts.windowsDirectories")
    @safe
    unittest
    {
        import std.algorithm.searching : endsWith;

        const listing = listPlatformFonts(PlatformOptions.init);
        assert(listing.files.empty);
        assert(listing.directories.length > 0);
        assert(listing.directories[0].endsWith(`\Fonts`), listing.directories[0].idup);
        // The per-user directory exists only once a user installs a font.
        foreach (issue; listing.issues)
            assert(issue.kind == PlatformProblem.directoryUnavailable, issue.name.idup);
    }
}

version (Android)
{
    /// `/system/fonts` is listed.
    @("platform_fonts.listPlatformFonts.android")
    @safe
    unittest
    {
        const listing = listPlatformFonts(PlatformOptions.init);
        assert(listing.issues.empty, listing.issues[0].name.idup);
        assert(listing.files.empty);
        assert(listing.directories.length == 1);
        assert(listing.directories[0] == "/system/fonts");
    }
}
