/**
The protocol milestone's acceptance suite (`TPR`), at the public boundary: a
`TerminalView` on a real pty whose other side is a recording program.

$(B The oracle is the authorities, not our encoder.) Every byte sequence a
test writes as "the program" and every reply it expects is transcribed from
the specification named beside it — XTerm Control Sequences (Patch #411),
kitty's keyboard-protocol and desktop-notifications documents, Contour's
colour-palette-update-notifications extension — never produced by calling
the code under test. See [testing](../../../../../docs/specs/terminal/testing.md).

$(B The recording pty.) The test holds the slave in raw mode and plays the
program: what it writes is the program's output, what it reads is exactly
what the terminal sent back. A DSR (`CSI 5 n`, answered `CSI 0 n` by the
engine) after each step is the barrier that proves every earlier reply has
arrived, so "nothing was sent" is an observation, not a timeout.
*/
module sparkles.terminal_view.protocol_oracle;

version (unittest):

import std.conv : text;

import sparkles.input : Key, KeyAction, KeyEvent, Mods;
import sparkles.terminal_view.component : ColorOverrides, TerminalView, TerminalViewOptions;
import sparkles.terminal_view.input : ExitBehavior;
import sparkles.terminal_view.notification_log : NotificationLog, NotificationRoute, NotifyWhen;
import sparkles.terminal_view.osc_scan : Notification, NotificationProtocol;
import sparkles.terminal_view.protocols : ClipboardReadAnswer, ClipboardReadPolicy,
    ColorScheme, PasteConfirm, PasteConfirmRequest;

extern (C) private int ptsname_r(int fd, char* buf, size_t len) nothrow @nogc;

/**
A fresh pty master and its slave's path — through `ptsname_r`: `ptsname`
returns a static buffer, and tests opening ptys on parallel threads then
open each other's slaves (bytes vanish into the wrong pane).
*/
package(sparkles.terminal_view) int openTestPty(ref char[128] slavePath) @system nothrow @nogc
{
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR;
    import core.sys.posix.stdlib : grantpt, posix_openpt, unlockpt;

    const master = posix_openpt(O_RDWR | O_NOCTTY);
    assert(master >= 0);
    assert(grantpt(master) == 0 && unlockpt(master) == 0);
    assert(ptsname_r(master, slavePath.ptr, slavePath.length) == 0);
    return master;
}

/// A pane on a pty whose slave the test holds, raw.
private struct RecordingPty
{
    int slave = -1;
    TerminalView* tv;
    char[] recorded;

    @disable this(this);

    static RecordingPty* open(TerminalViewOptions o) @system
    {
        import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NOCTTY, O_NONBLOCK,
            O_RDWR, open_ = open;
        import core.sys.posix.termios;

        char[128] slavePath = 0;
        const master = openTestPty(slavePath);
        auto r = new RecordingPty;
        r.slave = open_(slavePath.ptr, O_RDWR | O_NOCTTY);
        assert(r.slave >= 0);
        termios t;
        assert(tcgetattr(r.slave, &t) == 0);
        t.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
        t.c_oflag &= ~OPOST;
        t.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
        t.c_cflag |= CS8;
        assert(tcsetattr(r.slave, TCSANOW, &t) == 0);
        assert(fcntl(r.slave, F_SETFL, fcntl(r.slave, F_GETFL) | O_NONBLOCK) == 0);

        r.tv = new TerminalView;
        r.tv.opts = o;
        r.tv.opts.adoptMaster = master;
        r.tv.opts.exitBehavior = ExitBehavior.hold;
        assert(r.tv.openCore(80, 24, 0, 0));
        return r;
    }

    void close() @system
    {
        import core.sys.posix.unistd : close_ = close;

        tv.close();
        close_(slave);
    }

    private void readAvailable() @system
    {
        import core.sys.posix.unistd : read;

        char[4096] buf = void;
        for (;;)
        {
            const n = read(slave, buf.ptr, buf.length);
            if (n <= 0)
                break;
            recorded ~= buf[0 .. n];
        }
    }

