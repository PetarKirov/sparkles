#!/usr/bin/env dub
/+ dub.sdl:
    name "wsi_input_echo"
    dependency "sparkles:wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "expected" version="~>0.4.1"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help? no — interactive; the flake builds it, humans run it.
/**
Interactive `sparkles:wsi` event echo — the UAT program for the native
window stack. Opens one window on the platform's native backend (Wayland
when `$WAYLAND_DISPLAY` is set, X11 otherwise, AppKit on macOS) and prints
every event the backend queues, one per line.

Things to try:
$(LIST
    * hold a key — `repeat` actions (client-synthesized on Wayland);
    * type through your IME — `TextCommitted` and `Composition` lines
        (text-input-v3 on a v3 compositor such as Mutter; XIM through
        `$XMODIFIERS` on X11; `NSTextInputClient` on macOS);
    * scroll, click, and drag — pointer and scroll lines with the shared
        sign convention;
    * drag near a window edge on Wayland — the compositor takes over as an
        interactive resize (GNOME draws no server decorations, so this is
        the only way a bare toplevel resizes there); hold Alt and drag
        anywhere to move the window;
    * press `c` to cycle the standard cursor shapes, `m` to toggle
        maximize, `q` to quit.
)
*/
module wsi_input_echo;

import core.time : Duration, msecs;
import std.stdio : stdout, writefln, writeln;
import std.traits : EnumMembers;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi;

/// How close to a border a press must land to count as a resize grip.
private enum double gripSize = 16;

private string modsText(in Mods mods)
{
    string text;
    if (mods.ctrl) text ~= "ctrl+";
    if (mods.alt) text ~= "alt+";
    if (mods.shift) text ~= "shift+";
    if (mods.super_) text ~= "super+";
    return text.length ? text[0 .. $ - 1] : "-";
}

private string logicalText(in LogicalKey logical)
{
    import std.conv : text;

    final switch (logical.kind)
    {
        case LogicalKeyKind.unknown:
            return "?";
        case LogicalKeyKind.character:
            return text('\'', logical.character, '\'');
        case LogicalKeyKind.named:
            return text("named:0x", logical.nativeCode);
    }
}

private struct EchoState
{
    WindowId id;
    SurfaceMetrics metrics;
    size_t cursorIndex;
    bool repaint;
    bool quit;
}

