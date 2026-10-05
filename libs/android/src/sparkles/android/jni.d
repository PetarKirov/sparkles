/**
The JNI calling frame every bridge in this package stands on.

`hasCode="false"` means the APK ships no Java, but the framework's classes are
all reachable through JNI from native code — clipboard, soft input, wake
locks, intents. A bridge opens a $(LREF JniFrame), makes its calls, and the
frame's destructor releases every local reference and reports (describes, then
clears) any pending Java exception, so a failure shows up in logcat with its
stack trace instead of collapsing into an opaque `false`.

$(B Every JNI call runs on one worker thread) ($(LREF withJni)). The glue
thread D `main` runs on is not a safe place for them: `sparkles:ui-app` runs
its frames on event-horizon $(I fibers), whose stacks are heap blocks, and ART
checks the calling stack against the thread's real bounds — the first
`AttachCurrentThread` from a fiber aborts the process ("Check failed:
FindStackTop() > GetStackEnd()"), and interpreted Java called from one can
raise a spurious `StackOverflowError`. The worker is a real pthread, attached
once for the process lifetime (safe: the process exits with the activity), and
the caller blocks for the round trip — a bridge call is short, and every one
of them is already synchronous from the caller's point of view.

$(B Argument forms.) Method calls go through the `…A` forms, which take a
`jvalue[]` rather than C varargs — for legibility (each argument's JNI type is
written down), not ABI safety: LDC's `extern(C)` variadics are correct on both
ABIs.
*/
module sparkles.android.jni;

version (Android):

public import jni_c;

import sparkles.android.activity : nativeActivity;

/**
Run `job` on the JNI worker thread with a fresh $(LREF JniFrame) and return its
result; `R.init` when the worker could not attach. Re-entrant: a job that
calls another bridge runs it inline.
*/
R withJni(R)(scope R delegate(ref JniFrame) nothrow job) @trusted nothrow
{
    R result;
    scope void delegate() nothrow run = () {
        auto f = JniFrame.open();
        if (f.ok)
            result = job(f);
    };
    runOnWorker(run);
    return result;
}

/// ditto
void withJni(scope void delegate(ref JniFrame) nothrow job) @trusted nothrow
{
    scope void delegate() nothrow run = () {
        auto f = JniFrame.open();
        if (f.ok)
            job(f);
    };
    runOnWorker(run);
}

/// A `jvalue` holding an object reference (`jv(obj)`), an `int` or a
/// `boolean` — the argument cells of the `…A` call forms.
jvalue jv(jobject o) @trusted pure nothrow @nogc
{
    jvalue v;
    v.l = o;
    return v;
}

/// ditto
jvalue jv(int x) @trusted pure nothrow @nogc
{
    jvalue v;
    v.i = x;
    return v;
}

/// ditto
jvalue jv(bool b) @trusted pure nothrow @nogc
{
    jvalue v;
    v.z = b;
    return v;
}

// ── the worker ──────────────────────────────────────────────────────────────

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

private __gshared Mutex workerLock; // one request in flight
private __gshared Mutex stateLock;
private __gshared Condition stateCv;
private __gshared Thread worker;
private __gshared void delegate() nothrow pendingJob;
private __gshared bool jobDone;

shared static this() @trusted
{
    workerLock = new Mutex;
    stateLock = new Mutex;
    stateCv = new Condition(stateLock);
}

private void runOnWorker(scope void delegate() nothrow job) @trusted nothrow
{
    if (worker !is null && Thread.getThis() is worker)
    {
        job(); // re-entrant: already on the worker
        return;
    }
    try
    {
        workerLock.lock_nothrow();
        scope (exit) workerLock.unlock_nothrow();
        if (worker is null)
        {
            worker = new Thread(&workerLoop);
            worker.isDaemon = true;
            worker.start();
        }
        stateLock.lock_nothrow();
        scope (exit) stateLock.unlock_nothrow();
        pendingJob = job;
        jobDone = false;
        stateCv.notifyAll();
        while (!jobDone)
            stateCv.wait();
    }
    catch (Exception)
    {
        // Thread creation failed: the bridge reports its usual failure.
    }
}

