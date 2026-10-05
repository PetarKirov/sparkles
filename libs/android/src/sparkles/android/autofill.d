/**
A password from the system's autofill service, typed into the terminal — the
spike behind the terminal's Autofill action (docs/specs/terminal/selection.md,
`TSE8`, `TSE9`).

Autofill services fill $(I views): they see a focused field with the
`password` hint and offer what they hold for it. A NativeActivity's surface is
no view, but $(MREF sparkles,android,ime)'s hidden field is one. So a request
borrows that field: it becomes an empty password input with the hint, and
`AutofillManager.requestAutofill` asks the service to fill it. What the
service writes is read once, handed to the caller, and the field goes back to
being the keyboard's sentinel run.

$(B The value goes to one place.) While a request holds the field, the IME's
poll does not diff it (a diff would turn the sentinel run's removal into
backspaces sent to the pty); the value waits in a fixed buffer, not on the GC
heap, until $(LREF takeAutofilled) hands it over and wipes it, and nothing
here logs it — only its length.

Every view operation runs on the main thread
($(MREF sparkles,android,main_thread)), like the field's own.
*/
module sparkles.android.autofill;

version (Android):

import core.atomic : atomicLoad, atomicStore, cas;

import jni_c;

/// `true` while a request holds the IME field; main thread only.
package __gshared bool autofillOwnsField;

/// The request's progress, shared between the glue and main threads.
private enum State : int
{
    idle,
    requested, /// the field waits for the service
    filled, /// a value waits in `value` for `takeAutofilled`
}

private shared int state;
private shared bool watchPending;
private __gshared char[512] value = 0;
private __gshared size_t valueLength;

/// What the last request learnt about the service (for the spike's record).
struct AutofillReport
{
    bool managerFound; /// `getSystemService(AutofillManager.class)` answered
    bool enabled; /// `AutofillManager.isEnabled()`
    bool requested; /// `requestAutofill(field)` returned without throwing
}

private __gshared AutofillReport lastReport;

/**
Ask the autofill service for a password, into the IME field. Asynchronous:
`false` when the field is not installed or a request is already open. Poll
$(LREF pollAutofill) each frame, then collect with $(LREF takeAutofilled).
*/
bool requestPasswordAutofill() @trusted nothrow @nogc
{
    import sparkles.android.ime : imeFieldActive;
    import sparkles.android.main_thread : postToMainThread;

    if (!imeFieldActive || !cas(&state, cast(int) State.idle, cast(int) State.requested))
        return false;
    if (postToMainThread(&requestJob, null))
        return true;
    atomicStore(state, cast(int) State.idle);
    return false;
}

private shared int enabledSeen = -1; // AutofillManager.isEnabled(), last asked
private shared bool enabledPending;

/**
Whether the selection menu may offer Autofill password (`TSE8`): the IME
field exists and `AutofillManager.isEnabled()` said so when last asked.
Asking is asynchronous — each call refreshes the answer for the next one —
so the first call after start may say `false`.
*/
bool autofillAvailable() @trusted nothrow @nogc
{
    import sparkles.android.ime : imeFieldActive;
    import sparkles.android.main_thread : postToMainThread;

    if (cas(&enabledPending, false, true) && !postToMainThread(&enabledJob, null))
        atomicStore(enabledPending, false);
    return imeFieldActive && atomicLoad(enabledSeen) == 1;
}

private void enabledJob(JNIEnv* env, void*) nothrow @nogc
{
    scope (exit) atomicStore(enabledPending, false);
    auto am = autofillManager(env);
    if (am is null)
        return atomicStore(enabledSeen, 0);
    auto isEnabled = (*env).GetMethodID(env, (*env).GetObjectClass(env, am), "isEnabled", "()Z");
    const on = (*env).CallBooleanMethodA(env, am, isEnabled, null) != 0;
    atomicStore(enabledSeen, (*env).ExceptionCheck(env) ? 0 : on ? 1 : 0);
    (*env).ExceptionClear(env);
}

/// `true` while a request waits for the service.
bool autofillPending() @trusted nothrow @nogc => atomicLoad(state) == State.requested;

/// The last request's findings.
AutofillReport autofillReport() @trusted nothrow @nogc => lastReport;

/// Look at the field for a filled value; call once per frame while
/// $(LREF autofillPending). Coalesces like the IME's poll.
void pollAutofill() @trusted nothrow @nogc
{
    import sparkles.android.main_thread : postToMainThread;

    if (atomicLoad(state) != State.requested || !cas(&watchPending, false, true))
        return;
    if (!postToMainThread(&watchJob, null))
        atomicStore(watchPending, false);
}