    /// Plays `bytes` as the program's output, then waits at the DSR barrier:
    /// on return the pane has consumed them and every reply is recorded.
    void program(scope const(char)[] bytes) @system
    {
        import core.stdc.errno : EAGAIN, errno;
        import core.sys.posix.unistd : write;
        import core.thread : Thread;
        import core.time : MonoTime, msecs, seconds;
        import std.string : indexOf;

        enum dsr = "\x1b[5n", ok = "\x1b[0n";
        auto all = bytes ~ dsr;
        size_t off;
        const deadline = MonoTime.currTime + 20.seconds;
        while (off < all.length)
        {
            const n = write(slave, all.ptr + off, all.length - off);
            assert(n > 0 || errno == EAGAIN);
            if (n > 0)
                off += n;
            tv.pump();
            readAvailable();
            assert(MonoTime.currTime < deadline, "the pane stopped reading");
        }
        while (MonoTime.currTime < deadline)
        {
            tv.pump();
            readAvailable();
            const at = recorded.indexOf(ok); // bytes, not code points
            if (at >= 0)
            {
                recorded = recorded[0 .. at] ~ recorded[at + ok.length .. $];
                return;
            }
            Thread.sleep(1.msecs);
        }
        assert(0, "the DSR barrier never came back");
    }

    /// The barrier alone: everything the pane sent so far is recorded.
    void sync() @system => program("");

    /// Everything recorded since the last take.
    string take() @system
    {
        sync();
        auto r = recorded.idup;
        recorded = null;
        return r;
    }

    void deliver() @system
    {
        NoHost h;
        tv.deliverEvents(h);
    }
}

private struct NoHost {}

private struct ClipboardHost
{
    string written;
    void clipboard(scope const(char)[] t) @safe { written = t.idup; }
}

private KeyEvent key(Key k, Mods m = Mods(), dchar unshifted = 0, string text = null,
    KeyAction a = KeyAction.press) @safe pure nothrow @nogc
{
    auto e = KeyEvent(key: k, ch: 0, mods: m, action: a, unshifted: unshifted);
    if (text.length)
        e.text(text);
    return e;
}

// ── TPR1, TPR2: titles and icons (XTerm: OSC 0 icon+title, 1 icon, 2 title) ──

@("protocol_oracle.TPR1.titleAndIconFromOsc0Through2")
@system unittest
{
    string[] titles, icons;
    TerminalViewOptions o;
    o.hooks.titleChanged = (scope const(char)[] t) { titles ~= t.idup; };
    o.hooks.iconChanged = (scope const(char)[] i) { icons ~= i.idup; };
    auto p = RecordingPty.open(o);
    scope (exit) p.close();

    p.program("\x1b]0;both\x07");
    p.deliver();
    assert(titles == ["both"] && icons == ["b"], text(titles, icons));

    p.program("\x1b]1;\U0001F980 crab\x1b\\");
    p.deliver();
    assert(titles == ["both"], "OSC 1 leaves the title");
    assert(icons == ["b", "\U0001F980"]);
    assert(p.tv.icon == "\U0001F980");

    p.program("\x1b]2;only the title\x07");
    p.deliver();
    assert(titles == ["both", "only the title"]);
    assert(icons.length == 2, "OSC 2 leaves the icon");
    assert(p.take() == "", "titles are never answered");
}

@("protocol_oracle.TPR2.hostileTitlesAreSanitized")
@system unittest
{
    import std.algorithm.searching : all;

    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();

    // C1 CSI (U+009B), DEL and a stray control inside the payload.
    p.program("\x1b]2;a\u009B31mb\x7fc\x01d\x07");
    assert(p.tv.title == "a31mbcd");

    // A 1 MiB title: whatever reaches the pane is capped and control-free.
    auto huge = new char[](1024 * 1024);
    huge[] = 'x';
    p.program("\x1b]2;" ~ huge ~ "\x07");
    assert(p.tv.title.length <= 256);
    assert(p.tv.title.all!(c => c >= 0x20 && c != 0x7f));

    // An icon is one grapheme cluster, at most two cells.
    p.program("\x1b]1;\x1b");
    p.program("\x1b]1;ab\x07");
    p.deliver();
    assert(p.tv.icon == "a");
}

