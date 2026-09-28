/**
The system clipboard, through the activity's `ClipboardManager`.

raylib's `PLATFORM_ANDROID` `SetClipboardText`/`GetClipboardText` are
unimplemented (a `TRACELOG` warning — see `rcore_android.c`), so a
NativeActivity drives `ClipboardManager` itself over $(MREF sparkles,android,jni).

Known limit: `ClipboardManager` wants a Looper-owning thread on API < 23; that
surfaces as a pending exception, described to logcat and reported as a failure
rather than an abort. Reading is further limited by Android 10+'s rule that
only the focused app may read the clipboard — which a foreground terminal is.
*/
module sparkles.android.clipboard;

version (Android):

import sparkles.android.jni;

/**
Copy `text` to the system clipboard. Returns `false` when any JNI step failed
(the Java stack trace goes to logcat).

Takes a slice, not a `const(char)*`: a raw pointer would make this an
unchecked NUL-termination precondition, and the bridge wants a length anyway.
*/
bool setClipboardText(scope const(char)[] text, string label = "text") @safe nothrow
{
    import std.utf : toUTF16;

    wstring utf16;
    try
        utf16 = text.toUTF16;
    catch (Exception)
        return false; // invalid UTF in the selection → report the failure
    return (() @trusted => setUtf16(utf16, label))();
}

private bool setUtf16(scope const(wchar)[] text, string label) @system nothrow
{
    return withJni((ref JniFrame f) => setOnWorker(f, text, label));
}

private bool setOnWorker(ref JniFrame f, scope const(wchar)[] text, string label) @system nothrow
{
    import std.utf : toUTF16;

    auto env = f.env;

    auto clipboard = f.systemService("clipboard");
    if (clipboard is null)
        return false;

    // ClipData.newPlainText(label, text)
    auto clipDataClass = (*env).FindClass(env, "android/content/ClipData");
    if (clipDataClass is null)
        return false;
    auto newPlainText = (*env).GetStaticMethodID(env, clipDataClass, "newPlainText",
        "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;");
    if (newPlainText is null)
        return false;

    wstring label16;
    try
        label16 = label.toUTF16;
    catch (Exception)
        return false;
    auto jlabel = f.newString(label16);
    if (jlabel is null)
        return false;
    // Checked separately from `jlabel`: a null return leaves an
    // OutOfMemoryError pending, and the next JNI call would then be made with
    // a pending exception — undefined per the spec, an abort under CheckJNI.
    auto jtext = f.newString(text);
    if (jtext is null)
        return false;

    jvalue[2] clipArgs;
    clipArgs[0].l = jlabel;
    clipArgs[1].l = jtext;
    auto clip = (*env).CallStaticObjectMethodA(env, clipDataClass, newPlainText,
        clipArgs.ptr);
    if (f.failed || clip is null)
        return false;

    // clipboard.setPrimaryClip(clip)
    auto clipboardClass = (*env).GetObjectClass(env, clipboard);
    auto setPrimaryClip = (*env).GetMethodID(env, clipboardClass,
        "setPrimaryClip", "(Landroid/content/ClipData;)V");
    if (setPrimaryClip is null)
        return false;

    jvalue[1] clipArg;
    clipArg[0].l = clip;
    (*env).CallVoidMethodA(env, clipboard, setPrimaryClip, clipArg.ptr);
    return !f.failed;
}

/**
The clipboard's first item coerced to text (`ClipData.Item.coerceToText`, so a
URI or an intent clip still pastes as something), or `null` when the
clipboard is empty or unreadable.
*/
string getClipboardText() @trusted nothrow
{
    return withJni((ref JniFrame f) => getOnWorker(f));
}

private string getOnWorker(ref JniFrame f) @system nothrow
{
    auto env = f.env;

    auto clipboard = f.systemService("clipboard");
    if (clipboard is null)
        return null;

    auto clipboardClass = (*env).GetObjectClass(env, clipboard);
    auto getPrimaryClip = (*env).GetMethodID(env, clipboardClass,
        "getPrimaryClip", "()Landroid/content/ClipData;");
    if (getPrimaryClip is null)
        return null;
    auto clip = (*env).CallObjectMethodA(env, clipboard, getPrimaryClip, null);
    if (f.failed || clip is null)
        return null;

    auto clipDataClass = (*env).GetObjectClass(env, clip);
    auto getItemCount = (*env).GetMethodID(env, clipDataClass, "getItemCount", "()I");
    auto getItemAt = (*env).GetMethodID(env, clipDataClass, "getItemAt",
        "(I)Landroid/content/ClipData$Item;");
    if (getItemCount is null || getItemAt is null)
        return null;
    if ((*env).CallIntMethodA(env, clip, getItemCount, null) <= 0 || f.failed)
        return null;

    jvalue[1] index;
    index[0].i = 0;
    auto item = (*env).CallObjectMethodA(env, clip, getItemAt, index.ptr);
    if (f.failed || item is null)
        return null;

    auto itemClass = (*env).GetObjectClass(env, item);
    auto coerceToText = (*env).GetMethodID(env, itemClass, "coerceToText",
        "(Landroid/content/Context;)Ljava/lang/CharSequence;");
    if (coerceToText is null)
        return null;
    jvalue[1] ctx;
    ctx[0].l = f.activity;
    auto seq = (*env).CallObjectMethodA(env, item, coerceToText, ctx.ptr);
    if (f.failed || seq is null)
        return null;

    auto seqClass = (*env).GetObjectClass(env, seq);
    auto toString = (*env).GetMethodID(env, seqClass, "toString", "()Ljava/lang/String;");
    if (toString is null)
        return null;
    auto str = cast(jstring) (*env).CallObjectMethodA(env, seq, toString, null);
    if (f.failed)
        return null;
    return f.toDString(str);
}
