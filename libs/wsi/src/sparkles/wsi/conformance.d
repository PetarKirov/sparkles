/**
Backend-agnostic WSI behavior checks.

Every property here is written once against the value-level WSI contract —
ordered sequences, ready metrics, typed handles, resize reporting, close
requests, generation-safe destruction, single-wait progress, and physical
keyboard delivery — and every backend must pass the same assertions. A
platform driver supplies the backend, the loop, and a `Hooks` value; Design by
Introspection over the hooks decides which optional properties run, so a
backend that cannot trigger a behavior out-of-band skips that check instead of
weakening it.

Hooks:
$(LIST
    * `void step(Duration timeout)` — advance the backend's single integrated
        or hosted Event Horizon wait once. Native drivers provide it; a pure
        model backend (the recording fake) omits it, which skips the
        environmental properties (wrong-thread rejection, expose/frame
        opportunities, timer/waker progress) and requires every remaining
        event to be observable synchronously.
)

Optional hooks (checked by presence):
$(LIST
    * `void requestResize(uint width, uint height)` — out-of-band resize; the
        property then requires a `SurfaceMetricsChangedEvent` for that size, or
        any changed size when the hook cannot promise exact dimensions
        (`enum resizeExact = false`).
    * `void requestClose()` — native close request; requires
        `CloseRequestedEvent`.
    * `void injectChord()` plus `enum uint chordShiftCode` and
        `enum uint chordKeyCode` — a left-shift-chorded key press/release. The
        property requires the shift press with `KeyLocation.left`, the chorded
        press, and the release; `enum chordModifierObserved = false` relaxes the
        modifier assertion where the injection path cannot populate real
        modifier state (Wine `SendMessage`), and `chordDeadline` extends the
        wait where injection is external to the process. An
        `enum dchar chordKeyCharacter` additionally requires the chorded key
        to carry that layout-derived unshifted `LogicalKey` character.
    * `void onWindowReady(WindowId id)` — post-ready driver setup (e.g.
        mapping a buffer so a compositor will grant keyboard focus).
    * `enum expectFocusEvent = true` — the chord property additionally
        requires a `FocusChangedEvent(true)` before the keys.
    * `void checkHandles(in NativeHandles handles)` — backend-specific handle
        validation beyond "the query succeeds".
)
*/
module sparkles.wsi.conformance;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;
import sparkles.input.events : KeyAction;
import sparkles.wsi.events;
import sparkles.wsi.types;

private void timerComplete(void* context, ref Completion completion)
    nothrow @nogc
{
    *cast(bool*) context = completion.res == 0;
}

/// What one conformance run exercised.
struct ConformanceOutcome
{
    uint checked;
    uint skipped;
}

/// Everything the shared drain observes about the window under test.
private struct Observed
{
    ulong lastSequence;
    bool ready;
    SurfaceMetrics readyMetrics;
    bool exposed;
    bool frameReady;
    bool metricsChanged;
    SurfaceMetrics lastMetrics;
    bool focusGained;
    bool closeRequested;
    bool destroyed;
    bool shiftLeftPress;
    bool chordedPress;
    bool chordedPressAnyMods;
    bool chordReleased;
}

