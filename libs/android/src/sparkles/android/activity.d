/**
The NativeActivity handle: hand-declared mirrors of the stable head of
`android_app`/`ANativeActivity`, and the process constants read from it.

ImportC cannot parse `android_native_app_glue.h` (its kernel-header closure
trips on `__int128`/`__alignof__`), and only these leading fields are touched,
so they are mirrored here instead. `GetAndroidApp()` is defined by raylib's
`rcore_android.c` (not bound by raylib-d) and is valid from `android_main` on.
*/
module sparkles.android.activity;

version (Android):

import std.string : fromStringz;

/// The leading fields of `<android/native_activity.h>`'s `ANativeActivity`;
/// the tail is never touched.
struct ANativeActivity
{
    void* callbacks;
    void* vm; /// `JavaVM*`
    void* env; /// `JNIEnv*` of the activity's main (Java UI) thread — not ours
    void* clazz; /// the `NativeActivity` Java object
    const(char)* internalDataPath;
    const(char)* externalDataPath;
    int sdkVersion;
    void* instance;
    void* assetManager; /// `AAssetManager*`
    const(char)* obbPath;
}

/// `<android/rect.h>`'s `ARect`, in window pixels.
struct ARect
{
    int left, top, right, bottom;
}

/// The leading fields of native_app_glue's `android_app` (NDK r28 layout,
/// unchanged since the glue's introduction); the tail is never touched.
struct AndroidApp
{
    void* userData;
    void* onAppCmd; /// `void function(android_app*, int)`
    void* onInputEvent; /// `int function(android_app*, AInputEvent*)`
    ANativeActivity* activity;
    void* config;
    void* savedState;
    size_t savedStateSize;
    void* looper;
    void* inputQueue;
    void* window; /// `ANativeWindow*`; null while the activity has no surface
    ARect contentRect; /// the window area not covered by system UI or the IME
    int activityState;
    int destroyRequested;
}

/// Defined by raylib's rcore_android.c; set before it calls our `main()`.
extern (C) AndroidApp* GetAndroidApp() @nogc nothrow;

/// The activity; valid for the process lifetime (the process exits with it).
ANativeActivity* nativeActivity() @trusted nothrow @nogc => GetAndroidApp().activity;

/**
The app's private data directory (`ANativeActivity.internalDataPath`,
`/data/user/0/<package>/files`) — where an asset bundle is materialized and
all writable state lives.

Resolved once, into `immutable`, by the module constructor below. The ordering
it depends on is exact: raylib's `android_main` sets `platform.app` and only
then calls `main()`, and LDC's generated C `main` enters `_d_run_main`, which
runs `rt_init` — and therefore every module constructor — before the D `main`
body. A null path reads as `""`, which every derived path treats as unusable.
*/
private immutable string internalDataPathValue;

/// ditto
private immutable string externalDataPathValue;

/// ditto
private immutable int sdkVersionValue;

shared static this() @trusted
{
    auto a = GetAndroidApp().activity;
    internalDataPathValue = a.internalDataPath.fromStringz.idup;
    externalDataPathValue = a.externalDataPath.fromStringz.idup;
    sdkVersionValue = a.sdkVersion;
}

/// See $(LREF internalDataPathValue).
string internalDataPath() @safe nothrow @nogc => internalDataPathValue;

/// The app-specific external directory (`/sdcard/Android/data/<package>/files`);
/// may be empty when no shared storage is mounted.
string externalDataPath() @safe nothrow @nogc => externalDataPathValue;

/// The device's API level (`Build.VERSION.SDK_INT`).
int sdkVersion() @safe nothrow @nogc => sdkVersionValue;

/**
Whether the activity currently has a native window to draw into. `false`
between `APP_CMD_TERM_WINDOW` and the next `APP_CMD_INIT_WINDOW` — the app is
stopped (in the background, the screen off) and any EGL swap would fail.
*/
bool hasNativeWindow() @trusted nothrow @nogc => GetAndroidApp().window !is null;

/**
The part of the window the app's content may use, in pixels: the window minus
what the system decorations and the soft keyboard cover, as the framework last
reported it (`APP_CMD_CONTENT_RECT_CHANGED`). Empty before the first report.
*/
ARect contentRect() @trusted nothrow @nogc => GetAndroidApp().contentRect;
