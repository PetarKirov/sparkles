/**
The Android clipboard bridge, driven straight through JNI.

raylib's `PLATFORM_ANDROID` `SetClipboardText` is an unimplemented no-op (a
`TRACELOG` warning — see raylib's `rcore_android.c`), and `hasCode="false"`
leaves no Java side to delegate to, so hue drives `ClipboardManager` itself.

This is D over an ImportC'd `<jni.h>` (`jni_c.c`) rather than hand-written C:
the function tables and `jvalue` come from the real NDK header, so nothing can
drift, and the logic lives where the repo wants logic (AGENTS.md). The one
thing the port must get right that C got for free is the calling convention —
see [setClipboardText].

Called from the glue thread (the thread D `main` runs on).
`AttachCurrentThread` is a no-op when already attached; the thread stays
attached for the process lifetime, which is safe because the process exits
with the activity (see `app.d`).

Known limit: `ClipboardManager` internally wants a Looper-owning thread on
API < 23; that surfaces as a pending exception, which is described to logcat
and reported as a failure rather than an abort.
*/
module android_clipboard;

version (Android):

import jni_c;

/**
Copy `text` to the system clipboard. Returns `false` when any JNI step failed
(the Java stack trace goes to logcat, the only diagnostic channel a
NativeActivity has).

`text` is UTF-16 because a `java.lang.String` is: it reaches Java through
`NewString`, not `NewStringUTF`. The latter is specified over $(I modified)
UTF-8, where an astral scalar must arrive as a CESU-8 surrogate pair rather
than the 4-byte sequence standard UTF-8 uses — so copying a selection
containing an emoji fed it input its contract forbids, which under CheckJNI
can abort the process.

$(B Argument forms.) Every method call goes through the `…A` form, which takes
a `jvalue[]` rather than C varargs. This is for legibility — each argument's
JNI type is written down — $(I not) for ABI safety: LDC's `extern(C)` variadic
support on AArch64 is correct on both ABIs (measured; see the trap list in
docs/specs/hue/android.md). The variadic forms would work too.
*/
bool setClipboardText(void* vm, void* activity, scope const(wchar)[] text) @trusted nothrow
{
    auto javaVm = cast(JavaVM*) vm;
    auto act = cast(jobject) activity;

    JNIEnv* env;
    if ((*javaVm).AttachCurrentThread(javaVm, &env, null) != JNI_OK || env is null)
        return false;

    // Every local ref is released on the way out: the glue thread never
    // returns to Java, so a leaked ref would sit in the 512-entry local table
    // for the process lifetime.
    jobject[8] locals;
    size_t localCount;
    jobject track(jobject o) @safe nothrow
    {
        if (o !is null && localCount < locals.length)
            locals[localCount++] = o;
        return o;
    }

    scope (exit)
    {
        if ((*env).ExceptionCheck(env))
        {
            // Describe before clearing — otherwise every failure, including
            // the API<23 Looper case above, collapses into one opaque
            // "bridge failed" with no way to tell which step broke.
            (*env).ExceptionDescribe(env);
            (*env).ExceptionClear(env);
        }
        foreach (o; locals[0 .. localCount])
            (*env).DeleteLocalRef(env, o);
    }

    // activity.getSystemService("clipboard")
    auto activityClass = track((*env).GetObjectClass(env, act));
    auto getSystemService = (*env).GetMethodID(env, activityClass,
        "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    if (getSystemService is null)
        return false;

    auto service = track((*env).NewStringUTF(env, "clipboard")); // ASCII
    if (service is null)
        return false;

    jvalue[1] serviceArg;
    serviceArg[0].l = service;
    auto clipboard = track((*env).CallObjectMethodA(env, act, getSystemService,
        serviceArg.ptr));
    if ((*env).ExceptionCheck(env) || clipboard is null)
        return false;

    // ClipData.newPlainText("hue", text)
    auto clipDataClass = track((*env).FindClass(env, "android/content/ClipData"));
    if (clipDataClass is null)
        return false;
    auto newPlainText = (*env).GetStaticMethodID(env, clipDataClass, "newPlainText",
        "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;");
    if (newPlainText is null)
        return false;

    auto label = track((*env).NewStringUTF(env, "hue")); // ASCII
    if (label is null)
        return false;
    // Checked separately from `label`: a null return leaves an
    // OutOfMemoryError pending, and the next JNI call would then be made with
    // a pending exception — undefined per the spec, an abort under CheckJNI.
    auto jtext = track((*env).NewString(env, cast(const(jchar)*) text.ptr,
        cast(jsize) text.length));
    if (jtext is null)
        return false;

    jvalue[2] clipArgs;
    clipArgs[0].l = label;
    clipArgs[1].l = jtext;
    auto clip = track((*env).CallStaticObjectMethodA(env, clipDataClass,
        newPlainText, clipArgs.ptr));
    if ((*env).ExceptionCheck(env) || clip is null)
        return false;

    // clipboard.setPrimaryClip(clip)
    auto clipboardClass = track((*env).GetObjectClass(env, clipboard));
    auto setPrimaryClip = (*env).GetMethodID(env, clipboardClass,
        "setPrimaryClip", "(Landroid/content/ClipData;)V");
    if (setPrimaryClip is null)
        return false;

    jvalue[1] clipArg;
    clipArg[0].l = clip;
    (*env).CallVoidMethodA(env, clipboard, setPrimaryClip, clipArg.ptr);
    return !(*env).ExceptionCheck(env);
}