private void echoLoop(Backend)(ref Backend wsi, ref DefaultLoop loop,
    ref EchoState state)
{
    void handle(WindowEvent event)
    {
        event.payload.match!(
            (in ReadyEvent value) {
                state.metrics = value.metrics;
                writefln("#%s ready       %s×%s logical, %s×%s physical, ×%s",
                    event.sequence, value.metrics.logicalSize.width,
                    value.metrics.logicalSize.height,
                    value.metrics.physicalSize.width,
                    value.metrics.physicalSize.height,
                    value.metrics.scale.value);
                state.repaint = true;
            },
            (in SurfaceMetricsChangedEvent value) {
                state.metrics = value.metrics;
                state.repaint = true;
                writefln("#%s metrics     %s×%s logical, %s×%s physical, ×%s",
                    event.sequence, value.metrics.logicalSize.width,
                    value.metrics.logicalSize.height,
                    value.metrics.physicalSize.width,
                    value.metrics.physicalSize.height,
                    value.metrics.scale.value);
            },
            (in KeyboardEvent value) {
                writefln("#%s key %-7s physical=%s logical=%s loc=%s mods=%s",
                    event.sequence, value.action, value.physical.nativeCode,
                    logicalText(value.logical), value.location,
                    modsText(value.modifiers));
                if (value.action != KeyAction.release)
                    return;
                if (value.logical.kind == LogicalKeyKind.character)
                    handleCommand(wsi, state, value.logical.character);
            },
            (in TextCommittedEvent value) {
                writefln("#%s text        \"%s\"", event.sequence,
                    value.text.value);
            },
            (in CompositionEvent value) {
                writefln("#%s composition \"%s\" cursor=%s selection=%s+%s segments=%s",
                    event.sequence, value.preedit.value, value.cursor,
                    value.selectionStart, value.selectionLength,
                    value.segmentCount);
            },
            (in PointerEvent value) {
                writefln("#%s pointer %-8s button=%s at %s,%s mods=%s",
                    event.sequence, value.phase, value.button,
                    value.logicalPosition.x, value.logicalPosition.y,
                    modsText(value.modifiers));
                if (value.phase == PointerPhase.pressed
                    && value.button == PointerButton.left)
                    handleLeftPress(wsi, state, value);
            },
            (in ScrollEvent value) {
                writefln("#%s scroll      d=%s,%s discrete=%s,%s source=%s",
                    event.sequence, value.dx, value.dy, value.discreteX,
                    value.discreteY, value.source);
            },
            (in FocusChangedEvent value) {
                writefln("#%s focus       %s", event.sequence,
                    value.focused ? "gained" : "lost");
            },
            (in CloseRequestedEvent _) {
                writefln("#%s close requested — quitting", event.sequence);
                state.quit = true;
            },
            (in DestroyedEvent _) {
                writefln("#%s destroyed", event.sequence);
                state.quit = true;
            },
            (other) {
                writefln("#%s %s", event.sequence,
                    typeof(other).stringof);
            });
    }

    // The queue's drain wants a @safe sink; collect first, then let the
    // handlers do their platform-native (system) work outside it.
    WindowEvent[128] batch;
    size_t batched;
    while (!state.quit)
    {
        static if (is(typeof(wsi.runIntegratedOnce(loop, Duration.init))))
            auto ticked = wsi.runIntegratedOnce(loop, 250.msecs);
        else
            auto ticked = loop.runHostedOnce(wsi, 250.msecs);
        if (ticked.hasError)
        {
            writefln("loop error: %s (errno=%s stage=%s)",
                ticked.error.context, ticked.error.errnoValue,
                ticked.error.stage);
            // The backend's sticky diagnostic names the original failure.
            auto sticky = wsi.drain((WindowEvent _) @safe {});
            if (sticky.hasError)
                writefln("backend diagnostic: %s (kind=%s native=%s)",
                    sticky.error.diagnostic.value, sticky.error.kind,
                    sticky.error.nativeCode);
            return;
        }
        batched = 0;
        auto drained = wsi.drain((WindowEvent event) @safe {
            if (batched < batch.length)
                // The generated sum-type assignment is @system; copying a
                // queued event into a local buffer is the one trusted op.
                () @trusted { batch[batched++] = event; }();
        });
        if (drained.hasError)
        {
            writeln("event queue error: ", drained.error.diagnostic.value);
            break;
        }
        foreach (ref event; batch[0 .. batched])
            handle(event);
        // Paint once per drained batch, not per metrics event: a resize
        // drag floods configures, and a per-event repaint would spend the
        // whole flood painting sizes nobody will ever see again.
        if (state.repaint)
        {
            state.repaint = false;
            paintIfNeeded(wsi, state);
        }
        if (batched != 0)
            stdout.flush(); // stay line-visible when piped through tee
    }
}

private void handleCommand(Backend)(ref Backend wsi, ref EchoState state,
    dchar command)
{
    switch (command)
    {
        case 'q':
            writeln("quit");
            state.quit = true;
            break;
        case 'c':
            static immutable shapes = [EnumMembers!PointerShape];
            state.cursorIndex = (state.cursorIndex + 1) % shapes.length;
            const shape = shapes[state.cursorIndex];
            auto set = wsi.setCursor(state.id, shape);
            writefln("setCursor(%s): %s", shape,
                set.hasError ? cast(string) set.error.diagnostic.value : "ok");
            break;
        case 'm':
            static if (is(typeof(wsi.setMaximized(state.id, true))))
            {
                static bool maximized;
                maximized = !maximized;
                auto result = wsi.setMaximized(state.id, maximized);
                writefln("setMaximized(%s): %s", maximized,
                    result.hasError
                        ? cast(string) result.error.diagnostic.value : "ok");
            }
            else
                writeln("setMaximized: not available on this backend");
            break;
        default:
            break;
    }
}

