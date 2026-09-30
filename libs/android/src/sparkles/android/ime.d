/**
The soft keyboard's text, through a real `InputConnection`, with no Java.

An input method edits text through the `InputConnection` of the focused view,
and NativeActivity's own view has none: the framework then serves it through
a dummy connection, where a backspace edits an empty buffer (Gboard's does
nothing at all) and a character with no key — `©`, `√` — becomes an
`ACTION_MULTIPLE` key event whose text the native input queue drops. So this
module gives the IME a real editor: a framework `EditText`, created over JNI
on the main thread ($(MREF sparkles,android,main_thread)), one pixel in size
and invisible, holding focus.

$(B The field is a diff, not a document.) It always holds a run of
$(LREF sentinel) characters with the cursor at the end, so a backspace always
has something to delete. Each frame the glue thread asks the main thread to
compare the field with that run: characters deleted become backspaces,
characters inserted become text, a committed newline becomes Enter — all in
the order $(MREF sparkles,android,text_input) delivers typed text — and the run
is restored. Nothing is diffed while the IME holds a composing region
(suggestions are switched off, as Termux does, so a keyboard normally commits
at once).

Hardware and extra keys still arrive as key events in the native queue;
$(MREF sparkles,android,text_input) reports them handled, so the focused field
never sees them too.
*/
module sparkles.android.ime;

version (Android):

import core.atomic : atomicLoad, atomicStore, cas;

import jni_c;
import sparkles.android.ime_diff : diff, eachCodePoint, FieldEdit, isSentinelRun,
    sentinel, sentinelLength;
import sparkles.android.main_thread : mainThreadReady, postToMainThread;
import sparkles.android.text_input : imeBackspace, imeEnter, pushTyped;

// android.text.InputType / EditorInfo
private enum int inputTypeText = 0x1 // TYPE_CLASS_TEXT
    | 0x90 // TYPE_TEXT_VARIATION_VISIBLE_PASSWORD: no learning, no composing
    | 0x20000 // TYPE_TEXT_FLAG_MULTI_LINE: Enter commits "\n", never an action
    | 0x80000; // TYPE_TEXT_FLAG_NO_SUGGESTIONS
private enum int imeOptions = 0x02000000 // IME_FLAG_NO_FULLSCREEN
    | 0x10000000; // IME_FLAG_NO_EXTRACT_UI
private enum int showForced = 2; // InputMethodManager.SHOW_FORCED

private __gshared jobject field; // global ref, main thread only
private shared bool installed, pollPending;

/**
Create the field. Asynchronous; `false` when the main thread is not wired
(the manifest did not name the entry point), and the IME then keeps the
framework's dummy connection.
*/
bool installImeField() @trusted nothrow @nogc
{
    if (!mainThreadReady || atomicLoad(installed))
        return atomicLoad(installed);
    atomicStore(installed, true);
    return postToMainThread(&installJob, null);
}

/// `true` once the field is installed (text then arrives through it).
bool imeFieldActive() @trusted nothrow @nogc => atomicLoad(installed);

/// Ask for one diff of the field; call once per frame. Coalesces: a poll
/// already queued is not queued again.
void pollImeField() @trusted nothrow @nogc
{
    if (!atomicLoad(installed) || !cas(&pollPending, false, true))
        return;
    if (!postToMainThread(&pollJob, null))
        atomicStore(pollPending, false);
}

/// Show / hide the soft keyboard for the field; `false` when not installed.
bool showImeKeyboard(bool show) @trusted nothrow @nogc
{
    if (!atomicLoad(installed))
        return false;
    return postToMainThread(show ? &showJob : &hideJob, null);
}

// ── main-thread jobs ────────────────────────────────────────────────────────

