/**
Which build of the app is installed: its package name, `versionCode` and
`versionName`, as the package manager reports them
(`getPackageManager().getPackageInfo(getPackageName(), 0)`, over JNI).

The APK builder injects the version (`aapt2 --replace-version`), so the native
library — built once and cached across commits — cannot know it; the package
manager can. An about page asks once.
*/
module sparkles.android.package_info;

version (Android):

import sparkles.android.jni;

/// The installed package's identity.
struct PackageInfo
{
    string packageName; /// `dev.example.app`
    int versionCode = -1; /// `-1` when the package manager did not say
    string versionName;
}

/// The installed package's identity; empty fields when JNI failed. A round
/// trip to the JNI worker: ask once, not every frame.
PackageInfo packageInfo() @trusted nothrow
{
    return withJni((ref JniFrame f) {
        PackageInfo r;
        auto name = f.callObject(f.activity, "getPackageName", "()Ljava/lang/String;");
        if (name is null)
            return r;
        r.packageName = f.toDString(cast(jstring) name);
        auto pm = f.callObject(f.activity, "getPackageManager",
            "()Landroid/content/pm/PackageManager;");
        if (pm is null)
            return r;
        jvalue[2] args = [jv(name), jv(0)];
        auto info = f.callObject(pm, "getPackageInfo",
            "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;", args);
        if (info is null)
            return r;
        auto env = f.env;
        auto cls = (*env).GetObjectClass(env, info);
        auto code = (*env).GetFieldID(env, cls, "versionCode", "I");
        if (code !is null && !f.failed)
            r.versionCode = (*env).GetIntField(env, info, code);
        auto vname = (*env).GetFieldID(env, cls, "versionName", "Ljava/lang/String;");
        if (vname !is null && !f.failed)
            r.versionName = f.toDString(cast(jstring)(*env).GetObjectField(env, info, vname));
        return r;
    });
}