private void handleLeftPress(Backend)(ref Backend wsi, ref EchoState state,
    in PointerEvent value)
{
    static if (is(typeof(wsi.startInteractiveResize(state.id,
        ResizeEdge.none))))
    {
        if (value.modifiers.alt)
        {
            auto moved = wsi.startInteractiveMove(state.id);
            writefln("startInteractiveMove: %s", moved.hasError
                ? cast(string) moved.error.diagnostic.value : "ok");
            return;
        }
        const edge = resizeEdgeAt(state.metrics, value.logicalPosition.x,
            value.logicalPosition.y);
        if (edge == ResizeEdge.none)
            return;
        auto resized = wsi.startInteractiveResize(state.id, edge);
        writefln("startInteractiveResize(%s): %s", edge, resized.hasError
            ? cast(string) resized.error.diagnostic.value : "ok");
    }
}

// Painting exists only where an unmapped surface would stay invisible:
// a Wayland toplevel maps when a buffer is committed, while X11 windows
// paint their background pixel and AppKit windows draw their own chrome.
version (linux)
{
    import core.sys.posix.stdlib : mkstemp;
    import core.sys.posix.unistd : posixClose = close, ftruncate, unlink;

    import wayland_native;

    private struct ShmGlobal
    {
        wl_shm* shm;
    }

    private extern (C) void onShmGlobal(void* data, wl_registry* registry,
        uint name, const(char)* interfaceName, uint) nothrow @nogc
    {
        import core.stdc.string : strcmp;

        auto probe = cast(ShmGlobal*) data;
        if (strcmp(interfaceName, wl_shm_interface.name) == 0
            && probe.shm is null)
            probe.shm = cast(wl_shm*) wl_registry_bind(registry, name,
                &wl_shm_interface, 1);
    }

    private extern (C) void onShmGlobalRemove(void*, wl_registry*, uint)
        nothrow @nogc
    {
    }

    private immutable wl_registry_listener shmListener = {
        &onShmGlobal, &onShmGlobalRemove
    };

    /*
    Fills the surface with a flat color and brighter `gripSize` borders —
    the visible affordance for the compositor-resize zones. One buffer per
    paint; the previous one is destroyed on the next call, when the
    compositor has long since attached its replacement.
    */
    private struct WaylandPainter
    {
        wl_shm* shm;
        wl_buffer* previous;

        bool bind(wl_display* display)
        {
            ShmGlobal probe;
            auto registry = wl_display_get_registry(display);
            if (registry is null)
                return false;
            scope (exit) wl_proxy_destroy(cast(wl_proxy*) registry);
            if (wl_registry_add_listener(registry,
                    cast(wl_registry_listener*) &shmListener, &probe) != 0
                || wl_display_roundtrip(display) < 0)
                return false;
            shm = probe.shm;
            return shm !is null;
        }

        bool paint(wl_display* display, wl_surface* surface, int width,
            int height)
        {
            import core.sys.posix.sys.mman : MAP_FAILED, MAP_SHARED,
                PROT_READ, PROT_WRITE, mmap, munmap;

            if (shm is null || width <= 0 || height <= 0)
                return false;
            char[26] path = "/tmp/wsi-echo-shm-XXXXXX\0\0";
            const fd = mkstemp(path.ptr);
            if (fd < 0)
                return false;
            scope (exit) posixClose(fd);
            unlink(path.ptr);
            const stride = width * 4;
            const size = stride * height;
            if (ftruncate(fd, size) != 0)
                return false;
            auto pixels = mmap(null, size, PROT_READ | PROT_WRITE,
                MAP_SHARED, fd, 0);
            if (pixels is MAP_FAILED)
                return false;
            auto view = (cast(uint*) pixels)[0 .. width * height];
            foreach (y; 0 .. height)
                foreach (x; 0 .. width)
                {
                    const grip = x < gripSize || y < gripSize
                        || x >= width - gripSize || y >= height - gripSize;
                    view[y * width + x] = grip ? 0xFF3A6EA5 : 0xFF20242C;
                }
            munmap(pixels, size);

            auto pool = wl_shm_create_pool(shm, fd, size);
            if (pool is null)
                return false;
            scope (exit) wl_shm_pool_destroy(pool);
            auto buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
                stride, WL_SHM_FORMAT_XRGB8888);
            if (buffer is null)
                return false;
            wl_surface_attach(surface, buffer, 0, 0);
            wl_surface_damage(surface, 0, 0, width, height);
            wl_surface_commit(surface);
            if (previous !is null)
                wl_buffer_destroy(previous);
            previous = buffer;
            return wl_display_flush(display) >= 0;
        }
    }

    private WaylandPainter painter;

    private void paintIfNeeded(Backend)(ref Backend wsi, ref EchoState state)
    {
        static if (is(Backend == WaylandWsi))
        {
            if (state.metrics.suspended)
                return;
            auto queried = wsi.nativeHandles(state.id);
            if (queried.hasError)
                return;
            auto handles = queried.value;
            auto display = handles.display.match!(
                (in WaylandDisplayHandle handle)
                    => cast(wl_display*) handle.display,
                (_) => null);
            auto surface = handles.window.match!(
                (in WaylandWindowHandle handle)
                    => cast(wl_surface*) handle.surface,
                (_) => null);
            if (display is null || surface is null)
                return;
            assert(!wsi.beginNativeIo().hasError);
            scope (exit) assert(!wsi.endNativeIo().hasError);
            if (painter.shm is null && !painter.bind(display))
                return;
            painter.paint(display, surface,
                cast(int) state.metrics.logicalSize.width,
                cast(int) state.metrics.logicalSize.height);
        }
    }
}
else
{
    private void paintIfNeeded(Backend)(ref Backend, ref EchoState)
    {
    }
}