@("protocol_oracle.TPR3.renamePinsTheTitle")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();

    p.program("\x1b]2;from the program\x07");
    assert(p.tv.takeTitleChanged() && p.tv.title == "from the program");
    p.tv.rename("mine");
    assert(p.tv.takeTitleChanged() && p.tv.title == "mine");
    p.program("\x1b]2;ignored while pinned\x07");
    assert(!p.tv.takeTitleChanged() && p.tv.title == "mine");
    assert(p.tv.programTitle == "ignored while pinned");
    p.tv.clearRename();
    assert(p.tv.takeTitleChanged() && p.tv.title == "ignored while pinned");

    // No OSC 1 icon and no foreground process (an adopted pty): the
    // generic glyph — or nothing on a target without a Nerd Font.
    assert(p.tv.icon == "");
    p.tv.opts.nerdFont = false;
    assert(p.tv.icon.length == 0);
}

// ── TPR4: OSC 7 working directory (XTerm: OSC 7, `file://host/path`) ──

@("protocol_oracle.TPR4.osc7FollowsLocalExistingDirectories")
@system unittest
{
    import core.sys.posix.unistd : gethostname;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.conv : text;
    import std.process : thisProcessID;
    import std.string : fromStringz;

    string[] seen;
    TerminalViewOptions o;
    o.hooks.cwdChanged = (scope const(char)[] d) { seen ~= d.idup; };
    auto p = RecordingPty.open(o);
    scope (exit) p.close();

    char[256] hostBuf = 0;
    gethostname(hostBuf.ptr, hostBuf.length - 1);
    const host = fromStringz(hostBuf.ptr).idup;
    const dir = buildPath(tempDir, text("tpr4-", thisProcessID, " dir"));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // vte.sh's `printf '\e]7;file://%s%s\a' "$HOSTNAME" "$(urlencode $PWD)"`.
    p.program("\x1b]7;file://" ~ host ~ dir[0 .. $ - 4] ~ "%20dir\x07");
    p.deliver();
    assert(seen == [dir] && p.tv.cwd == dir);

    // A foreign host, a missing path and a relative one change nothing.
    p.program("\x1b]7;file://not-" ~ host ~ "/tmp\x07");
    p.deliver();
    p.program("\x1b]7;file:///no/such/directory/here\x07");
    p.deliver();
    p.program("\x1b]7;relative\x07");
    p.deliver();
    assert(seen == [dir] && p.tv.cwd == dir);

    p.program("\x1b]7;file:///\x07");
    p.deliver();
    assert(p.tv.cwd == "/");
}

// ── TPR8, TPR9, TPG9: notifications ──

