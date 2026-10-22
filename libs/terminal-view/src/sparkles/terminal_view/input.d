module sparkles.terminal_view.input;

import core.sys.posix.unistd : write;

import sparkles.ghostty.c;
import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import sparkles.base.text.cstring : writeStringz;
import sparkles.input : mousePointer, PointerAction, PointerButton,
    PointerEvent;
import sparkles.ui.components.scroll_view : scrollLayout, ScrollArea,
    ScrollAreaAxis, ScrollView;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.state : CaptureState;
import sparkles.terminal_view.posix_util : spawnDetached;
import sparkles.terminal_view.selection : Granularity, moveEnd, selectAt, selectCells,
    SelectionEnd;

// --- @nogc byte-string helpers (URL hover detection) ------------------------

/// True if `s[at .. at+pfx.length]` equals `pfx` (bounds-checked).
@safe pure nothrow @nogc
private bool startsWithAt(scope const(char)[] s, size_t at, scope const(char)[] pfx)
{
    if (at + pfx.length > s.length) return false;
    foreach (k; 0 .. pfx.length)
        if (s[at + k] != pfx[k]) return false;
    return true;
}

/// True if an `http://`/`https://` scheme starts at byte offset `at`.
@safe pure nothrow @nogc
private bool urlSchemeAt(scope const(char)[] s, size_t at)
    => startsWithAt(s, at, "http://") || startsWithAt(s, at, "https://");

/// A byte that terminates a URL run (whitespace or NUL).
@safe pure nothrow @nogc
private bool isUrlBoundary(char c)
    => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\0';

/// Count decoded cell codepoints without throwing on malformed UTF-8.
@safe pure nothrow @nogc
private size_t utf8Cols(scope const(char)[] s)
{
    import sparkles.base.text.tokens : byUtfToken;
    import sparkles.base.text.utf : UtfMode;

    size_t n = 0;
    foreach (_; byUtfToken(s, UtfMode.replacement))
        ++n;
    return n;
}

/// Best-effort write of all `len` bytes to the (non-blocking) pty master.
///
/// Because the fd is non-blocking, `write` may return short or fail with
/// `EAGAIN`. We retry on `EINTR`, advance past partial writes, and silently
/// drop the remainder if the kernel buffer is full — which is what terminal
/// emulators do under back-pressure (mirrors ghostling's `pty_write`).
@system nothrow @nogc
void pty_write(int fd, scope const(void)* data, size_t len)
{
    import core.stdc.errno : errno, EINTR;

    auto buf = cast(const(ubyte)*) data;
    while (len > 0)
    {
        const n = write(fd, buf, len);
        if (n > 0)
        {
            buf += n;
            len -= cast(size_t) n;
        }
        else if (n < 0)
        {
            if (errno == EINTR) continue;
            break; // EAGAIN or a real error — drop the remainder.
        }
        else
        {
            break; // n == 0: nothing written, avoid spinning.
        }
    }
}

/// What the terminal does when the child process (the shell) exits.
enum ExitBehavior
{
    /// Close the window immediately on any child exit (xterm / Ghostty default).
    close,
    /// Keep the window open with a status banner; close on the next keypress
    /// (Ghostty's `wait-after-command = true`).
    waitForKey,
    /// Keep the window open with a status banner until the user closes it
    /// (strict ghostling parity).
    hold,
    /// Close on a clean exit (status 0); hold with a banner on a non-zero or
    /// signal exit (wezterm's "CloseOnCleanExit").
    holdOnFailure,
}

/// Parse the `--exit-behavior` CLI value. Unknown values fall back to the
/// default (`holdOnFailure`).
@safe pure nothrow @nogc
ExitBehavior parseExitBehavior(scope const(char)[] s)
{
    switch (s)
    {
        case "close":           return ExitBehavior.close;
        case "wait-for-key":    return ExitBehavior.waitForKey;
        case "hold":            return ExitBehavior.hold;
        case "hold-on-failure": return ExitBehavior.holdOnFailure;
        default:                return ExitBehavior.holdOnFailure;
    }
}

