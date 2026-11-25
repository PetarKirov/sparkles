/**
Where `ci` keeps what it caches: the build graph's store, the run
directories, the perf history clones and the pull requests' perf records,
all beneath `<cache home>/sparkles`.

The cache home is `--cache-dir`, which falls back to `$XDG_CACHE_HOME` and
then to `~/.cache`. `ciMain` sets it once the command line has parsed; a
caller that never parsed one (a unittest) gets the environment's.
*/
module cache_home;

import std.path : buildPath;

@safe:

private __gshared string configured;

/// Make `dir` the cache home for the rest of the process; empty restores the default.
void setCacheHome(string dir) @trusted nothrow @nogc
{
    configured = dir;
}

/// The cache home: `--cache-dir`, else `$XDG_CACHE_HOME`, else `~/.cache`.
string cacheHome()
{
    import std.process : environment;

    return resolveCacheHome((() @trusted => configured)(), environment.get("XDG_CACHE_HOME"),
        environment.get("HOME", "/"));
}

/// `ci`'s own directory beneath the cache home: `<cache home>/sparkles`.
string sparklesCache() => buildPath(cacheHome(), "sparkles");

/// The first of `configured` and `xdg` that is set, else `<home>/.cache`.
string resolveCacheHome(string configured, string xdg, string home) pure nothrow
    => configured.length ? configured : xdg.length ? xdg : buildPath(home, ".cache");

@("cache_home.resolveCacheHome")
@safe pure nothrow unittest
{
    assert(resolveCacheHome("/typed", "/xdg", "/home/u") == "/typed");
    assert(resolveCacheHome(null, "/xdg", "/home/u") == "/xdg");
    assert(resolveCacheHome(null, "", "/home/u") == "/home/u/.cache");
}
