/**
What the Android app runs, decided as data (docs/specs/terminal/android.md,
`D5`): the session configuration the APK carries, the paths under the app's
data dir, the program and its environment. Pure — the platform half is
`android_app.d` — so every rule here is tested on the host.
*/
module session;

import std.path : buildPath;

/// The session modes (`NOD4`, `NOD5`–`NOD7`).
enum SessionMode
{
    shell, /// `/system/bin/sh` as a login shell
    bootstrap, /// nix-on-droid: install the bootstrap once, then run `login`
}

/// The APK's `session.conf` asset (`KEY=VALUE` lines), parsed.
struct SessionConfig
{
    SessionMode mode = SessionMode.shell;
    /// The bootstrap base URL offered as the installer's default; the zip is
    /// `<url>/bootstrap-<arch>.zip`.
    string bootstrapUrl;
}

/**
Parse `session.conf`. Unknown keys are ignored (a newer builder's options on
an older app), an unknown mode is the plain shell — the app must start, and a
shell is the safe thing to start.
*/
SessionConfig parseSessionConfig(const(char)[] text) @safe pure
{
    import sparkles.android.bundle : parseEnvFile;

    SessionConfig c;
    foreach (pair; parseEnvFile(text))
    {
        switch (pair.key)
        {
            case "mode":
                c.mode = pair.value == "bootstrap" ? SessionMode.bootstrap
                    : SessionMode.shell;
                break;
            case "bootstrapUrl":
                c.bootstrapUrl = pair.value;
                break;
            default:
                break;
        }
    }
    return c;
}

///
@("session.parseSessionConfig")
@safe pure unittest
{
    const c = parseSessionConfig(
        "# written by mkTerminalApk\nmode=bootstrap\n" ~
        "bootstrapUrl=https://example.org/bootstrap\nfuture=1\n");
    assert(c.mode == SessionMode.bootstrap);
    assert(c.bootstrapUrl == "https://example.org/bootstrap");

    assert(parseSessionConfig("").mode == SessionMode.shell);
    assert(parseSessionConfig("mode=unheard-of").mode == SessionMode.shell);
}

/// The directories under the app's data dir (`/data/user/0/<pkg>/files`),
/// laid out as Termux and nix-on-droid's bootstrap expect.
struct SessionPaths
{
    string files;

    string home() const @safe pure nothrow => buildPath(files, "home");
    string prefix() const @safe pure nothrow => buildPath(files, "usr");
    string staging() const @safe pure nothrow => buildPath(files, "usr-staging");
    string tmp() const @safe pure nothrow => buildPath(files, "usr", "tmp");
    string login() const @safe pure nothrow => buildPath(files, "usr", "bin", "login");
    /// `~/.termux` — the appearance and extra-keys files (`NOD10`, `NOD11`).
    string termuxDir() const @safe pure nothrow => buildPath(home, ".termux");
    /// The on-device test oracle's directory (`NOD14`).
    string debugDir() const @safe pure nothrow => buildPath(files, ".debug");
}

///
@("session.SessionPaths")
@safe pure unittest
{
    const p = SessionPaths("/data/user/0/dev.sparkles.nix/files");
    assert(p.home == "/data/user/0/dev.sparkles.nix/files/home");
    assert(p.prefix == "/data/user/0/dev.sparkles.nix/files/usr");
    assert(p.login == "/data/user/0/dev.sparkles.nix/files/usr/bin/login");
    assert(p.termuxDir == "/data/user/0/dev.sparkles.nix/files/home/.termux");
}

