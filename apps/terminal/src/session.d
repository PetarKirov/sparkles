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
    bootstrapShell, /// experimental current-target bootstrap: `sh login`
}

/// The APK's `session.conf` asset (`KEY=VALUE` lines), parsed.
struct SessionConfig
{
    SessionMode mode = SessionMode.shell;
    /// The bootstrap base URL offered as the installer's default; the zip is
    /// `<url>/bootstrap-<arch>.zip`.
    string bootstrapUrl;
    /// Where the `am` server listens; empty for Termux's layout
    /// ($(LREF SessionPaths.amSocket)).
    string amSocket;
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
                    : pair.value == "bootstrap-shell" ? SessionMode.bootstrapShell
                    : SessionMode.shell;
                break;
            case "bootstrapUrl":
                c.bootstrapUrl = pair.value;
                break;
            case "amSocket":
                c.amSocket = pair.value;
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
        "bootstrapUrl=https://example.org/bootstrap\nfuture=1\n" ~
        "amSocket=/data/data/org.example/files/apps/termux-am/am.sock\n");
    assert(c.mode == SessionMode.bootstrap);
    assert(c.bootstrapUrl == "https://example.org/bootstrap");
    assert(c.amSocket == "/data/data/org.example/files/apps/termux-am/am.sock");

    assert(parseSessionConfig("").mode == SessionMode.shell);
    assert(parseSessionConfig("mode=unheard-of").mode == SessionMode.shell);
    assert(parseSessionConfig("mode=bootstrap-shell").mode == SessionMode.bootstrapShell);
}

/// The directories under the app's data dir (`/data/user/0/<pkg>/files`),
/// laid out as Termux and nix-on-droid's bootstrap expect.
struct SessionPaths
{
    string files;
    /// `session.conf`'s `amSocket`, if any.
    string amSocketOverride;
    /// The extracted APK native-library directory, resolved by the Android
    /// host. Install/update paths are not stable, so login must not guess it.
    string nativeLibraryDir;

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
    /// Where the `am` server listens and nix-on-droid's `termux-am`
    /// connects: the session's `amSocket`, else Termux's layout. That names
    /// the package twice, and a socket path has at most 107 bytes, so a long
    /// package id needs the former.
    string amSocket() const @safe pure nothrow =>
        amSocketOverride.length ? amSocketOverride
            : buildPath(files, "apps", packageName, "termux-am", "am.sock");
}

///
@("session.SessionPaths")
@safe pure unittest
{
    const p = SessionPaths("/data/user/0/dev.petar_kirov.sparkles.terminal/files");
    assert(p.home == "/data/user/0/dev.petar_kirov.sparkles.terminal/files/home");
    assert(p.prefix == "/data/user/0/dev.petar_kirov.sparkles.terminal/files/usr");
    assert(p.login == "/data/user/0/dev.petar_kirov.sparkles.terminal/files/usr/bin/login");
    assert(p.termuxDir == "/data/user/0/dev.petar_kirov.sparkles.terminal/files/home/.termux");
    assert(p.packageName == "dev.petar_kirov.sparkles.terminal");
    assert(p.amSocket == "/data/user/0/dev.petar_kirov.sparkles.terminal/files/apps/"
        ~ "dev.petar_kirov.sparkles.terminal/termux-am/am.sock", "Termux's layout");
    // `sun_path` holds 108 bytes including the NUL, so this layout does not fit.
    assert(p.amSocket.length > 107);
    const short_ = SessionPaths(p.files, "/data/data/x/files/apps/termux-am/am.sock");
    assert(short_.amSocket == "/data/data/x/files/apps/termux-am/am.sock");
    assert(short_.amSocket.length <= 107);
}

/**
The program and arguments to start in the PTY. `bootstrap-shell` reads the
login script through the system shell rather than executing an app-data file.
This changes only the first script: its PRoot command and loader still need
APK-native paths before a current-target bootstrap can work.
*/
struct SessionCommand
{
    string program;
    string[] argv;
}

/// Select the login route; a missing bootstrap always starts the plain shell.
SessionCommand sessionCommand(const SessionPaths paths, SessionMode mode,
    bool bootstrapped) @safe pure nothrow
{
    if (!bootstrapped || mode == SessionMode.shell)
        return SessionCommand("/system/bin/sh", ["-sh"]);
    if (mode == SessionMode.bootstrapShell)
        return SessionCommand("/system/bin/sh", ["sh", paths.login]);
    return SessionCommand(paths.login, ["-login"]);
}