/**
Drives `wsi` through the shared behavior properties.

The window is created, exercised, and destroyed inside this call. Assertion
failures name the property that broke; the returned outcome counts which
optional properties ran.
*/
ConformanceOutcome checkWsiConformance(Backend, Hooks)(ref Backend wsi,
    ref DefaultLoop loop, ref Hooks hooks, string backendName)
{
    ConformanceOutcome outcome;
    Observed seen;

    void drainAll()
    {
        // Property: sequences are strictly increasing across every event the
        // backend ever queues, whatever the check currently running.
        auto drained = wsi.drain((WindowEvent event) {
            assert(event.sequence > seen.lastSequence,
                "event sequence did not increase");
            seen.lastSequence = event.sequence;
            event.payload.match!(
                (in ReadyEvent value) {
                    seen.ready = true;
                    seen.readyMetrics = value.metrics;
                    seen.lastMetrics = value.metrics;
                },
                (in SurfaceMetricsChangedEvent value) {
                    seen.metricsChanged = true;
                    seen.lastMetrics = value.metrics;
                },
                (in ExposedEvent _) { seen.exposed = true; },
                (in FrameReadyEvent _) { seen.frameReady = true; },
                (in FocusChangedEvent value) {
                    seen.focusGained |= value.focused;
                },
                (in CloseRequestedEvent _) { seen.closeRequested = true; },
                (in DestroyedEvent _) { seen.destroyed = true; },
                (in KeyboardEvent value) { observeKey(hooks, seen, value); },
                (_) {});
        });
        assert(!drained.hasError, "draining the event queue failed");
    }

    enum hasStep = is(typeof(hooks.step(Duration.init)));

    void driveUntil(scope bool delegate() satisfied, string what,
        Duration limit = 5.seconds)
    {
        const deadline = MonoTime.currTime + limit;
        drainAll();
        while (!satisfied())
        {
            static if (hasStep)
            {
                assert(MonoTime.currTime < deadline, what);
                hooks.step(2.seconds);
                drainAll();
            }
            else
                assert(false, what);
        }
    }

    // Property: creation reaches ready with the requested logical size and a
    // positive physical size.
    WindowConfig config;
    assert(config.title.assign(backendName));
    config.logicalSize = LogicalSize(480, 320);
    const id = wsi.createWindow(config).value;
    ++outcome.checked;
    driveUntil(() => seen.ready, "no ReadyEvent after createWindow");
    assert(seen.readyMetrics.logicalSize == config.logicalSize,
        "ready metrics do not match the requested logical size");
    assert(seen.readyMetrics.physicalSize.width > 0
        && seen.readyMetrics.physicalSize.height > 0,
        "ready physical size is empty");
    ++outcome.checked;

    static if (is(typeof(hooks.onWindowReady(id))))
        hooks.onWindowReady(id);

    // Property: after ready every backend eventually offers an expose and a
    // frame opportunity — a window that can never be painted is not ready.
    static if (hasStep)
    {
        driveUntil(() => seen.exposed && seen.frameReady,
            "no expose/frame opportunity after ready");
        ++outcome.checked;
    }
    else
        ++outcome.skipped;

    // Property: the owner-thread rule rejects any other thread with a typed
    // wrongThread error, never a crash or a silent success. The closure
    // captures are heap-allocated and the join orders the write.
    static if (hasStep)
    {
        WsiErrorKind fromOtherThread;
        auto wsiPointer = &wsi;
        auto probe = new Thread({
            auto queried = wsiPointer.nativeHandles(id);
            if (queried.hasError)
                fromOtherThread = queried.error.kind;
        });
        probe.start();
        probe.join();
        assert(fromOtherThread == WsiErrorKind.wrongThread,
            "a non-owner thread was not rejected with wrongThread");
        ++outcome.checked;
    }
    else
        ++outcome.skipped;

    // Property: typed native handles are queryable while the window lives —
    // or explicitly `unsupported`, never garbage. A driver that supplies
    // `checkHandles` promises real handles and validates their backend.
    static if (is(typeof(hooks.checkHandles(NativeHandles.init))))
    {
        hooks.checkHandles(wsi.nativeHandles(id).value);
        ++outcome.checked;
    }
    else
    {
        auto handles = wsi.nativeHandles(id);
        assert(!handles.hasError
            || handles.error.kind == WsiErrorKind.unsupported,
            "handle query failed with something other than unsupported");
        ++outcome.checked;
    }

    // Property: an out-of-band resize is reported as an ordered
    // SurfaceMetricsChangedEvent, never silently absorbed.
    static if (is(typeof(hooks.requestResize(0, 0))))
    {
        const before = seen.lastMetrics;
        seen.metricsChanged = false;
        hooks.requestResize(640, 480);
        static if (is(typeof(Hooks.resizeExact)) && !Hooks.resizeExact)
            driveUntil(() => seen.metricsChanged
                && seen.lastMetrics != before,
                "no metrics change after the resize request");
        else
            driveUntil(() => seen.metricsChanged
                && seen.lastMetrics.physicalSize == PhysicalSize(640, 480),
                "no metrics change to the requested size");
        ++outcome.checked;
    }
    else
        ++outcome.skipped;

    // Property: a shift-chorded key press arrives in order with physical
    // identity, left-hand location, chord modifier state, and its release.
    static if (is(typeof(hooks.injectChord())))
    {
        // `chordEnabled` is a runtime gate for drivers whose injection is
        // external to the process and only present in some lanes.
        bool runChord = true;
        static if (is(typeof(hooks.chordEnabled)))
            runChord = hooks.chordEnabled;
        if (runChord)
        {
            static if (is(typeof(Hooks.chordDeadline)))
                const chordLimit = Hooks.chordDeadline;
            else
                const chordLimit = 5.seconds;
            hooks.injectChord();
            driveUntil(() => seen.shiftLeftPress && seen.chordedPress
                && seen.chordReleased,
                "the injected key chord never arrived", chordLimit);
            static if (is(typeof(Hooks.expectFocusEvent))
                && Hooks.expectFocusEvent)
                assert(seen.focusGained, "keyboard focus was never reported");
            ++outcome.checked;
        }
        else
            ++outcome.skipped;
    }
    else
        ++outcome.skipped;

    // Property: Event Horizon work still progresses through the backend's
    // single wait — a timer and a foreign-thread waker both land. The timer
    // callback runs on the owner thread inside step(), so no sharing.
    static if (hasStep)
    {
        bool timerFired;
        auto fired = loop.submitAfter(25.msecs, &timerComplete, &timerFired);
        assert(!fired.hasError, "arming the conformance timer failed");
        auto waker = loop.waker().value;
        auto worker = new Thread({
            Thread.sleep(10.msecs);
            waker.wake();
        });
        worker.start();
        driveUntil(() => timerFired,
            "the timer never fired through the shared wait");
        worker.join();
        ++outcome.checked;
    }
    else
        ++outcome.skipped;

    // Property: a native close request surfaces as CloseRequestedEvent and
    // does not destroy the window by itself.
    static if (is(typeof(hooks.requestClose())))
    {
        hooks.requestClose();
        driveUntil(() => seen.closeRequested,
            "no CloseRequestedEvent after the close request");
        assert(!seen.destroyed,
            "a close request must not destroy the window by itself");
        ++outcome.checked;
    }
    else
        ++outcome.skipped;

    // Property: destruction reports DestroyedEvent and the id becomes stale —
    // never reusable, never a crash.
    {
        assert(!wsi.destroyWindow(id).hasError, "destroyWindow failed");
        driveUntil(() => seen.destroyed,
            "no DestroyedEvent after destroyWindow");
        auto stale = wsi.nativeHandles(id);
        assert(stale.hasError && stale.error.kind == WsiErrorKind.staleId,
            "a destroyed window id was not reported stale");
        ++outcome.checked;
    }

    return outcome;
}

