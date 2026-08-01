// The Android clipboard bridge: raylib's PLATFORM_ANDROID SetClipboardText is
// unimplemented, and with hasCode="false" there is no Java side to delegate
// to — so the ClipboardManager is driven straight through JNI from the
// activity's JavaVM. Called from the glue thread (the thread D main runs on);
// AttachCurrentThread is a no-op when already attached, and the thread stays
// attached for the process lifetime (the process exits with the activity, see
// app.d). Compiled by the nix cross build with the NDK clang (jni.h comes
// from the sysroot) and linked into libhue.so; consumed via a plain
// extern(C) declaration in android_glue.d.
//
// Known limit: ClipboardManager internally wants a Looper-owning thread on
// API < 23; the ExceptionCheck path degrades that to a logged failure rather
// than an abort.
#include <jni.h>
#include <stddef.h>

// `text` is UTF-16 (jchar) with an explicit length, NOT modified UTF-8.
// NewStringUTF is specified over *modified* UTF-8, where an astral scalar
// must arrive as a CESU-8 surrogate PAIR (two 3-byte sequences) rather than
// the 4-byte sequence standard UTF-8 uses. hue copies arbitrary document
// text, and the repo-embedded bundle alone has ~118 tracked files containing
// astral characters — so a long-press-and-copy over an emoji handed
// NewStringUTF input its contract forbids. Under CheckJNI (which
// android:debuggable="true" force-enables) ART's checked path can AbortF on
// an "illegal start byte", i.e. kill the process mid-gesture; without it,
// older ART mis-decoded. NewString sidesteps the question entirely: it takes
// UTF-16 units, which is what a Java String already is.
//
// Returns 0 on success, nonzero when any step of the JNI dance failed.
int hue_android_set_clipboard(
    JavaVM *vm, jobject activity, const jchar *text, jsize textLen)
{
    JNIEnv *env = NULL;
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK || env == NULL) return 1;

    int rc = 1;
    jstring service = NULL, label = NULL, jtext = NULL;
    jobject clipboard = NULL, clip = NULL;
    jclass activityClass = NULL, clipDataClass = NULL, clipboardClass = NULL;

    activityClass = (*env)->GetObjectClass(env, activity);
    jmethodID getSystemService = (*env)->GetMethodID(env, activityClass,
        "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    if (getSystemService == NULL) goto done;

    service = (*env)->NewStringUTF(env, "clipboard");
    if (service == NULL) goto done;
    clipboard = (*env)->CallObjectMethod(env, activity, getSystemService, service);
    if ((*env)->ExceptionCheck(env) || clipboard == NULL) goto done;

    clipDataClass = (*env)->FindClass(env, "android/content/ClipData");
    if (clipDataClass == NULL) goto done;
    jmethodID newPlainText = (*env)->GetStaticMethodID(env, clipDataClass,
        "newPlainText",
        "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;");
    if (newPlainText == NULL) goto done;

    // Checked one at a time: a NULL return leaves an OutOfMemoryError
    // pending, and making the next JNI call with a pending exception is
    // undefined per the spec (and an abort under CheckJNI).
    label = (*env)->NewStringUTF(env, "hue");   // ASCII literal: UTF-8 is fine
    if (label == NULL) goto done;
    jtext = (*env)->NewString(env, text, textLen);
    if (jtext == NULL) goto done;
    clip = (*env)->CallStaticObjectMethod(env, clipDataClass, newPlainText, label, jtext);
    if ((*env)->ExceptionCheck(env) || clip == NULL) goto done;

    clipboardClass = (*env)->GetObjectClass(env, clipboard);
    jmethodID setPrimaryClip = (*env)->GetMethodID(env, clipboardClass,
        "setPrimaryClip", "(Landroid/content/ClipData;)V");
    if (setPrimaryClip == NULL) goto done;
    (*env)->CallVoidMethod(env, clipboard, setPrimaryClip, clip);
    if ((*env)->ExceptionCheck(env)) goto done;

    rc = 0;

done:
    if ((*env)->ExceptionCheck(env))
    {
        // Describe before clearing: this writes the Java stack trace to
        // logcat, which is the only diagnostic channel a NativeActivity has.
        // Without it every failure — including the documented API<23
        // "ClipboardManager wants a Looper thread" case — collapses into one
        // undifferentiated "JNI clipboard bridge failed" warning D-side.
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (clip != NULL) (*env)->DeleteLocalRef(env, clip);
    if (clipboard != NULL) (*env)->DeleteLocalRef(env, clipboard);
    if (jtext != NULL) (*env)->DeleteLocalRef(env, jtext);
    if (label != NULL) (*env)->DeleteLocalRef(env, label);
    if (service != NULL) (*env)->DeleteLocalRef(env, service);
    if (activityClass != NULL) (*env)->DeleteLocalRef(env, activityClass);
    if (clipDataClass != NULL) (*env)->DeleteLocalRef(env, clipDataClass);
    if (clipboardClass != NULL) (*env)->DeleteLocalRef(env, clipboardClass);
    return rc;
}