/// Give up on an open request: the field returns to the keyboard and nothing
/// is sent.
void cancelPasswordAutofill() @trusted nothrow @nogc
{
    import sparkles.android.main_thread : postToMainThread;

    if (atomicLoad(state) == State.requested)
        cast(void) postToMainThread(&restoreJob, null);
}

/**
Hand a filled value to `sink` — once, borrowed for the call — then wipe it;
`false` when there is none. `sink` must send it on and keep no copy.
*/
bool takeAutofilled(scope void delegate(scope const(char)[] secret) nothrow sink) @trusted nothrow
{
    if (atomicLoad(state) != State.filled)
        return false;
    scope (exit)
    {
        value[] = 0;
        valueLength = 0;
        atomicStore(state, cast(int) State.idle);
    }
    sink(value[0 .. valueLength]);
    return true;
}

/**
Test hook: fill the field as a service would — `View.autofill(AutofillValue)`,
the call the framework makes with a service's dataset — with `text`, so the
path from the fill to the pty can be checked for leaks without a real service
(`TSE9`). Only meaningful while a request is open.
*/
void fakeAutofill(scope const(char)[] text) @trusted nothrow @nogc
{
    import sparkles.android.main_thread : postToMainThread;

    if (atomicLoad(state) != State.requested)
        return;
    const n = text.length < fakeText.length - 1 ? text.length : fakeText.length - 1;
    fakeText[0 .. n] = text[0 .. n];
    fakeText[n] = 0; // for NewStringUTF
    fakeLength = n;
    cast(void) postToMainThread(&fakeJob, null);
}

private __gshared char[128] fakeText = 0;
private __gshared size_t fakeLength;

// ── main-thread jobs ────────────────────────────────────────────────────────

private enum int inputTypePassword = 0x1 | 0x80; // TYPE_CLASS_TEXT | TYPE_TEXT_VARIATION_PASSWORD
private enum int importantYes = 1; // View.IMPORTANT_FOR_AUTOFILL_YES
private enum int importantNo = 2; // View.IMPORTANT_FOR_AUTOFILL_NO

private void requestJob(JNIEnv* env, void*) nothrow @nogc
{
    import sparkles.android.ime : callInt, field;

    lastReport = AutofillReport.init;
    if (field is null)
        return atomicStore(state, cast(int) State.idle);
    autofillOwnsField = true;

    callInt(env, field, "setInputType", inputTypePassword);
    setHints(env, "password");
    callInt(env, field, "setImportantForAutofill", importantYes);
    clearText(env);
    auto view = (*env).GetObjectClass(env, field);
    auto focus = (*env).GetMethodID(env, view, "requestFocus", "()Z");
    cast(void) (*env).CallBooleanMethodA(env, field, focus, null);

    auto am = autofillManager(env);
    if (am is null)
        return;
    lastReport.managerFound = true;
    auto amCls = (*env).GetObjectClass(env, am);
    auto isEnabled = (*env).GetMethodID(env, amCls, "isEnabled", "()Z");
    lastReport.enabled = (*env).CallBooleanMethodA(env, am, isEnabled, null) != 0;
    auto request = (*env).GetMethodID(env, amCls, "requestAutofill", "(Landroid/view/View;)V");
    jvalue[1] a;
    a[0].l = field;
    (*env).CallVoidMethodA(env, am, request, a.ptr);
    lastReport.requested = !(*env).ExceptionCheck(env);
}

private void watchJob(JNIEnv* env, void*) nothrow @nogc
{
    import sparkles.base.text.utf : convertPrefix, UtfMode;
    import sparkles.android.ime : field;

    scope (exit) atomicStore(watchPending, false);
    if (!autofillOwnsField || field is null)
        return;
    auto text = fieldText(env);
    if (text is null)
        return;
    const len = (*env).GetStringLength(env, text);
    if (len == 0)
        return;
    auto units = (*env).GetStringChars(env, text, null);
    if (units is null)
        return;
    // GetStringChars is ordinary UTF-16; preserve whole-scalar truncation.
    valueLength = convertPrefix((cast(const(wchar)*) units)[0 .. len],
        value[], UtfMode.replacement).written;
    (*env).ReleaseStringChars(env, text, units);
    restore(env);
    atomicStore(state, cast(int) State.filled);
}

private void restoreJob(JNIEnv* env, void*) nothrow @nogc
{
    if (!autofillOwnsField)
        return;
    restore(env);
    atomicStore(state, cast(int) State.idle);
}

