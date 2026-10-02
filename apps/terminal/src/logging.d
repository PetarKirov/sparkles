/**
The terminal's log (docs/specs/terminal/pages.md, `TPG4`–`TPG7`, D24): every
entry goes to the platform sink (stderr on the desktop, logcat on Android), to
`<state dir>/sparkles-terminal/terminal.log` (rotated to `terminal.log.1`, the
previous run's) and to an in-memory ring the log page reads
($(LREF terminalLog)).

Only metadata is ever logged — never text typed, pasted, autofilled or copied
(`TPG6`).
*/
module logging;

import sparkles.base.log_sinks : RingCoreLogger;

/// The log file's directory under the state directory.
enum logDirName = "sparkles-terminal";

/// The log file's name; the previous one is `terminal.log.1`.
enum logFileName = "terminal.log";

// What `installTerminalLog` set up, for the log page: the ring, and the
// directory the file (and the pages' own state) lives in. Main-thread state,
// set once at start.
private RingCoreLogger ring;
private string appStateDir;

/**
Puts the file and the ring in front of the platform sink already installed
(`initLogger`'s stderr, `installLogcatSink`'s logcat) and returns the ring,
which $(LREF terminalLog) hands out from then on. With no `stateDir`, there is
no file — the ring still records.
*/
RingCoreLogger installTerminalLog(string stateDir) @safe
{
    import std.path : buildPath;

    import sparkles.base.log_sinks : installFileLog, installRingLog;

    import sparkles.base.logger : coreGlobalLogLevel, LogLevel;

    // The file and the ring keep `trace` — protocol events, the log page's
    // "debug" (`TPG7`) — while the platform sink behind them keeps its own
    // level: each forwarding sink hands an entry on, and the next one filters.
    coreGlobalLogLevel = LogLevel.trace;
    if (stateDir.length)
    {
        installFileLog(logPath(stateDir)).coreLogLevel = LogLevel.trace;
        appStateDir = buildPath(stateDir, logDirName);
    }
    ring = installRingLog();
    ring.coreLogLevel = LogLevel.trace;
    return ring;
}

/// The ring $(LREF installTerminalLog) installed; null before it ran.
RingCoreLogger terminalLog() @safe nothrow @nogc => ring;

/// `<state dir>/sparkles-terminal`, where the log file and the pages' own
/// state live; empty when there is no state directory.
string terminalStateDir() @safe nothrow @nogc => appStateDir;

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

/// The previous run's log file (`terminal.log.1`, `TPG5`); empty without a
/// state directory.
string previousLogPath() @safe nothrow
{
    import std.path : buildPath;

    return appStateDir.length ? buildPath(appStateDir, logFileName ~ ".1") : null;
}

/// The desktop's state directory: XDG's, else the data directory (macOS has
/// no state directory), else none.
string desktopStateDir() @safe
{
    import sparkles.core_cli.common_dirs : dataDir, stateDir;

    const state = stateDir();
    return state.length ? state : dataDir();
}
