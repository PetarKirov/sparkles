/**
The chord-capture editor (`PRT41`): a key binding edited by pressing the new
key rather than typing its name — the machine, and its view (terminal mockup
G4).

$(UL
    $(LI $(B Activating) a binding row starts a capture that waits for the
    next chord — or, for a sequence, each key in turn — and shows what has
    been pressed so far, live.)
    $(LI $(B A reserved key) (the host's rule, design-system `KBD3`) is
    refused with the reason and not taken; the capture keeps listening.)
    $(LI $(B A path already bound) stops the capture at a conflict, naming
    what the path does now; the host offers $(B Swap), $(B Bind both) or
    $(B Cancel) and reads the choice back as a $(LREF CaptureResolution).
    A path that would shadow (or be shadowed by) a sequence is refused
    outright: no choice makes both work.)
    $(LI $(B `Esc`) cancels the capture — it is never captured.)
)

The machine knows no command vocabulary and no table: the host supplies the
reserved-key rule and the conflict lookup per key, so hue's and the
terminal's tables (hue `SET9`, terminal `TSP8`) share it. A touch host
latches modifiers before the key reaches $(LREF ChordCapture.feed) — the key
arrives as a chord like any other.
*/
module sparkles.ui.components.chord_capture;

import sparkles.input.events : altModifierName, isModifierKey, Key, KeyAction,
    KeyEvent, namedKeyLabel, superModifierName;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.keymap : acceptsTyped, Chord, maxPathLength, normalise,
    ShiftReq;
import sparkles.ui.style : BorderStyle, Decoration, FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind;
import sparkles.ui.wrap : TextWrap;

/// Where a capture is.
enum CapturePhase : ubyte
{
    idle,      /// no capture
    listening, /// waiting for the next key
    conflict,  /// the path is bound; the host asks what to do
    done,      /// a free path (or a resolved conflict): the host writes it
    cancelled, /// `Esc`, or the host's cancel
}

/// How a conflict was resolved.
enum CaptureResolution : ubyte
{
    /// No conflict: the new path replaces the old one.
    replace,
    /// The new path takes this command, the old path the other one.
    swap,
    /// The new path takes this command, which keeps its old path too.
    both,
}

/// What the host says about a captured path.
struct CaptureConflict
{
    /// What the path does now ("closes the pane"); empty when it is free.
    string what;
    /// No resolution exists (a prefix of a sequence, or a sequence under a
    /// bound key): refuse with `what` as the reason.
    bool blocking;
    /// The path so far opens other keys (the leader, a group): the capture
    /// keeps listening for the rest of the sequence, as typing it would.
    bool prefix;
}

/// The capture machine.
struct ChordCapture
{
    /// ditto
    CapturePhase phase;
    /// How many keys the edited binding has — the hint's wording; the
    /// capture itself settles as soon as the path stops being a prefix.
    ubyte want = 1;
    /// The keys pressed so far.
    Chord[maxPathLength] keys;
    /// ditto
    ubyte depth;
    /// Why the last key was not taken (a reserved key, a blocking
    /// conflict); empty otherwise.
    string refusal;
    /// What the captured path does now, at `CapturePhase.conflict`.
    string conflict;
    /// The answer to the conflict, at `CapturePhase.done`.
    CaptureResolution resolution;

@safe:

    /// Whether a capture owns the keyboard.
    bool listening() const scope pure nothrow @nogc => phase == CapturePhase.listening;

    /// Whether the capture is showing (listening or asking).
    bool open() const scope pure nothrow @nogc
        => phase == CapturePhase.listening || phase == CapturePhase.conflict;

    /// The path captured so far.
    const(Chord)[] path() const return pure nothrow @nogc => keys[0 .. depth];

    /// Starts listening for a path of `length` keys.
    void begin(size_t length) pure nothrow @nogc
    {
        this = ChordCapture.init;
        want = cast(ubyte)(length < 1 ? 1 : length > maxPathLength ? maxPathLength : length);
        phase = CapturePhase.listening;
    }

