/**
The M1 Android smoke test: a raylib clear-color + text loop that logs to
logcat. It exists to prove the port's risky spine on a device before any hue
code rides on it — the static druntime living inside `libhello.so` (GC, TLS,
module ctors under bionic), raylib's `android_main()` → this module's D
`main()` handoff, EGL/GLES2 bring-up, and the nix APK pipeline.

Built by `nix build .#hello-apk` (see nix/packages/android/hello.nix); not part
of any dub configuration.
*/
module main;

import raylib;

/// logcat is the only visible output in a NativeActivity (stdout/stderr go
/// nowhere); tag "hue" matches the port's logcat filter convention.
extern (C) int __android_log_print(int prio, const(char)* tag, const(char)* fmt, ...)
    nothrow @nogc;

private enum androidLogInfo = 4;

void main()
{
    __android_log_print(androidLogInfo, "hue", "hello: main() entered — druntime is up");

    // Exercise the GC + Phobos early, so a broken runtime fails loudly here
    // rather than mid-frame.
    import std.format : format;

    auto probe = format("gc/phobos probe: %s", [1, 2, 3]);
    __android_log_print(androidLogInfo, "hue", "hello: %.*s",
        cast(int) probe.length, probe.ptr);

    // 0×0 on Android = the native surface resolution. A non-zero size is NOT
    // ignored: raylib letterboxes that logical size onto the screen (content
    // scaled into a box, GetScreenWidth reporting the requested size).
    InitWindow(0, 0, "hue hello");
    scope (exit) CloseWindow();
    SetTargetFPS(60);

    __android_log_print(androidLogInfo, "hue", "hello: window up, %dx%d",
        GetScreenWidth(), GetScreenHeight());

    int frames;
    while (!WindowShouldClose())
    {
        BeginDrawing();
        ClearBackground(Color(30, 30, 46, 255));
        DrawText("hue: hello from D", 60, 120, 60, Color(205, 214, 244, 255));
        DrawFPS(60, 220);
        EndDrawing();

        if (++frames % 300 == 0)
            __android_log_print(androidLogInfo, "hue", "hello: %d frames, %dx%d",
                frames, GetScreenWidth(), GetScreenHeight());
    }

    __android_log_print(androidLogInfo, "hue", "hello: exiting after %d frames", frames);
}