/**
The child's environment (`NOD7`): the app's own environment — which carries
the Android system variables (`ANDROID_*`, `BOOTCLASSPATH`,
`EXTERNAL_STORAGE`, …) the zygote gave it — minus what must not leak into a
session, plus the session's own.

Removed: the dynamic-loader overrides (`LD_LIBRARY_PATH` and `LD_PRELOAD`
would redirect every binary in the prefix) and anything the session sets
itself. `prefixed` selects the bootstrap layout: `PREFIX` set and `PATH` the
prefix's `bin` alone. Entries keep the parent's order, the session's
follow; the result is `KEY=VALUE` strings.
*/
string[] sessionEnvironment(scope const string[] parent, const SessionPaths p,
    bool prefixed) @safe pure
{
    import std.algorithm.searching : canFind, startsWith;
    import std.string : indexOf;

    string[] own = [
        "HOME=" ~ p.home,
        "TMPDIR=" ~ (prefixed ? p.tmp : buildPath(p.files, "tmp")),
        // Termux's: the prefix alone. nix-on-droid's `login` calls Android's
        // tools by absolute path, and under proot the host root stays
        // visible, so `/system/bin` here would shadow the environment's own
        // commands with Android's (`am`, `ls`, ...) wherever Nix has none.
        "PATH=" ~ (prefixed ? buildPath(p.prefix, "bin") : "/system/bin"),
        "LANG=en_US.UTF-8",
        "TERM=xterm-256color",
        "COLORTERM=truecolor",
    ];
    if (prefixed)
        own ~= "PREFIX=" ~ p.prefix;

    static immutable dropped = ["LD_LIBRARY_PATH", "LD_PRELOAD"];
    string[] result;
    foreach (entry; parent)
    {
        const eq = entry.indexOf('=');
        if (eq <= 0)
            continue;
        const key = entry[0 .. eq];
        if (dropped.canFind(key))
            continue;
        bool overridden = false;
        foreach (o; own)
            if (o.startsWith(key) && o.length > key.length && o[key.length] == '=')
                overridden = true;
        if (!overridden)
            result ~= entry;
    }
    return result ~ own;
}

///
@("session.sessionEnvironment")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    const p = SessionPaths("/f");
    const parent = [
        "ANDROID_ROOT=/system", "HOME=/", "LD_PRELOAD=libsigchain.so",
        "PATH=/sbin:/system/bin", "BOOTCLASSPATH=/apex/x.jar", "odd",
    ];

    const boot = sessionEnvironment(parent, p, true);
    assert(boot.canFind("ANDROID_ROOT=/system"), "system variables pass through");
    assert(boot.canFind("BOOTCLASSPATH=/apex/x.jar"));
    assert(!boot.canFind("LD_PRELOAD=libsigchain.so"), "loader overrides never leak");
    assert(!boot.canFind("HOME=/") && boot.canFind("HOME=/f/home"),
        "the session's own values replace the parent's");
    assert(boot.canFind("PREFIX=/f/usr"));
    assert(boot.canFind("PATH=/f/usr/bin"), "the prefix alone, as Termux sets it");
    assert(boot.canFind("TMPDIR=/f/usr/tmp"));
    assert(!boot.canFind("odd"), "an entry without `=` is not an entry");

    const shell = sessionEnvironment(parent, p, false);
    assert(shell.canFind("PATH=/system/bin"));
    assert(shell.canFind("TMPDIR=/f/tmp"));
    assert(!shell.canFind!(e => e.length >= 7 && e[0 .. 7] == "PREFIX="));
}

/// The bootstrap zip's name for the running ABI (`NOD5`) — nix-on-droid's
/// `bootstrap-<arch>.zip`, where `arch` is the Nix system's CPU.
string bootstrapArch() @safe pure nothrow
{
    version (AArch64)
        return "aarch64";
    else version (X86_64)
        return "x86_64";
    else version (ARM)
        return "arm";
    else version (X86)
        return "i686";
    else
        static assert(0, "no nix-on-droid bootstrap for this CPU");
}

/// `<base>/bootstrap-<arch>.zip`, tolerating a trailing slash on `base`.
string bootstrapZipUrl(string base, string arch) @safe pure nothrow
{
    while (base.length && base[$ - 1] == '/')
        base = base[0 .. $ - 1];
    return base ~ "/bootstrap-" ~ arch ~ ".zip";
}

///
@("session.bootstrapZipUrl")
@safe pure nothrow unittest
{
    assert(bootstrapZipUrl("https://h/boot", "aarch64") == "https://h/boot/bootstrap-aarch64.zip");
    assert(bootstrapZipUrl("https://h/boot//", "x86_64") == "https://h/boot/bootstrap-x86_64.zip");
}
