/**
The window's density and the insets around its content, read through JNI.

Two NDK sources go stale or say too little. The activity's `AAssetManager`
keeps the configuration it was created with, so its density misses a density
change the activity handles itself. And `onContentRectChanged` reports the
content view's frame, which for an app targeting API 35 or later (edge-to-edge
layout) is the whole window: the soft keyboard and the system bars never
shrink it. The framework's own answers are `DisplayMetrics.density` and the
decor view's root `WindowInsets`.

Both are round trips to the JNI worker ($(MREF sparkles,android,jni)): read
them when something may have changed, not every frame.
*/
module sparkles.android.window_metrics;

version (Android):

import sparkles.android.jni;

/// Physical pixels at each edge: left, top, right, bottom.
alias EdgePixels = int[4];

/// What the window's root insets cover.
struct WindowInsetsReading
{
    bool known;          /// `false` when the view is not attached yet
    EdgePixels bars;     /// system bars and a display cutout
    EdgePixels keyboard; /// the soft keyboard; zero while it is hidden
}

private extern (C) int android_get_device_api_level() nothrow @nogc;

/// `getResources().getDisplayMetrics().density`: pixels per dp, or `0` when
/// it could not be read.
float displayDensity() @trusted nothrow
{
    return withJni((ref JniFrame f) {
        auto resources = f.callObject(f.activity, "getResources",
            "()Landroid/content/res/Resources;");
        auto metrics = f.callObject(resources, "getDisplayMetrics",
            "()Landroid/util/DisplayMetrics;");
        if (metrics is null)
            return 0.0f;
        auto env = f.env;
        auto field = (*env).GetFieldID(env, (*env).GetObjectClass(env, metrics),
            "density", "F");
        return field is null ? 0.0f : (*env).GetFloatField(env, metrics, field);
    });
}

/**
The decor view's root insets: `getInsets(systemBars() | displayCutout())` and
`getInsets(ime())` from API 30, `getSystemWindowInsets()` before it, when the
keyboard is not reported separately.
*/
WindowInsetsReading windowInsets() @trusted nothrow
{
    return withJni((ref JniFrame f) {
        WindowInsetsReading reading;
        auto window = f.callObject(f.activity, "getWindow", "()Landroid/view/Window;");
        auto decor = f.callObject(window, "getDecorView", "()Landroid/view/View;");
        auto insets = f.callObject(decor, "getRootWindowInsets",
            "()Landroid/view/WindowInsets;");
        if (insets is null)
            return reading;
        if (android_get_device_api_level() >= 30)
        {
            // WindowInsets.Type: STATUS_BARS | NAVIGATION_BARS | CAPTION_BAR
            // (systemBars()), DISPLAY_CUTOUT, IME.
            enum int systemBars = 0x1 | 0x2 | 0x4, cutout = 0x80, ime = 0x8;
            if (!edges(f, insets, systemBars | cutout, reading.bars)
                || !edges(f, insets, ime, reading.keyboard))
                return reading;
        }
        else
        {
            reading.bars[0] = f.callInt(insets, "getSystemWindowInsetLeft", "()I");
            reading.bars[1] = f.callInt(insets, "getSystemWindowInsetTop", "()I");
            reading.bars[2] = f.callInt(insets, "getSystemWindowInsetRight", "()I");
            reading.bars[3] = f.callInt(insets, "getSystemWindowInsetBottom", "()I");
            if (f.failed)
                return reading;
        }
        reading.known = true;
        return reading;
    });
}

// `insets.getInsets(types)` as left, top, right, bottom.
private bool edges(ref JniFrame f, jobject insets, int types, ref EdgePixels into)
    @trusted nothrow @nogc
{
    jvalue[1] a = [jv(types)];
    auto value = f.callObject(insets, "getInsets", "(I)Landroid/graphics/Insets;", a[]);
    if (value is null)
        return false;
    auto env = f.env;
    auto cls = (*env).GetObjectClass(env, value);
    static immutable const(char)*[4] names = ["left", "top", "right", "bottom"];
    foreach (i, name; names)
    {
        auto field = (*env).GetFieldID(env, cls, name, "I");
        if (field is null)
            return false;
        into[i] = (*env).GetIntField(env, value, field);
    }
    return !f.failed;
}

/**
Lays the activity's window out edge to edge, asynchronously on the main
thread: into a display cutout on every edge (`LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS`,
`SHORT_EDGES` before API 30) and, from API 30, behind the system bars
(`setDecorFitsSystemWindows(false)`). The window then covers the whole panel
and what covers it arrives as insets ($(LREF windowInsets)). `false` when the
main thread is not wired.
*/
bool layOutEdgeToEdge() @trusted nothrow @nogc
{
    import sparkles.android.main_thread : postToMainThread;

    return postToMainThread(&edgeToEdgeJob, null);
}

private void edgeToEdgeJob(JNIEnv* env, void*) nothrow @nogc
{
    import sparkles.android.activity : nativeActivity;

    const api = android_get_device_api_level();
    if (api < 28)
        return;
    auto activity = cast(jobject) nativeActivity().clazz;
    jobject call(jobject o, const(char)* name, const(char)* sig)
    {
        auto m = (*env).GetMethodID(env, (*env).GetObjectClass(env, o), name, sig);
        return m is null ? null : (*env).CallObjectMethodA(env, o, m, null);
    }
    auto window = call(activity, "getWindow", "()Landroid/view/Window;");
    if (window is null)
        return;
    auto attributes = call(window, "getAttributes", "()Landroid/view/WindowManager$LayoutParams;");
    if (attributes is null)
        return;
    auto mode = (*env).GetFieldID(env, (*env).GetObjectClass(env, attributes),
        "layoutInDisplayCutoutMode", "I");
    if (mode !is null)
        (*env).SetIntField(env, attributes, mode, api >= 30 ? 3 : 1);
    auto set = (*env).GetMethodID(env, (*env).GetObjectClass(env, window),
        "setAttributes", "(Landroid/view/WindowManager$LayoutParams;)V");
    jvalue[1] a;
    a[0].l = attributes;
    if (set !is null)
        (*env).CallVoidMethodA(env, window, set, a.ptr);
    if (api >= 30)
    {
        auto fits = (*env).GetMethodID(env, (*env).GetObjectClass(env, window),
            "setDecorFitsSystemWindows", "(Z)V");
        jvalue[1] no;
        no[0].z = false;
        if (fits !is null)
            (*env).CallVoidMethodA(env, window, fits, no.ptr);
    }
    if ((*env).ExceptionCheck(env))
        (*env).ExceptionClear(env);
}
