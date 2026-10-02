/**
The protocol inbox (`TPR`): what the pty's OSC traffic asked of the host,
captured while the VT engine consumes it and handed to the embedder at frame
time — the title pattern (`EffectsContext.titleDirty`) widened to icons,
notifications and the clipboard.

Capture runs inside the pty feed, which is `@nogc nothrow` and must never
call out: an embedder's hook could close the pane mid-feed. So the feed only
$(I records) — bounded, pointer-free — and `TerminalView.deliverEvents`
applies the policy and calls the hooks afterwards. The one reply sent from
the feed is kitty's notification support query (`p=?`), which needs no
policy and must precede a DA1 answer that follows it in the same chunk.

The policy and hook vocabulary the embedder fills in
($(LREF ProtocolPolicy), $(LREF TerminalViewHooks)) lives here too.
*/
module sparkles.terminal_view.protocols;

import sparkles.base.buffer : HeapBuffer;
import sparkles.terminal_view.notification_log : NotificationRoute, NotifyWhen;
import sparkles.terminal_view.osc_query : OscScanner;
import sparkles.terminal_view.osc_scan;

/// Notifications held between two deliveries; more are counted and dropped.
enum size_t maxPendingNotifications = 32;

/// When a paste without bracketed-paste mode asks first (`paste.confirm`, `TPR19`).
enum PasteConfirm : ubyte
{
    multiline, /// a paste containing a line break (default)
    always,    /// every paste
    never,     /// none
}

/// OSC 52 read policy (`clipboard.osc52.read`, `TPR21`).
enum ClipboardReadPolicy : ubyte
{
    ask,   /// raise `clipboardReadRequest`; the embedder answers (default)
    allow, /// answer at once
    deny,  /// answer nothing
}

/// The answer to an OSC 52 read the embedder was asked about (`TPR21`).
enum ClipboardReadAnswer : ubyte
{
    deny,        /// send nothing
    allowOnce,   /// answer this read
    allowAlways, /// answer this one and every later read from this pane
}

/// The light/dark scheme in effect (`TPR13`, `TPR14`).
enum ColorScheme : ubyte
{
    dark,
    light,
}

/**
The protocol policy of one pane — the `notifications`, `paste` and
`clipboard.osc52` settings of the terminal's configuration, as plain values
the application fills in.
*/
struct ProtocolPolicy
{
    NotifyWhen notifyWhen = NotifyWhen.unseen;     /// `TPR9`
    PasteConfirm pasteConfirm = PasteConfirm.multiline; /// `TPR19`
    bool osc52Write = true;                        /// `TPR20`
    ClipboardReadPolicy osc52Read = ClipboardReadPolicy.ask; /// `TPR21`
}

/// What a paste awaiting confirmation is (`TPR19`), borrowed until answered.
struct PasteConfirmRequest
{
    size_t lines;            /// line count (line breaks + 1)
    const(char)[] text;      /// the whole paste, already stripped of controls
}

/**
The embedder's hooks: what each protocol event $(I does) belongs to the
application (a tab label, a system notification, the clipboard), so the
pane only reports. Every hook is optional; `TerminalView.deliverEvents`
calls them from the frame, never from inside the pty feed. Arguments are
borrowed for the call.
*/
struct TerminalViewHooks
{
    /// OSC 0/2: the pane's title changed (sanitized, `TPR1`/`TPR2`). Unset,
    /// the whole-surface component sets the window title instead.
    void delegate(scope const(char)[] title) titleChanged;
    /// OSC 0/1: the pane's icon string changed (one grapheme, ≤ 2 cells; may
    /// be empty when the program cleared it).
    void delegate(scope const(char)[] icon) iconChanged;
    /// OSC 7: the pane's working directory changed to an existing local path
    /// (`TPR4`).
    void delegate(scope const(char)[] path) cwdChanged;
    /// OSC 9/99/777 (`TPR8`), after routing (`TPR9`) and logging (`TPG9`):
    /// `route` says whether to post a system notification or show a toast.
    void delegate(in Notification n, NotificationRoute route) notify;
    /// OSC 52 write, allowed by the policy (`TPR20`): set the clipboard and
    /// show the "Copied by" toast. Unset, the host's `clipboard` errand sets it.
    void delegate(scope const(char)[] text) clipboardWrite;
    /// OSC 52 read under `ask` (`TPR21`): confirm, then answer with
    /// `TerminalView.answerClipboardRead`. Unset, `ask` answers nothing.
    void delegate() clipboardReadRequest;
    /// The clipboard's text for an allowed OSC 52 read. Unset, the platform
    /// clipboard (raylib on the desktop, JNI on Android) is read.
    const(char)[] delegate() clipboardText;
    /// A paste needs confirming (`TPR19`): answer with
    /// `TerminalView.confirmPaste`. Unset, the paste is sent unasked — an
    /// embedder without a confirmation surface cannot enforce the policy.
    void delegate(in PasteConfirmRequest r) pasteConfirm;
    /// The label of the tab holding this pane, for the notification log
    /// (`TPG9`). Unset, the pane's title.
    const(char)[] delegate() tabTitle;
}

/**
What the pty asked of the host since the last delivery — recorded inside the
feed, consumed by `TerminalView.deliverEvents`.
*/
struct ProtocolInbox
{
    char[maxIconBytes] icon = 0;
    size_t iconLen;
    bool iconDirty;

    HeapBuffer!Notification notifications;
    size_t droppedNotifications;
    KittyNotifyAssembler kitty;

    HeapBuffer!ubyte clipboard;
    bool clipboardWrite;
    bool clipboardOversize;