@("input.parseExitBehavior")
@safe pure nothrow @nogc
unittest
{
    assert(parseExitBehavior("close") == ExitBehavior.close);
    assert(parseExitBehavior("wait-for-key") == ExitBehavior.waitForKey);
    assert(parseExitBehavior("hold") == ExitBehavior.hold);
    assert(parseExitBehavior("hold-on-failure") == ExitBehavior.holdOnFailure);
    // Unknown values fall back to the default.
    assert(parseExitBehavior("bogus") == ExitBehavior.holdOnFailure);
    assert(parseExitBehavior("") == ExitBehavior.holdOnFailure);
}

/// The selection's tracked ends and shape — the model
/// `sparkles.terminal_view.selection` operates on (`TSE2`) — plus the
/// desktop path's click counting.
struct SelectionState {
    bool isSelecting = false;
    bool isRectangular = false;
    GhosttyTrackedGridRef start = null;
    GhosttyTrackedGridRef end = null;
    /// Where the user last placed the ends, as screen points. libghostty
    /// moves both to screen cell (0, 0) when it clears their rows (`TSE4`);
    /// a selection the user anchored there already had those points.
    bool screenNoted;
    /// ditto
    GhosttyPointCoordinate notedStart, notedEnd;
    /// The first code point at each end when it was placed (`-1`: unknown, a
    /// blank cell or a failed query): content replaced at the origin is a
    /// clear, a selection the user anchored there is not (`TSE4`).
    int notedStartGrapheme = -1;
    /// ditto
    int notedEndGrapheme = -1;
    // The last left press, for double- and triple-click (`TSE7`).
    double lastPressTime = -1;
    int lastPressX = -1, lastPressY = -1;
    ubyte clicks;

    @system nothrow @nogc
    void free() {
        if (start) { ghostty_tracked_grid_ref_free(start); start = null; }
        if (end) { ghostty_tracked_grid_ref_free(end); end = null; }
        isSelecting = false;
        isRectangular = false;
        screenNoted = false;
        notedStartGrapheme = -1;
        notedEndGrapheme = -1;
    }
}

struct OverlayScrollbar {
    ScrollView view;
    CaptureState capture;
}

struct HoverState {
    bool isHoveringUrl = false;
    // Owned, NUL-terminated URL bytes (for Ctrl-click "open"). @nogc, grows via
    // pureMalloc. SharedBuffer is non-copyable, so HoverState must be kept as a
    // single stack-pinned instance and only passed by `ref`.
    UniqueBuffer!(char, 2048) url;
    int start_x = -1;
    int end_x = -1;
    int y = -1;
    // Last hovered cell, so hover detection only re-runs when it changes (or
    // the mouse moves) rather than every frame.
    int lastCellX = int.min;
    int lastCellY = int.min;
    // A Ctrl+click on the hovered link asked to open it; the component
    // answers through `TerminalViewHooks.openLink` (`TPR7`), outside this
    // @nogc poll.
    bool openRequested;
    // The hovered link came from OSC 8 (not detected in the text).
    bool hyperlink;
}

@system nothrow @nogc
void mouse_encode_and_write(int pty_fd, GhosttyMouseEncoder encoder, GhosttyMouseEvent event)
{
    char[128] buf;
    size_t written = 0;
    GhosttyResult res = ghostty_mouse_encoder_encode(encoder, event, buf.ptr, buf.sizeof, &written);
    if (res == GHOSTTY_SUCCESS && written > 0)
        pty_write(pty_fd, buf.ptr, written);
}


