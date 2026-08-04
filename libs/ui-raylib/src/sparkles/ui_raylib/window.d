/**
The window and frame lifecycle behind a named seam (`UIA7`).

An application should not have to name raylib to open a window, ask how big it
is, or start a frame. This module is that boundary: creation and teardown,
size and title, the frame clock, the draw/clear pair, fullscreen, and the small
platform errands (pointer shape, clipboard, screenshot).

$(B Deliberately thin.) It moves calls behind names; it does not invent policy.
The window-system research
($(LINK2 ../../../../docs/research/window-system-integration/index.md, docs/research/window-system-integration))
is designing a replacement for raylib's event loop and windowing, and this seam
exists so that swap does not reach into `apps/hue`. A seam that guessed at a
richer abstraction now would simply be re-cut then.

The one place it does more than rename is $(LREF Window.fullscreenSupported):
a capability the caller can ask about, rather than a manoeuvre that silently
misbehaves where it does not apply.
*/
module sparkles.ui_raylib.window;

import core.stdc.stdarg : va_list;

import raylib;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.ui_raylib.scrollbar : toRaylibCursor;

/**
What the caller wants of a window. Sizes are $(B pixels); a caller thinking in
cells multiplies by its own cell metrics, because this module has no font.

`0` for a dimension means "let the platform decide" — which on Android is the
only correct answer, since the surface size is the device's.
*/
struct WindowRequest
{
    string title;
    int width;             /// pixels; 0 = platform default
    int height;            /// pixels; 0 = platform default
    bool resizable = true;
    int targetFps = 60;
    /// Leave the platform's own "escape quits" binding off, so the
    /// application owns every key. raylib's default is `KEY_ESCAPE`.
    bool platformExitKey = false;
}

/**
The signature raylib hands a log line: level, printf format, varargs.

Re-exported so an application can bridge raylib's chatter into its own logger
without importing raylib for the callback type alone.
*/
alias TraceLogSink = extern (C) void function(int, const(char)*, va_list) @nogc nothrow;

/**
A short tag for the backend's trace-log level.

The numbering is raylib's, so translating it is the seam's job — a consumer
bridging the log into its own should not have to name `TraceLogLevel` (`UIA7`).
*/
string traceLevelTag(int level) @safe pure nothrow @nogc
{
    switch (level)
    {
        case TraceLogLevel.LOG_TRACE:   return "trace";
        case TraceLogLevel.LOG_DEBUG:   return "debug";
        case TraceLogLevel.LOG_INFO:    return "info";
        case TraceLogLevel.LOG_WARNING: return "warning";
        case TraceLogLevel.LOG_ERROR:   return "error";
        case TraceLogLevel.LOG_FATAL:   return "fatal";
        default:                        return "log";
    }
}

/**
Routes the backend's own trace log through `sink`.

Call BEFORE $(LREF Window.open): raylib emits its initialisation chatter during
window creation, and a sink installed afterwards misses exactly the lines worth
having when creation is what failed.
*/
void traceLogTo(TraceLogSink sink) @system => SetTraceLogCallback(sink);

/**
An open window. Construct with $(LREF open); it closes on scope exit.

Non-copyable: two handles to one window would let a stale copy close it.
*/
struct Window
{
    private bool opened;
    // Geometry saved across a fullscreen toggle, so the caller does not carry
    // four ints it has no other use for.
    private int savedX, savedY, savedW, savedH;
    private bool fullscreen_;

    @disable this(this);

    /// Opens the window and installs the requested policy.
    static Window open(in WindowRequest r) @system
    {
        Window w;
        InitWindow(r.width, r.height, r.title.length ? r.title.ptr : "");
        w.opened = true;
        if (r.resizable)
            SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
        if (r.targetFps > 0)
            SetTargetFPS(r.targetFps);
        if (!r.platformExitKey)
            SetExitKey(KeyboardKey.KEY_NULL);
        return w;
    }

    ~this() @system
    {
        if (opened)
            CloseWindow();
    }

    /// The platform asked to close (title-bar button, session end).
    bool shouldClose() const @system => WindowShouldClose();

    /// Current surface size in pixels.
    int width() const @system => GetScreenWidth();
    /// ditto
    int height() const @system => GetScreenHeight();

    /// Seconds the last frame took — the frame clock every animation reads.
    float frameSeconds() const @system => GetFrameTime();

    /// Retitles the window. `title` must be NUL-terminated.
    void title(scope const(char)* title) @system => SetWindowTitle(title);

    /// Resizes the window (pixels).
    void resize(int w, int h) @system => SetWindowSize(w, h);

    /// Opens the frame. Pair with $(LREF endFrame).
    void beginFrame() @system => BeginDrawing();

    /// Closes the frame and presents it.
    void endFrame() @system => EndDrawing();

    /**
    Drops any clip region still in force.

    The GL scissor is global state that survives a buffer swap, so a clip
    leaked from any earlier path would silently crop the next frame's clear.
    Callers reset at both ends of a frame rather than trusting every path in
    between to balance.
    */
    void resetClip() @system => EndScissorMode();

    /// Fills the whole surface.
    void clear(RgbColor c) @system => ClearBackground(Color(c.r, c.g, c.b, 255));

    /// The pointer shape the application wants right now.
    void pointerShape(PointerShape s) @system => SetMouseCursor(toRaylibCursor(s));

    /// Puts `text` (NUL-terminated) on the system clipboard.
    void clipboard(scope const(char)* text) @system => SetClipboardText(text);

    /**
    Writes the surface to `path` (NUL-terminated).

    $(B The path is resolved against the working directory), and an absolute
    one silently writes nothing — a trap worth knowing before trusting a
    capture that appeared to succeed.
    */
    void screenshot(scope const(char)* path) @system => TakeScreenshot(path);

    /**
    Whether this target has a fullscreen concept the toggle below can serve.

    `false` on Android, where the surface already IS the screen: the
    undecorate / reposition / resize dance has nothing to act on, and running
    it there was a live defect before this became a question a caller could
    ask. Report the capability; do not gate on the platform at every call site.
    */
    bool fullscreenSupported() const @system
    {
        version (Android)
            return false;
        else
            return true;
    }

    /// `true` while the window is in the borderless-fullscreen state.
    bool isFullscreen() const @system => fullscreen_;

    /**
    Toggles borderless fullscreen, remembering the windowed geometry.

    Manual rather than raylib's `ToggleBorderlessWindowed`, which forces the
    primary monitor and, on some compositors, loses the decorations on the way
    back. A no-op where $(LREF fullscreenSupported) is `false`.
    */
    void toggleFullscreen() @system
    {
        if (!fullscreenSupported)
            return;
        if (!fullscreen_)
        {
            const wp = GetWindowPosition();
            savedX = cast(int) wp.x;
            savedY = cast(int) wp.y;
            savedW = GetScreenWidth();
            savedH = GetScreenHeight();
            const mon = GetCurrentMonitor();
            const mp = GetMonitorPosition(mon);
            SetWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED);
            SetWindowPosition(cast(int) mp.x, cast(int) mp.y);
            SetWindowSize(GetMonitorWidth(mon), GetMonitorHeight(mon));
            fullscreen_ = true;
        }
        else
        {
            ClearWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED);
            SetWindowSize(savedW, savedH);
            SetWindowPosition(savedX, savedY);
            fullscreen_ = false;
        }
    }
}
