/**
Android driver for the shared WSI conformance suites.

Every assertion lives in `sparkles.wsi.conformance` and
`sparkles.wsi.clipboard_conformance`; this driver supplies the Android step
and reports to logcat under the tag `sparkles-wsi`, one `ok:` line per suite,
which `scripts/verify-android-emulator.sh` waits for. It is an APK of its own
(`legacyPackages.wsi-android-smoke-apk`), started on the emulator.
*/
module android_hosted_smoke;

version (Android):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.string : toStringz;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.wsi;
import sparkles.wsi.platform.android : AndroidWsi, AndroidWsiMain;

private extern (C) int __android_log_write(int priority, const(char)* tag,
    const(char)* message) nothrow @nogc;

mixin AndroidWsiMain!run;

private void say(string line)
{
    __android_log_write(4, "sparkles-wsi", line.toStringz);
}

private struct AndroidHooks
{
    AndroidWsi* wsi;
    DefaultLoop* loop;
    ulong transferBytes;
    // The activity's window is device-sized: the platform owns it, as a
    // kiosk compositor does.
    bool readySizeExact = false;

    void step(Duration timeout)
    {
        // A quiet timeout is a legitimate outcome; the suites' deadlines are
        // the failures.
        wsi.runIntegratedOnce(*loop, timeout).value;
    }
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

    // The clipboard suite needs a live window: name the activity's again. It
    // kept focus throughout, which Android 10+ requires to read the clip.
    const window = wsi.createWindow(WindowConfig()).value;
    foreach (_; 0 .. 5)
        hooks.step(50.msecs);
    assert(!wsi.drain((WindowEvent event) {}).hasError);

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
