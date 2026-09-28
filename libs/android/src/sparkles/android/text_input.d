/**
Typed text for a NativeActivity.

raylib's `PLATFORM_ANDROID` backend records key $(I codes) only: it never
fills the character queue `GetCharPressed` drains, and it ignores the meta
state, so Shift+a and a soft keyboard's `é` both vanish. This module chains an
`onInputEvent` hook in front of raylib's and turns key events into text the
way the framework's own `KeyEvent.getUnicodeChar` would:

$(LIST
    * a key-down is translated through its device's `KeyCharacterMap` with
        the event's meta state (JNI; one call per keystroke) — Shift, Caps
        Lock and AltGr layouts all resolve there;
    * an `ACTION_MULTIPLE` event with `KEYCODE_UNKNOWN` is how an IME without
        an `InputConnection` commits text it has no key for (the framework's
        fallback connection sends it that way): its characters are read back
        through `AKeyEvent_toJava` (API 31+) and `KeyEvent.getCharacters`.
)

Ctrl and Alt chords produce no text — the terminal encodes those from the key
event itself, exactly as a desktop window reports them (GLFW's character
callback does not fire for them either).

The hook runs on the glue thread, called from raylib's `PollInputEvents`
(the JNI lookups hop to the worker, see $(MREF sparkles,android,jni)), and
$(LREF popTypedChar) drains the queue from the frame that follows it.
*/
module sparkles.android.text_input;

version (Android):

import sparkles.android.activity : AndroidApp, GetAndroidApp;
import sparkles.android.jni;

// <android/input.h> — the calls and constants the hook needs.
private extern (C) nothrow @nogc
{
    int AInputEvent_getType(const(void)* event);
    int AInputEvent_getDeviceId(const(void)* event);
    int AKeyEvent_getAction(const(void)* event);
    int AKeyEvent_getKeyCode(const(void)* event);
    int AKeyEvent_getMetaState(const(void)* event);
}

// API 31. Weak, so the library still loads on API 29/30, where IME text
// without a key simply cannot be read.
version (LDC)
    pragma(LDC_extern_weak) private extern (C) jobject AKeyEvent_toJava(
        JNIEnv* env, const(void)* keyEvent) nothrow @nogc;

private enum int inputEventTypeKey = 1;
private enum int keyActionDown = 0;
private enum int keyActionMultiple = 2;
private enum int keycodeUnknown = 0;
private enum int metaAltOn = 0x02;
private enum int metaCtrlOn = 0x1000;
private enum int metaMetaOn = 0x10000;
/// `KeyCharacterMap.COMBINING_ACCENT`: the result is a dead key's accent.
private enum int combiningAccent = 0x8000_0000;

private alias InputCallback = extern (C) int function(AndroidApp*, void*) nothrow;

private __gshared InputCallback chained;
private __gshared dchar[256] queue;
private __gshared size_t head, count;

/// JNI handles resolved on first use; global refs, held for the process.
private __gshared jclass kcmClass, keyEventClass;
private __gshared jmethodID kcmLoad, kcmGet, keyEventGetCharacters;
private __gshared int cachedDevice = int.min;
private __gshared jobject cachedMap;

/**
Install the hook in front of raylib's input callback. Call once, after the
window is open (raylib assigns its callback during `InitWindow`). Idempotent.
*/
void installTextInputHook() @trusted nothrow @nogc
{
    auto app = GetAndroidApp();
    auto current = cast(InputCallback) app.onInputEvent;
    if (current is &onInputEvent)
        return;
    chained = current;
    app.onInputEvent = cast(void*) &onInputEvent;
}

/// The next typed code point, or `0` when none is queued.
dchar popTypedChar() @trusted nothrow @nogc
{
    if (count == 0)
        return 0;
    const c = queue[head];
    head = (head + 1) % queue.length;
    --count;
    return c;
}

private void push(dchar c) @trusted nothrow @nogc
{
    if (c == 0 || count == queue.length)
        return; // a full queue drops: a frame never types 256 characters
    queue[(head + count) % queue.length] = c;
    ++count;
}

