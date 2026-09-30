/**
Typed text for a NativeActivity.

raylib's `PLATFORM_ANDROID` backend records key $(I codes) only: it never
fills the character queue `GetCharPressed` drains, and it ignores the meta
state, so Shift+a vanishes. This module chains an `onInputEvent` hook in front
of raylib's and turns key events into text the way the framework's own
`KeyEvent.getUnicodeChar` would: a key-down is translated through its device's
`KeyCharacterMap` with the event's meta state (JNI; one call per keystroke) —
Shift, Caps Lock and AltGr layouts all resolve there.

The soft keyboard's text does not come through here: it is edited into the
hidden field of $(MREF sparkles,android,ime), which diffs it into this queue
with $(LREF pushTyped) — text as code points, and the two edits that are keys
rather than text as $(LREF imeBackspace) and $(LREF imeEnter).

$(B Every key event is reported handled) (system keys aside — volume, power,
media): the framework forwards an unhandled key to the focused view, and with
the IME field focused that would type every hardware key twice.

Ctrl and Alt chords produce no text — the terminal encodes those from the key
event itself, exactly as a desktop window reports them (GLFW's character
callback does not fire for them either).

The hook runs on the glue thread, called from raylib's `PollInputEvents`
(the JNI lookups hop to the worker, see $(MREF sparkles,android,jni)), the
IME field's diff on the main thread, and $(LREF popTypedChar) drains the queue
from the frame that follows them.
*/
module sparkles.android.text_input;

version (Android):

import core.sys.posix.pthread;

import sparkles.android.activity : AndroidApp, GetAndroidApp;
import sparkles.android.jni;

/// A backspace from the soft keyboard, in the typed-text queue: a key, where
/// every other entry is text (above Unicode's range, so never a character).
enum dchar imeBackspace = cast(dchar) 0x11_0001;
/// ditto — Enter (a committed newline).
enum dchar imeEnter = cast(dchar) 0x11_0002;

// <android/input.h> — the calls and constants the hook needs.
private extern (C) nothrow @nogc
{
    int AInputEvent_getType(const(void)* event);
    int AInputEvent_getDeviceId(const(void)* event);
    int AKeyEvent_getAction(const(void)* event);
    int AKeyEvent_getKeyCode(const(void)* event);
    int AKeyEvent_getMetaState(const(void)* event);
}

private enum int inputEventTypeKey = 1;
private enum int keyActionDown = 0;
private enum int metaAltOn = 0x02;
private enum int metaCtrlOn = 0x1000;
private enum int metaMetaOn = 0x10000;
/// `KeyCharacterMap.COMBINING_ACCENT`: the result is a dead key's accent.
private enum int combiningAccent = 0x8000_0000;

private alias InputCallback = extern (C) int function(AndroidApp*, void*) nothrow;

private __gshared InputCallback chained;
private __gshared pthread_mutex_t queueLock = PTHREAD_MUTEX_INITIALIZER;
private __gshared dchar[256] queue;
private __gshared size_t head, count;

/// JNI handles resolved on first use; global refs, held for the process.
private __gshared jclass kcmClass;
private __gshared jmethodID kcmLoad, kcmGet;
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

/// The next typed code point — or $(LREF imeBackspace) / $(LREF imeEnter) —
/// or `0` when none is queued.
dchar popTypedChar() @trusted nothrow @nogc
{
    pthread_mutex_lock(&queueLock);
    scope (exit) pthread_mutex_unlock(&queueLock);
    if (count == 0)
        return 0;
    const c = queue[head];
    head = (head + 1) % queue.length;
    --count;
    return c;
}

/// Queue a typed code point (or an IME key); any thread. A full queue drops:
/// a frame never types 256 characters.
void pushTyped(dchar c) @trusted nothrow @nogc
{
    if (c == 0)
        return;
    pthread_mutex_lock(&queueLock);
    scope (exit) pthread_mutex_unlock(&queueLock);
    if (count == queue.length)
        return;
    queue[(head + count) % queue.length] = c;
    ++count;
}

private extern (C) int onInputEvent(AndroidApp* app, void* event) nothrow
{
    const isKey = AInputEvent_getType(event) == inputEventTypeKey;
    if (isKey)
        collectText(event);
    const handled = chained !is null ? chained(app, event) : 0;
    return handled || (isKey && !isSystemKey(AKeyEvent_getKeyCode(event)));
}

/// Keys the system acts on (volume, power, media, …): left unhandled so it
/// still does.
private bool isSystemKey(int keyCode) @safe pure nothrow @nogc
{
    switch (keyCode)
    {
        case 3: // HOME
        case 24, 25, 164: // VOLUME_UP, VOLUME_DOWN, VOLUME_MUTE
        case 26, 223, 224: // POWER, SLEEP, WAKEUP
        case 27, 80: // CAMERA, FOCUS
        case 79, 85, 86, 87, 88, 89, 90, 91, 126, 127: // HEADSETHOOK, MEDIA_*, MUTE
        case 187, 219, 220, 221: // APP_SWITCH, ASSIST, BRIGHTNESS_DOWN/UP
            return true;
        default:
            return false;
    }
}

private void collectText(void* event) @trusted nothrow
{
    const action = AKeyEvent_getAction(event);
    const keyCode = AKeyEvent_getKeyCode(event);
    const meta = AKeyEvent_getMetaState(event);

    if (action != keyActionDown)
        return;
    if (meta & (metaCtrlOn | metaAltOn | metaMetaOn))
        return; // a chord: the key event carries it, not text

    const c = unicodeChar(AInputEvent_getDeviceId(event), keyCode, meta);
    if (c > 0 && !(c & combiningAccent))
        pushTyped(cast(dchar) c);
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