@("protocol_oracle.TPR8.everyProtocolRaisesOneEvent")
@system unittest
{
    static struct Got { NotificationProtocol protocol; string title, body; NotificationRoute route; }
    Got[] got;
    auto log = new NotificationLog;
    TerminalViewOptions o;
    o.notificationLog = log;
    o.notificationSource = 42;
    o.hooks.notify = (in Notification n, NotificationRoute r) {
        got ~= Got(n.protocol, n.title.idup, n.body.idup, r);
    };
    o.hooks.tabTitle = () => "tab 3";
    auto p = RecordingPty.open(o);
    scope (exit) p.close();
    p.program("\x1b]2;pane title\x07");

    // iTerm2: `ESC ] 9 ; message ST`.
    p.program("\x1b]9;Build finished\x07");
    // rxvt-unicode: `ESC ] 777 ; notify ; title ; body ST`.
    p.program("\x1b]777;notify;Tests;all green\x1b\\");
    // kitty: chunked title then body, joined by `i=`.
    p.program("\x1b]99;i=1:d=0;Hello world\x1b\\\x1b]99;i=1:p=body;This is cool\x1b\\");
    // ConEmu's numbered family is not a notification.
    p.program("\x1b]9;4;1;50\x07");
    p.tv.setSeen(true);
    p.deliver();

    with (NotificationProtocol) assert(got == [
        Got(osc9, "", "Build finished", NotificationRoute.toast),
        Got(osc777, "Tests", "all green", NotificationRoute.toast),
        Got(osc99, "Hello world", "This is cool", NotificationRoute.toast),
    ]);

    // TPR9: unseen → a system notification; `never` → a toast regardless.
    p.tv.setSeen(false);
    p.program("\x1b]9;while away\x07");
    p.deliver();
    assert(got[$ - 1].route == NotificationRoute.system);
    p.tv.opts.policy.notifyWhen = NotifyWhen.never;
    p.program("\x1b]9;still away\x07");
    p.deliver();
    assert(got[$ - 1].route == NotificationRoute.toast);

    // TPG9: every one logged, with its pane as it was.
    assert(log.length == 5);
    assert((*log)[0].protocol == NotificationProtocol.osc9 && (*log)[0].body == "Build finished");
    assert((*log)[2].title == "Hello world" && (*log)[2].tabTitle == "tab 3");
    assert((*log)[2].paneTitle == "pane title");
    assert((*log)[2].source == 42, "TPG10: the pane it came from");
    assert((*log)[3].route == NotificationRoute.system);
    assert(p.take() == "", "no notification is answered");
}

@("protocol_oracle.TPR8.kittySupportQueryIsAnswered")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();
    // `<OSC> 99 ; i=<id> : p=? ; <terminator>` →
    // `<OSC> 99 ; i=<id> : p=? ; key=value : key=value <terminator>`.
    p.program("\x1b]99;i=probe:p=?;\x1b\\");
    assert(p.take() == "\x1b]99;i=probe:p=?;p=title,body:o=always\x1b\\");
}

@("protocol_oracle.TPG9.unhookedPanesStillLog")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();
    p.program("\x1b]9;nobody listening\x07");
    p.deliver();
    auto log = p.tv.notificationLog;
    assert(log.length == 1 && log.back.body == "nobody listening");
    assert(log.back.route == NotificationRoute.none, "shown nowhere");
    assert(log.back.tabTitle == "" && log.back.process is null);
}

// ── TPR14, TPR15: the scheme and colour reports ──

@("protocol_oracle.TPR14.schemeQueryAndMode2031Reports")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();

    ColorOverrides light, dark;
    light.background = typeof(light.background)(255, 255, 255);
    light.hasBackground = true;
    dark.background = typeof(dark.background)(0, 0, 0);
    dark.hasBackground = true;

    // Contour: `CSI ? 996 n` → `CSI ? 997 ; 1 n` (dark) / `CSI ? 997 ; 2 n` (light).
    p.program("\x1b[?996n");
    assert(p.take() == "\x1b[?997;1n", "the default background is dark");

    // Without mode 2031 a switch is silent; the query sees the new scheme.
    p.tv.setColorScheme(ColorScheme.light, light);
    assert(p.take() == "");
    p.program("\x1b[?996n");
    assert(p.take() == "\x1b[?997;2n");

    // Enabling 2031 reports nothing by itself — "only … when the palette
    // has been updated" (Contour) — then each change is reported once.
    p.program("\x1b[?2031h");
    assert(p.take() == "");
    p.tv.setColorScheme(ColorScheme.dark, dark);
    assert(p.take() == "\x1b[?997;1n");
    p.tv.setColorScheme(ColorScheme.dark, dark);
    assert(p.take() == "", "no change, no report");
    p.tv.setColorScheme(ColorScheme.light, light);
    assert(p.take() == "\x1b[?997;2n");

    // Reset 2031: silent again.
    p.program("\x1b[?2031l");
    p.tv.setColorScheme(ColorScheme.dark, dark);
    assert(p.take() == "");
}