private extern (C) int onInputEvent(AndroidApp* app, void* event) nothrow
{
    if (AInputEvent_getType(event) == inputEventTypeKey)
        collectText(event);
    return chained !is null ? chained(app, event) : 0;
}

private void collectText(void* event) @trusted nothrow
{
    const action = AKeyEvent_getAction(event);
    const keyCode = AKeyEvent_getKeyCode(event);
    const meta = AKeyEvent_getMetaState(event);

    if (action == keyActionMultiple && keyCode == keycodeUnknown)
    {
        pushCharacters(event);
        return;
    }
    if (action != keyActionDown)
        return;
    if (meta & (metaCtrlOn | metaAltOn | metaMetaOn))
        return; // a chord: the key event carries it, not text

    const c = unicodeChar(AInputEvent_getDeviceId(event), keyCode, meta);
    if (c > 0 && !(c & combiningAccent))
        push(cast(dchar) c);
}

/// `KeyCharacterMap.load(deviceId).get(keyCode, metaState)`; 0 on any failure.
private int unicodeChar(int deviceId, int keyCode, int meta) @system nothrow
{
    return withJni((ref JniFrame f) => unicodeCharOnWorker(f, deviceId, keyCode, meta));
}

private int unicodeCharOnWorker(ref JniFrame f, int deviceId, int keyCode, int meta) @system nothrow
{
    auto env = f.env;

    if (kcmClass is null)
    {
        auto local = (*env).FindClass(env, "android/view/KeyCharacterMap");
        if (local is null)
            return 0;
        kcmClass = cast(jclass) (*env).NewGlobalRef(env, local);
        kcmLoad = (*env).GetStaticMethodID(env, kcmClass, "load",
            "(I)Landroid/view/KeyCharacterMap;");
        kcmGet = (*env).GetMethodID(env, kcmClass, "get", "(II)I");
        if (kcmLoad is null || kcmGet is null)
        {
            kcmClass = null;
            return 0;
        }
    }
    if (cachedDevice != deviceId || cachedMap is null)
    {
        jvalue[1] id;
        id[0].i = deviceId;
        auto map = (*env).CallStaticObjectMethodA(env, kcmClass, kcmLoad, id.ptr);
        if (f.failed || map is null)
            return 0;
        if (cachedMap !is null)
            (*env).DeleteGlobalRef(env, cachedMap);
        cachedMap = (*env).NewGlobalRef(env, map);
        cachedDevice = deviceId;
    }
    jvalue[2] args;
    args[0].i = keyCode;
    args[1].i = meta;
    const c = (*env).CallIntMethodA(env, cachedMap, kcmGet, args.ptr);
    return f.failed ? 0 : c;
}

/// An IME commit without a key: `KeyEvent.getCharacters()` (API 31+).
private void pushCharacters(void* event) @system nothrow
{
    version (LDC)
        if (&AKeyEvent_toJava is null)
            return;

    // The event stays valid for the round trip: the input callback that owns
    // it is blocked on this call.
    withJni((ref JniFrame f) => charactersOnWorker(f, event));
}

private void charactersOnWorker(ref JniFrame f, void* event) @system nothrow
{
    import std.utf : byDchar;

    auto env = f.env;

    auto jev = AKeyEvent_toJava(env, event);
    if (jev is null || f.failed)
        return;
    if (keyEventClass is null)
    {
        auto local = (*env).GetObjectClass(env, jev);
        keyEventClass = cast(jclass) (*env).NewGlobalRef(env, local);
        keyEventGetCharacters = (*env).GetMethodID(env, keyEventClass,
            "getCharacters", "()Ljava/lang/String;");
    }
    if (keyEventGetCharacters is null)
        return;
    auto chars = cast(jstring) (*env).CallObjectMethodA(env, jev,
        keyEventGetCharacters, null);
    if (f.failed || chars is null)
        return;
    foreach (dchar c; f.toDString(chars).byDchar)
        push(c);
}