    /**
    Steps one key event. A release, a bare modifier or a key with no name is
    ignored; `Esc` cancels; a key `reserved` gives a reason for is refused and
    not taken. When the path is long enough, `boundTo` decides between
    `done` and `conflict`.
    */
    CapturePhase feed(in KeyEvent k, scope string delegate(in Chord) @safe reserved,
        scope CaptureConflict delegate(in Chord[]) @safe boundTo)
    {
        if (phase != CapturePhase.listening)
            return phase;
        if (k.action == KeyAction.release || k.key == Key.none || isModifierKey(k.key))
            return phase;
        const c = chordOf(k);
        // Esc, and a phone's Back, cancel: neither is ever captured.
        if ((c.key == Key.escape || c.key == Key.back) && !c.ctrl && !c.alt && !c.super_)
        {
            phase = CapturePhase.cancelled;
            return phase;
        }
        if (reserved !is null)
            if (const why = reserved(c))
            {
                refusal = why;
                return phase;
            }
        refusal = null;
        keys[depth++] = c;
        const found = boundTo !is null ? boundTo(path) : CaptureConflict.init;
        if (found.prefix && depth < maxPathLength)
            return phase; // a sequence: the next key follows
        settleWith(found);
        return phase;
    }

    /// Settles the keys pressed so far as the whole path (the touch
    /// "Done"); nothing before the first key.
    CapturePhase finish(scope CaptureConflict delegate(in Chord[]) @safe boundTo)
    {
        if (phase == CapturePhase.listening && depth)
            settleWith(boundTo !is null ? boundTo(path) : CaptureConflict.init);
        return phase;
    }

    /// The conflict's answer: `swap` or `both` settles it.
    void resolve(CaptureResolution r) pure nothrow @nogc
    {
        if (phase != CapturePhase.conflict)
            return;
        resolution = r;
        phase = CapturePhase.done;
    }

    /// Abandons the capture.
    void cancel() pure nothrow @nogc
    {
        phase = CapturePhase.cancelled;
    }

    /// Back to no capture, after the host acted on `done` or `cancelled`.
    void reset() pure nothrow @nogc
    {
        this = ChordCapture.init;
    }

    private void settleWith(CaptureConflict c)
    {
        // A prefix that is settled (Done, or the longest path) would shadow
        // the keys it opens.
        if (c.blocking || c.prefix)
        {
            // Refused: start the path again.
            refusal = c.what;
            depth = 0;
            return;
        }
        conflict = c.what;
        resolution = CaptureResolution.replace;
        phase = c.what.length ? CapturePhase.conflict : CapturePhase.done;
    }
}

/**
The chord a pressed key binds: its modifiers as held. Shift is part of the
chord only where the character does not already say it — `Shift+W` and
`Ctrl+Shift+Space` keep it; `?` (shifted `/`) does not; an unshifted key
binds either way, as the tables' own rows do.
*/
Chord chordOf(in KeyEvent raw) @safe pure nothrow @nogc
{
    const k = normalise(raw);
    Chord c = Chord(key: k.key, ctrl: k.mods.ctrl, alt: k.mods.alt, super_: k.mods.super_);
    if (k.key == Key.char_)
        c.ch = k.ch;
    const letter = k.key == Key.char_ && k.ch >= 'a' && k.ch <= 'z';
    const printable = k.key == Key.char_ && k.ch > ' ' && !letter;
    c.shift = k.mods.shift && !printable ? ShiftReq.yes : ShiftReq.ignore;
    return c;
}

///
@("ui.chord_capture.chordOf.shiftOnlyWhereTheKeyDoesNotSayIt")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : Mods;

    const w = chordOf(KeyEvent(Key.char_, 'W', Mods(ctrl: true)));
    assert(w.ch == 'w' && w.ctrl && w.shift == ShiftReq.yes);
    const q = chordOf(KeyEvent(Key.char_, '?', Mods(shift: true)));
    assert(q.ch == '?' && q.shift == ShiftReq.ignore);
    const v = chordOf(KeyEvent(Key.char_, 'v'));
    assert(v.ch == 'v' && v.shift == ShiftReq.ignore && !v.ctrl);
}

/**
A chord as a person reads it: `Ctrl+Shift+W`, `p`, `↵`. A chord the host's
`leader` accepts reads as `leaderGlyph` (terminal mockup G4 writes the leader
`␣`).
*/
string chordLabel(in Chord c, in Chord leader = Chord.init, string leaderGlyph = "␣")
    @safe pure
{
    import std.conv : text;
    import std.uni : toUpper;

    if (leader.key != Key.none && acceptsTyped(leader, c))
        return leaderGlyph;
    string s;
    if (c.ctrl)
        s ~= "Ctrl+";
    if (c.alt)
        s ~= altModifierName ~ "+";
    if (c.shift == ShiftReq.yes)
        s ~= "Shift+";
    if (c.super_)
        s ~= superModifierName ~ "+";
    if (c.key != Key.char_)
        return s ~ namedKeyLabel(c.key);
    if (c.ch == ' ')
        return s ~ "Space";
    if (c.chEnd)
        return s ~ text(c.ch, "–", c.chEnd);
    // A modified letter reads as the key cap (`Ctrl+W`); a bare one as typed.
    return s ~ (s.length ? text(c.ch).toUpper : text(c.ch));
}

