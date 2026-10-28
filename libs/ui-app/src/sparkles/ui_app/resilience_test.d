/**
The executable half of `docs/specs/ui-app/resilience.md`: its scenario
catalog, run.

A test here is named `resilience.RSC<n>.<lane>.<what>`. The `model` lane
drives $(REF Lifecycle, sparkles,ui_app,lifecycle) — the native arm's own
decisions — through a $(LREF Rig) that executes each plan the way the loop
does and keeps a ledger of what is alive. The `recorder` lane runs a probe
application on the recording host. `catalogMatchesTheSuite` reads the page
and fails when the catalog and these tests disagree.
*/
module sparkles.ui_app.resilience_test;

version (unittest):

import core.time : Duration, msecs, seconds;

import sparkles.ui_app.lifecycle : Failure, FrameResult, HostPhase, Lifecycle, Plan, Rebuild,
    Surface;

// ─────────────────────────────────────────────────────────────────────────────
// The model lane's rig: the loop, without a window or a device.
// ─────────────────────────────────────────────────────────────────────────────

/**
Executes plans as the native loop does and counts what lives in each scope.
Results for the frames it draws and failures for the rebuilds it attempts
are scripted; by default every frame presents and every rebuild works.
*/
private struct Rig
{
    Lifecycle lc;
    Duration now;

    // ── the ledger: what is alive, and what was made ──
    int devices, surfaces, targets;
    int deviceCreates, surfaceCreates, targetBuilds, cacheReleases, pressureReports;
    int[] remeasured;   /// every re-measure, in pixels
    bool[] drawn;       /// every frame drawn: whether it had to be
    bool stopped;
    Failure failure;

    // ── the script ──
    FrameResult[] results;   /// how the next frames go
    int failDevice;          /// how many device creations fail next
    int failSurface;         /// ditto, surfaces
    int failTargets;         /// ditto, swapchains
    bool noHandles;          /// the window has no native surface now
    bool requesting;         /// the application asks for another frame in each

    @safe pure nothrow:

    void start(Surface s = Surface(800, 600, 1))
    {
        lc.started(s);
        devices = 1;
        if (!s.suspended)
            surfaces = targets = 1;
    }

    /// The window system reports metrics; a re-measure happens at once.
    void metrics(Surface s)
    {
        if (const px = lc.metrics(s))
            remeasured ~= px;
    }

    /// The application chooses a font size; it is measured at once.
    void fontSize(int px)
    {
        remeasured ~= lc.fontSize(px);
    }

    /// One loop iteration at `now`, then `dt` passes.
    Plan step(Duration dt = 16.msecs, Duration wakeAsk = Duration.max)
    {
        auto p = lc.step(now, wakeAsk);
        exec(p);
        now += dt;
        return p;
    }

    /// Steps until a plan is idle (nothing to do, nothing to draw).
    void settle()
    {
        foreach (_; 0 .. 32)
        {
            const p = step();
            if (p.idle || p.stop)
                return;
        }
        assert(false, "the host did not settle in 32 iterations");
    }