private void fakeJob(JNIEnv* env, void*) nothrow @nogc
{
    import sparkles.android.ime : field;

    if (!autofillOwnsField || field is null)
        return;
    auto s = (*env).NewStringUTF(env, fakeText.ptr);
    auto avCls = (*env).FindClass(env, "android/view/autofill/AutofillValue");
    auto forText = (*env).GetStaticMethodID(env, avCls, "forText",
        "(Ljava/lang/CharSequence;)Landroid/view/autofill/AutofillValue;");
    jvalue[1] a;
    a[0].l = s;
    auto av = (*env).CallStaticObjectMethodA(env, avCls, forText, a.ptr);
    auto fill = (*env).GetMethodID(env, (*env).GetObjectClass(env, field), "autofill",
        "(Landroid/view/autofill/AutofillValue;)V");
    a[0].l = av;
    (*env).CallVoidMethodA(env, field, fill, a.ptr);
    fakeText[] = 0;
    fakeLength = 0;
}

// ── helpers (main thread) ───────────────────────────────────────────────────

/// The field back to the keyboard's: its input type, no hint, out of
/// autofill, the sentinel run — and the service's session ended unsaved.
private void restore(JNIEnv* env) nothrow @nogc
{
    import sparkles.android.ime : callInt, field, inputTypeText, resetField;

    clearText(env);
    auto am = autofillManager(env);
    if (am !is null)
    {
        auto cancel = (*env).GetMethodID(env, (*env).GetObjectClass(env, am), "cancel", "()V");
        (*env).CallVoidMethodA(env, am, cancel, null);
    }
    setHints(env, null);
    callInt(env, field, "setImportantForAutofill", importantNo);
    callInt(env, field, "setInputType", inputTypeText);
    resetField(env);
    autofillOwnsField = false;
}

private jstring fieldText(JNIEnv* env) nothrow @nogc
{
    import sparkles.android.ime : field;

    auto getText = (*env).GetMethodID(env, (*env).GetObjectClass(env, field), "getText",
        "()Landroid/text/Editable;");
    auto editable = (*env).CallObjectMethodA(env, field, getText, null);
    if (editable is null || (*env).ExceptionCheck(env))
        return null;
    auto objCls = (*env).FindClass(env, "java/lang/Object");
    auto toStr = (*env).GetMethodID(env, objCls, "toString", "()Ljava/lang/String;");
    auto s = cast(jstring) (*env).CallObjectMethodA(env, editable, toStr, null);
    return (*env).ExceptionCheck(env) ? null : s;
}

private void clearText(JNIEnv* env) nothrow @nogc
{
    import sparkles.android.ime : field;

    auto getText = (*env).GetMethodID(env, (*env).GetObjectClass(env, field), "getText",
        "()Landroid/text/Editable;");
    auto editable = (*env).CallObjectMethodA(env, field, getText, null);
    if (editable is null || (*env).ExceptionCheck(env))
        return;
    auto clear = (*env).GetMethodID(env, (*env).GetObjectClass(env, editable), "clear", "()V");
    (*env).CallVoidMethodA(env, editable, clear, null);
}

/// `field.setAutofillHints(hint)`, or no hints for a null `hint`.
private void setHints(JNIEnv* env, const(char)* hint) nothrow @nogc
{
    import sparkles.android.ime : field;

    jobjectArray arr = null;
    if (hint !is null)
    {
        auto strCls = (*env).FindClass(env, "java/lang/String");
        arr = (*env).NewObjectArray(env, 1, strCls, (*env).NewStringUTF(env, hint));
    }
    auto m = (*env).GetMethodID(env, (*env).GetObjectClass(env, field), "setAutofillHints",
        "([Ljava/lang/String;)V");
    jvalue[1] a;
    a[0].l = arr;
    (*env).CallVoidMethodA(env, field, m, a.ptr);
}

private jobject autofillManager(JNIEnv* env) nothrow @nogc
{
    import sparkles.android.activity : nativeActivity;

    auto activity = cast(jobject) nativeActivity().clazz;
    auto cls = (*env).FindClass(env, "android/view/autofill/AutofillManager");
    if (cls is null)
    {
        (*env).ExceptionClear(env);
        return null;
    }
    auto getService = (*env).GetMethodID(env, (*env).GetObjectClass(env, activity),
        "getSystemService", "(Ljava/lang/Class;)Ljava/lang/Object;");
    jvalue[1] a;
    a[0].l = cls;
    auto am = (*env).CallObjectMethodA(env, activity, getService, a.ptr);
    return (*env).ExceptionCheck(env) ? null : am;
}
