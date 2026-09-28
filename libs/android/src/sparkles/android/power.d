/**
A partial wake lock (`PowerManager.PARTIAL_WAKE_LOCK`): the CPU keeps running
with the screen off, for a long job in a terminal. Needs the `WAKE_LOCK`
permission in the manifest. One lock per process, not reference-counted:
acquiring twice and releasing once releases it.
*/
module sparkles.android.power;

version (Android):

import sparkles.android.jni;

private __gshared jobject wakeLock; // a global ref, created on first use

/// Take (`held = true`) or release the wake lock; `null` on success, else the
/// reason.
string setWakeLock(bool held) @trusted nothrow
{
    return withJni((ref JniFrame f) => setOnWorker(f, held));
}

/// Whether the wake lock is currently held.
bool wakeLockHeld() @trusted nothrow
{
    return withJni((ref JniFrame f) {
        if (wakeLock is null)
            return false;
        auto env = f.env;
        auto cls = (*env).GetObjectClass(env, wakeLock);
        auto isHeld = (*env).GetMethodID(env, cls, "isHeld", "()Z");
        return isHeld !is null && (*env).CallBooleanMethodA(env, wakeLock, isHeld, null) != 0;
    });
}

private string setOnWorker(ref JniFrame f, bool held) @system nothrow
{
    auto env = f.env;
    if (wakeLock is null)
    {
        auto pm = f.systemService("power");
        if (pm is null)
            return "no PowerManager";
        auto pmClass = (*env).GetObjectClass(env, pm);
        auto newWakeLock = (*env).GetMethodID(env, pmClass, "newWakeLock",
            "(ILjava/lang/String;)Landroid/os/PowerManager$WakeLock;");
        jvalue[2] a;
        a[0].i = 1; // PARTIAL_WAKE_LOCK
        a[1].l = (*env).NewStringUTF(env, "sparkles:terminal");
        auto wl = (*env).CallObjectMethodA(env, pm, newWakeLock, a.ptr);
        if (f.failed || wl is null)
            return "cannot create the wake lock";
        auto wlClass = (*env).GetObjectClass(env, wl);
        auto setRefCounted = (*env).GetMethodID(env, wlClass, "setReferenceCounted", "(Z)V");
        jvalue[1] no;
        no[0].z = JNI_FALSE;
        (*env).CallVoidMethodA(env, wl, setRefCounted, no.ptr);
        wakeLock = (*env).NewGlobalRef(env, wl);
    }
    auto cls = (*env).GetObjectClass(env, wakeLock);
    auto m = (*env).GetMethodID(env, cls, held ? "acquire" : "release", "()V");
    (*env).CallVoidMethodA(env, wakeLock, m, null);
    if (f.failed)
    {
        f.clearException();
        return held ? "acquiring the wake lock failed" : "releasing the wake lock failed";
    }
    return null;
}