private void installJob(JNIEnv* env, void*) nothrow @nogc
{
    import sparkles.android.activity : nativeActivity;

    auto activity = cast(jobject) nativeActivity().clazz;
    auto cls = (*env).FindClass(env, "android/widget/EditText");
    if (cls is null)
        return;
    auto ctor = (*env).GetMethodID(env, cls, "<init>", "(Landroid/content/Context;)V");
    jvalue[1] a;
    a[0].l = activity;
    auto view = (*env).NewObjectA(env, cls, ctor, a.ptr);
    if (view is null || (*env).ExceptionCheck(env))
        return;

    callInt(env, view, "setInputType", inputTypeText);
    callInt(env, view, "setImeOptions", imeOptions);
    callFloat(env, view, "setAlpha", 0);
    callBool(env, view, "setCursorVisible", false);
    callBool(env, view, "setFocusableInTouchMode", true);

    // activity.addContentView(view, new ViewGroup.LayoutParams(1, 1))
    auto lpCls = (*env).FindClass(env, "android/view/ViewGroup$LayoutParams");
    auto lpCtor = (*env).GetMethodID(env, lpCls, "<init>", "(II)V");
    jvalue[2] size;
    size[0].i = 1;
    size[1].i = 1;
    auto lp = (*env).NewObjectA(env, lpCls, lpCtor, size.ptr);
    auto actCls = (*env).GetObjectClass(env, activity);
    auto addView = (*env).GetMethodID(env, actCls, "addContentView",
        "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V");
    jvalue[2] args;
    args[0].l = view;
    args[1].l = lp;
    (*env).CallVoidMethodA(env, activity, addView, args.ptr);
    if ((*env).ExceptionCheck(env))
        return;

    field = (*env).NewGlobalRef(env, view);
    resetField(env);
    auto focus = (*env).GetMethodID(env, (*env).GetObjectClass(env, view),
        "requestFocus", "()Z");
    cast(void) (*env).CallBooleanMethodA(env, view, focus, null);
}

private void pollJob(JNIEnv* env, void*) nothrow @nogc
{
    scope (exit) atomicStore(pollPending, false);
    if (field is null)
        return;

    auto viewCls = (*env).GetObjectClass(env, field);
    auto getText = (*env).GetMethodID(env, viewCls, "getText", "()Landroid/text/Editable;");
    auto editable = (*env).CallObjectMethodA(env, field, getText, null);
    if (editable is null || (*env).ExceptionCheck(env))
        return;

    // A composing region is text the IME has not committed yet.
    auto bic = (*env).FindClass(env, "android/view/inputmethod/BaseInputConnection");
    auto composing = (*env).GetStaticMethodID(env, bic, "getComposingSpanStart",
        "(Landroid/text/Spannable;)I");
    jvalue[1] e;
    e[0].l = editable;
    if ((*env).CallStaticIntMethodA(env, bic, composing, e.ptr) >= 0)
        return;

    auto objCls = (*env).FindClass(env, "java/lang/Object");
    auto toStr = (*env).GetMethodID(env, objCls, "toString", "()Ljava/lang/String;");
    auto str = cast(jstring) (*env).CallObjectMethodA(env, editable, toStr, null);
    if (str is null || (*env).ExceptionCheck(env))
        return;
    const len = (*env).GetStringLength(env, str);
    auto units = (*env).GetStringChars(env, str, null);
    if (units is null)
        return;
    scope (exit) (*env).ReleaseStringChars(env, str, units);

    const text = (cast(const(wchar)*) units)[0 .. len];
    if (isSentinelRun(text))
        return; // nothing typed

    feed(diff(text));
    resetField(env);
}

private void showJob(JNIEnv* env, void*) nothrow @nogc
{
    if (field is null)
        return;
    auto imm = inputMethodManager(env);
    if (imm is null)
        return;
    auto focus = (*env).GetMethodID(env, (*env).GetObjectClass(env, field),
        "requestFocus", "()Z");
    cast(void) (*env).CallBooleanMethodA(env, field, focus, null);
    auto show = (*env).GetMethodID(env, (*env).GetObjectClass(env, imm),
        "showSoftInput", "(Landroid/view/View;I)Z");
    jvalue[2] a;
    a[0].l = field;
    a[1].i = showForced;
    cast(void) (*env).CallBooleanMethodA(env, imm, show, a.ptr);
}