/**
Finds the link at `pt` (a viewport cell): an OSC 8 hyperlink, else a
detected `http(s)://` URL, its span on the row in `hoverState`
(`isHoveringUrl`, `url`, `start_x`, `end_x`, `y`). `max_cols` bounds the
row. Shared by the hover and by `TerminalView.linkAt` (`TPR5`).
*/
@system nothrow @nogc
void detectLink(GhosttyTerminal terminal, GhosttyPoint pt, int max_cols,
    ref HoverState hoverState)
{
    hoverState.hyperlink = false;
    hoverState.isHoveringUrl = false;
    hoverState.url.clear();
    hoverState.start_x = -1;
    hoverState.end_x = -1;
    hoverState.y = -1;

    GhosttyGridRef hoverRef;
    if (ghostty_terminal_grid_ref(terminal, pt, &hoverRef) == GHOSTTY_SUCCESS) {
        size_t uri_len = 0;
        if (ghostty_grid_ref_hyperlink_uri(&hoverRef, null, 0, &uri_len) == GHOSTTY_OUT_OF_SPACE && uri_len > 0) {
            import core.memory : pureMalloc, pureFree;
            ubyte* buf = cast(ubyte*)pureMalloc(uri_len);
            if (buf) {
                if (ghostty_grid_ref_hyperlink_uri(&hoverRef, buf, uri_len, &uri_len) == GHOSTTY_SUCCESS) {
                    hoverState.isHoveringUrl = true;
                    hoverState.hyperlink = true;
                    hoverState.url.writeStringz(cast(const(char)[])buf[0 .. uri_len]);
                    hoverState.y = pt.value.coordinate.y;

                    // Scan left to find start of link
                    int left_x = pt.value.coordinate.x;
                    while (left_x > 0) {
                        GhosttyPoint p = pt; p.value.coordinate.x = cast(ushort)(left_x - 1);
                        GhosttyGridRef r; ghostty_terminal_grid_ref(terminal, p, &r);
                        size_t l = 0; ghostty_grid_ref_hyperlink_uri(&r, null, 0, &l);
                        if (l != uri_len) break;
                        left_x--;
                    }

                    // Scan right to find end of link
                    int right_x = pt.value.coordinate.x;
                    while (right_x < max_cols - 1) {
                        GhosttyPoint p = pt; p.value.coordinate.x = cast(ushort)(right_x + 1);
                        GhosttyGridRef r; ghostty_terminal_grid_ref(terminal, p, &r);
                        size_t l = 0; ghostty_grid_ref_hyperlink_uri(&r, null, 0, &l);
                        if (l != uri_len) break;
                        right_x++;
                    }

                    hoverState.start_x = left_x;
                    hoverState.end_x = right_x;
                }
                pureFree(buf);
            }
        }
    }

    if (!hoverState.isHoveringUrl) {
        GhosttyPoint p1 = { tag: GHOSTTY_POINT_TAG_VIEWPORT, value: { coordinate: { x: 0, y: pt.value.coordinate.y } } };
        GhosttyPoint p2 = { tag: GHOSTTY_POINT_TAG_VIEWPORT, value: { coordinate: { x: cast(ushort)(max_cols - 1), y: pt.value.coordinate.y } } };
        GhosttyGridRef r1, r2;
        if (ghostty_terminal_grid_ref(terminal, p1, &r1) == GHOSTTY_SUCCESS &&
            ghostty_terminal_grid_ref(terminal, p2, &r2) == GHOSTTY_SUCCESS) {

            GhosttySelection sel = { start: r1, end: r2, rectangle: false };
            GhosttyFormatterTerminalOptions fmt_opts;
            fmt_opts.size = GhosttyFormatterTerminalOptions.sizeof;
            fmt_opts.selection = &sel;
            GhosttyFormatter fmt;
            if (ghostty_formatter_terminal_new(null, &fmt, terminal, fmt_opts) == GHOSTTY_SUCCESS) {
                size_t len = 0;
                if (ghostty_formatter_format_buf(fmt, null, 0, &len) == GHOSTTY_OUT_OF_SPACE && len > 0) {
                    import core.memory : pureMalloc, pureFree;
                    ubyte* buf = cast(ubyte*)pureMalloc(len);
                    if (buf) {
                        if (ghostty_formatter_format_buf(fmt, buf, len, &len) == GHOSTTY_SUCCESS) {
                            // Hand-rolled @nogc scan for an http(s) URL covering
                            // the hovered column. Replaces std.regex (which
                            // allocates and can throw on invalid UTF-8). Byte
                            // offsets map to columns by counting UTF-8 lead
                            // bytes, matching the old code-point-based mapping.
                            const(char)[] line = cast(const(char)[])buf[0 .. len];
                            const hovered = pt.value.coordinate.x;
                            size_t i = 0;
                            while (i < line.length) {
                                if (urlSchemeAt(line, i)) {
                                    size_t j = i;
                                    while (j < line.length && !isUrlBoundary(line[j])) j++;
                                    const start_col = cast(int)utf8Cols(line[0 .. i]);
                                    const end_col = start_col + cast(int)utf8Cols(line[i .. j]) - 1;
                                    if (hovered >= start_col && hovered <= end_col) {
                                        hoverState.isHoveringUrl = true;
                                        hoverState.url.writeStringz(line[i .. j]);
                                        hoverState.start_x = start_col;
                                        hoverState.end_x = end_col;
                                        hoverState.y = pt.value.coordinate.y;
                                        break;
                                    }
                                    i = j;
                                } else {
                                    i++;
                                }
                            }
                        }
                        pureFree(buf);
                    }
                }
                ghostty_formatter_free(fmt);
            }
        }
    }
}