///
@("session.sessionCommand")
@safe pure nothrow unittest
{
    const p = SessionPaths("/data/user/0/org.example/files");
    const direct = sessionCommand(p, SessionMode.bootstrap, true);
    assert(direct.program == p.login && direct.argv == ["-login"]);
    const interpreted = sessionCommand(p, SessionMode.bootstrapShell, true);
    assert(interpreted.program == "/system/bin/sh");
    assert(interpreted.argv == ["sh", p.login]);
    foreach (mode; [SessionMode.shell, SessionMode.bootstrap, SessionMode.bootstrapShell])
    {
        const fallback = sessionCommand(p, mode, false);
        assert(fallback.program == "/system/bin/sh" && fallback.argv == ["-sh"]);
    }
    assert(sessionCommand(p, SessionMode.shell, true).argv == ["-sh"]);
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
    bool prefixed, bool openInApp = true) @safe pure
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
    if (p.nativeLibraryDir.length)
        own ~= "SPARKLES_NATIVE_LIBRARY_DIR=" ~ p.nativeLibraryDir;
    // The plain shell's opener is live only while open requests are the
    // app's (`TDV4`); the prefix has no shim (its `termux-open` is the
    // `am` server's, which decides for itself).
    if (!prefixed && openInApp)
        own ~= "SPARKLES_TERMINAL_OPEN=1";
    if (prefixed)
    {
        own ~= "PREFIX=" ~ p.prefix;
        // Which app this is — as a Termux-based app says it. nix-on-droid
        // defaults `build.androidAppId` to it, so a configuration that does
        // not name the app still builds its paths for this one.
        own ~= "TERMUX_APP__PACKAGE_NAME=" ~ p.packageName;
        // And where its `am` server listens: nix-on-droid defaults
        // `android-integration.am.socketPath` to it.
        own ~= "NIX_ON_DROID_AM_SOCKET=" ~ p.amSocket;
    }

    static immutable dropped = [
        "LD_LIBRARY_PATH", "LD_PRELOAD", "SPARKLES_NATIVE_LIBRARY_DIR",
        "SPARKLES_TERMINAL_OPEN",
    ];
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
    assert(boot.canFind("NIX_ON_DROID_AM_SOCKET=" ~ p.amSocket));
    assert(!boot.canFind("odd"), "an entry without `=` is not an entry");

    const shell = sessionEnvironment(parent, p, false);
    assert(shell.canFind("PATH=/data/org.example/files/bin:/system/bin"),
        "the app's own commands first (shellTools)");
    assert(shell.canFind("TMPDIR=/data/org.example/files/tmp"));
    assert(!shell.canFind!(e => e.length >= 7 && e[0 .. 7] == "PREFIX="));
    assert(shell.canFind("SPARKLES_TERMINAL_OPEN=1"), "the plain shell's opener is live (`TDV4`)");
    assert(!boot.canFind("SPARKLES_TERMINAL_OPEN=1"), "the prefix has no opener shim");
    const off = sessionEnvironment(parent, p, false, false);
    assert(!off.canFind("SPARKLES_TERMINAL_OPEN=1"), "off with `open.intercept = false`");
}

/// The host's actual APK path replaces stale inherited paths in both modes.
@("session.sessionEnvironment.nativeLibraryDir")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    const parent = ["SPARKLES_NATIVE_LIBRARY_DIR=/old/install/lib/arm64"];
    const p = SessionPaths("/data/org.example/files", null, "/data/app/current/lib/arm64");
    foreach (prefixed; [false, true])
    {
        const env = sessionEnvironment(parent, p, prefixed);
        assert(env.canFind("SPARKLES_NATIVE_LIBRARY_DIR=/data/app/current/lib/arm64"));
        assert(!env.canFind(parent[0]));
        const absent = sessionEnvironment(parent, SessionPaths(p.files), prefixed);
        assert(!absent.canFind(parent[0]), "never reuse an inherited APK location");
    }
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
    ShellTool("sparkles-open", openerScript),
    ShellTool("xdg-open", openerScript),
    ShellTool("termux-open", openerScript),
];

