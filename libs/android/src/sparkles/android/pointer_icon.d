/**
The mouse or stylus pointer's shape over the activity's window: Android 7
(API 24) and later draw the icon a view asks for with `View.setPointerIcon`,
from the system set `PointerIcon.getSystemIcon` names by type. A
NativeActivity has no views of its own, so the icon is the window's decor
view's, which every view under the pointer defers to.

Views belong to the main thread, so the call is posted there
($(MREF sparkles,android,main_thread)); without it wired, or below API 24,
nothing changes and the pointer keeps the system's arrow.
*/
module sparkles.android.pointer_icon;

version (Android):

import core.atomic : atomicLoad, atomicStore;

import jni_c;
import sparkles.android.activity : nativeActivity;
import sparkles.android.main_thread : postToMainThread;

/// `android.view.PointerIcon`'s system types (API 24).
enum PointerIconType : int
{
    arrow = 1000,                 /// `TYPE_ARROW`
    hand = 1002,                  /// `TYPE_HAND`
    text = 1008,                  /// `TYPE_TEXT`
    horizontalDoubleArrow = 1014, /// `TYPE_HORIZONTAL_DOUBLE_ARROW`
    verticalDoubleArrow = 1015,   /// `TYPE_VERTICAL_DOUBLE_ARROW`
    grab = 1020,                  /// `TYPE_GRAB`
    grabbing = 1021,              /// `TYPE_GRABBING`
}

// The type the next main-thread job applies: the latest asked for, so a burst
// of requests costs one job each but lands on the last.
private shared int wanted = PointerIconType.arrow;

/**
Asks for the pointer icon of `type` over the window, asynchronously. `false`
when the main thread is not wired (the manifest did not name the entry
point), and the icon then stays the system's.
*/
bool setPointerIcon(PointerIconType type) @trusted nothrow @nogc
{
    atomicStore(wanted, cast(int) type);
    return postToMainThread(&applyJob, null);
}

// `activity.getWindow().getDecorView().setPointerIcon(
//     PointerIcon.getSystemIcon(activity, type))`, on the main thread. A
// missing method (below API 24) raises `NoSuchMethodError`, which the job
// runner reports and clears.
private void applyJob(JNIEnv* env, void*) nothrow @nogc
{
    auto activity = cast(jobject) nativeActivity().clazz;
    if (activity is null)
        return;
    auto getWindow = (*env).GetMethodID(env, (*env).GetObjectClass(env, activity), "getWindow",
        "()Landroid/view/Window;");
    if (getWindow is null)
        return;
    auto window = (*env).CallObjectMethodA(env, activity, getWindow, null);
    if (window is null || (*env).ExceptionCheck(env))
        return;
    auto getDecor = (*env).GetMethodID(env, (*env).GetObjectClass(env, window), "getDecorView",
        "()Landroid/view/View;");
    if (getDecor is null)
        return;
    auto decor = (*env).CallObjectMethodA(env, window, getDecor, null);
    if (decor is null || (*env).ExceptionCheck(env))
        return;
    auto iconClass = (*env).FindClass(env, "android/view/PointerIcon");
    if (iconClass is null)
        return;
    auto getSystemIcon = (*env).GetStaticMethodID(env, iconClass, "getSystemIcon",
        "(Landroid/content/Context;I)Landroid/view/PointerIcon;");
    if (getSystemIcon is null)
        return;
    jvalue[2] a;
    a[0].l = activity;
    a[1].i = atomicLoad(wanted);
    auto icon = (*env).CallStaticObjectMethodA(env, iconClass, getSystemIcon, a.ptr);
    if (icon is null || (*env).ExceptionCheck(env))
        return;
    auto set = (*env).GetMethodID(env, (*env).GetObjectClass(env, decor), "setPointerIcon",
        "(Landroid/view/PointerIcon;)V");
    if (set is null)
        return;
    jvalue[1] b;
    b[0].l = icon;
    (*env).CallVoidMethodA(env, decor, set, b.ptr);
}