/// A path's chords, space-separated.
string pathLabel(in Chord[] path, in Chord leader = Chord.init, string leaderGlyph = "␣")
    @safe pure
{
    string s;
    foreach (i, ref c; path)
        s ~= (i ? " " : "") ~ chordLabel(c, leader, leaderGlyph);
    return s;
}

///
@("ui.chord_capture.chordLabel.readsAsTheKeyCaps")
@safe pure unittest
{
    const leader = Chord(key: Key.char_, ch: ' ', ctrl: true, shift: ShiftReq.yes);
    assert(chordLabel(Chord(key: Key.char_, ch: 'w', ctrl: true, shift: ShiftReq.yes))
        == "Ctrl+Shift+W");
    assert(chordLabel(leader) == "Ctrl+Shift+Space");
    assert(pathLabel([leader, Chord(key: Key.char_, ch: 'p'), Chord(key: Key.char_, ch: 'v')],
        leader) == "␣ p v");
}

// ─────────────────────────────────────────────────────────────────────────────
// The view.
// ─────────────────────────────────────────────────────────────────────────────

/// The capture's buttons, as offsets from the view's `hitBase`.
enum CaptureHit : size_t
{
    cancel = 1, ///
    both = 2,   ///
    swap = 3,   ///
    done = 4,   /// settle a shorter sequence (touch)
}

/// The slots the view references (design-system `TOK6`).
enum Slot[] chordCaptureSlots = [Slot.accentPrimary, Slot.surfaceRaised, Slot.warn,
    Slot.muted, Slot.textPrimary, Slot.chromeAccent, Slot.error];

