/**
The terminal's log (docs/specs/terminal/pages.md, `TPG4`–`TPG7`, D24): every
entry goes to the platform sink (stderr on the desktop, logcat on Android), to
`<state dir>/sparkles-terminal/terminal.log` (rotated to `terminal.log.1`, the
previous run's) and to an in-memory ring a log page reads.

Only metadata is ever logged — never text typed, pasted, autofilled or copied
(`TPG6`).
*/
module logging;

import sparkles.base.log_sinks : RingCoreLogger;

/// The log file's directory under the state directory.
enum logDirName = "sparkles-terminal";

/// The log file's name; the previous one is `terminal.log.1`.
enum logFileName = "terminal.log";

/**
Puts the file and the ring in front of the platform sink already installed
(`initLogger`'s stderr, `installLogcatSink`'s logcat) and returns the ring.
With no `stateDir`, there is no file — the ring still records.
*/
RingCoreLogger installTerminalLog(string stateDir) @safe
{
    import sparkles.base.log_sinks : installFileLog, installRingLog;

    if (stateDir.length)
        installFileLog(logPath(stateDir));
    return installRingLog();
}

/// `<stateDir>/sparkles-terminal/terminal.log`.
string logPath(string stateDir) @safe pure nothrow
{
    import std.path : buildPath;

    return buildPath(stateDir, logDirName, logFileName);
}

///
@("logging.logPath")
@safe pure nothrow unittest
{
    assert(logPath("/home/alice/.local/state")
        == "/home/alice/.local/state/sparkles-terminal/terminal.log");
}

/// The desktop's state directory: XDG's, else the data directory (macOS has
/// no state directory), else none.
string desktopStateDir() @safe
{
    import sparkles.core_cli.common_dirs : dataDir, stateDir;

    const state = stateDir();
    return state.length ? state : dataDir();
}