@("protocol_oracle.TPR15.colourQueriesAnswerTheSchemeInEffect")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();

    ColorOverrides light;
    light.foreground = typeof(light.foreground)(0x10, 0x20, 0x30);
    light.hasForeground = true;
    light.background = typeof(light.background)(0xfa, 0xfb, 0xfc);
    light.hasBackground = true;
    light.palette[1] = typeof(light.foreground)(0xab, 0x01, 0x02);
    light.paletteMask = 1 << 1;
    p.tv.setColorScheme(ColorScheme.light, light);

    // XTerm: `OSC Ps ; ? ST` is answered `OSC Ps ; rgb:rrrr/gggg/bbbb` with
    // the query's own terminator; OSC 4 names the index.
    p.program("\x1b]11;?\x1b\\");
    assert(p.take() == "\x1b]11;rgb:fafa/fbfb/fcfc\x1b\\");
    p.program("\x1b]10;?\x07");
    assert(p.take() == "\x1b]10;rgb:1010/2020/3030\x07");
    p.program("\x1b]4;1;?\x07");
    assert(p.take() == "\x1b]4;1;rgb:abab/0101/0202\x07");
    p.program("\x1b]4;255;?\x1b\\");
    const r = p.take();
    assert(r.length == "\x1b]4;255;rgb:0000/0000/0000\x1b\\".length
        && r[0 .. 12] == "\x1b]4;255;rgb:" && r[$ - 2 .. $] == "\x1b\\", r);
}

// ── TPR16, TPR17: the kitty keyboard protocol (kitty keyboard-protocol.rst) ──

@("protocol_oracle.TPR16.hardwareKeysFollowThePushedFlags")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();
    string send(in KeyEvent k) { p.tv.sendKey(k); return p.take(); }

    // Legacy until a program asks.
    assert(send(key(Key.escape)) == "\x1b");
    assert(send(key(Key.char_, Mods(), 'a', "a")) == "a");

    // `CSI > 1 u` — disambiguate: Esc and ctrl+key become `CSI … u`; Enter,
    // Tab and Backspace keep their legacy bytes; text stays text.
    p.program("\x1b[>1u");
    assert(send(key(Key.escape)) == "\x1b[27u");
    assert(send(key(Key.char_, Mods(ctrl: true), 'a')) == "\x1b[97;5u");
    assert(send(key(Key.enter)) == "\r");
    assert(send(key(Key.char_, Mods(), 'a', "a")) == "a");
    p.program("\x1b[?u");
    assert(p.take() == "\x1b[?1u", "`CSI ? u` reports the flags");

    // `CSI > 11 u` — + report events + all keys as escape codes:
    // `CSI 97 u`, repeat `:2`, release `:3`; Enter is `CSI 13 u` now.
    p.program("\x1b[>11u");
    assert(send(key(Key.char_, Mods(), 'a', "a")) == "\x1b[97u");
    assert(send(key(Key.char_, Mods(), 'a', null, KeyAction.repeat)) == "\x1b[97;1:2u");
    assert(send(key(Key.char_, Mods(), 'a', null, KeyAction.release)) == "\x1b[97;1:3u");
    assert(send(key(Key.enter)) == "\x1b[13u");
    assert(send(key(Key.enter, Mods(), 0, null, KeyAction.release)) == "\x1b[13;1:3u");

    // `CSI = 24 ; 1 u` — all keys + associated text: the spec's own
    // example, `shift+a -> CSI 97 ; 2 ; 65 u`.
    p.program("\x1b[=24;1u");
    assert(send(key(Key.char_, Mods(shift: true), 'a', "A")) == "\x1b[97;2;65u");

    // `CSI = 13 ; 1 u` — + alternate keys: the shifted key follows a colon.
    p.program("\x1b[=13;1u");
    assert(send(key(Key.char_, Mods(shift: true), 'a', "A")) == "\x1b[97:65;2u");

    // `CSI < u` pops back through the stack to legacy.
    p.program("\x1b[<u\x1b[<u");
    assert(send(key(Key.escape)) == "\x1b");
}