private void hideJob(JNIEnv* env, void*) nothrow @nogc
{
    if (field is null)
        return;
    auto imm = inputMethodManager(env);
    if (imm is null)
        return;
    auto getToken = (*env).GetMethodID(env, (*env).GetObjectClass(env, field),
        "getWindowToken", "()Landroid/os/IBinder;");
    auto token = (*env).CallObjectMethodA(env, field, getToken, null);
    auto hide = (*env).GetMethodID(env, (*env).GetObjectClass(env, imm),
        "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z");
    jvalue[2] a;
    a[0].l = token;
    a[1].i = 0;
    cast(void) (*env).CallBooleanMethodA(env, imm, hide, a.ptr);
}

// ── helpers (main thread) ───────────────────────────────────────────────────

/// Put the sentinel run back, cursor at its end — through the `Editable`, so
/// the IME sees an edit, not a new field (`setText` would restart input).
private void resetField(JNIEnv* env) nothrow @nogc
{
    wchar[sentinelLength] run = sentinel;
    auto s = (*env).NewString(env, cast(const(jchar)*) run.ptr, sentinelLength);
    auto viewCls = (*env).GetObjectClass(env, field);
    auto getText = (*env).GetMethodID(env, viewCls, "getText", "()Landroid/text/Editable;");
    auto editable = (*env).CallObjectMethodA(env, field, getText, null);
    if (editable is null || (*env).ExceptionCheck(env))
        return;
    auto edCls = (*env).GetObjectClass(env, editable);
    auto length = (*env).GetMethodID(env, edCls, "length", "()I");
    const n = (*env).CallIntMethodA(env, editable, length, null);
    auto replace = (*env).GetMethodID(env, edCls, "replace",
        "(IILjava/lang/CharSequence;)Landroid/text/Editable;");
    jvalue[3] r;
    r[0].i = 0;
    r[1].i = n;
    r[2].l = s;
    cast(void) (*env).CallObjectMethodA(env, editable, replace, r.ptr);
    callInt(env, field, "setSelection", sentinelLength);
}

private jobject inputMethodManager(JNIEnv* env) nothrow @nogc
{
    import sparkles.android.activity : nativeActivity;

    auto activity = cast(jobject) nativeActivity().clazz;
    auto getService = (*env).GetMethodID(env, (*env).GetObjectClass(env, activity),
        "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    jvalue[1] a;
    a[0].l = (*env).NewStringUTF(env, "input_method");
    auto imm = (*env).CallObjectMethodA(env, activity, getService, a.ptr);
    return (*env).ExceptionCheck(env) ? null : imm;
}

private void callInt(JNIEnv* env, jobject o, const(char)* name, int v) nothrow @nogc
{
    auto m = (*env).GetMethodID(env, (*env).GetObjectClass(env, o), name, "(I)V");
    if (m is null)
        return (*env).ExceptionClear(env);
    jvalue[1] a;
    a[0].i = v;
    (*env).CallVoidMethodA(env, o, m, a.ptr);
}

private void callBool(JNIEnv* env, jobject o, const(char)* name, bool v) nothrow @nogc
{
    auto m = (*env).GetMethodID(env, (*env).GetObjectClass(env, o), name, "(Z)V");
    if (m is null)
        return (*env).ExceptionClear(env);
    jvalue[1] a;
    a[0].z = v;
    (*env).CallVoidMethodA(env, o, m, a.ptr);
}

private void callFloat(JNIEnv* env, jobject o, const(char)* name, float v) nothrow @nogc
{
    auto m = (*env).GetMethodID(env, (*env).GetObjectClass(env, o), name, "(F)V");
    if (m is null)
        return (*env).ExceptionClear(env);
    jvalue[1] a;
    a[0].f = v;
    (*env).CallVoidMethodA(env, o, m, a.ptr);
}

/// Deliver an edit in the order it happened: backspaces, then the text.
private void feed(FieldEdit e) nothrow @nogc
{
    foreach (_; 0 .. e.deleted)
        pushTyped(imeBackspace);
    eachCodePoint(e.inserted, (dchar c) { pushTyped(c == '\n' ? imeEnter : c); });
}