private void workerLoop() nothrow
{
    for (;;)
    {
        void delegate() nothrow job;
        try
        {
            stateLock.lock_nothrow();
            scope (exit) stateLock.unlock_nothrow();
            while (pendingJob is null)
                stateCv.wait();
            job = pendingJob;
        }
        catch (Exception)
            continue;
        job();
        try
        {
            stateLock.lock_nothrow();
            scope (exit) stateLock.unlock_nothrow();
            pendingJob = null;
            jobDone = true;
            stateCv.notifyAll();
        }
        catch (Exception) {}
    }
}

/**
One JNI local-reference frame on the calling thread — the worker's, through
$(LREF withJni); never open one directly on the glue thread. Move-only; everything a
bridge creates between `open` and destruction is released by `PopLocalFrame`,
so no bridge tracks its own local references.
*/
struct JniFrame
{
    JNIEnv* env; /// null when attaching or pushing the frame failed

    @disable this(this);

    /// Attach the calling thread and push a local frame of `capacity` refs.
    static JniFrame open(int capacity = 32) @trusted nothrow @nogc
    {
        JniFrame f;
        auto vm = cast(JavaVM*) nativeActivity().vm;
        JNIEnv* env;
        if ((*vm).AttachCurrentThread(vm, &env, null) != JNI_OK || env is null)
            return f;
        if ((*env).PushLocalFrame(env, capacity) != 0)
        {
            (*env).ExceptionClear(env);
            return f;
        }
        f.env = env;
        return f;
    }

    ~this() @trusted nothrow @nogc
    {
        if (env is null)
            return;
        clearException();
        (*env).PopLocalFrame(env, null);
    }

    /// `true` once the frame is usable.
    bool ok() const @safe pure nothrow @nogc => env !is null;

    /// The `NativeActivity` Java object (a global reference owned by the
    /// framework; never released here).
    jobject activity() const @trusted nothrow @nogc
        => cast(jobject) nativeActivity().clazz;

    /**
    `true` when a Java exception is pending. It stays pending — the next JNI
    call would be undefined behaviour, so callers return right after — and the
    destructor describes it to logcat and clears it.
    */
    bool failed() @trusted nothrow @nogc => (*env).ExceptionCheck(env) != 0;

    /// Describe (to logcat) and clear a pending exception; `true` if one was.
    bool clearException() @trusted nothrow @nogc
    {
        if (!(*env).ExceptionCheck(env))
            return false;
        (*env).ExceptionDescribe(env);
        (*env).ExceptionClear(env);
        return true;
    }

    /// `activity.getSystemService(name)` — `null` on failure.
    jobject systemService(const(char)* name) @trusted nothrow @nogc
    {
        auto cls = (*env).GetObjectClass(env, activity);
        auto mid = (*env).GetMethodID(env, cls, "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;");
        if (mid is null)
            return null;
        auto jname = (*env).NewStringUTF(env, name); // ASCII service names
        if (jname is null)
            return null;
        jvalue[1] args;
        args[0].l = jname;
        auto svc = (*env).CallObjectMethodA(env, activity, mid, args.ptr);
        return failed ? null : svc;
    }

    /// A `java.lang.String` from UTF-16 — `NewString`, never `NewStringUTF`
    /// for arbitrary text: the latter wants $(I modified) UTF-8, where an
    /// astral scalar must arrive as a CESU-8 surrogate pair.
    jstring newString(scope const(wchar)[] text) @trusted nothrow @nogc
        => (*env).NewString(env, cast(const(jchar)*) text.ptr, cast(jsize) text.length);

    // ── chained calls ───────────────────────────────────────────────────────
    //
    // Each helper does nothing and returns `null`/`0`/`false` when its
    // receiver is null or an exception is already pending, so a bridge can
    // chain several calls and test `failed` (or the last result) once: a JNI
    // call made with an exception pending is undefined behaviour, and these
    // never make one.