    private void exec(in Plan p)
    {
        if (p.stop)
        {
            stopped = true;
            failure = p.failure;
            targets = surfaces = devices = 0;
            return;
        }
        if (p.releaseDevice)
            devices = surfaces = targets = 0;
        if (p.releaseSurface)
            surfaces = targets = 0;
        if (p.releaseCaches)
            ++cacheReleases;
        if (p.deliverPressure)
            ++pressureReports;
        if (p.createDevice)
        {
            devices = surfaces = targets = 0; // the lost one goes first
            if (failDevice > 0)
            {
                --failDevice;
                lc.rebuildFailed(Rebuild.device);
                return;
            }
            devices = surfaces = targets = 1;
            ++deviceCreates;
            lc.rebuilt(Rebuild.device);
        }
        if (p.createSurface)
        {
            surfaces = targets = 0;
            if (noHandles || failSurface > 0)
            {
                if (!noHandles)
                    --failSurface;
                lc.rebuildFailed(Rebuild.surface, hasHandles: !noHandles);
                return;
            }
            surfaces = 1;
            ++surfaceCreates;
            lc.rebuilt(Rebuild.surface);
        }
        if (p.rebuildTargets)
        {
            assert(devices == 1 && surfaces == 1, "a swapchain needs a device and a surface");
            if (failTargets > 0)
            {
                --failTargets;
                targets = 0;
                lc.rebuildFailed(Rebuild.targets);
                return;
            }
            targets = 1;
            ++targetBuilds;
            lc.rebuilt(Rebuild.targets);
        }
        if (p.draw)
        {
            assert(devices == 1 && surfaces == 1 && targets == 1,
                "a frame is drawn only onto a complete target");
            drawn ~= p.mustDraw;
            lc.requested(requesting); // as the loop reports it: before the outcome
            FrameResult r = FrameResult.presented;
            if (results.length)
            {
                r = results[0];
                results = results[1 .. $];
            }
            lc.frameDone(r, now);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Model-lane scenarios.
// ─────────────────────────────────────────────────────────────────────────────

@("resilience.RSC3.model.anAcceptedCloseStopsAtOnce")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.lc.close();
    const p = r.step(Duration.zero, wakeAsk: 10.seconds);
    assert(p.stop && p.failure == Failure.none && p.park == Duration.zero,
        "no wait on the pending wake (`RES36`)");
    assert(r.lc.state == HostPhase.stopping);
    assert(r.step().stop, "and it stays stopped");
}

@("resilience.RSC4.model.eachResizeRebuildsTheTargetAndDraws")
@safe pure nothrow unittest
{
    Rig r;
    r.start(Surface(800, 600, 1));
    r.settle();
    foreach (s; [Surface(1200, 800, 1), Surface(600, 400, 1)])
    {
        const builds = r.targetBuilds, frames = r.drawn.length;
        r.metrics(s);
        const p = r.step();
        assert(p.rebuildTargets && p.draw, "the target and the frame, in one iteration");
        assert(r.targetBuilds == builds + 1 && r.drawn.length == frames + 1);
        assert(r.deviceCreates == 0 && r.lc.surface == s);
        r.settle();
    }
}

@("resilience.RSC5.model.aFloodOfChangesIsOneRebuildAndOneFrame")
@safe pure nothrow unittest
{
    Rig r;
    r.start(Surface(800, 600, 1));
    r.settle();
    const builds = r.targetBuilds, frames = r.drawn.length;
    foreach (i; 0 .. 50)
        r.metrics(Surface(800 + i, 600 + i, 1));
    foreach (scale; [1.5, 2.0, 1.25])
        r.metrics(Surface(1000, 700, scale));
    r.settle();
    assert(r.targetBuilds == builds + 1, "one rebuild (`RES33`)");
    assert(r.drawn.length == frames + 1, "one frame");
    assert(r.remeasured == [27, 36, 23], "each scale measured as it arrives (`HST7`)");
    assert(r.lc.surface == Surface(1000, 700, 1.25));
}

@("resilience.RSC6.model.theChosenFontSizeOutlivesScaleAndSize")
@safe pure nothrow unittest
{
    Rig r;
    r.start(Surface(800, 600, 1));
    r.settle();
    r.fontSize(22);
    r.settle();
    r.metrics(Surface(1600, 1200, 2));
    r.settle();
    r.metrics(Surface(800, 600, 1));
    r.settle();
    r.metrics(Surface(900, 700, 1)); // a resize at the same scale
    r.settle();
    assert(r.remeasured == [22, 44, 22], "follows the scale, keeps the choice (`RES55`)");
    assert(r.lc.measuredPx == 22, "never back to the starting 18");
}

@("resilience.RSC9.model.suspensionReleasesTheSurfaceAndKeepsWhatArrives")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.metrics(Surface(0, 0, 1));
    const gone = r.step();
    assert(gone.releaseSurface && !gone.draw, "released before the acknowledgement (`RES12`)");
    assert(r.surfaces == 0 && r.targets == 0 && r.devices == 1, "the device stays");
    assert(r.lc.state == HostPhase.suspended);

    const frames = r.drawn.length;
    r.lc.input();
    r.fontSize(30);
    r.settle();
    assert(r.drawn.length == frames, "nothing drawn without a surface");

    r.metrics(Surface(800, 600, 1));
    const back = r.step();
    assert(back.createSurface && back.rebuildTargets && back.draw && back.mustDraw);
    assert(r.remeasured[$ - 1] == 30 && r.lc.measuredPx == 30,
        "the setting made while away is in the first frame (`RES18`)");
    assert(r.deviceCreates == 0 && r.lc.state == HostPhase.visible);
}

@("resilience.RSC10.model.resumingUnchangedRedrawsWithoutANewDevice")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.metrics(Surface(0, 0, 1));
    r.settle();
    r.metrics(Surface(800, 600, 1));
    r.settle();
    assert(r.deviceCreates == 0 && r.surfaceCreates == 1 && r.drawn[$ - 1],
        "a new surface on the same device, and a frame that had to draw (`RES14`)");
    assert(r.remeasured.length == 0, "same scale: nothing re-measured");
}

