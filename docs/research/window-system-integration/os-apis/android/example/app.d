// Minimal Android native-activity "window" handler. On Android you do NOT create a
// window: the system creates the Activity's surface and hands you an `ANativeWindow`
// through the `APP_CMD_INIT_WINDOW` event delivered on the `ALooper`. This is the
// irreducible NDK shape that GLFW/SDL/winit's Android backends wrap. The NDK headers
// are bound via ImportC (`c.c`); `android_main` is the entry the `android_native_app_glue`
// runtime calls. See ../index.md (the Android/NDK OS-API survey).
//
// > [!NOTE] Built with the Android NDK (cross-compiled to aarch64-linux-android),
// > packaged as `lib<name>.so` inside an APK with a NativeActivity manifest, and run
// > on a device/emulator. Because LDC ships no prebuilt Android druntime, the runtime
// > must first be built with `ldc-build-runtime` against the NDK. This example is
// > therefore **not auto-verified in CI** (mobile is out of CI scope); the full build
// > + emulator run is documented step-by-step in the survey.
module app;

import c; // ImportC: android_native_app_glue.h + native_window.h + log.h

// Handles lifecycle/window commands posted by the glue onto the looper.
extern (C) void handleCmd(android_app* app, int cmd) nothrow @nogc
{
    switch (cmd)
    {
    case APP_CMD_INIT_WINDOW:
        // The surface is ready: `app.window` is a usable ANativeWindow. A renderer
        // would set up EGL/Vulkan against it here; we just report its geometry.
        if (app.window !is null)
        {
            const w = ANativeWindow_getWidth(app.window);
            const h = ANativeWindow_getHeight(app.window);
            __android_log_print(ANDROID_LOG_INFO, "sparkles",
                "ok: ANativeWindow ready, %dx%d", w, h);
        }
        break;
    case APP_CMD_TERM_WINDOW:
        // The surface is being torn down: release any per-window resources here.
        break;
    default:
        break;
    }
}

// The entry point the native_app_glue runtime invokes (off the main UI thread).
extern (C) void android_main(android_app* app)
{
    app.onAppCmd = &handleCmd;

    // Drain the looper: the glue's source delivers lifecycle + input events; we exit
    // when the system requests destruction.
    int events;
    android_poll_source* source;
    while (true)
    {
        const ident = ALooper_pollOnce(-1, null, &events, cast(void**)&source);
        if (ident == ALOOPER_POLL_ERROR)
            return;
        if (source !is null)
            source.process(app, source);
        if (app.destroyRequested != 0)
            return;
    }
}
