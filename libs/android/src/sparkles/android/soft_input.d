/**
The soft keyboard.

`ANativeActivity_showSoftInput` does not work on current Android: it asks the
`InputMethodManager` to show the keyboard for NativeActivity's content view,
but a window with no text editor in it is served through its $(I decor) view,
so the request fails the served-view check (`ImeTracker: onFailed at
PHASE_CLIENT_VIEW_SERVED`, observed on API 36). This module makes the same
request over JNI for the view the manager actually serves — the window's decor
view — and falls back to `toggleSoftInput`, which picks the served view itself
(deprecated, but a no-op only for apps targeting API 31+; this one targets 28).

With no `InputConnection` on the view (the app ships no Java), the IME types
through key events and, for text it has no key for, `ACTION_MULTIPLE` events;
both become text in $(MREF sparkles,android,text_input).

Whether the keyboard is $(I shown) is not reported back to native code; the
layout follows it through the content rect instead
($(REF contentRect, sparkles,android,activity)).
*/
module sparkles.android.soft_input;

version (Android):

import sparkles.android.jni;

/// `InputMethodManager.SHOW_FORCED`: show even with a hardware keyboard
/// attached — the user tapped the terminal to ask for it.
private enum int showForced = 2;

/// Bring up the soft keyboard; `false` when every route failed.
bool showSoftKeyboard() @trusted nothrow
{
    return withJni((ref JniFrame f) => showOnWorker(f));
}

/// Dismiss the soft keyboard.
void hideSoftKeyboard() @trusted nothrow
{
    withJni((ref JniFrame f) { hideOnWorker(f); });
}

private bool showOnWorker(ref JniFrame f) @system nothrow
{
    auto env = f.env;
    auto imm = f.systemService("input_method");
    auto decor = decorView(f);
    if (imm is null || decor is null)
        return false;
    auto immClass = (*env).GetObjectClass(env, imm);

    auto show = (*env).GetMethodID(env, immClass, "showSoftInput",
        "(Landroid/view/View;I)Z");
    if (show !is null)
    {
        jvalue[2] args;
        args[0].l = decor;
        args[1].i = showForced;
        const shown = (*env).CallBooleanMethodA(env, imm, show, args.ptr);
        if (!f.clearException() && shown)
            return true;
    }

    auto toggle = (*env).GetMethodID(env, immClass, "toggleSoftInput", "(II)V");
    if (toggle is null)
        return false;
    jvalue[2] flags;
    flags[0].i = showForced;
    flags[1].i = 0;
    (*env).CallVoidMethodA(env, imm, toggle, flags.ptr);
    return !f.failed;
}

private void hideOnWorker(ref JniFrame f) @system nothrow
{
    auto env = f.env;
    auto imm = f.systemService("input_method");
    auto decor = decorView(f);
    if (imm is null || decor is null)
        return;

    auto viewClass = (*env).GetObjectClass(env, decor);
    auto getToken = (*env).GetMethodID(env, viewClass, "getWindowToken",
        "()Landroid/os/IBinder;");
    if (getToken is null)
        return;
    auto token = (*env).CallObjectMethodA(env, decor, getToken, null);
    if (f.failed || token is null)
        return;

    auto immClass = (*env).GetObjectClass(env, imm);
    auto hide = (*env).GetMethodID(env, immClass, "hideSoftInputFromWindow",
        "(Landroid/os/IBinder;I)Z");
    if (hide is null)
        return;
    jvalue[2] args;
    args[0].l = token;
    args[1].i = 0;
    cast(void) (*env).CallBooleanMethodA(env, imm, hide, args.ptr);
}

/// `activity.getWindow().getDecorView()`; `null` on failure.
private jobject decorView(ref JniFrame f) @system nothrow
{
    auto env = f.env;
    auto activityClass = (*env).GetObjectClass(env, f.activity);
    auto getWindow = (*env).GetMethodID(env, activityClass, "getWindow",
        "()Landroid/view/Window;");
    if (getWindow is null)
        return null;
    auto window = (*env).CallObjectMethodA(env, f.activity, getWindow, null);
    if (f.failed || window is null)
        return null;
    auto windowClass = (*env).GetObjectClass(env, window);
    auto getDecor = (*env).GetMethodID(env, windowClass, "getDecorView",
        "()Landroid/view/View;");
    if (getDecor is null)
        return null;
    auto decor = (*env).CallObjectMethodA(env, window, getDecor, null);
    return f.failed ? null : decor;
}