@("resilience.RSC12.model.hiddenDrawsNothingAndKeepsWaking")
@safe pure nothrow unittest
{
    Rig r;
    r.lc.hiddenPeriod = 250.msecs;
    r.start();
    r.settle();
    const frames = r.drawn.length;
    r.lc.occluded(true);
    foreach (_; 0 .. 5)
    {
        r.lc.input();
        const p = r.step(1.seconds, wakeAsk: 1.seconds);
        assert(!p.draw && p.park == 250.msecs, "no frame; parked at the hidden period");
    }
    assert(r.lc.state == HostPhase.hidden && r.drawn.length == frames);
    r.lc.occluded(false);
    const p = r.step();
    assert(p.draw && r.lc.state == HostPhase.visible, "one frame on uncovering (`RES11`)");
}

@("resilience.RSC13.model.pressureReleasesCachesThenTheDevice")
@safe pure nothrow unittest
{
    Rig r;
    r.lc.releaseDeviceUnderPressure = true;
    r.start();
    r.settle();
    r.lc.memoryPressure(critical: false);
    r.step();
    assert(r.cacheReleases == 1 && r.pressureReports == 1 && r.devices == 1,
        "moderate: caches only, and the application is told (`RES17`)");

    r.lc.memoryPressure(critical: true);
    r.step();
    assert(r.devices == 1, "critical while visible keeps the device");

    r.lc.occluded(true);
    r.step();
    r.lc.memoryPressure(critical: true);
    r.step();
    assert(r.devices == 0, "critical while hidden releases it");
    r.lc.occluded(false);
    r.settle();
    assert(r.devices == 1 && r.deviceCreates == 1 && r.drawn[$ - 1],
        "made again on return, and the frame must draw");
}

@("resilience.RSC14.model.aLostDeviceIsRebuiltAndTheFrameRedrawn")
@safe pure nothrow unittest
{
    foreach (lostAt; [0, 1, 99])
    {
        Rig r;
        r.start();
        foreach (_; 0 .. lostAt)
        {
            r.lc.input();
            r.step();
        }
        r.results = [FrameResult.deviceLost];
        r.lc.input();
        r.step();
        assert(r.lc.state == HostPhase.recovering, "the device is dead, not yet replaced");
        const p = r.step();
        assert(p.createDevice && p.draw && p.mustDraw, "rebuilt and redrawn at once (`RES20`)");
        assert(r.deviceCreates == 1 && r.lc.state == HostPhase.visible);
    }
}

@("resilience.RSC15.model.recoveryIsBounded")
@safe pure nothrow unittest
{
    {
        Rig r;
        r.start();
        r.settle();
        r.results = [FrameResult.deviceLost];
        r.failDevice = 5;
        r.lc.input();
        r.settle();
        assert(r.stopped && r.failure == Failure.recoveryExhausted,
            "three failed rebuilds stop the run with a cause (`RES27`)");
        assert(r.failDevice == 5 - Lifecycle.maxRecoveries);
    }
    {
        Rig r;
        r.start();
        r.settle();
        foreach (i; 0 .. Lifecycle.maxLosses + 1)
        {
            r.results = [FrameResult.deviceLost];
            r.lc.input();
            r.step(1.seconds);
            r.step(1.seconds);
        }
        r.step();
        assert(r.stopped && r.failure == Failure.lossStorm, "four losses in ten seconds");
    }
    {
        Rig r;
        r.start();
        r.settle();
        foreach (i; 0 .. 10)
        {
            r.results = [FrameResult.deviceLost];
            r.lc.input();
            r.step(5.seconds);
            r.step(5.seconds);
        }
        assert(!r.stopped, "a loss every ten seconds is recovered from indefinitely");
    }
}

