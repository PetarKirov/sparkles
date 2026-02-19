/// Cross-platform common directories.
///
/// Provides platform-aware paths for standard user directories (home, config,
/// cache, data, state) following XDG conventions on Linux and native paths on
/// macOS and Windows. Also provides [repoRoot] for locating the git repository
/// root.
///
/// Modeled after Rust's $(LINK2 https://docs.rs/dirs/latest/dirs/, dirs) crate.
///
/// $(TABLE
///     $(TR $(TH Function) $(TH Linux)                                          $(TH macOS)                                   $(TH Windows))
///     $(TR $(TD [homeDir])   $(TD `$HOME`)                                     $(TD `$HOME`)                                 $(TD `{FOLDERID_Profile}`))
///     $(TR $(TD [configDir]) $(TD `$XDG_CONFIG_HOME` or `$HOME/.config`)       $(TD `$HOME/Library/Application Support`)     $(TD `{FOLDERID_RoamingAppData}`))
///     $(TR $(TD [cacheDir])  $(TD `$XDG_CACHE_HOME` or `$HOME/.cache`)         $(TD `$HOME/Library/Caches`)                  $(TD `{FOLDERID_LocalAppData}`))
///     $(TR $(TD [dataDir])   $(TD `$XDG_DATA_HOME` or `$HOME/.local/share`)    $(TD `$HOME/Library/Application Support`)     $(TD `{FOLDERID_RoamingAppData}`))
///     $(TR $(TD [stateDir])  $(TD `$XDG_STATE_HOME` or `$HOME/.local/state`)   $(TD —)                                       $(TD —))
/// )
module sparkles.core_cli.common_dirs;

import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.process : environment;

// ─────────────────────────────────────────────────────────────────────────────
// User Directories
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the path to the user's home directory.
///
/// | Platform | Value                | Example           |
/// |----------|----------------------|-------------------|
/// | Linux    | `$HOME`              | `/home/alice`     |
/// | macOS    | `$HOME`              | `/Users/Alice`    |
/// | Windows  | `{FOLDERID_Profile}` | `C:\Users\Alice`  |
///
/// Returns `null` if the home directory cannot be determined.
string homeDir() @safe
{
    version (Windows)
        return environment.get("USERPROFILE");
    else
        return environment.get("HOME");
}

///
@safe unittest
{
    auto home = homeDir();
    assert(home is null || home.length > 0);
}

/// Returns the path to the user's config directory.
///
/// | Platform | Value                                        | Example                                   |
/// |----------|----------------------------------------------|-------------------------------------------|
/// | Linux    | `$XDG_CONFIG_HOME` or `$HOME/.config`        | `/home/alice/.config`                     |
/// | macOS    | `$HOME/Library/Application Support`          | `/Users/Alice/Library/Application Support` |
/// | Windows  | `{FOLDERID_RoamingAppData}`                  | `C:\Users\Alice\AppData\Roaming`           |
///
/// Returns `null` if the home directory cannot be determined.
string configDir() @safe
{
    version (Windows)
        return environment.get("APPDATA");
    else version (OSX)
        return xdgOrHome("XDG_CONFIG_HOME", "Library/Application Support");
    else
        return xdgOrHome("XDG_CONFIG_HOME", ".config");
}

///
@safe unittest
{
    auto dir = configDir();
    assert(dir is null || dir.length > 0);
}

/// Returns the path to the user's cache directory.
///
/// | Platform | Value                                        | Example                              |
/// |----------|----------------------------------------------|--------------------------------------|
/// | Linux    | `$XDG_CACHE_HOME` or `$HOME/.cache`          | `/home/alice/.cache`                 |
/// | macOS    | `$HOME/Library/Caches`                       | `/Users/Alice/Library/Caches`         |
/// | Windows  | `{FOLDERID_LocalAppData}`                    | `C:\Users\Alice\AppData\Local`        |
///
/// Returns `null` if the home directory cannot be determined.
string cacheDir() @safe
{
    version (Windows)
        return environment.get("LOCALAPPDATA");
    else version (OSX)
        return xdgOrHome("XDG_CACHE_HOME", "Library/Caches");
    else
        return xdgOrHome("XDG_CACHE_HOME", ".cache");
}

///
@safe unittest
{
    auto dir = cacheDir();
    assert(dir is null || dir.length > 0);
}

/// Returns the path to the user's data directory.
///
/// | Platform | Value                                            | Example                                   |
/// |----------|--------------------------------------------------|-------------------------------------------|
/// | Linux    | `$XDG_DATA_HOME` or `$HOME/.local/share`         | `/home/alice/.local/share`                |
/// | macOS    | `$HOME/Library/Application Support`              | `/Users/Alice/Library/Application Support` |
/// | Windows  | `{FOLDERID_RoamingAppData}`                      | `C:\Users\Alice\AppData\Roaming`           |
///
/// Returns `null` if the home directory cannot be determined.
string dataDir() @safe
{
    version (Windows)
        return environment.get("APPDATA");
    else version (OSX)
        return xdgOrHome("XDG_DATA_HOME", "Library/Application Support");
    else
        return xdgOrHome("XDG_DATA_HOME", ".local/share");
}

///
@safe unittest
{
    auto dir = dataDir();
    assert(dir is null || dir.length > 0);
}

/// Returns the path to the user's state directory.
///
/// | Platform | Value                                            | Example                        |
/// |----------|--------------------------------------------------|--------------------------------|
/// | Linux    | `$XDG_STATE_HOME` or `$HOME/.local/state`        | `/home/alice/.local/state`     |
/// | macOS    | —                                                | —                              |
/// | Windows  | —                                                | —                              |
///
/// Returns `null` on macOS and Windows (no standard equivalent), or if
/// the home directory cannot be determined on Linux.
string stateDir() @safe
{
    version (Windows)
        return null;
    else version (OSX)
        return null;
    else
        return xdgOrHome("XDG_STATE_HOME", ".local/state");
}

///
@safe unittest
{
    auto dir = stateDir();

    version (Windows) { }
    else version (OSX) { }
    else
        assert(dir is null || dir.length > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Repository Root
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the root directory of the current git repository.
///
/// Runs `git rev-parse --show-toplevel` to locate the repository root.
/// Falls back to the current working directory (as an absolute, normalized
/// path) if not inside a git repository.
string repoRoot() @safe
{
    import std.process : execute;
    import std.string : strip;

    auto res = () @trusted { return execute(["git", "rev-parse", "--show-toplevel"]); }();

    if (res.status == 0)
        return res.output.strip;

    return ".".absolutePath.buildNormalizedPath;
}

///
@system unittest
{
    auto root = repoRoot();
    assert(root.length > 0);

    import std.file : exists;
    assert(root.exists);
}

// ─────────────────────────────────────────────────────────────────────────────
// Internals
// ─────────────────────────────────────────────────────────────────────────────

/// Returns `$envVar` if set and non-empty, otherwise `$HOME/fallbackSuffix`.
/// Returns `null` when `$HOME` is also unset.
private string xdgOrHome(string envVar, string fallbackSuffix) @safe
{
    auto xdg = environment.get(envVar);
    if (xdg !is null && xdg.length > 0)
        return xdg;

    auto home = homeDir();
    if (home is null)
        return null;

    return buildPath(home, fallbackSuffix);
}