    /// `obj.name(args)` returning an object, by JNI signature `sig`.
    jobject callObject(jobject obj, const(char)* name, const(char)* sig,
        scope jvalue[] args = null) @trusted nothrow @nogc
    {
        auto m = method(obj, name, sig);
        if (m is null)
            return null;
        auto r = (*env).CallObjectMethodA(env, obj, m, args.ptr);
        return failed ? null : r;
    }

    /// ditto, returning nothing; `false` when the call did not happen or threw.
    bool callVoid(jobject obj, const(char)* name, const(char)* sig,
        scope jvalue[] args = null) @trusted nothrow @nogc
    {
        auto m = method(obj, name, sig);
        if (m is null)
            return false;
        (*env).CallVoidMethodA(env, obj, m, args.ptr);
        return !failed;
    }

    /// ditto, returning an `int` (`fallback` when the call failed).
    int callInt(jobject obj, const(char)* name, const(char)* sig,
        scope jvalue[] args = null, int fallback = 0) @trusted nothrow @nogc
    {
        auto m = method(obj, name, sig);
        if (m is null)
            return fallback;
        const r = (*env).CallIntMethodA(env, obj, m, args.ptr);
        return failed ? fallback : r;
    }

    /// ditto, returning a `boolean` (`false` when the call failed).
    bool callBool(jobject obj, const(char)* name, const(char)* sig,
        scope jvalue[] args = null) @trusted nothrow @nogc
    {
        auto m = method(obj, name, sig);
        if (m is null)
            return false;
        const r = (*env).CallBooleanMethodA(env, obj, m, args.ptr);
        return !failed && r != 0;
    }

    /// `ClassName.name(args)`, a static method returning an object.
    jobject callStaticObject(const(char)* className, const(char)* name,
        const(char)* sig, scope jvalue[] args = null) @trusted nothrow @nogc
    {
        if (failed)
            return null;
        auto cls = (*env).FindClass(env, className);
        if (cls is null)
            return null;
        auto m = (*env).GetStaticMethodID(env, cls, name, sig);
        if (m is null)
            return null;
        auto r = (*env).CallStaticObjectMethodA(env, cls, m, args.ptr);
        return failed ? null : r;
    }

    /// `new ClassName(args)` through the constructor of signature `sig`.
    jobject newObject(const(char)* className, const(char)* sig,
        scope jvalue[] args = null) @trusted nothrow @nogc
    {
        if (failed)
            return null;
        auto cls = (*env).FindClass(env, className);
        if (cls is null)
            return null;
        auto ctor = (*env).GetMethodID(env, cls, "<init>", sig);
        if (ctor is null)
            return null;
        auto r = (*env).NewObjectA(env, cls, ctor, args.ptr);
        return failed ? null : r;
    }

    private jmethodID method(jobject obj, const(char)* name, const(char)* sig) @trusted nothrow @nogc
    {
        if (obj is null || failed)
            return null;
        return (*env).GetMethodID(env, (*env).GetObjectClass(env, obj), name, sig);
    }

    /// A D string from a `java.lang.String`; `null` for a null reference.
    string toDString(jstring s) @trusted nothrow
    {
        import sparkles.base.text.utf16 : measureConversion, utf16ToUtf8;
        import std.exception : assumeUnique;

        if (s is null)
            return null;
        const len = (*env).GetStringLength(env, s);
        auto chars = (*env).GetStringChars(env, s, null);
        if (chars is null)
            return null;
        scope (exit) (*env).ReleaseStringChars(env, s, chars);
        const source = (cast(const(wchar)*) chars)[0 .. len];
        const measured = measureConversion!char(source);
        if (measured.hasError)
            return null; // unpaired surrogate
        auto bytes = new char[measured.value.required];
        if (utf16ToUtf8(source, bytes).hasError)
            return null;
        return assumeUnique(bytes);
    }
}
