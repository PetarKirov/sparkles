/**
HTTP(S) downloads through the framework's `java.net.HttpURLConnection` — the
platform's TLS stack, trust store and proxy settings, with no TLS library in
the APK and no Java in it either (the calls are JNI into framework classes).

$(B Threading.) Unlike the short bridges, a download runs for minutes, so it
does not go through the shared JNI worker ($(REF withJni,
sparkles,android,jni)) — that would stall every keystroke's `KeyCharacterMap`
lookup behind it. It runs on the $(I calling) thread, which must be a real
thread (never a fiber: ART checks the stack bounds), and attaches it to the VM
for the duration; $(LREF download) detaches it again before returning.
*/
module sparkles.android.http;

version (Android):

import sparkles.android.jni;

/// A download's progress: `got` bytes of `total` (`-1` when the server sent
/// no length).
alias DownloadProgress = void delegate(long got, long total) nothrow;

/**
GET `url` into the file `dest` (created or truncated), following redirects.
Returns `null` on success, else a one-line reason (the HTTP status, or the Java
exception's message). A failed download removes `dest`.

Timeouts: 20 s to connect, 60 s between reads.
*/
string download(string url, string dest, scope DownloadProgress progress = null) @system nothrow
{
    import std.file : remove;

    auto vm = cast(JavaVM*) nativeActivityVm();
    scope (exit) (*vm).DetachCurrentThread(vm);

    string err;
    {
        auto f = JniFrame.open(64);
        if (!f.ok)
            return "cannot attach the downloader thread to the Java VM";
        err = downloadWith(f, url, dest, progress);
    }
    if (err !is null)
    {
        try
            remove(dest);
        catch (Exception) {}
    }
    return err;
}

private void* nativeActivityVm() @trusted nothrow @nogc
{
    import sparkles.android.activity : nativeActivity;

    return nativeActivity().vm;
}

