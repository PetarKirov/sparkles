/**
Whether the user asked for no animation: Settings › Accessibility › Remove
animations, which sets `Settings.Global.ANIMATOR_DURATION_SCALE` to 0 — the
reduced-motion preference of the design system (`ACC5`).

A module of its own for the reason $(MREF sparkles,android,system_scheme)
gives: it needs $(MREF sparkles,android,jni).
*/
module sparkles.android.motion;

version (Android):

import sparkles.android.jni;

/**
`1` when animations are removed, `0` when they run, `-1` unknown. A round
trip to the JNI worker: read it on resume, not every frame.
*/
int animationsRemoved() @trusted nothrow
{
    // 0 unknown, 1 running, 2 removed: a worker that cannot attach returns 0.
    return withJni((ref JniFrame f) {
        auto resolver = f.callObject(f.activity, "getContentResolver",
            "()Landroid/content/ContentResolver;");
        if (resolver is null)
            return 0;
        auto env = f.env;
        auto cls = (*env).FindClass(env, "android/provider/Settings$Global");
        if (cls is null || f.failed)
            return 0;
        auto getFloat = (*env).GetStaticMethodID(env, cls, "getFloat",
            "(Landroid/content/ContentResolver;Ljava/lang/String;F)F");
        if (getFloat is null || f.failed)
            return 0;
        jvalue[3] args;
        args[0] = jv(resolver);
        args[1] = jv(f.newString("animator_duration_scale"w));
        args[2].f = 1.0f;
        const scale = (*env).CallStaticFloatMethodA(env, cls, getFloat, args.ptr);
        if (f.failed)
            return 0;
        return scale == 0 ? 2 : 1;
    }) - 1;
}