/// One keystroke as plain data — the seam between `sparkles:input` key
/// events (`event_map.d`) and the libghostty key encoder. Everything the
/// encoder is told about a stroke lives here, so the byte stream a stroke
/// produces is testable without a window or a pty.
struct KeyStroke {
    GhosttyKey key;
    GhosttyKeyAction action;
    GhosttyMods mods;
    /// The key's unshifted codepoint (0 = none) — what lets the encoder tell
    /// Ctrl+A (`\x01`) from a bare `a`.
    uint unshiftedCodepoint;
    /// The associated text, when the stroke produced any (empty on release
    /// and for non-printable keys).
    const(char)[] utf8;
}

/// Encodes `stroke` into `buf`, returning the bytes to write to the pty (a
/// slice of `buf`; empty when the stroke encodes to nothing, e.g. a release
/// under the legacy protocol). Shift consumed by a printable key is reported
/// to the encoder, matching what a keyboard layout does — `A` is Shift+a with
/// the shift consumed, not Shift applied to `A`.
@system nothrow @nogc
const(char)[] encodeKeyStroke(GhosttyKeyEncoder encoder, GhosttyKeyEvent event,
    in KeyStroke stroke, return scope char[] buf)
{
    ghostty_key_event_set_key(event, stroke.key);
    ghostty_key_event_set_action(event, stroke.action);
    ghostty_key_event_set_mods(event, stroke.mods);
    ghostty_key_event_set_unshifted_codepoint(event, stroke.unshiftedCodepoint);

    GhosttyMods consumed = 0;
    if (stroke.unshiftedCodepoint != 0 && (stroke.mods & GHOSTTY_MODS_SHIFT))
        consumed |= GHOSTTY_MODS_SHIFT;
    ghostty_key_event_set_consumed_mods(event, consumed);

    if (stroke.utf8.length > 0)
        ghostty_key_event_set_utf8(event, stroke.utf8.ptr, stroke.utf8.length);
    else
        ghostty_key_event_set_utf8(event, null, 0);

    size_t written = 0;
    GhosttyResult res = ghostty_key_encoder_encode(encoder, event, buf.ptr, buf.length, &written);
    return res == GHOSTTY_SUCCESS ? buf[0 .. written] : null;
}