private string downloadWith(ref JniFrame f, string url, string dest,
    scope DownloadProgress progress) @system nothrow
{
    import std.stdio : File;
    import std.utf : toUTF16;

    auto env = f.env;

    // new URL(url).openConnection()
    auto urlClass = (*env).FindClass(env, "java/net/URL");
    if (urlClass is null)
        return "java.net.URL unavailable";
    auto urlCtor = (*env).GetMethodID(env, urlClass, "<init>", "(Ljava/lang/String;)V");
    wstring url16;
    try
        url16 = url.toUTF16;
    catch (Exception)
        return "the URL is not valid UTF-8";
    auto jurl = f.newString(url16);
    if (urlCtor is null || jurl is null)
        return "cannot build the URL";
    jvalue[1] ctorArgs;
    ctorArgs[0].l = jurl;
    auto urlObj = (*env).NewObjectA(env, urlClass, urlCtor, ctorArgs.ptr);
    if (f.failed || urlObj is null)
        return fail(f, "malformed URL");

    auto openConnection = (*env).GetMethodID(env, urlClass, "openConnection",
        "()Ljava/net/URLConnection;");
    auto conn = (*env).CallObjectMethodA(env, urlObj, openConnection, null);
    if (f.failed || conn is null)
        return fail(f, "cannot open a connection");

    auto connClass = (*env).FindClass(env, "java/net/HttpURLConnection");
    if (connClass is null || !(*env).IsInstanceOf(env, conn, connClass))
        return "not an http(s) URL";

    callVoidInt(f, conn, connClass, "setConnectTimeout", 20_000);
    callVoidInt(f, conn, connClass, "setReadTimeout", 60_000);
    auto follow = (*env).GetMethodID(env, connClass, "setInstanceFollowRedirects", "(Z)V");
    jvalue[1] yes;
    yes[0].z = JNI_TRUE;
    (*env).CallVoidMethodA(env, conn, follow, yes.ptr);
    if (f.failed)
        return fail(f, "cannot configure the connection");

    auto getCode = (*env).GetMethodID(env, connClass, "getResponseCode", "()I");
    const code = (*env).CallIntMethodA(env, conn, getCode, null);
    if (f.failed)
        return fail(f, "connection failed");
    scope (exit)
    {
        auto disconnect = (*env).GetMethodID(env, connClass, "disconnect", "()V");
        (*env).CallVoidMethodA(env, conn, disconnect, null);
        f.clearException();
    }
    if (code != 200)
    {
        import std.conv : to;

        try
            return "HTTP " ~ code.to!string;
        catch (Exception)
            return "HTTP error";
    }

    auto getLength = (*env).GetMethodID(env, connClass, "getContentLengthLong", "()J");
    const total = getLength is null ? -1L : (*env).CallLongMethodA(env, conn, getLength, null);
    f.clearException();

    auto getStream = (*env).GetMethodID(env, connClass, "getInputStream",
        "()Ljava/io/InputStream;");
    auto stream = (*env).CallObjectMethodA(env, conn, getStream, null);
    if (f.failed || stream is null)
        return fail(f, "no response body");
    auto streamClass = (*env).GetObjectClass(env, stream);
    auto read = (*env).GetMethodID(env, streamClass, "read", "([B)I");
    auto close = (*env).GetMethodID(env, streamClass, "close", "()V");
    scope (exit)
    {
        (*env).CallVoidMethodA(env, stream, close, null);
        f.clearException();
    }

    enum chunk = 64 * 1024;
    auto jbuf = (*env).NewByteArray(env, chunk);
    if (jbuf is null)
        return "out of memory";
    ubyte[chunk] buf = void;

    try
    {
        auto file = File(dest, "wb");
        long got;
        for (;;)
        {
            jvalue[1] arg;
            arg[0].l = jbuf;
            const n = (*env).CallIntMethodA(env, stream, read, arg.ptr);
            if (f.failed)
                return fail(f, "the download was interrupted");
            if (n < 0)
                break; // end of stream
            if (n == 0)
                continue;
            (*env).GetByteArrayRegion(env, jbuf, 0, n, cast(jbyte*) buf.ptr);
            file.rawWrite(buf[0 .. n]);
            got += n;
            if (progress !is null)
                progress(got, total);
        }
        file.close();
        if (total >= 0 && got != total)
            return "the download was truncated";
    }
    catch (Exception e)
        return e.msg;
    return null;
}

private void callVoidInt(ref JniFrame f, jobject obj, jclass cls,
    const(char)* name, int value) @system nothrow
{
    auto env = f.env;
    auto mid = (*env).GetMethodID(env, cls, name, "(I)V");
    if (mid is null)
        return;
    jvalue[1] args;
    args[0].i = value;
    (*env).CallVoidMethodA(env, obj, mid, args.ptr);
}

/// `what`, plus the pending Java exception's `toString()` when there is one
/// — cleared here, so the cleanup that runs next makes its JNI calls with no
/// exception pending (anything else is undefined behaviour).
private string fail(ref JniFrame f, string what) @system nothrow
{
    const why = pendingMessage(f);
    return why.length ? what ~ ": " ~ why : what;
}

/// The pending exception's `toString()` (then cleared), or `""`.
private string pendingMessage(ref JniFrame f) @system nothrow
{
    auto env = f.env;
    auto ex = (*env).ExceptionOccurred(env);
    if (ex is null)
        return "";
    (*env).ExceptionClear(env);
    auto cls = (*env).GetObjectClass(env, ex);
    auto toString = (*env).GetMethodID(env, cls, "toString", "()Ljava/lang/String;");
    if (toString is null)
        return "";
    auto s = cast(jstring) (*env).CallObjectMethodA(env, ex, toString, null);
    if ((*env).ExceptionCheck(env))
    {
        (*env).ExceptionClear(env);
        return "";
    }
    return f.toDString(s);
}
