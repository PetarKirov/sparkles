/**
`ci`'s console ([ci task-DAG CIC19](../../../docs/specs/ci/task-dag/SPEC.md)): every
line it writes for a person — a command's progress and a log record alike —
in the one line form of `sparkles.base.status_line`.

A status line (`sparkles.base.logger.status`) is drawn as it was made. Any
other log record becomes one too, its level as the verb: `Info`, `Warning`,
`Error`. A trace record also names its source line, muted; so do the
details a command reports at trace, which `--log-level trace` shows and the
default hides.

While a live view is on screen (`ci test`'s), nothing may write beneath it:
$(LREF holdConsole) queues each line instead, and the view prints them above
itself each time it draws ($(LREF drainConsole)).
*/
module console;

import sparkles.base.buffer : HeapBuffer, SharedBuffer;
import sparkles.base.logger : CoreLogEntry, DeltaTimeLogger, LogLevel;
import sparkles.base.status_line : plain, StatusLine, StatusSpan, Tone, writeStatusLine;
import sparkles.base.sync.mutex : Mutex;

/// The console's logger: status lines, and every record as one.
final class ConsoleLogger : DeltaTimeLogger
{
    private immutable bool colour;

    /// A console at `level`, coloured or not.
    this(this Q)(LogLevel level, bool colour) @safe
    {
        super(level);
        this.colour = colour;
    }

    override protected void writeCoreLog(const ref CoreLogEntry entry, scope const(char)[] message)
        @safe nothrow @nogc
    {
        // The `Δtᵢ` a command's own footers measure stays the log's.
        cast(void) takeDelta();
        SharedBuffer!(char, 2048) line;
        if (entry.status !is null)
            writeStatusLine(line, *entry.status, colour);
        else
            writeRecord(line, entry, message, colour);
        emit(line[]);
    }
}

/**
Writes a record that is not a status line as one: its level as the verb,
the message as given, and at trace its source line, muted.
*/
void writeRecord(Writer)(ref Writer w, const ref CoreLogEntry entry, scope const(char)[] message, bool colour) @safe
{
    import sparkles.base.status_line : detail;
    import sparkles.base.text.writers : writeInteger;

    const(char)[] verb;
    Tone tone;
    switch (entry.level)
    {
        case LogLevel.trace: verb = "Trace"; tone = Tone.muted; break;
        case LogLevel.info: verb = "Info"; tone = Tone.info; break;
        case LogLevel.warning: verb = "Warning"; tone = Tone.warning; break;
        case LogLevel.error: verb = "Error"; tone = Tone.failure; break;
        case LogLevel.critical: verb = "Critical"; tone = Tone.failure; break;
        default: verb = "Fatal"; tone = Tone.failure; break;
    }
    SharedBuffer!(char, 128) where;
    if (entry.level <= LogLevel.trace && entry.file.length)
    {
        import std.path : baseName;

        where ~= entry.file.baseName;
        where ~= ':';
        writeInteger(where, entry.line);
    }
    const StatusSpan[2] spans = [plain(message), detail(where[])];
    // `@trusted`: the slice of a local array, read by the call below alone.
    scope const line = StatusLine(verb, tone, () @trusted { return spans[0 .. where.length ? 2 : 1]; }());
    writeStatusLine(w, line, colour);
}

/**
Installs the console as `ci`'s logger at `level`: coloured on a terminal, on
a CI service's log (which renders colour), and never under `NO_COLOR`.
*/
void installConsole(LogLevel level) @safe
{
    import std.logger : globalLogLevel, sharedLog;
    import sparkles.base.logger : coreGlobalLogLevel, sharedCoreLog;

    globalLogLevel = level;
    coreGlobalLogLevel = level;
    auto logger = new shared ConsoleLogger(level, consoleColour());
    sharedLog = logger;
    sharedCoreLog = logger;
}

/// Whether the console colours its lines.
bool consoleColour() @safe
{
    import std.process : environment;
    import sparkles.base.term_caps : isTerminal, StdStream;

    if (environment.get("NO_COLOR", "").length)
        return false;
    return isTerminal(StdStream.stderr) || environment.get("GITHUB_ACTIONS", "") == "true"
        || environment.get("GITLAB_CI", "").length || environment.get("CIRCLECI", "").length;
}

/// From now on the console queues its lines for $(LREF drainConsole), until
/// $(LREF releaseConsole).
void holdConsole() @trusted nothrow @nogc
{
    queueMutex.lock();
    scope (exit)
        queueMutex.unlock();
    holding = true;
}

/// Hands every queued line to `sink`, in order.
void drainConsole(scope void delegate(scope const(char)[] line) @safe sink) @trusted
{
    import std.algorithm.iteration : splitter;

    string text;
    {
        queueMutex.lock();
        scope (exit)
            queueMutex.unlock();
        text = held[].idup;
        held.clear();
    }
    if (text.length)
        foreach (line; text[0 .. $ - 1].splitter('\n'))
            sink(line);
}

/// The console writes to standard error again; queued lines are handed to
/// `sink` first.
void releaseConsole(scope void delegate(scope const(char)[] line) @safe sink) @trusted
{
    drainConsole(sink);
    queueMutex.lock();
    scope (exit)
        queueMutex.unlock();
    holding = false;
}

private:

// The lines held while a live view is up, each ending in '\n'.
__gshared Mutex queueMutex;
__gshared bool holding;
__gshared HeapBuffer!char held;

void emit(scope const(char)[] line) @trusted nothrow @nogc
{
    import core.stdc.stdio : fflush, fwrite, stderr;

    {
        queueMutex.lock();
        scope (exit)
            queueMutex.unlock();
        if (holding)
        {
            held ~= line;
            held ~= '\n';
            return;
        }
    }
    fwrite(line.ptr, 1, line.length, stderr);
    fwrite("\n".ptr, 1, 1, stderr);
    fflush(stderr);
}

/// A record that is not a status line reads as one, its level the verb; at
/// trace it names its source line.
@("console.writeRecord.levelAsTheVerb")
@safe unittest
{
    import sparkles.base.buffer : checkWriter;

    auto warn = CoreLogEntry(level: LogLevel.warning, file: "apps/ci/src/app.d", line: 48);
    checkWriter!((ref b) => writeRecord(b, warn, "swap in use", false))("     Warning swap in use");
    auto tr = CoreLogEntry(level: LogLevel.trace, file: "apps/ci/src/app.d", line: 48);
    checkWriter!((ref b) => writeRecord(b, tr, "32 CPUs", false))("       Trace 32 CPUs  app.d:48");
}

/// Held lines wait for the view, in order, and the console writes again once
/// released.
@("console.hold.queuesUntilReleased")
@system unittest
{
    holdConsole();
    emit("one");
    emit("two");
    string[] seen;
    releaseConsole((scope const(char)[] l) { seen ~= l.idup; });
    assert(seen == ["one", "two"]);
    assert(!holding);
}