@("resilience.RSC16.model.aLostSurfaceIsReplacedOrSuspends")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.results = [FrameResult.surfaceLost];
    r.lc.input();
    r.step();
    const p = r.step();
    assert(p.createSurface && !p.createDevice && p.draw, "a new surface, the same device (`RES22`)");
    assert(r.surfaceCreates == 1 && r.deviceCreates == 0);

    r.results = [FrameResult.surfaceLost];
    r.noHandles = true;
    r.lc.input();
    r.settle();
    assert(r.lc.state == HostPhase.suspended && !r.stopped, "no handles: suspended, still running");
    r.noHandles = false;
    r.metrics(Surface(800, 600, 1));
    r.settle();
    assert(r.lc.state == HostPhase.visible && r.surfaceCreates == 2 && r.drawn[$ - 1]);
}

@("resilience.RSC17.model.anOutOfDateTargetIsRebuiltAlone")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.results = [FrameResult.outOfDate];
    r.lc.input();
    r.step();
    const p = r.step();
    assert(p.rebuildTargets && !p.createSurface && !p.createDevice && p.draw, "`RES21`");

    // A swapchain that cannot be built escalates to a new surface.
    r.results = [FrameResult.outOfDate];
    r.failTargets = 1;
    r.lc.input();
    r.settle();
    assert(r.surfaceCreates == 1 && r.deviceCreates == 0 && !r.stopped);
}

@("resilience.RSC18.model.aLossDuringSuspensionResolvesOnResume")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.results = [FrameResult.deviceLost];
    r.lc.input();
    r.step();
    r.metrics(Surface(0, 0, 1)); // suspended before the rebuild ran
    r.settle();
    assert(r.lc.state == HostPhase.suspended && r.deviceCreates == 0,
        "nothing is built without a surface");
    r.metrics(Surface(1000, 800, 1));
    r.settle();
    assert(r.deviceCreates == 1 && r.devices == 1 && r.surfaces == 1 && r.targets == 1,
        "the same end state as the two handled one after the other (`RES23`)");
    assert(r.lc.state == HostPhase.visible && r.drawn[$ - 1]);
}

@("resilience.RSC20.model.aCloseDuringRecoveryStillStops")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.results = [FrameResult.deviceLost];
    r.lc.input();
    r.step();
    r.lc.close();
    const p = r.step();
    assert(p.stop && !p.createDevice, "stopping wins over recovery (`RES25`)");
}

@("resilience.RSC21.model.everyScopeEndsWithItsCause")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.metrics(Surface(1000, 700, 1));
    r.settle();
    assert(r.devices == 1 && r.surfaces == 1 && r.targets == 1);
    r.metrics(Surface(0, 0, 1));
    r.settle();
    assert(r.devices == 1 && r.surfaces == 0 && r.targets == 0, "suspension: the surface scope");
    r.metrics(Surface(1000, 700, 1));
    r.settle();
    r.results = [FrameResult.deviceLost];
    r.lc.input();
    r.settle();
    assert(r.devices == 1 && r.deviceCreates == 1 && r.surfaceCreates == 1 && r.targetBuilds == 2,
        "a lost device: its scope and the surface's, nothing else (`RES4`)");
    r.lc.close();
    r.step();
    assert(r.stopped && r.devices == 0 && r.surfaces == 0 && r.targets == 0);
}

@("resilience.RSC27.model.inputIsInTheSameIterationsFrame")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.lc.input();
    assert(r.step().draw, "no frame of latency added (`RES31`)");
}

@("resilience.RSC28.model.pacedFramesWaitAndMissedOnesAreNotQueued")
@safe pure nothrow unittest
{
    Rig r;
    r.lc.paced = true;
    r.start();
    r.settle();
    r.lc.input();
    const waiting = r.step();
    assert(!waiting.draw, "waits for a frame opportunity (`RES32`)");
    assert(waiting.askFrame, "and asks for one");
    r.lc.frameReady();
    r.lc.frameReady();
    r.lc.frameReady();
    r.lc.input();
    assert(r.step().draw);
    r.lc.input();
    assert(!r.step().draw, "the extra opportunities were not queued");
    r.lc.frameReady();
    assert(r.step().draw);
    assert(!r.step().askFrame, "nothing wanted, nothing asked");
}