@("protocol_oracle.TPR17.softKeyboardTextUnderKittyMode")
@system unittest
{
    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();
    // A soft keyboard's commit: a char event naming no key (`unshifted` 0).
    string type(dchar c) { p.tv.sendKey(KeyEvent(Key.char_, c)); return p.take(); }

    // No pushed mode: the bytes are what they always were.
    assert(type('a') == "a");
    assert(type('A') == "A");
    assert(type(0xA9) == "©");

    // Report events + all keys: a synthetic press and release of the key
    // that types the character on a US layout.
    p.program("\x1b[>11u");
    assert(type('a') == "\x1b[97u\x1b[97;1:3u");
    assert(type('A') == "\x1b[97;2u\x1b[97;2:3u");
    assert(type('!') == "\x1b[49;2u\x1b[49;2:3u");

    // All keys + associated text: no key types `©`, so it is a pure text
    // event — key number 0 ("If no known key is associated with the text
    // the key number 0 must be used").
    p.program("\x1b[=24;1u");
    assert(type('A') == "\x1b[97;2;65u");
    assert(type('©') == "\x1b[0;;169u");
}

// ── TPR18, TPR19: paste ──

@("protocol_oracle.TPR18.aPasteCannotCloseTheBracket")
@system unittest
{
    import std.string : indexOf;

    auto p = RecordingPty.open(TerminalViewOptions());
    scope (exit) p.close();
    p.program("\x1b[?2004h"); // XTerm: bracketed paste mode

    // The injection fixture: a paste that tries to end the bracket and run
    // a command, with a ctrl-C and an EOT for good measure.
    p.tv.sendPaste("\x1b[201~rm -rf ~\n\x03\x04");
    const got = p.take();
    assert(got == "\x1b[200~[201~rm -rf ~\n\x1b[201~", got);
    assert(got.indexOf("\x1b[201~") == got.length - "\x1b[201~".length,
        "the only bracket close is the terminal's own, after `rm`");

    // HT, LF and CR survive.
    p.tv.sendPaste("a\tb\r\nc");
    assert(p.take() == "\x1b[200~a\tb\r\nc\x1b[201~");
}

@("protocol_oracle.TPR19.multiLinePasteAsksFirst")
@system unittest
{
    PasteConfirmRequest[] asked;
    TerminalViewOptions o;
    o.hooks.pasteConfirm = (in PasteConfirmRequest r) {
        asked ~= PasteConfirmRequest(r.lines, r.text.idup);
    };
    auto p = RecordingPty.open(o);
    scope (exit) p.close();

    // Without mode 2004: held, nothing sent; cancelling sends nothing.
    p.tv.sendPaste("echo one\necho two\n");
    assert(p.take() == "");
    assert(asked.length == 1 && asked[0].lines == 2 && asked[0].text == "echo one\necho two\n");
    p.tv.confirmPaste(false);
    assert(p.take() == "" && !p.tv.pasteConfirmPending);

    // Confirmed: sent, newlines as carriage returns.
    p.tv.sendPaste("a\nb");
    p.tv.confirmPaste(true);
    assert(p.take() == "a\rb");

    // One line goes straight through; `never` never asks.
    p.tv.sendPaste("single");
    assert(p.take() == "single" && asked.length == 2);
    p.tv.opts.policy.pasteConfirm = PasteConfirm.never;
    p.tv.sendPaste("x\ny");
    assert(p.take() == "x\ry" && asked.length == 2);

    // With bracketed paste on, the bracket is the protection: no question.
    p.tv.opts.policy.pasteConfirm = PasteConfirm.always;
    p.program("\x1b[?2004h");
    p.tv.sendPaste("x\ny");
    assert(p.take() == "\x1b[200~x\ny\x1b[201~" && asked.length == 2);
}

// ── TPR20, TPR21: OSC 52 (XTerm: Manipulate Selection Data) ──