/**
The plain shell's opener (`TDV4`, `TDV15`), under the names programs call:
one local file, made absolute and checked where it is, becomes an open
request on the terminal (`ESC ] 5379 ; open ; <base64> ST`); a missing one is
refused with status 1 (`TDV3`). The plain shell has no next opener to hand
the rest to, so what the desktop's shim passes on — a URL, another host's
`file:` path, a directory, a non-regular file, no `SPARKLES_TERMINAL_OPEN` —
the script refuses where it runs, with a message and status 1. The content
kind stays the host's to decline (`TDV1`): a shell script cannot sniff it.
*/
enum string openerScript = "#!/system/bin/sh\n"
    ~ "# Written by the terminal app: one local file opens in its viewer.\n"
    ~ "name=${0##*/}\n"
    ~ "if [ \"${SPARKLES_TERMINAL_OPEN:-}\" != \"1\" ]; then\n"
    ~ "  echo \"$name: open requests are off in this terminal\" >&2; exit 1\n"
    ~ "fi\n"
    ~ "if [ $# -ne 1 ] || [ \"${1#-}\" != \"$1\" ]; then\n"
    ~ "  echo \"$name: opens one local file in the terminal's viewer\" >&2; exit 2\n"
    ~ "fi\n"
    ~ "t=$1\n"
    ~ "case $t in\n"
    ~ "  file://localhost/*) p=${t#file://localhost} ;;\n"
    ~ "  file:///*) p=${t#file://} ;;\n"
    ~ "  /*) p=$t ;;\n"
    ~ "  *)\n"
    ~ "    h=${t%%/*}\n"
    ~ "    case $h in\n"
    ~ "      *:*) echo \"$name: $t: not a local file\" >&2; exit 1 ;;\n"
    ~ "      *) p=$PWD/$t ;;\n"
    ~ "    esac ;;\n"
    ~ "esac\n"
    ~ "if [ -d \"$p\" ]; then\n"
    ~ "  echo \"$name: $t: a directory\" >&2; exit 1\n"
    ~ "elif [ ! -f \"$p\" ]; then\n"
    ~ "  if [ -e \"$p\" ]; then\n"
    ~ "    echo \"$name: $t: not a regular file\" >&2\n"
    ~ "  else\n"
    ~ "    echo \"$name: $t: no such file\" >&2\n"
    ~ "  fi\n"
    ~ "  exit 1\n"
    ~ "elif [ ! -r \"$p\" ]; then\n"
    ~ "  echo \"$name: $t: not readable\" >&2; exit 1\n"
    ~ "fi\n"
    ~ "case $t in file://*) ;; *) t=$p ;;\n"
    ~ "esac\n"
    ~ "printf '\\033]5379;open;%s\\033\\\\' \"$(printf %s \"$t\" | base64 | tr -d '\\n')\" > /dev/tty\n";

///
@("session.shellTools")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    assert(shellTools[0].name == "clear");
    assert(shellTools[0].script.canFind(`\033[3J`), "clear erases the scrollback too");
}

/// The plain shell's opener writes what the desktop's shim writes (`TDV15`).
@("session.openerScript.writesTheOpenRequest")
@system unittest
{
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.algorithm.searching : canFind;
    import std.array : replace;
    import std.conv : text;
    import std.process : execute, thisProcessID;
    import open_request : openRequestSequence;

    import sparkles.test_runner.skip : skipTest;

    // `/system/bin/sh` is Android's; any POSIX sh runs the script, its output
    // sent to stdout in place of the terminal.
    if (!exists("/bin/sh"))
        return skipTest("no /bin/sh");
    const dir = buildPath(tempDir, text("opener-", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    const script = buildPath(dir, "xdg-open");
    write(script, openerScript.replace(" > /dev/tty", ""));
    write(buildPath(dir, "a b.md"), "# hi\n");
    string[string] on = ["SPARKLES_TERMINAL_OPEN": "1"];
    auto run(string args, string[string] env = on) =>
        execute(["/bin/sh", "-c", "cd '" ~ dir ~ "' && sh ./xdg-open " ~ args], env);
    auto r = run("'a b.md'");
    assert(r.status == 0 && r.output == openRequestSequence(buildPath(dir, "a b.md")), r.output);
    r = run("missing.md");
    assert(r.status == 1 && r.output.canFind("no such file"));
    r = run("-a b");
    assert(r.status == 2);
    // What the desktop's shim hands to the next opener, the plain shell
    // refuses where it runs (`TDV3`, `TDV4`): no request is written.
    r = run("'a b.md'", ["SPARKLES_TERMINAL_OPEN": "0"]);
    assert(r.status == 1 && !r.output.canFind("5379"), "off without the env (`TDV4`)");
    r = run("https://example.org/a.md");
    assert(r.status == 1 && !r.output.canFind("5379"), "a URL is not a local file");
    r = run("file://otherhost/tmp/a.md");
    assert(r.status == 1 && !r.output.canFind("5379"), "another host's path is not local");
    r = run(".");
    assert(r.status == 1 && !r.output.canFind("5379"), "a directory is refused");
    r = execute(["/bin/sh", "-c", "cd '" ~ dir ~ "' && mkfifo fifo.md && sh ./xdg-open fifo.md"], on);
    assert(r.status == 1 && !r.output.canFind("5379"), "a FIFO is not a regular file");
    r = run("'file://localhost" ~ buildPath(dir, "a b.md") ~ "'");
    assert(r.status == 0
        && r.output == openRequestSequence("file://localhost" ~ buildPath(dir, "a b.md")),
        "a local file: URI is passed on for the host to decode");
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