@("resilience.RSC29.model.frameSecondsIsTheIntervalClamped")
@safe pure nothrow unittest
{
    import std.math : isClose;

    Rig r;
    r.start();
    r.step(17.msecs); // the first frame: no interval yet
    r.lc.input();
    r.step(7.msecs);
    assert(isClose(r.lc.frameSeconds, 0.017f), "60 Hz (`RES34`)");
    r.lc.input();
    r.step(3.seconds);
    assert(isClose(r.lc.frameSeconds, 0.007f), "144 Hz");
    r.lc.input();
    r.step();
    assert(isClose(r.lc.frameSeconds, 0.25f), "after three seconds away: the clamp");
}

@("resilience.RSC46.model.requestedFramesKeepComing")
@safe pure nothrow unittest
{
    Rig r;
    r.start();
    r.settle();
    r.requesting = true;
    r.lc.input();
    foreach (i; 0 .. 100)
        assert(r.step().draw, "an animation gets a frame every iteration (`RES31`)");
    r.requesting = false;
    r.step(); // the last frame it asked for
    assert(r.step().idle, "and none once it stops asking (`RES30`)");
}

@("resilience.RSC40.model.aFontSizeSetWhileSuspendedIsInTheFirstFrame")
@safe pure nothrow unittest
{
    Rig r;
    r.start(Surface(800, 600, 2));
    r.settle();
    r.metrics(Surface(0, 0, 2));
    r.settle();
    r.fontSize(40);
    r.settle();
    r.metrics(Surface(800, 600, 2));
    const p = r.step();
    assert(p.draw && r.remeasured[$ - 1] == 40 && r.lc.measuredPx == 40,
        "measured before the first frame (`RES56`)");
}

// ─────────────────────────────────────────────────────────────────────────────
// Recorder-lane scenarios: a probe application on the recording host.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.input : charEvent, Event, match, ResizeEvent;
    import sparkles.ui.geometry : Size;
    import sparkles.ui.widget : WidgetTree;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : runAppRecorded;

    // A probe (resilience §9.2): its frame depends on its state and on the
    // surface's size, it counts its shutdowns, and it can be told to throw.
    private struct Probe
    {
        int token;     // changed by input
        int shutdowns;
        int throwAt = -1;
        int events;
        Size seen;

        WidgetTree view(H)(ref H h)
        {
            import sparkles.ui.canvas : fillRectOp;
            import sparkles.ui.geometry : Rect;

            seen = h.size;
            h.ops() ~= fillRectOp(Rect(0, 0, h.size.width, h.size.height));
            h.ops() ~= fillRectOp(Rect(token % h.size.width, 0, 1, 1));
            return WidgetTree.init;
        }

        void handle(H)(ref H h, in Event e)
        {
            if (events++ == throwAt)
                throw new Exception("the probe was told to throw");
            e.match!((in ResizeEvent _) {}, (in _) { ++token; });
        }

        void shutdown(H)(ref H h) { ++shutdowns; }
    }
}

@("resilience.RSC2.recorder.aThrowingHandlerStillShutsDownOnce")
@safe unittest
{
    import std.exception : assertThrown;

    Probe p;
    p.throwAt = 2;
    assertThrown!Exception(runAppRecorded(p, RunConfig.init,
        [charEvent('a'), charEvent('b'), charEvent('c'), charEvent('d')]));
    assert(p.shutdowns == 1 && p.token == 2, "`RES1`");
}

@("resilience.RSC4.recorder.aResizedRunSettlesLikeAColdStart")
@safe unittest
{
    const Event[] typed = [charEvent('a'), charEvent('b')];
    Probe changed;
    auto live = runAppRecorded(changed, RunConfig.init, typed ~ [
        Event(ResizeEvent(Size(120, 40))), Event(ResizeEvent(Size(60, 20)))]);
    Probe fresh;
    auto cold = runAppRecorded(fresh, RunConfig.init, typed,
        (ref RecordingHost h) { h.size = Size(60, 20); });
    assert(changed.seen == Size(60, 20), "the host's size follows the surface (`RES40`)");
    assert(live.lastOps == cold.lastOps, "cold-start equivalent (`RES3`)");
    assert(changed.shutdowns == 1 && changed.token == fresh.token);
}

// ─────────────────────────────────────────────────────────────────────────────
// The page and the suite stay in step (resilience §9.3).
// ─────────────────────────────────────────────────────────────────────────────

private struct Row
{
    string id;
    string[] requirements;
    string[] lanes;
    string status;
}