/**
The capture's body under its row (mockup G4): the keys pressed so far in a
dashed box, live; at a conflict, what the path does now with Cancel, Bind both
and Swap; a refusal's reason; and the hint. `leader` reads as `␣`;
`targetRows` sizes the buttons as touch targets (`TOK7`); `touch` adds the
Done button that settles a shorter sequence.
*/
uint chordCaptureView(ref Builder b, ref const ChordCapture cap, in Chord leader,
    size_t hitBase, int targetRows = 1, bool touch = false) @safe
{
    uint[] body_;

    // The keys, live, each a key cap.
    {
        uint[] caps;
        foreach (i, ref c; cap.path)
        {
            if (i)
                caps ~= b.add(Widget(kind: WidgetKind.text, text: " ", slot: Slot.muted));
            caps ~= b.add(Widget(kind: WidgetKind.panel,
                children: [b.add(Widget(kind: WidgetKind.text, text: chordLabel(c, leader),
                    slot: Slot.textPrimary, alignX: Alignment.center,
                    textStyle: TextStyle(bold: true, fontRole: FontRole.uiMono, typeStep: TypeStep.body)))],
                padding: Insets(0, 1, 0, 1), slot: Slot.surfaceRaised, paintBackground: true,
                decoration: Decoration(borderRadius: 4)));
        }
        if (cap.listening)
            caps ~= b.add(Widget(kind: WidgetKind.text,
                text: cap.depth ? " …" : "Press the new key", slot: Slot.muted,
                textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body)));
        body_ ~= b.add(Widget(kind: WidgetKind.row, children: caps,
            width: SizeSpec.grow(),
            height: targetRows > 1 ? SizeSpec.fixed(targetRows) : SizeSpec.fit_,
            padding: Insets(0, 1, 0, 1),
            alignX: Alignment.center, alignY: Alignment.center,
            decoration: Decoration(borderStyle: BorderStyle.dashed, borderWidth: Insets.all(1),
                borderSlot: Slot.accentPrimary, borderRadius: 8)));
    }

    uint button(string icon, string text, size_t part, bool primary)
    {
        // The icon is data, the caption words (D50).
        const slot = primary ? Slot.chromeAccent : Slot.textPrimary;
        const t = b.add(Widget(kind: WidgetKind.row, gap: 1, alignY: Alignment.center, children: [
            b.add(Widget(kind: WidgetKind.text, text: icon, slot: slot,
                textStyle: TextStyle(bold: primary, fontRole: FontRole.uiMono, typeStep: TypeStep.label))),
            b.add(Widget(kind: WidgetKind.text, text: text, slot: slot,
                textStyle: TextStyle(bold: primary, fontRole: FontRole.ui, typeStep: TypeStep.label)))]));
        return b.add(Widget(kind: WidgetKind.panel, children: [t], alignX: Alignment.center,
            padding: Insets(0, 1, 0, 1),
            height: targetRows > 1 ? SizeSpec.fixed(targetRows) : SizeSpec.fit_,
            alignY: Alignment.center, hitId: hitBase + part,
            slot: primary ? Slot.chromeAccent : Slot.surfaceRaised, paintBackground: true,
            decoration: Decoration(borderRadius: 8, drawHeight: 36)));
    }

    if (cap.phase == CapturePhase.conflict)
    {
        const warn = b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(text: "⚠ Already bound", slot: Slot.warn,
                textStyle: TextStyle(bold: true, fontRole: FontRole.ui, typeStep: TypeStep.body)),
            TextSpan(text: " — " ~ pathLabel(cap.path, leader) ~ ": "
                ~ cap.conflict ~ ".", slot: Slot.textPrimary,
                textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body)),
        ]));
        const buttons = b.add(Widget(kind: WidgetKind.row, children: [
            button("✕", "Cancel", CaptureHit.cancel, false),
            button("⊕", "Bind both", CaptureHit.both, false),
            button("⇄", "Swap", CaptureHit.swap, true)], gap: 1, width: SizeSpec.grow(),
            alignX: Alignment.end));
        body_ ~= b.add(Widget(kind: WidgetKind.column, children: [warn, buttons],
            width: SizeSpec.grow(), padding: Insets(0, 1, 0, 1),
            decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
                borderSlot: Slot.warn, borderRadius: 6)));
    }
    else if (cap.listening)
    {
        if (cap.refusal.length)
            body_ ~= b.add(Widget(kind: WidgetKind.text, text: "✗ " ~ cap.refusal,
                slot: Slot.error, wrap: TextWrap.greedy,
                textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.caption)));
        uint[] actions;
        if (touch && cap.depth)
            actions ~= button("✓", "Done", CaptureHit.done, true);
        actions ~= button("✕", "Cancel", CaptureHit.cancel, false);
        body_ ~= b.add(Widget(kind: WidgetKind.row, children: actions, gap: 1,
            width: SizeSpec.grow(), alignX: Alignment.end));
    }
    body_ ~= b.add(Widget(kind: WidgetKind.text,
        text: cap.want > 1
            ? "Press each key of the sequence in turn · Esc cancels"
            : "Press the new key · Esc cancels",
        slot: Slot.muted, wrap: TextWrap.greedy,
        textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.caption)));
    return b.add(Widget(kind: WidgetKind.column, children: body_, gap: targetRows > 1 ? 1 : 0,
        width: SizeSpec.grow()));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.functional : toDelegate;

    private enum Chord ctrlShiftW = Chord(key: Key.char_, ch: 'w', ctrl: true,
        shift: ShiftReq.yes);

    private string reservedCtrlC(in Chord c) @safe
        => c.ctrl && c.key == Key.char_ && c.ch == 'c' && c.shift != ShiftReq.yes
            ? "Ctrl+C belongs to the program" : null;

    private CaptureConflict boundLike(in Chord[] p) @safe
    {
        if (p.length == 1 && p[0] == ctrlShiftW)
            return CaptureConflict("closes the pane");
        if (p.length == 1 && p[0].key == Key.char_ && p[0].ch == 'g' && !p[0].ctrl)
            return CaptureConflict("starts 3 other bindings", true);
        if (p.length == 1 && p[0].key == Key.char_ && p[0].ch == 'z')
            return CaptureConflict("opens the z keys", false, true);
        return CaptureConflict.init;
    }
}

