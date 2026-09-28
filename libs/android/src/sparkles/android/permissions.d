/**
Runtime permissions: asking (`Activity.requestPermissions`, which shows the
system dialog) and checking (`checkSelfPermission`). A NativeActivity cannot
receive `onRequestPermissionsResult` — there is no Java to override it — so a
caller asks, then polls $(LREF hasPermission).
*/
module sparkles.android.permissions;

version (Android):

import sparkles.android.jni;

/// Whether the app holds the permission `name` (`"android.permission.…"`).
bool hasPermission(string name) @trusted nothrow
{
    return withJni((ref JniFrame f) {
        import sparkles.android.intents : utf8String;

        auto env = f.env;
        auto cls = (*env).GetObjectClass(env, f.activity);
        auto check = (*env).GetMethodID(env, cls, "checkSelfPermission",
            "(Ljava/lang/String;)I");
        auto jname = utf8String(f, name);
        if (check is null || jname is null)
            return false;
        jvalue[1] a;
        a[0].l = jname;
        const r = (*env).CallIntMethodA(env, f.activity, check, a.ptr);
        return !f.failed && r == 0; // PERMISSION_GRANTED
    });
}

/// Show the system dialog asking for `names`; returns at once.
void requestPermissions(scope const string[] names) @trusted nothrow
{
    withJni((ref JniFrame f) {
        import sparkles.android.intents : utf8String;

        auto env = f.env;
        auto stringClass = (*env).FindClass(env, "java/lang/String");
        auto arr = (*env).NewObjectArray(env, cast(jsize) names.length, stringClass, null);
        if (arr is null)
            return;
        foreach (i, n; names)
            (*env).SetObjectArrayElement(env, arr, cast(jsize) i, utf8String(f, n));
        auto cls = (*env).GetObjectClass(env, f.activity);
        auto req = (*env).GetMethodID(env, cls, "requestPermissions",
            "([Ljava/lang/String;I)V");
        if (req is null)
            return;
        jvalue[2] a;
        a[0].l = arr;
        a[1].i = 1;
        (*env).CallVoidMethodA(env, f.activity, req, a.ptr);
    });
}