@("protocol_oracle.TPR20.writesFollowThePolicy")
@system unittest
{
    string[] writes;
    TerminalViewOptions o;
    o.hooks.clipboardWrite = (scope const(char)[] t) { writes ~= t.idup; };
    auto p = RecordingPty.open(o);
    scope (exit) p.close();

    // `printf '\e]52;c;%s\a' "$(printf 'hello world' | base64)"`.
    p.program("\x1b]52;c;aGVsbG8gd29ybGQ=\x07");
    p.deliver();
    assert(writes == ["hello world"]);

    // Invalid base64 is ignored; so is a write over 1 MiB decoded.
    p.program("\x1b]52;c;not base64!\x07");
    p.deliver();
    auto big = new char[]((1024 * 1024 + 3) / 3 * 4 + 4);
    big[] = 'Q';
    p.program("\x1b]52;c;" ~ big ~ "\x07");
    p.deliver();
    assert(writes.length == 1);

    // Off: nothing reaches the clipboard.
    p.tv.opts.policy.osc52Write = false;
    p.program("\x1b]52;c;aGk=\x07");
    p.deliver();
    assert(writes.length == 1);
    assert(p.take() == "", "a write is never answered");

    // No hook: the host's clipboard errand takes it.
    p.tv.opts.policy.osc52Write = true;
    p.tv.opts.hooks.clipboardWrite = null;
    p.program("\x1b]52;c;aGk=\x07");
    ClipboardHost h;
    p.tv.deliverEvents(h);
    assert(h.written == "hi");
}

@("protocol_oracle.TPR21.readsFollowThePolicy")
@system unittest
{
    size_t asked;
    TerminalViewOptions o;
    o.hooks.clipboardText = () => "hello";
    o.hooks.clipboardReadRequest = () { ++asked; };
    o.policy.osc52Read = ClipboardReadPolicy.allow;
    auto p = RecordingPty.open(o);
    scope (exit) p.close();

    // allow: "xterm replies to the host with the selection data encoded
    // using the same protocol", with the query's terminator.
    p.program("\x1b]52;c;?\x07");
    p.deliver();
    assert(p.take() == "\x1b]52;c;aGVsbG8=\x07");
    p.program("\x1b]52;;?\x1b\\");
    p.deliver();
    assert(p.take() == "\x1b]52;s0;aGVsbG8=\x1b\\", "an empty Pc means s0");

    // deny: nothing, ever.
    p.tv.opts.policy.osc52Read = ClipboardReadPolicy.deny;
    p.program("\x1b]52;c;?\x07");
    p.deliver();
    assert(p.take() == "" && asked == 0);

    // ask: nothing until answered; a denial sends nothing.
    p.tv.opts.policy.osc52Read = ClipboardReadPolicy.ask;
    p.program("\x1b]52;c;?\x07");
    p.deliver();
    assert(asked == 1 && p.tv.clipboardReadPending && p.take() == "");
    p.tv.answerClipboardRead(ClipboardReadAnswer.deny);
    assert(p.take() == "" && !p.tv.clipboardReadPending);

    // Allowed once: answered; always: answered now and unasked hereafter.
    p.program("\x1b]52;c;?\x07");
    p.deliver();
    p.tv.answerClipboardRead(ClipboardReadAnswer.allowOnce);
    assert(p.take() == "\x1b]52;c;aGVsbG8=\x07" && asked == 2);
    p.program("\x1b]52;c;?\x07");
    p.deliver();
    p.tv.answerClipboardRead(ClipboardReadAnswer.allowAlways);
    assert(p.take() == "\x1b]52;c;aGVsbG8=\x07" && asked == 3);
    p.program("\x1b]52;c;?\x07");
    p.deliver();
    assert(p.take() == "\x1b]52;c;aGVsbG8=\x07" && asked == 3, "remembered for this pane");

    // ask with no hook to ask through: nothing is sent.
    p.tv.opts.hooks.clipboardReadRequest = null;
    auto q = RecordingPty.open(TerminalViewOptions());
    scope (exit) q.close();
    q.program("\x1b]52;c;?\x07");
    q.deliver();
    assert(q.take() == "");
}