@("ui.chord_capture.feed.aFreeChordIsDone")
@safe unittest
{
    import sparkles.input.events : Mods;

    ChordCapture cap;
    cap.begin(1);
    assert(cap.listening);
    // A bare modifier and a release are not keys.
    assert(cap.feed(KeyEvent(Key.ctrl), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.listening);
    KeyEvent up = KeyEvent(Key.char_, 'e', Mods(ctrl: true));
    up.action = KeyAction.release;
    assert(cap.feed(up, toDelegate(&reservedCtrlC), toDelegate(&boundLike)) == CapturePhase.listening);
    assert(cap.feed(KeyEvent(Key.char_, 'e', Mods(ctrl: true)), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.done);
    assert(cap.path.length == 1 && cap.path[0].ch == 'e' && cap.path[0].ctrl);
    assert(cap.resolution == CaptureResolution.replace);
}

@("ui.chord_capture.feed.reservedIsRefusedWithTheReason")
@safe unittest
{
    import sparkles.input.events : Mods;

    ChordCapture cap;
    cap.begin(1);
    assert(cap.feed(KeyEvent(Key.char_, 'c', Mods(ctrl: true)), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.listening);
    assert(cap.refusal == "Ctrl+C belongs to the program" && cap.depth == 0);
    // The next key is taken, and the reason goes.
    assert(cap.feed(KeyEvent(Key.f5), toDelegate(&reservedCtrlC), toDelegate(&boundLike)) == CapturePhase.done);
    assert(!cap.refusal.length);
}

@("ui.chord_capture.feed.escCancelsAndIsNeverBound")
@safe unittest
{
    ChordCapture cap;
    cap.begin(2);
    assert(cap.feed(KeyEvent(Key.char_, 'z'), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.listening);
    assert(cap.feed(KeyEvent(Key.escape), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.cancelled);
    // A phone's Back cancels the same way.
    cap.begin(1);
    assert(cap.feed(KeyEvent(Key.back), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.cancelled);
}

@("ui.chord_capture.feed.aBoundChordAsksAndASequenceWaits")
@safe unittest
{
    import sparkles.input.events : Mods;

    ChordCapture cap;
    cap.begin(1);
    assert(cap.feed(KeyEvent(Key.char_, 'W', Mods(ctrl: true)), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.conflict);
    assert(cap.conflict == "closes the pane");
    cap.resolve(CaptureResolution.swap);
    assert(cap.phase == CapturePhase.done && cap.resolution == CaptureResolution.swap);

    // A sequence: a prefix keeps listening, the key after it settles.
    cap.begin(2);
    assert(cap.feed(KeyEvent(Key.char_, 'z'), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.listening);
    assert(cap.feed(KeyEvent(Key.char_, 'q'), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.done && cap.path.length == 2);
    // Done on a bare prefix is refused: it would shadow the keys it opens.
    cap.begin(2);
    cast(void) cap.feed(KeyEvent(Key.char_, 'z'), toDelegate(&reservedCtrlC),
        toDelegate(&boundLike));
    assert(cap.finish(toDelegate(&boundLike)) == CapturePhase.listening
        && cap.refusal == "opens the z keys");

    // A prefix of other bindings is refused outright, and the path restarts.
    cap.begin(1);
    assert(cap.feed(KeyEvent(Key.char_, 'g'), toDelegate(&reservedCtrlC), toDelegate(&boundLike))
        == CapturePhase.listening);
    assert(cap.refusal == "starts 3 other bindings" && cap.depth == 0);
}

@("ui.chord_capture.chordCaptureView.showsTheConflictChoices")
@safe unittest
{
    import std.algorithm.searching : canFind;

    import sparkles.input.events : Mods;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hoverTargets;

    ChordCapture cap;
    cap.begin(1);
    cast(void) cap.feed(KeyEvent(Key.char_, 'W', Mods(ctrl: true)), toDelegate(&reservedCtrlC), toDelegate(&boundLike));
    Builder b;
    auto tree = b.finish(chordCaptureView(b, cap, Chord.init, 100, 3));
    const(char)[] all;
    foreach (ref n; tree.nodes)
    {
        all ~= n.text;
        foreach (ref s; n.spans)
            all ~= s.text;
    }
    assert(all.canFind("Ctrl+Shift+W") && all.canFind("closes the pane"));
    assert(all.canFind("Swap") && all.canFind("Bind both") && all.canFind("Cancel"));

    // Every choice is a touch target three rows tall (`TOK7`).
    auto frames = layout(tree, Constraints(maxW: 60));
    size_t[] ids;
    foreach (ref t; hoverTargets(tree, frames))
    {
        ids ~= t.hitId;
        assert(t.rect.height == 3);
    }
    assert(ids.canFind(100 + CaptureHit.swap) && ids.canFind(100 + CaptureHit.both)
        && ids.canFind(100 + CaptureHit.cancel));
}
