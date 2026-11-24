/// The composition root: what every command shares before it runs.
module app;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.hw_caps :
    hwAvailableMemoryBytes, hwLoadAverageCenti, hwLoadUnknown, hwMemoryBytes, hwOnlineCpuCount,
    hwSwapUsedBytes, describe, hwWorkerBudget, ResourceCap;
import sparkles.base.logger : LogLevel, trace;
import std.conv : text;

/// Re-apply the Sparkles + Phobos log level without resetting the
/// `DeltaTimeLogger` clock, so `--log-level` after the early `initLogger`
/// does not drop the timestamps already emitted.
void applyLogLevel(LogLevel level) @safe
{
    import std.logger : globalLogLevel;

    globalLogLevel = level;
    import sparkles.base.logger : coreGlobalLogLevel, sharedCoreLog;
    coreGlobalLogLevel = level;
    if (auto logger = sharedCoreLog)
        () @trusted {
            auto l = cast() logger;
            l.coreLogLevel = level;
            l.logLevel = level;
        }();
}

/// One host-resource snapshot: the breadcrumb that tells a slow CI log
/// whether the runner was already tight on RAM/CPUs before any work started.
void logHostResources()
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.base.text.writers : writeBytes, writeFixedPoint;

    SharedBuffer!(char, 24) total, avail, swap;
    writeBytes(total, hwMemoryBytes());
    writeBytes(avail, hwAvailableMemoryBytes());
    writeBytes(swap, hwSwapUsedBytes());

    SharedBuffer!(char, 16) loadBuf;
    const load = hwLoadAverageCenti();
    if (load == hwLoadUnknown)
        loadBuf ~= "?";
    else
        writeFixedPoint(loadBuf, load, 2);

    trace(i"host: $(hwOnlineCpuCount()) CPUs online, load $(loadBuf[]); RAM $(avail[]) available of $(total[]), swap $(swap[]) in use");
    const budget = hwWorkerBudget();
    if (budget.cap == ResourceCap.none)
        trace(i"host: workers=$(budget.workers) (every allowed CPU)");
    else
        trace(i"host: workers=$(budget.workers) of $(budget.cpus) CPUs — $(describe(budget.cap))");
}
