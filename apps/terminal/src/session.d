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
    /// The plain shell's own commands, ahead of `/system/bin` on its `PATH`
    /// ($(LREF shellTools)).
    string shellBin() const @safe pure nothrow => buildPath(files, "bin");
    /// The on-device test oracle's directory (`NOD14`).
    string debugDir() const @safe pure nothrow => buildPath(files, ".debug");
    /// The app's package name: the data dir is `…/<package>/files`.
    string packageName() const @safe pure nothrow
    {
        import std.path : baseName, dirName;

        return files.dirName.baseName;
    }
}

///
@("session.SessionPaths")
@safe pure unittest
{
    const p = SessionPaths("/data/user/0/dev.petar_kirov.sparkles.terminal.nix/files");
    assert(p.home == "/data/user/0/dev.petar_kirov.sparkles.terminal.nix/files/home");
    assert(p.prefix == "/data/user/0/dev.petar_kirov.sparkles.terminal.nix/files/usr");
    assert(p.login == "/data/user/0/dev.petar_kirov.sparkles.terminal.nix/files/usr/bin/login");
    assert(p.termuxDir == "/data/user/0/dev.petar_kirov.sparkles.terminal.nix/files/home/.termux");
    assert(p.packageName == "dev.petar_kirov.sparkles.terminal.nix");
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
        "PATH=" ~ (prefixed ? buildPath(p.prefix, "bin") : p.shellBin ~ ":/system/bin"),
        "LANG=en_US.UTF-8",
        "TERM=xterm-256color",
        "COLORTERM=truecolor",
    ];
    if (prefixed)
    {
        own ~= "PREFIX=" ~ p.prefix;
        // Which app this is — as a Termux-based app says it. nix-on-droid
        // defaults `build.androidAppId` to it, so a configuration that does
        // not name the app still builds its paths for this one.
        own ~= "TERMUX_APP__PACKAGE_NAME=" ~ p.packageName;
    }

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

    const p = SessionPaths("/data/org.example/files");
    const parent = [
        "ANDROID_ROOT=/system", "HOME=/", "LD_PRELOAD=libsigchain.so",
        "PATH=/sbin:/system/bin", "BOOTCLASSPATH=/apex/x.jar", "odd",
    ];

    const boot = sessionEnvironment(parent, p, true);
    assert(boot.canFind("ANDROID_ROOT=/system"), "system variables pass through");
    assert(boot.canFind("BOOTCLASSPATH=/apex/x.jar"));
    assert(!boot.canFind("LD_PRELOAD=libsigchain.so"), "loader overrides never leak");
    assert(!boot.canFind("HOME=/") && boot.canFind("HOME=/data/org.example/files/home"),
        "the session's own values replace the parent's");
    assert(boot.canFind("PREFIX=/data/org.example/files/usr"));
    assert(boot.canFind("PATH=/data/org.example/files/usr/bin"), "the prefix alone, as Termux sets it");
    assert(boot.canFind("TMPDIR=/data/org.example/files/usr/tmp"));
    assert(boot.canFind("TERMUX_APP__PACKAGE_NAME=org.example"));
    assert(!boot.canFind("odd"), "an entry without `=` is not an entry");

    const shell = sessionEnvironment(parent, p, false);
    assert(shell.canFind("PATH=/data/org.example/files/bin:/system/bin"),
        "the app's own commands first (shellTools)");
    assert(shell.canFind("TMPDIR=/data/org.example/files/tmp"));
    assert(!shell.canFind!(e => e.length >= 7 && e[0 .. 7] == "PREFIX="));
}

/// A command the plain shell gets from the app rather than from Android.
struct ShellTool
{
    string name; /// the file name in $(LREF SessionPaths.shellBin)
    string script; /// its contents, a `/system/bin/sh` script
}

/**
The plain shell's own commands, written to `SessionPaths.shellBin` when the
session starts.

`clear`: Android's is toybox's, which sends only `ESC[2J ESC[H` — erase the
screen, home the cursor — and so leaves the scrollback, as any terminal keeps
it on `2J`. The `clear` of every Linux system (ncurses, for
`TERM=xterm-256color`) also sends `ESC[3J`, which erases the scrollback, and
so does this one. The bootstrap session needs none of this: its `clear` is
ncurses'.
*/
immutable ShellTool[] shellTools = [
    ShellTool("clear",
        "#!/system/bin/sh\n"
        ~ "# Written by the terminal app: Android's clear keeps the scrollback.\n"
        ~ "printf '\\033[H\\033[2J\\033[3J'\n"),
];

///
@("session.shellTools")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    assert(shellTools[0].name == "clear");
    assert(shellTools[0].script.canFind(`\033[3J`), "clear erases the scrollback too");
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
