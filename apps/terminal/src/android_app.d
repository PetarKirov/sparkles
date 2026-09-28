/**
The Android entry (docs/specs/terminal/android.md): a NativeActivity has no
command line, no `$SHELL` and no stderr, so what `main` would parse is decided
here — from the APK's `session.conf` asset and the app's data dir.
*/
module android_app;

version (Android):

import cli : guiOptionsFrom, TerminalCli;
import droid_terminal : DroidTerminal;
import session;
import sparkles.base.logger : info, LogLevel, warning;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run_app : runApp;

/// The logcat tag (`adb logcat -s terminal`).
enum logTag = "terminal";

/// The font the APK bundles (nix/packages/android/terminal.nix) and falls
/// back from: Android's own monospace face.
private enum bundledFont = "FiraCodeNerdFontMono";
private enum systemFont = "DroidSansMono";

int androidMain()
{
    import core.stdc.stdlib : exit;
    import std.file : exists, mkdirRecurse;
    import std.path : buildPath;

    import sparkles.android.activity : internalDataPath;
    import sparkles.android.assets : extractAssetBundle, readAssetText;
    import sparkles.android.log : installLogcatSink;

    installLogcatSink(LogLevel.info, logTag);

    const paths = SessionPaths(internalDataPath);
    const fontsDir = buildPath(paths.files, "fonts");
    static immutable owned = ["fonts"];
    if (!extractAssetBundle(paths.files, owned, buildPath(paths.files, "assets-ready")))
        warning(i"terminal: no font bundle — falling back to $(systemFont)");

    const conf = readAssetText("session.conf");
    const config = conf is null ? SessionConfig.init : parseSessionConfig(conf);
    info(i"terminal: session mode $(config.mode)");

    try
        mkdirRecurse(paths.home);
    catch (Exception e)
        warning(i"terminal: cannot create $(paths.home): $(e.msg)");

    // `~/.termux/font.ttf` wins (nix-on-droid's `terminal.font`, `NOD11`),
    // then the bundled face, then the system's.
    const termuxFont = buildPath(paths.termuxDir, "font.ttf");
    const font = termuxFont.exists ? termuxFont
        : buildPath(fontsDir, bundledFont ~ "-Regular.ttf").exists ? bundledFont
        : systemFont;

    RunConfig cfg = {
        title: "Sparkles Terminal",
        gui: guiOptionsFrom(TerminalCli(
            font: font,
            fontDirs: [fontsDir, "/system/fonts"],
        )),
        keyRelease: true, // the terminal-grade keyboard
        touchGestures: true, // taps, drags and pinches — not an emulated mouse
    };

    DroidTerminal app;
    app.oracle.dir = paths.debugDir;
    configureSession(app, config, paths);
    runApp(app, cfg);
    app.tv.close();
    // Static druntime cannot rt_init twice, and Android reuses the process
    // across activity recreations: end the process with the activity.
    exit(0);
}

/// Point the terminal at the session `config` asks for (`NOD4`, `NOD7`).
private void configureSession(ref DroidTerminal app, const SessionConfig config,
    const SessionPaths paths)
{
    import std.array : array;
    import std.algorithm.iteration : map;
    import std.file : exists, mkdirRecurse;
    import std.process : environment;
    import std.string : toStringz;

    const bootstrapped = config.mode == SessionMode.bootstrap && paths.login.exists;
    if (config.mode == SessionMode.bootstrap && !bootstrapped)
        warning(i"terminal: no bootstrap installed yet — starting a plain shell");

    string[] parentEnv;
    foreach (key, value; environment.toAA)
        parentEnv ~= key ~ "=" ~ value;
    const env = sessionEnvironment(parentEnv, paths, bootstrapped);
    try
        mkdirRecurse(bootstrapped ? paths.tmp : paths.files ~ "/tmp");
    catch (Exception) {}

    const(char)*[] envz = env.map!(e => cast(const(char)*) e.toStringz).array;
    envz ~= null;
    const(char)*[] argv = bootstrapped
        ? ["-login".ptr, null]
        : ["-sh".ptr, null];

    app.tv.opts.program = bootstrapped ? paths.login.toStringz : "/system/bin/sh";
    app.tv.opts.argv = argv;
    app.tv.opts.cwd = paths.home.toStringz;
    app.tv.opts.env = envz;
    app.tv.opts.pollMouse = false; // touch arrives as gestures (DroidTerminal)
}
