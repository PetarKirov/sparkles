/**
Starting other apps: an `ACTION_VIEW` intent for a URI, over JNI into the
framework's `Intent` and `Activity.startActivity` (no Java in the APK).
*/
module sparkles.android.intents;

version (Android):

import sparkles.android.jni;

/// `Intent.FLAG_ACTIVITY_NEW_TASK`.
private enum int flagActivityNewTask = 0x1000_0000;

/**
Open `uri` in whatever app handles it (`ACTION_VIEW`), with an optional MIME
type; through the system chooser when `chooser`. `null` on success, else the
reason (no app for it, a malformed URI, ...).
*/
string viewUri(string uri, string mimeType = null, bool chooser = false) @trusted nothrow
{
    return withJni((ref JniFrame f) => viewOnWorker(f, uri, mimeType, chooser));
}

private string viewOnWorker(ref JniFrame f, string uri, string mimeType, bool chooser) @system nothrow
{
    auto env = f.env;
    auto uriClass = (*env).FindClass(env, "android/net/Uri");
    auto parse = (*env).GetStaticMethodID(env, uriClass, "parse",
        "(Ljava/lang/String;)Landroid/net/Uri;");
    auto juri = utf8String(f, uri);
    if (parse is null || juri is null)
        return "cannot build the URI";
    jvalue[1] a;
    a[0].l = juri;
    auto uriObj = (*env).CallStaticObjectMethodA(env, uriClass, parse, a.ptr);
    if (f.failed || uriObj is null)
        return "malformed URI";

    auto intentClass = (*env).FindClass(env, "android/content/Intent");
    auto ctor = (*env).GetMethodID(env, intentClass, "<init>", "(Ljava/lang/String;)V");
    auto action = (*env).NewStringUTF(env, "android.intent.action.VIEW");
    jvalue[1] ca;
    ca[0].l = action;
    auto intent = (*env).NewObjectA(env, intentClass, ctor, ca.ptr);
    if (f.failed || intent is null)
        return "cannot build the intent";

    if (mimeType.length)
    {
        auto setDataAndType = (*env).GetMethodID(env, intentClass, "setDataAndType",
            "(Landroid/net/Uri;Ljava/lang/String;)Landroid/content/Intent;");
        jvalue[2] da;
        da[0].l = uriObj;
        da[1].l = utf8String(f, mimeType);
        (*env).CallObjectMethodA(env, intent, setDataAndType, da.ptr);
    }
    else
    {
        auto setData = (*env).GetMethodID(env, intentClass, "setData",
            "(Landroid/net/Uri;)Landroid/content/Intent;");
        jvalue[1] da;
        da[0].l = uriObj;
        (*env).CallObjectMethodA(env, intent, setData, da.ptr);
    }
    auto addFlags = (*env).GetMethodID(env, intentClass, "addFlags", "(I)Landroid/content/Intent;");
    jvalue[1] fl;
    fl[0].i = flagActivityNewTask;
    (*env).CallObjectMethodA(env, intent, addFlags, fl.ptr);
    if (f.failed)
        return "cannot configure the intent";

    if (chooser)
    {
        auto createChooser = (*env).GetStaticMethodID(env, intentClass, "createChooser",
            "(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;");
        jvalue[2] cha;
        cha[0].l = intent;
        cha[1].l = null;
        intent = (*env).CallStaticObjectMethodA(env, intentClass, createChooser, cha.ptr);
        if (f.failed || intent is null)
            return "cannot build the chooser";
        (*env).CallObjectMethodA(env, intent, addFlags, fl.ptr);
    }

    auto activityClass = (*env).GetObjectClass(env, f.activity);
    auto start = (*env).GetMethodID(env, activityClass, "startActivity",
        "(Landroid/content/Intent;)V");
    jvalue[1] sa;
    sa[0].l = intent;
    (*env).CallVoidMethodA(env, f.activity, start, sa.ptr);
    if (f.failed)
    {
        f.clearException();
        return "no app can open " ~ uri;
    }
    return null;
}

/// A `java.lang.String` from UTF-8 text (`null` on failure).
jstring utf8String(ref JniFrame f, string s) @system nothrow
{
    import std.utf : toUTF16;

    wstring w;
    try
        w = s.toUTF16;
    catch (Exception)
        return null;
    return f.newString(w);
}