private int runBackend(Backend)(ref Backend wsi, ref DefaultLoop loop,
    string name)
{
    WindowConfig config;
    assert(config.title.assign("sparkles wsi-input-echo"));
    config.logicalSize = LogicalSize(720, 420);
    auto created = wsi.createWindow(config);
    if (created.hasError)
    {
        writeln("createWindow failed: ",
            created.error.diagnostic.value);
        return 1;
    }
    EchoState state;
    state.id = created.value;
    writefln("wsi-input-echo on %s — hold keys, type through your IME, " ~
        "scroll, drag the blue border to resize, alt+drag to move, " ~
        "c cycles cursors, m toggles maximize, q quits", name);
    stdout.flush();
    // Drain the ready event before the first paint so metrics are real.
    auto drained = wsi.drain((WindowEvent event) @safe {
        event.payload.match!(
            (in ReadyEvent value) { state.metrics = value.metrics; },
            (_) {});
    });
    assert(!drained.hasError);
    // On Wayland the ready event follows the first configure, later in the
    // loop; painting waits for real metrics either way.
    if (!state.metrics.suspended)
        paintIfNeeded(wsi, state);
    echoLoop(wsi, loop, state);
    return 0;
}

int main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    version (OSX)
    {
        AppKitWsi wsi;
        auto opened = AppKitWsi.open(wsi);
        if (opened.hasError)
        {
            writeln("AppKit open failed: ", opened.error.diagnostic.value);
            return 1;
        }
        return runBackend(wsi, loop, "AppKit");
    }
    else version (linux)
    {
        import core.stdc.stdlib : getenv;

        if (getenv("WAYLAND_DISPLAY") !is null)
        {
            WaylandWsi wsi;
            auto opened = WaylandWsi.open(wsi, loop);
            if (opened.hasError)
            {
                writeln("Wayland open failed: ",
                    opened.error.diagnostic.value);
                return 1;
            }
            // Registry bootstrap completes asynchronously.
            while (!wsi.bootstrapComplete)
                wsi.runIntegratedOnce(loop, 100.msecs).value;
            return runBackend(wsi, loop, "Wayland");
        }
        X11Wsi wsi;
        auto opened = X11Wsi.open(wsi);
        if (opened.hasError)
        {
            writeln("X11 open failed: ", opened.error.diagnostic.value);
            return 1;
        }
        auto attached = wsi.attach(loop);
        if (attached.hasError)
        {
            writeln("X11 attach failed: ", attached.error.diagnostic.value);
            return 1;
        }
        return runBackend(wsi, loop, "X11");
    }
    else
    {
        writeln("no native backend for this platform yet");
        return 1;
    }
}
