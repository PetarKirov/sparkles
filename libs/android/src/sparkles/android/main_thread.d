/**
Running native code on the activity's main (Java UI) thread, with no Java.

Views may only be touched from the thread that owns them, and a Java app
reaches it with `runOnUiThread`. A NativeActivity can do the same natively:
the main thread runs an `ALooper`, and a pipe registered on it with
`ALooper_addFd` makes the looper call back into native code whenever a byte is
written. The looper pointer can only be read on the main thread itself
(`ALooper_forThread`), so this module owns the activity's entry point: the
manifest names $(LREF sparkles_onCreate) as `android.app.func_name`, which
records the looper and the pipe and then hands over to native_app_glue's
`ANativeActivity_onCreate` unchanged.

Without that manifest entry nothing here is set up, and $(LREF postToMainThread)
returns `false`: an app opts in, and every caller keeps a fallback.

$(B The jobs run on a thread D knows nothing about.) The main thread is never
attached to druntime, so a job must not allocate from the GC, throw, or touch
thread-local state (every module-level variable a job reads is `__gshared`). It
gets the main thread's `JNIEnv*` and a local-reference frame around it.
*/
module sparkles.android.main_thread;

version (Android):

import core.sys.posix.pthread;

import jni_c : JNIEnv;

// <android/looper.h>
private extern (C) nothrow @nogc
{
    struct ALooper;
    alias ALooperCallback = extern (C) int function(int fd, int events, void* data) nothrow @nogc;
    ALooper* ALooper_forThread();
    void ALooper_acquire(ALooper* looper);
    int ALooper_addFd(ALooper* looper, int fd, int ident, int events,
        ALooperCallback callback, void* data);
}

private enum int looperPollCallback = -2; // ALOOPER_POLL_CALLBACK
private enum int looperEventInput = 1; // ALOOPER_EVENT_INPUT

/// native_app_glue's entry point, which this module's runs first.
private extern (C) void ANativeActivity_onCreate(void* activity, void* savedState,
    size_t savedStateSize) nothrow @nogc;

/// A job for the main thread: `env` is its `JNIEnv*`, inside a local frame.
alias MainThreadJob = void function(JNIEnv* env, void* context) nothrow @nogc;

private struct Pending
{
    MainThreadJob job;
    void* context;
}

private __gshared ALooper* mainLooper;
private __gshared JNIEnv* mainEnv;
private __gshared int wakeRead = -1, wakeWrite = -1;
private __gshared pthread_mutex_t queueLock = PTHREAD_MUTEX_INITIALIZER;
private __gshared Pending[32] queue;
private __gshared size_t queueHead, queueCount;

/**
The activity's entry point when the manifest names it
(`<meta-data android:name="android.app.func_name" android:value="sparkles_onCreate"/>`):
wire the main thread's looper, then start the app exactly as
native_app_glue would. Runs on the main thread, before druntime is up — C
calls and `__gshared` stores only.
*/
export extern (C) void sparkles_onCreate(void* activity, void* savedState,
    size_t savedStateSize) nothrow @nogc
{
    import core.sys.posix.fcntl : O_CLOEXEC, O_NONBLOCK;
    import sparkles.android.activity : ANativeActivity;

    int[2] fds;
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) == 0)
    {
        auto looper = ALooper_forThread();
        if (looper !is null
            && ALooper_addFd(looper, fds[0], looperPollCallback, looperEventInput,
                &onWake, null) == 1)
        {
            ALooper_acquire(looper);
            mainLooper = looper;
            mainEnv = cast(JNIEnv*) (cast(ANativeActivity*) activity).env;
            wakeRead = fds[0];
            wakeWrite = fds[1];
        }
    }
    ANativeActivity_onCreate(activity, savedState, savedStateSize);
}

private extern (C) int pipe2(ref int[2] fds, int flags) nothrow @nogc;

/// `true` once the entry point wired the main thread (the manifest opted in).
bool mainThreadReady() @trusted nothrow @nogc => mainLooper !is null;

/**
Queue `job(env, context)` to run on the main thread, and return at once;
`false` when the main thread is not wired or the queue is full. Never blocks
on the main thread: it may itself be waiting on the glue thread (a window
being destroyed is), and a synchronous call would deadlock.
*/
bool postToMainThread(MainThreadJob job, void* context) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : write;

    if (mainLooper is null)
        return false;
    pthread_mutex_lock(&queueLock);
    const full = queueCount == queue.length;
    if (!full)
    {
        queue[(queueHead + queueCount) % queue.length] = Pending(job, context);
        ++queueCount;
    }
    pthread_mutex_unlock(&queueLock);
    if (full)
        return false;
    ubyte one = 1;
    cast(void) write(wakeWrite, &one, 1); // a full pipe already wakes the looper
    return true;
}

private extern (C) int onWake(int fd, int events, void* data) nothrow @nogc
{
    import core.sys.posix.unistd : read;

    ubyte[64] drain = void;
    while (read(fd, drain.ptr, drain.length) > 0) {}

    for (;;)
    {
        Pending p;
        pthread_mutex_lock(&queueLock);
        if (queueCount > 0)
        {
            p = queue[queueHead];
            queueHead = (queueHead + 1) % queue.length;
            --queueCount;
        }
        pthread_mutex_unlock(&queueLock);
        if (p.job is null)
            break;
        run(p);
    }
    return 1; // keep the fd registered
}

private void run(Pending p) nothrow @nogc
{
    auto env = mainEnv;
    if ((*env).PushLocalFrame(env, 64) != 0)
    {
        (*env).ExceptionClear(env);
        return;
    }
    p.job(env, p.context);
    if ((*env).ExceptionCheck(env))
    {
        (*env).ExceptionDescribe(env);
        (*env).ExceptionClear(env);
    }
    (*env).PopLocalFrame(env, null);
}
