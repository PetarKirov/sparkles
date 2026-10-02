/**
Starting other apps over JNI into the framework's `Intent` and
`Activity.startActivity` (no Java in the APK): `ACTION_VIEW` for a URI, and
`ACTION_SEND` to share text through the system's share sheet.
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

/**
Share `text` (`ACTION_SEND`, `text/plain`) through the system's share sheet
(`Intent.createChooser`), with an optional `subject` (`EXTRA_SUBJECT`, which
mail apps use). `null` once the sheet is started, else the reason. What the
user then picks, if anything, is not reported back.
*/
string shareText(string text, string subject = null) @trusted nothrow
{
    return withJni((ref JniFrame f) {
        jvalue[1] action = [jv(utf8String(f, "android.intent.action.SEND"))];
        auto intent = f.newObject("android/content/Intent", "(Ljava/lang/String;)V", action);
        jvalue[1] mime = [jv(utf8String(f, "text/plain"))];
        f.callObject(intent, "setType", "(Ljava/lang/String;)Landroid/content/Intent;", mime);
        enum putString = "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;";
        jvalue[2] body = [jv(utf8String(f, "android.intent.extra.TEXT")), jv(utf8String(f, text))];
        f.callObject(intent, "putExtra", putString, body);
        if (subject.length)
        {
            jvalue[2] subj = [jv(utf8String(f, "android.intent.extra.SUBJECT")),
                jv(utf8String(f, subject))];
            f.callObject(intent, "putExtra", putString, subj);
        }
        jvalue[2] ch = [jv(intent), jv(cast(jobject) null)];
        auto chooser = f.callStaticObject("android/content/Intent", "createChooser",
            "(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;", ch);
        jvalue[1] fl = [jv(flagActivityNewTask)];
        f.callObject(chooser, "addFlags", "(I)Landroid/content/Intent;", fl);
        if (chooser is null || f.failed)
            return "cannot build the share intent";
        jvalue[1] start = [jv(chooser)];
        if (!f.callVoid(f.activity, "startActivity", "(Landroid/content/Intent;)V", start))
            return "the share sheet did not start";
        return string.init;
    });
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
