#!/usr/bin/env dub
/+ dub.sdl:
    name "wsi-x11-clipboard-probe"
    dependency "sparkles:wsi" path="../../.."
    platforms "linux"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: build-only
// (it needs a private X server: run it under `xvfb-run`.)
/** Run native clipboard streaming and cancellation checks on a private X11 server. */
module x11_clipboard_probe;

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.stdio : writeln;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.wsi : checkClipboardConformance, PatternProvider, PatternSink,
    TransferStatus, WindowConfig, WindowEvent, X11Wsi;

int main() @system
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);
    X11Wsi wsi;
    assert(!X11Wsi.open(wsi).hasError, "Run this probe under xvfb-run.");
    scope (exit) wsi.close();
    assert(!wsi.attach(loop).hasError);
    WindowConfig config;
    assert(config.title.assign("sparkles:wsi clipboard probe"));
    const window = wsi.createWindow(config).value;
    struct Hooks
    {
        X11Wsi* wsi;
        DefaultLoop* loop;
        ulong transferBytes = 32UL << 20;
        enum size_t maxChunkBytes = X11Wsi.clipChunkBytes;
        void step(Duration timeout) @system
        {
            const result = wsi.runIntegratedOnce(*loop, timeout);
            assert(!result.hasError, text(result.error));
        }
    }
    auto hooks = Hooks(&wsi, &loop);
    const outcome = checkClipboardConformance(wsi, loop, hooks, window);
    assert(outcome.checked == 4);
    writeln("ok: four native clipboard checks, including 32 MiB INCR streaming");

    auto provider = PatternProvider(128);
    const(char)[][1] types = ["text/plain;charset=utf-8"];
    const offer = wsi.offerClipboard(window, types[], provider).value;
    scope (exit) wsi.withdrawClipboard(offer);
    PatternSink[9] cancelled;
    foreach (ref sink; cancelled)
    {
        const read = wsi.receive(offer, types[0], sink).value;
        assert(!wsi.cancelTransfer(read).hasError);
    }
    PatternSink current;
    wsi.receive(offer, types[0], current).value;
    const deadline = MonoTime.currTime + 5.seconds;
    while (!current.finishes && MonoTime.currTime < deadline)
    {
        hooks.step(50.msecs);
        assert(!wsi.drain((WindowEvent _) {}).hasError);
    }
    assert(current.finishes == 1 && current.status == TransferStatus.completed
        && current.received == 128 && !current.mismatch,
        text("Current transfer: finishes=", current.finishes, ", status=", current.status,
            ", bytes=", current.received, ", mismatch=", current.mismatch));
    foreach (_; 0 .. 3)
    {
        hooks.step(50.msecs);
        assert(!wsi.drain((WindowEvent _) {}).hasError);
    }
    foreach (ref sink; cancelled)
        assert(sink.received == 0 && sink.finishes == 1 && sink.status == TransferStatus.cancelled);
    writeln("ok: cancelled requestors cannot exhaust or corrupt a later own-clipboard read");
    return 0;
}
