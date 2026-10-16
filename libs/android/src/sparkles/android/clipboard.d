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
    import sparkles.base.text.utf16 : measureConversion, utf8ToUtf16;

    const measured = measureConversion!wchar(text);
    if (measured.hasError)
        return false; // invalid UTF in the selection → report the failure
    auto utf16 = new wchar[measured.value.required];
    if (utf8ToUtf16(text, utf16).hasError)
        return false;
    return (() @trusted => setUtf16(utf16, label))();
}

private bool setUtf16(scope const(wchar)[] text, string label) @system nothrow
{
    return withJni((ref JniFrame f) => setOnWorker(f, text, label));
}

private bool setOnWorker(ref JniFrame f, scope const(wchar)[] text, string label) @system nothrow
{
    import sparkles.base.text.utf16 : measureConversion, utf8ToUtf16;

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

    const measured = measureConversion!wchar(label);
    if (measured.hasError)
        return false;
    auto label16 = new wchar[measured.value.required];
    if (utf8ToUtf16(label, label16).hasError)
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

// ── streamed access, for the `sparkles:wsi` Android backend ─────────────────
//
// The whole-string calls above copy a clip into D in one go. The calls below
// let a caller describe a clip, hold its text on the Java side, and read it in
// bounded UTF-16 slices, so a large paste never exists twice in this process.

/// The most MIME types a clip description is read for.
enum size_t maxClipTypes = 8;

/// What the clipboard holds, without its content.
struct ClipDescription
{
    bool present;    /// the clipboard holds a clip
    long timestamp;  /// `ClipDescription.getTimestamp()`: changes with every clip
    char[255][maxClipTypes] types; /// MIME types, as UTF-8
    ubyte[maxClipTypes] typeLengths;
    ubyte typeCount;

    const(char)[] type(size_t i) const return @safe pure nothrow @nogc
        => types[i][0 .. typeLengths[i]];
}

/**
Reads the primary clip's description: its MIME types and timestamp. `present`
is false for an empty or unreadable clipboard (Android 10+ refuses an app
without focus).
*/
ClipDescription describePrimaryClip() @trusted nothrow
{
    return withJni((ref JniFrame f) => describeOnWorker(f));
}

private ClipDescription describeOnWorker(ref JniFrame f) @system nothrow
{
    ClipDescription result;
    auto clipboard = f.systemService("clipboard");
    auto description = f.callObject(clipboard, "getPrimaryClipDescription",
        "()Landroid/content/ClipDescription;");
    if (f.failed || description is null)
        return result;
    auto env = f.env;
    auto descriptionClass = (*env).GetObjectClass(env, description);
    auto getTimestamp = (*env).GetMethodID(env, descriptionClass, "getTimestamp", "()J");
    if (getTimestamp !is null)
        result.timestamp = (*env).CallLongMethodA(env, description, getTimestamp, null);
    if (f.failed)
        return result;
    const count = f.callInt(description, "getMimeTypeCount", "()I");
    const int limit = count < cast(int) maxClipTypes ? count : cast(int) maxClipTypes;
    foreach (int i; 0 .. limit)
    {
        jvalue[1] index;
        index[0].i = i;
        auto mime = cast(jstring) f.callObject(description, "getMimeType",
            "(I)Ljava/lang/String;", index[]);
        if (f.failed || mime is null)
            return result;
        // MIME types are ASCII; `GetStringUTFRegion` writes them as is.
        const length = (*env).GetStringUTFLength(env, mime);
        if (length <= 0 || length > result.types[0].length)
            continue;
        (*env).GetStringUTFRegion(env, mime, 0, (*env).GetStringLength(env, mime),
            result.types[result.typeCount].ptr);
        result.typeLengths[result.typeCount] = cast(ubyte) length;
        ++result.typeCount;
    }
    result.present = true;
    return result;
}

/// The primary clip's text, held on the Java side by a global reference.
struct ClipText
{
    void* global; /// a `jstring` global reference; null when closed
    size_t length; /// in UTF-16 code units
}

/**
Holds the primary clip's first item as text (`coerceToText`, so a URI clip
still yields its text form). `global` is null when there is nothing to read.
Release it with $(LREF closeClipText).
*/
ClipText openPrimaryClipText() @trusted nothrow
{
    return withJni((ref JniFrame f) => openOnWorker(f));
}

private ClipText openOnWorker(ref JniFrame f) @system nothrow
{
    ClipText result;
    auto clipboard = f.systemService("clipboard");
    auto clip = f.callObject(clipboard, "getPrimaryClip", "()Landroid/content/ClipData;");
    if (f.failed || clip is null || f.callInt(clip, "getItemCount", "()I") <= 0)
        return result;
    jvalue[1] index;
    index[0].i = 0;
    auto item = f.callObject(clip, "getItemAt", "(I)Landroid/content/ClipData$Item;",
        index[]);
    jvalue[1] context;
    context[0].l = f.activity;
    auto sequence = f.callObject(item, "coerceToText",
        "(Landroid/content/Context;)Ljava/lang/CharSequence;", context[]);
    auto text = cast(jstring) f.callObject(sequence, "toString", "()Ljava/lang/String;");
    if (f.failed || text is null)
        return result;
    auto env = f.env;
    result.global = (*env).NewGlobalRef(env, text);
    result.length = (*env).GetStringLength(env, text);
    return result;
}

/**
Copies the UTF-16 units `[offset, offset + into.length)` of `text` into
`into`, clipped to the text's end; returns how many it copied.
*/
size_t readClipText(in ClipText text, size_t offset, scope wchar[] into) @trusted nothrow
{
    if (text.global is null || offset >= text.length)
        return 0;
    const n = text.length - offset < into.length ? text.length - offset : into.length;
    return withJni((ref JniFrame f) {
        auto env = f.env;
        (*env).GetStringRegion(env, cast(jstring) text.global, cast(jsize) offset,
            cast(jsize) n, cast(jchar*) into.ptr);
        return f.failed ? size_t(0) : n;
    });
}

/// Releases what $(LREF openPrimaryClipText) holds.
void closeClipText(ref ClipText text) @trusted nothrow
{
    if (text.global is null)
        return;
    auto global = text.global;
    text = ClipText.init;
    withJni((ref JniFrame f) { (*f.env).DeleteGlobalRef(f.env, cast(jobject) global); });
}

/**
Sets the primary clip to `text` under `mimeTypes`, which may name any types:
the description declares them and the one item carries the text. Returns the
new clip's timestamp, or 0 when a JNI step failed (a clip larger than a Binder
transaction, about 1 MB, fails this way).
*/
long setPrimaryClipTyped(scope const(char)[] label, scope const(char[])[] mimeTypes,
    scope const(wchar)[] text) @trusted nothrow
{
    return withJni((ref JniFrame f) => setTypedOnWorker(f, label, mimeTypes, text));
}

private long setTypedOnWorker(ref JniFrame f, scope const(char)[] label,
    scope const(char[])[] mimeTypes, scope const(wchar)[] text) @system nothrow
{
    import std.string : toStringz;

    auto env = f.env;
    auto stringClass = (*env).FindClass(env, "java/lang/String");
    auto types = (*env).NewObjectArray(env, cast(jsize) mimeTypes.length, stringClass, null);
    if (f.failed || types is null)
        return 0;
    foreach (i, mime; mimeTypes)
    {
        auto jmime = (*env).NewStringUTF(env, mime.toStringz); // MIME types are ASCII
        if (jmime is null)
            return 0;
        (*env).SetObjectArrayElement(env, types, cast(jsize) i, jmime);
    }
    auto jlabel = (*env).NewStringUTF(env, label.toStringz);
    auto jtext = f.newString(text);
    if (f.failed || jlabel is null || jtext is null)
        return 0;

    jvalue[2] descriptionArgs;
    descriptionArgs[0].l = jlabel;
    descriptionArgs[1].l = types;
    auto description = f.newObject("android/content/ClipDescription",
        "(Ljava/lang/CharSequence;[Ljava/lang/String;)V", descriptionArgs[]);
    jvalue[1] itemArgs;
    itemArgs[0].l = jtext;
    auto item = f.newObject("android/content/ClipData$Item",
        "(Ljava/lang/CharSequence;)V", itemArgs[]);
    jvalue[2] clipArgs;
    clipArgs[0].l = description;
    clipArgs[1].l = item;
    auto clip = f.newObject("android/content/ClipData",
        "(Landroid/content/ClipDescription;Landroid/content/ClipData$Item;)V", clipArgs[]);
    if (f.failed || clip is null)
        return 0;

    auto clipboard = f.systemService("clipboard");
    jvalue[1] setArgs;
    setArgs[0].l = clip;
    f.callVoid(clipboard, "setPrimaryClip", "(Landroid/content/ClipData;)V", setArgs[]);
    if (f.failed)
        return 0;
    return describeOnWorker(f).timestamp;
}