version (unittest)
{
    /// A live encoder + event pair for the fixtures, freed on scope exit.
    package(sparkles.terminal_view) struct EncoderFixture
    {
        GhosttyKeyEncoder encoder;
        GhosttyKeyEvent event;

        @system nothrow @nogc:

        static EncoderFixture open()
        {
            EncoderFixture f;
            assert(ghostty_key_encoder_new(null, &f.encoder) == GHOSTTY_SUCCESS);
            assert(ghostty_key_event_new(null, &f.event) == GHOSTTY_SUCCESS);
            return f;
        }

        @disable this(this);

        ~this()
        {
            if (event) ghostty_key_event_free(event);
            if (encoder) ghostty_key_encoder_free(encoder);
        }

        void set(GhosttyKeyEncoderOption opt, bool v)
            => ghostty_key_encoder_setopt(encoder, opt, &v);

        const(char)[] encode(in KeyStroke s, return scope char[] buf)
            => encodeKeyStroke(encoder, event, s, buf);
    }

    // `int m`, because the GHOSTTY_MODS_* constants come through ImportC as
    // ints while GhosttyMods is a ushort.
    private KeyStroke press(GhosttyKey k, int m = 0,
        uint unshifted = 0, const(char)[] utf8 = null) @safe pure nothrow @nogc
        => KeyStroke(key: k, action: GHOSTTY_KEY_ACTION_PRESS,
            mods: cast(GhosttyMods) m,
            unshiftedCodepoint: unshifted, utf8: utf8);
}

// The byte oracle: what each stroke writes to the pty, pinned per encoder
// mode. The bytes were pinned while raylib was polled; `sparkles:input`
// events must produce exactly these (`event_map.d`'s fixtures replay them).
@("input.encodeKeyStroke.legacyDefaults")
@system nothrow @nogc
unittest
{
    auto f = EncoderFixture.open();
    char[128] buf;

    // The classics, under a fresh encoder (no terminal modes set).
    assert(f.encode(press(GHOSTTY_KEY_ENTER), buf) == "\r");
    assert(f.encode(press(GHOSTTY_KEY_TAB), buf) == "\t");
    assert(f.encode(press(GHOSTTY_KEY_ESCAPE), buf) == "\x1b");
    assert(f.encode(press(GHOSTTY_KEY_BACKSPACE), buf) == "\x7f",
        "backarrow mode off: backspace is DEL");

    // Cursor and navigation keys, normal (non-application) mode.
    assert(f.encode(press(GHOSTTY_KEY_ARROW_UP), buf) == "\x1b[A");
    assert(f.encode(press(GHOSTTY_KEY_ARROW_DOWN), buf) == "\x1b[B");
    assert(f.encode(press(GHOSTTY_KEY_ARROW_RIGHT), buf) == "\x1b[C");
    assert(f.encode(press(GHOSTTY_KEY_ARROW_LEFT), buf) == "\x1b[D");
    assert(f.encode(press(GHOSTTY_KEY_HOME), buf) == "\x1b[H");
    assert(f.encode(press(GHOSTTY_KEY_END), buf) == "\x1b[F");
    assert(f.encode(press(GHOSTTY_KEY_PAGE_UP), buf) == "\x1b[5~");
    assert(f.encode(press(GHOSTTY_KEY_PAGE_DOWN), buf) == "\x1b[6~");
    assert(f.encode(press(GHOSTTY_KEY_INSERT), buf) == "\x1b[2~");
    assert(f.encode(press(GHOSTTY_KEY_DELETE), buf) == "\x1b[3~");

    // Function keys: F1-F4 are SS3, F5+ are CSI.
    assert(f.encode(press(GHOSTTY_KEY_F1), buf) == "\x1bOP");
    assert(f.encode(press(GHOSTTY_KEY_F4), buf) == "\x1bOS");
    assert(f.encode(press(GHOSTTY_KEY_F5), buf) == "\x1b[15~");
    assert(f.encode(press(GHOSTTY_KEY_F12), buf) == "\x1b[24~");
}

