/**
Android driver for the shared WSI conformance suites.

Every assertion lives in `sparkles.wsi.conformance` and
`sparkles.wsi.clipboard_conformance`; this driver supplies the Android step
and the input it injects, and reports to logcat under the tag `sparkles-wsi`,
one `ok:` line per suite, which `scripts/verify-android-emulator.sh` waits for.
It is an APK of its own (`legacyPackages.wsi-android-smoke-apk`), started on
the emulator.

Input comes from outside, as a device's would: the driver logs what it
needs (`inject: chord 1`) and the lane script injects it.
*/
module android_hosted_smoke;

version (Android):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.string : toStringz;

import sparkles.android.ime : commitToImeField;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.wsi;
import sparkles.wsi.platform.android : AndroidWsi, AndroidWsiMain;

private extern (C) int __android_log_write(int priority, const(char)* tag,
    const(char)* message) nothrow @nogc;

mixin AndroidWsiMain!run;

private void say(string line) @trusted
{
    __android_log_write(4, "sparkles-wsi", line.toStringz);
}

/**
Asks the lane script to inject `what`: it watches logcat for `inject:` lines
and serves each once, keys through the emulator console (real scan codes,
trusted, so held keys repeat) and pointers through `adb shell input`. An app
cannot inject into its own window without `INJECT_EVENTS`.
*/
private void request(string what)
{
    __gshared uint serial;
    say(text("inject: ", what, " ", ++serial));
}

private struct ANativeWindowBuffer
{
    int width, height, stride, format;
    void* bits;
    uint[6] reserved;
}

private extern (C) nothrow @nogc
{
    int ANativeWindow_setBuffersGeometry(void* window, int width, int height, int format);
    int ANativeWindow_lock(void* window, ANativeWindowBuffer* buffer, void* dirty);
    int ANativeWindow_unlockAndPost(void* window);
}

/**
Fills the window's surface with one colour and posts it. The smoke has no
renderer, but a surface that never received a buffer has no bounds in the
compositor, and input is routed by those bounds: without a frame, no touch or
pointer event reaches the window.
*/
private void paint(ref AndroidWsi wsi, WindowId id)
{
    auto handles = wsi.nativeHandles(id);
    if (handles.hasError)
        return;
    void* surface;
    handles.value.window.match!(
        (AndroidWindowHandle h) { surface = h.nativeWindow; },
        (_) {});
    if (surface is null)
        return;
    ANativeWindow_setBuffersGeometry(surface, 0, 0, 1); // WINDOW_FORMAT_RGBA_8888
    ANativeWindowBuffer buffer;
    if (ANativeWindow_lock(surface, &buffer, null) != 0)
        return;
    auto pixels = (cast(uint*) buffer.bits)[0 .. cast(size_t) buffer.stride * buffer.height];
    pixels[] = 0xFF30_2010;
    ANativeWindow_unlockAndPost(surface);
}

private struct AndroidHooks
{
    AndroidWsi* wsi;
    DefaultLoop* loop;
    ulong transferBytes;
    // The activity's window is device-sized: the platform owns it, as a
    // kiosk compositor does.
    bool readySizeExact = false;
    bool imeEnabled;

    // Evdev codes, as the emulator's keyboard reports them.
    enum uint chordShiftCode = 42; // KEY_LEFTSHIFT
    enum uint chordKeyCode = 30;   // KEY_A
    enum dchar chordKeyCharacter = 'a';
    enum uint holdKeyCode = 48;    // KEY_B
    enum expectFocusEvent = true;
    enum string imeCommittedText = "héllo";
    // The lane script's injection runs through adb: allow for its latency.
    enum chordDeadline = 20.seconds;

    void step(Duration timeout)
    {
        // A quiet timeout is a legitimate outcome; the suites' deadlines are
        // the failures.
        wsi.runIntegratedOnce(*loop, timeout).value;
    }

    void onWindowReady(WindowId id)
    {
        paint(*wsi, id);
        imeEnabled = !wsi.setTextInput(id, true).hasError;
    }

    void injectChord() { request("chord"); }
    void holdKey() { request("hold"); }
    void releaseHold() { request("release"); }
    void injectClick() { request("click"); }
    void injectScroll() { request("scroll"); }

    void injectImeCommit()
    {
        // An input method's commit, into the field the IME edits; installing
        // the field is asynchronous, so it may not take the first one.
        foreach (_; 0 .. 40)
        {
            if (commitToImeField("héllo"w))
                return;
            step(50.msecs);
        }
        assert(false, "the IME field never accepted a commit");
    }
}

/**
A finger dragged across the window arrives as one contact that begins, moves
and ends. The platform batches a frame's samples into one event, so the moved
events' sample counts add up to every sample delivered, and the history ring
holds them in arrival order (`ED3`).
*/
private void checkTouchDrag(ref AndroidWsi wsi, ref AndroidHooks hooks, WindowId id)
{
    request("drag");
    bool began, ended;
    uint samples, events;
    PointerId contact;
    double lastX = 0;
    PointerSample[64] history;
    size_t kept;
    const deadline = MonoTime.currTime + 20.seconds;
    while (!ended)
    {
        assert(MonoTime.currTime < deadline, "the touch drag never ended");
        hooks.step(50.msecs);
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in TouchEvent e) {
                    final switch (e.phase)
                    {
                        case TouchPhase.began:
                            began = true;
                            contact = e.contact;
                            break;
                        case TouchPhase.moved:
                            assert(began && e.contact == contact,
                                "a contact moved before it began");
                            assert(e.logicalPosition.x >= lastX,
                                "touch samples arrived out of order");
                            lastX = e.logicalPosition.x;
                            samples += e.samples;
                            ++events;
                            // Read during the drain: the ring's newest
                            // samples are this event's.
                            kept = wsi.copySamples(id, contact, history[]);
                            break;
                        case TouchPhase.ended:
                            ended = true;
                            break;
                        case TouchPhase.cancelled:
                            assert(false, "the drag was cancelled");
                    }
                },
                (_) {});
        }).hasError);
    }
    assert(began && events != 0, "the drag never moved");
    const expected = samples < history.length ? samples : history.length;
    assert(kept == expected, text("the history ring holds ", kept,
        " samples of the drag's ", samples));
    foreach (i; 1 .. kept)
        assert(history[i].position.x >= history[i - 1].position.x
            && history[i].timestamp >= history[i - 1].timestamp,
            "the history ring is in arrival order");
    say(text("ok: Android touch drag with history (", samples, " samples in ",
        events, " events)"));
}