private void observeKey(Hooks)(ref Hooks hooks, ref Observed seen,
    in KeyboardEvent event)
{
    static if (is(typeof(Hooks.chordShiftCode)))
    {
        if (event.physical.nativeCode == Hooks.chordShiftCode
            && event.action == KeyAction.press)
        {
            assert(event.location == KeyLocation.left,
                "the left shift key did not report KeyLocation.left");
            seen.shiftLeftPress = true;
        }
        if (event.physical.nativeCode == Hooks.chordKeyCode)
        {
            assert(event.location == KeyLocation.standard,
                "a plain key did not report KeyLocation.standard");
            static if (is(typeof(Hooks.chordKeyCharacter)))
            {
                assert(event.logical.kind == LogicalKeyKind.character,
                    "the chorded key carried no layout-derived character");
                assert(event.logical.character == Hooks.chordKeyCharacter,
                    "the chorded key spelled the wrong unshifted character");
            }
            if (event.action == KeyAction.press)
            {
                seen.chordedPressAnyMods = true;
                static if (is(typeof(Hooks.chordModifierObserved))
                    && !Hooks.chordModifierObserved)
                    seen.chordedPress = true;
                else
                    seen.chordedPress |= event.modifiers.shift;
            }
            else if (event.action == KeyAction.release)
                seen.chordReleased = true;
        }
    }
}

@("wsi.conformance.recordingBackendPassesTheValueContract")
@system
unittest
{
    import sparkles.wsi.loop : RecordingWsi;

    // No step hook: the environmental properties skip and the loop is never
    // touched, so an unopened DefaultLoop value suffices.
    DefaultLoop loop;

    RecordingWsi!() wsi;
    static struct RecordingHooks
    {
        RecordingWsi!()* wsi;
        WindowId id;

        void onWindowReady(WindowId ready) { id = ready; }

        void requestResize(uint width, uint height)
        {
            const metrics = SurfaceMetrics(LogicalSize(width, height),
                PhysicalSize(width, height), ScaleFactor(1));
            assert(!wsi.setMetrics(id, metrics).hasError);
        }

        void requestClose() { assert(!wsi.requestClose(id).hasError); }
    }

    auto hooks = RecordingHooks(&wsi);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi recording conformance");
    assert(outcome.checked == 6 && outcome.skipped == 4);
}