    char[12] readSelectors = 0;
    size_t readSelectorsLen;
    bool clipboardRead;
    bool readEndedWithBel;
}

/**
Records what one complete OSC sequence asks of the host — the icon of
OSC 0/1, a notification, an OSC 52 operation — and answers a kitty
notification query on `ptyFd`. Titles (OSC 0/2) and working directories
(OSC 7) arrive through the engine's own effects instead.
*/
@system nothrow @nogc
void observeOsc(ref ProtocolInbox inbox, ref const OscScanner sc, int ptyFd)
{
    const payload = sc.payload[];
    const command = oscCommand(payload);
    if (sc.overflowed)
    {
        if (command == 52)
            inbox.clipboardOversize = true;
        return;
    }
    switch (command)
    {
        case 0:
        case 1:
            inbox.iconLen = sanitizeIcon(oscArgs(payload), inbox.icon);
            inbox.iconDirty = true;
            break;
        case 9:
        case 99:
        case 777:
            Notification n;
            final switch (parseNotification(payload, inbox.kitty, n))
            {
                case NotifyOutcome.none:
                    break;
                case NotifyOutcome.ready:
                    if (inbox.notifications.length < maxPendingNotifications)
                        inbox.notifications ~= n;
                    else
                        ++inbox.droppedNotifications;
                    break;
                case NotifyOutcome.query:
                    replyKittyQuery(n.id, sc.endedWithBel, ptyFd);
                    break;
            }
            break;
        case 52:
            observeClipboard(inbox, payload, sc.endedWithBel);
            break;
        default:
            break;
    }
}

private void replyKittyQuery(scope const(char)[] id, bool endedWithBel, int ptyFd)
    @system nothrow @nogc
{
    import sparkles.terminal_view.input : pty_write;

    static struct Sink
    {
        char[160] buf;
        size_t len;
        void put(scope const(char)[] s) @safe pure nothrow @nogc
        {
            const n = s.length <= buf.length - len ? s.length : buf.length - len;
            buf[len .. len + n] = s[0 .. n];
            len += n;
        }
    }

    Sink w;
    writeKittyQueryReply(w, id, endedWithBel);
    pty_write(ptyFd, w.buf.ptr, w.len);
}

private void observeClipboard(ref ProtocolInbox inbox, scope const(char)[] payload,
    bool endedWithBel) @safe nothrow @nogc
{
    import core.lifetime : move;

    char[12] sel;
    size_t selLen, dataLen;
    // Sized from the payload: base64 never decodes to more than 3/4 of it.
    // Decoded aside, so an invalid write leaves an earlier pending one be.
    const estimate = payload.length / 4 * 3 + 3;
    HeapBuffer!ubyte data;
    data.length = estimate < maxClipboardBytes ? estimate : maxClipboardBytes;
    final switch (parseClipboard(payload, sel, selLen, data[], dataLen))
    {
        case ClipboardOp.invalid:
            break; // ignored (`TPR20`)
        case ClipboardOp.write:
            data.length = dataLen;
            inbox.clipboard = move(data);
            inbox.clipboardWrite = true;
            break;
        case ClipboardOp.read:
            inbox.readSelectors[0 .. selLen] = sel[0 .. selLen];
            inbox.readSelectorsLen = selLen;
            inbox.readEndedWithBel = endedWithBel;
            inbox.clipboardRead = true;
            break;
    }
}

@("protocols.observeOsc.recordsWithoutCallingOut")
@system nothrow @nogc unittest
{
    import sparkles.terminal_view.osc_query : oscScanByte;

    ProtocolInbox inbox;
    OscScanner sc;
    void feed(scope const(char)[] bytes)
    {
        foreach (b; bytes)
            if (oscScanByte(sc, b))
                observeOsc(inbox, sc, -1);
    }

    feed("\x1b]1;\xF0\x9F\xA6\x80 crab\x07");
    assert(inbox.iconDirty && inbox.icon[0 .. inbox.iconLen] == "\xF0\x9F\xA6\x80");

    feed("\x1b]777;notify;Done;make finished\x1b\\");
    feed("\x1b]9;4;1;50\x07"); // ConEmu progress: not a notification
    assert(inbox.notifications.length == 1);
    assert(inbox.notifications[0].title == "Done");

    feed("\x1b]52;c;aGVsbG8=\x07");
    assert(inbox.clipboardWrite && inbox.clipboard[] == cast(const(ubyte)[]) "hello");

    feed("\x1b]52;c;?\x1b\\");
    assert(inbox.clipboardRead && !inbox.readEndedWithBel);
    assert(inbox.readSelectors[0 .. inbox.readSelectorsLen] == "c");
}

@("protocols.observeOsc.boundsHostileVolume")
@system nothrow @nogc unittest
{
    import sparkles.terminal_view.osc_query : oscScanByte;

    ProtocolInbox inbox;
    OscScanner sc;
    foreach (_; 0 .. maxPendingNotifications + 5)
        foreach (b; "\x1b]9;spam\x07")
            if (oscScanByte(sc, b))
                observeOsc(inbox, sc, -1);
    assert(inbox.notifications.length == maxPendingNotifications);
    assert(inbox.droppedNotifications == 5);

    // An OSC 52 write beyond 1 MiB decoded is flagged, not delivered.
    foreach (b; "\x1b]52;c;")
        oscScanByte(sc, b);
    foreach (_; 0 .. OscScanner.maxClipboardPayloadLength)
        oscScanByte(sc, 'Q');
    assert(oscScanByte(sc, '\x07') && sc.overflowed);
    observeOsc(inbox, sc, -1);
    assert(inbox.clipboardOversize && !inbox.clipboardWrite);
}