/**
Slice 3: the surface's scale and safe insets follow the platform. Under
edge-to-edge layout the system bars inset the surface; turning the display
resizes the surface and moves its insets with the bars; and a density change
rescales the logical size of an unchanged surface. (The soft keyboard's inset
is read the same way, but the emulator's hardware keyboard, which the lane
needs for scan codes, keeps Gboard from showing one.)
*/
private void checkScaleAndInsets(ref AndroidWsi wsi, ref AndroidHooks hooks,
    WindowId id, SurfaceMetrics metrics)
{
    void await(scope bool delegate(in SurfaceMetrics) satisfied, string what)
    {
        const deadline = MonoTime.currTime + 15.seconds;
        while (!satisfied(metrics))
        {
            assert(MonoTime.currTime < deadline, what);
            hooks.step(50.msecs);
            assert(!wsi.drain((WindowEvent event) {
                event.payload.match!(
                    (in SurfaceMetricsChangedEvent e) { metrics = e.metrics; },
                    (_) {});
            }).hasError);
        }
    }

    assert(!wsi.setTextInput(id, false).hasError);
    await((in m) => m.safeInsets.top > 0,
        "the system bars never inset the surface");
    const bars = metrics.safeInsets;
    assert(metrics.safeSize.height < metrics.logicalSize.height,
        "the safe region excludes the bars");

    const portrait = metrics.physicalSize;
    request("landscape");
    await((in m) => m.physicalSize.width == portrait.height
            && m.physicalSize.height == portrait.width,
        "turning the display never resized the surface");
    const landscape = metrics.safeInsets;
    assert(landscape != PhysicalInsets.init, "the bars inset the turned surface");
    request("portrait");
    await((in m) => m.physicalSize == portrait && m.safeInsets == bars,
        "the surface and its insets never turned back");

    const before = metrics;
    request("density");
    await((in m) => m.scale.value == 3,
        "a density change never rescaled the surface");
    assert(metrics.physicalSize == before.physicalSize,
        "a density change kept the surface's pixels");
    assert(metrics.logicalSize.width == metrics.physicalSize.width / 3.0,
        "the logical size follows the new scale");
    request("densityreset");
    await((in m) => m.scale == before.scale, "the density never returned");

    say(text("ok: Android scale and insets (portrait ", bars, ", landscape ",
        landscape, ", scale ", before.scale.value, " -> 3)"));
}

private void run()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError,
        "Event Horizon did not open");
    AndroidWsi wsi;
    assert(!AndroidWsi.open(wsi).hasError, "the Android backend did not open");
    assert(!wsi.attach(loop).hasError, "attaching to Event Horizon failed");

    auto hooks = AndroidHooks(&wsi, &loop);
    const core = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi Android conformance");
    say(text("ok: Android WSI conformance (", core.checked, " checked, ",
        core.skipped, " skipped)"));

    // The remaining checks need a live window: name the activity's again. It
    // kept focus throughout, which Android 10+ requires to read the clip.
    const window = wsi.createWindow(WindowConfig()).value;
    SurfaceMetrics metrics;
    foreach (_; 0 .. 5)
    {
        hooks.step(50.msecs);
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in ReadyEvent e) { metrics = e.metrics; },
                (in SurfaceMetricsChangedEvent e) { metrics = e.metrics; },
                (_) {});
        }).hasError);
    }
    paint(wsi, window);

    checkScaleAndInsets(wsi, hooks, window, metrics);
    checkTouchDrag(wsi, hooks, window);

    // One clip is bounded by a Binder transaction (about 1 MB): 256 KiB of
    // ASCII is 512 KiB as UTF-16, well inside it.
    hooks.transferBytes = 256 * 1024;
    const clip = checkClipboardConformance(wsi, loop, hooks, window);
    say(text("ok: Android clipboard conformance (", clip.checked,
        " checked, 256 KiB round trip)"));

    // `DT5`'s 32 MiB cannot be one clip without a `ContentProvider`: a clip
    // past one Binder transaction fails typed, never silently. 4 MiB is
    // enough to cross it without stressing the emulator's Java heap.
    auto big = PatternProvider(4UL << 20);
    const(char)[][1] plain = ["text/plain;charset=utf-8"];
    const refused = wsi.offerClipboard(window, plain[], big);
    assert(refused.hasError && refused.error.kind == WsiErrorKind.capacity,
        "a 4 MiB clip was not refused with capacity");
    say("ok: Android refuses a 4 MiB clip with capacity (one Binder transaction)");

    say("ok: Android smoke complete");
    assert(!wsi.finishActivity().hasError);
}