// The catalog's rows, between its markers, split into cells.
private Row[] catalogRows(string page) @safe pure
{
    import std.algorithm : countUntil, filter, map, splitter;
    import std.array : array;
    import std.string : indexOf, lineSplitter, strip;

    const begin = page.indexOf("<!-- scenario-catalog:begin -->");
    const end = page.indexOf("<!-- scenario-catalog:end -->");
    assert(begin >= 0 && end > begin, "the catalog's markers are missing");
    Row[] rows;
    foreach (line; page[begin .. end].lineSplitter)
    {
        const t = line.strip;
        if (t.length < 2 || t[0] != '|')
            continue;
        auto cells = t[1 .. $ - 1].splitter('|').map!(c => c.strip).array;
        if (cells.length < 6 || cells[0].length < 4 || cells[0][0 .. 3] != "RSC")
            continue;
        static string[] list(string s) => s.splitter(',').map!(x => x.strip.idup)
            .filter!(x => x.length > 0).array;
        rows ~= Row(cells[0].idup, list(cells[1]), list(cells[2]), cells[5].idup);
    }
    return rows;
}

// The requirement IDs the page defines: `**RESn:`.
private string[] requirementIds(string page) @safe pure
{
    import std.algorithm : startsWith;
    import std.string : indexOf;

    string[] ids;
    for (ptrdiff_t at = page.indexOf("**RES"); at >= 0;)
    {
        const rest = page[at + 2 .. $];
        const colon = rest.indexOf(':');
        if (colon > 0 && colon < 8)
            ids ~= rest[0 .. colon];
        const next = page[at + 2 .. $].indexOf("**RES");
        at = next < 0 ? -1 : at + 2 + next;
    }
    return ids;
}

// The lanes a status says run: `runs: model, recorder`.
private string[] runningLanes(string status) @safe pure
{
    import std.algorithm : filter, map, splitter, startsWith;
    import std.array : array;
    import std.string : indexOf, strip;

    if (!status.startsWith("runs:"))
        return null;
    auto s = status[5 .. $];
    foreach (stop; ["(", ";"])
        if (const at = s.indexOf(stop))
            if (at > 0)
                s = s[0 .. at];
    return s.splitter(',').map!(x => x.strip.idup).filter!(x => x.length > 0).array;
}

@("resilience.catalogMatchesTheSuite")
@safe unittest
{
    import std.algorithm : canFind, countUntil, splitter;
    import std.array : array;
    import std.format : format;
    import sparkles.test_runner.skip : skipTest;

    // The page is a string import of ui-app's own test configuration; a
    // consumer that compiles these sources with `-unittest` has no path to it.
    static if (!__traits(compiles, import("resilience.md")))
        return skipTest("docs/specs/ui-app/resilience.md is not on the -J path here");
    else
    {
    enum page = import("resilience.md");
    const rows = catalogRows(page);
    assert(rows.length >= 40, format("only %s catalog rows parsed", rows.length));

    // This module's tests, as (scenario, lane) pairs.
    string[2][] tests;
    static foreach (t; __traits(getUnitTests, mixin(__MODULE__)))
        static foreach (attr; __traits(getAttributes, t))
            static if (is(typeof(attr) : string))
            {{
                auto parts = attr.splitter('.').array;
                if (parts.length >= 4 && parts[0] == "resilience")
                    tests ~= [parts[1], parts[2]];
            }}

    // Every test has a row that lists its lane and says it runs there.
    foreach (t; tests)
    {
        const i = rows.countUntil!(r => r.id == t[0]);
        assert(i >= 0, format("%s has a test and no catalog row", t[0]));
        assert(rows[i].lanes.canFind(t[1]),
            format("%s runs on `%s`, which its row does not list", t[0], t[1]));
        assert(runningLanes(rows[i].status).canFind(t[1]),
            format("%s runs on `%s`; its status `%s` does not say so", t[0], t[1], rows[i].status));
    }
    // Every lane this module owns that a row says runs has a test.
    foreach (ref r; rows)
        foreach (lane; runningLanes(r.status))
            if (lane == "model" || lane == "recorder" || lane == "replay")
                assert(tests.canFind([r.id, lane]),
                    format("%s says it runs on `%s`; no such test here", r.id, lane));
    // Every requirement has a scenario.
    foreach (id; requirementIds(page))
        assert(rows.canFind!(r => r.requirements.canFind(id)),
            format("%s has no scenario in the catalog", id));
    }
}