@("input.encodeKeyStroke.textAndModifiers")
@system nothrow @nogc
unittest
{
    auto f = EncoderFixture.open();
    char[128] buf;

    // A printable key passes its text through.
    assert(f.encode(press(GHOSTTY_KEY_A, 0, 'a', "a"), buf) == "a");

    // Shift+a producing "A": the shift is consumed by the layout, so the
    // encoder emits the text — not a modified sequence.
    assert(f.encode(press(GHOSTTY_KEY_A, GHOSTTY_MODS_SHIFT, 'a', "A"), buf) == "A");

    // Ctrl+letter is the C0 control, from the unshifted codepoint.
    assert(f.encode(press(GHOSTTY_KEY_A, GHOSTTY_MODS_CTRL, 'a'), buf) == "\x01");
    assert(f.encode(press(GHOSTTY_KEY_C, GHOSTTY_MODS_CTRL, 'c'), buf) == "\x03");

    // Ctrl+modified cursor key: the xterm modifier encoding.
    assert(f.encode(press(GHOSTTY_KEY_ARROW_UP, GHOSTTY_MODS_CTRL), buf) == "\x1b[1;5A");
    assert(f.encode(press(GHOSTTY_KEY_ARROW_LEFT, GHOSTTY_MODS_SHIFT), buf) == "\x1b[1;2D");

    // A release encodes to nothing under the legacy protocol.
    KeyStroke rel = press(GHOSTTY_KEY_ENTER);
    rel.action = GHOSTTY_KEY_ACTION_RELEASE;
    assert(f.encode(rel, buf).length == 0);

    // A repeat encodes like a press.
    KeyStroke rep = press(GHOSTTY_KEY_ARROW_DOWN);
    rep.action = GHOSTTY_KEY_ACTION_REPEAT;
    assert(f.encode(rep, buf) == "\x1b[B");
}

@("input.encodeKeyStroke.encoderModes")
@system nothrow @nogc
unittest
{
    auto f = EncoderFixture.open();
    char[128] buf;

    // DEC mode 1 (cursor key application): CSI becomes SS3.
    f.set(GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, true);
    assert(f.encode(press(GHOSTTY_KEY_ARROW_UP), buf) == "\x1bOA");
    f.set(GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, false);

    // DEC mode 1036: Alt prefixes the text with ESC. On macOS the encoder
    // additionally gates this on option-as-alt (Option types text by default,
    // so a fresh encoder emits plain "x" there); the fixture is about mode
    // 1036, not the platform default, so pin option-as-alt explicitly —
    // ignored on the other platforms, deterministic on macOS.
    f.set(GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, true);
    GhosttyOptionAsAlt optAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE;
    ghostty_key_encoder_setopt(f.encoder,
        GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optAsAlt);
    assert(f.encode(press(GHOSTTY_KEY_X, GHOSTTY_MODS_ALT, 'x', "x"), buf) == "\x1bx");
    optAsAlt = GHOSTTY_OPTION_AS_ALT_FALSE;
    ghostty_key_encoder_setopt(f.encoder,
        GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optAsAlt);
    f.set(GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, false);

    // Backarrow mode: backspace flips from DEL to BS.
    f.set(GHOSTTY_KEY_ENCODER_OPT_BACKARROW_KEY_MODE, true);
    assert(f.encode(press(GHOSTTY_KEY_BACKSPACE), buf) == "\x08");
    f.set(GHOSTTY_KEY_ENCODER_OPT_BACKARROW_KEY_MODE, false);
}

@("input.encodeKeyStroke.kittyProtocol")
@system nothrow @nogc
unittest
{
    auto f = EncoderFixture.open();
    char[128] buf;

    // Kitty disambiguate mode (flag 1): the keys that are ambiguous in the
    // legacy encoding get CSI-u sequences, and a release reports.
    ubyte flags = 1;
    ghostty_key_encoder_setopt(f.encoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS, &flags);

    assert(f.encode(press(GHOSTTY_KEY_ESCAPE), buf) == "\x1b[27u");
    assert(f.encode(press(GHOSTTY_KEY_A, GHOSTTY_MODS_CTRL, 'a'), buf) == "\x1b[97;5u");

    // Plain text still passes through as text under disambiguate-only.
    assert(f.encode(press(GHOSTTY_KEY_A, 0, 'a', "a"), buf) == "a");
}
