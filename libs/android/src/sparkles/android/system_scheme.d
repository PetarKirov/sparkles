/**
The system's light/dark setting, as the activity's resources see it
(`getResources().getConfiguration().uiMode`, over JNI).

$(B Not native_app_glue's copy.) The glue keeps an `AConfiguration` it
refreshes from the asset manager on `APP_CMD_CONFIG_CHANGED`, and
`AConfiguration_getUiModeNight` on it would be the free, per-frame read. On
the Xiaomi 11T Pro (Android 14) it is not current: after a switch to dark mode
in the settings it still read light while the activity's own configuration
read dark (docs/specs/terminal/testing.md, the `TPR13` row). So the answer
comes from the framework, at the cost of a JNI round trip.

A module of its own, not part of `activity`: it needs $(MREF
sparkles,android,jni), which imports `activity`, and two modules that import
each other may not both have module constructors (druntime refuses to start —
`main` never runs).
*/
module sparkles.android.system_scheme;

version (Android):

import sparkles.android.jni : JniFrame, withJni;

/**
`1` dark, `0` light, `-1` unknown. A round trip to the JNI worker: poll it
about once a second, not every frame.
*/
int systemDarkMode() @trusted nothrow
{
    // 0 unknown, 1 light, 2 dark: a worker that cannot attach returns 0.
    return withJni((ref JniFrame f) {
        auto res = f.callObject(f.activity, "getResources", "()Landroid/content/res/Resources;");
        auto config = f.callObject(res, "getConfiguration",
            "()Landroid/content/res/Configuration;");
        if (config is null)
            return 0;
        auto env = f.env;
        auto field = (*env).GetFieldID(env, (*env).GetObjectClass(env, config), "uiMode", "I");
        if (field is null || f.failed)
            return 0;
        const night = (*env).GetIntField(env, config, field) & 0x30; // UI_MODE_NIGHT_MASK
        return night == 0x20 ? 2 : night == 0x10 ? 1 : 0;
    }) - 1;
}
