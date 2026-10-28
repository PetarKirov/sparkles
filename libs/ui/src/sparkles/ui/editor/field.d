/**
`EditorField`: an editor ready to embed as a text field (`EDU4`).

It owns the editor state, a small pool for the text that keys and pastes
carry, and the target's default key table. A host routes a focused field's
keys and pastes to it and reads back whether the text changed, was
submitted or was cancelled, and whether the field asked for the clipboard.
The kill ring is the host session's when the host provides one (`EDY1`),
else the field's own.

Specification: `docs/specs/ui/editor.md` §5–8.
*/
module sparkles.ui.editor.field;

import core.time : MonoTime;

import sparkles.base.pool.text_pool : TextPool;
import sparkles.input.events : InputTextTag, KeyEvent, TextId;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : EditCommand, EditKind;
import sparkles.ui.editor.context : LogicalContext;
import sparkles.ui.editor.effect : EditEffects, EffectKind, NoopReason;
import sparkles.ui.editor.keys : EditorTarget, editorCommand;
import sparkles.ui.editor.kill_ring : KillRing;
import sparkles.ui.editor.state : EditorOptions, EditorState;
import sparkles.ui.editor.step : stepInPlace;

/// The pool a field interns key and paste text in; each text is released
/// as soon as its step has copied it.
alias FieldTextPool = TextPool!(InputTextTag, 4, 4096);

/// What one input did to a field.
struct FieldResult
{
    /// The field consumed the input; otherwise it falls through (`EDK5`).
    bool handled;
    /// The text changed.
    bool changed;
    /// Enter in a single-line field, or an explicit submit.
    bool submitted;
    /// Escape with nothing left to collapse.
    bool cancelled;
    /// The field asks for the clipboard: answer with `pasteAnswer(request, …)`.
    uint clipboardRequest;
    /// Text the field asks to put on the clipboard, or empty.
    Text clipboardWrite;
    /// Every effect, for a host that needs more (`EDT9`).
    EditEffects effects;
}

/// An editor embedded as a field.
struct EditorField
{
    EditorState state;
    /// The host session's kill ring, or `null` for the field's own.
    KillRing* sessionRing;
    /// Which default key table applies.
    EditorTarget target = EditorTarget.terminal;
    /// The layout's answers; a field without wrapping uses logical lines. Set
    /// `context.clipboardRead` when the host answers the field's clipboard
    /// requests (`EDY5`).
    LogicalContext context;

    private KillRing ownRing;
    private SharedPool pool;

    /// A field holding `text`, caret at its end.
    static EditorField make(scope const(char)[] text = "", EditorOptions options = EditorOptions.init,
        EditorTarget target = EditorTarget.terminal) @safe pure nothrow @nogc
    {
        EditorField field;
        field.state = EditorState.create(text, options);
        field.target = target;
        return field;
    }

    /// A single-line field (`EDT8`).
    static EditorField singleLine(scope const(char)[] text = "",
        EditorTarget target = EditorTarget.terminal) @safe pure nothrow @nogc
    {
        EditorOptions options;
        options.singleLine = true;
        return make(text, options, target);
    }

    /// The text, copied.
    string text() const @safe pure nothrow
    {
        auto bytes = new char[state.text.length];
        state.text.copyTo(0, bytes.length, bytes);
        return (() @trusted => cast(string) bytes)(); // unique and never written again
    }

    /// Whether the field holds no text.
    bool empty() const @safe pure nothrow @nogc => state.text.length == 0;

    /// Replace the text, caret at its end; history starts afresh.
    void setText(scope const(char)[] text) @safe pure nothrow
    {
        state = EditorState.create(text, state.options);
    }

    /// Route a key (`EDI1`, `EDK5`). An unbound key is not handled.
    FieldResult key(in KeyEvent event, MonoTime now = MonoTime.init) @safe pure nothrow @nogc
    {
        EditCommand command;
        if (!editorCommand(event, target, *texts, command))
            return FieldResult.init;
        return run(command, now);
    }

    /// Insert `text`, as typed or as a paste (`EDI4`). Text of any length
    /// goes in whole.
    FieldResult insert(scope const(char)[] text, bool paste = false, MonoTime now = MonoTime.init)
        @safe pure nothrow @nogc
    {
        auto source = Given(text);
        return runWith(EditCommand.insert(TextId.init, paste), source, now);
    }

    /// Answer clipboard request `request` with `text` (`EDY5`).
    FieldResult pasteAnswer(uint request, scope const(char)[] text, MonoTime now = MonoTime.init)
        @safe pure nothrow @nogc
    {
        auto source = Given(text);
        return runWith(EditCommand.pasteAnswer(request, TextId.init), source, now);
    }

    /// Run `command`.
    FieldResult run(EditCommand command, MonoTime now = MonoTime.init) @safe pure nothrow @nogc
    {
        auto result = runWith(command, *texts, now);
        if (command.text.valid)
            cast(void) texts.release(command.text);
        return result;
    }

    private FieldResult runWith(Texts)(EditCommand command, ref scope Texts source, MonoTime now)
        @safe pure nothrow @nogc
    {
        const before = state.text;
        context.now = now;
        auto ring = sessionRing !is null ? sessionRing : (() @trusted => &ownRing)();
        FieldResult result;
        result.handled = true;
        result.effects = stepInPlace(state, *ring, source, command, context);
        // Vertical motion in a single line is a no-op the application can use:
        // a picker moves its list with Up and Down (`EDK5`).
        if (result.effects.has(EffectKind.noop)
            && result.effects.first(EffectKind.noop).reason == NoopReason.singleLine)
            result.handled = false;
        result.changed = state.text != before;
        result.submitted = result.effects.has(EffectKind.submit);
        result.cancelled = result.effects.has(EffectKind.cancel);
        if (result.effects.has(EffectKind.readClipboard))
            result.clipboardRequest = result.effects.first(EffectKind.readClipboard).request;
        if (result.effects.has(EffectKind.writeClipboard))
            result.clipboardWrite = Text(result.effects.first(EffectKind.writeClipboard).text);
        return result;
    }

    private FieldTextPool* texts() return @safe pure nothrow @nogc
    {
        if (pool.box is null)
            pool = SharedPool.make();
        return pool.get();
    }
}

/// One text a field already holds, served for whatever id its command names:
/// an insert or a paste needs no pool, so no length limits it.
private struct Given
{
    const(char)[] text;

    void withText(Fn)(in TextId, scope Fn fn) const => fn(text);
}

/**
The field's text pool, shared by copies of a field and freed with the last:
out of the collector, so routing a key allocates nothing it must collect.
*/
private struct SharedPool
{
    private static struct Box
    {
        shared size_t refs;
        FieldTextPool pool;
    }

    private Box* box;

    static SharedPool make() @trusted pure nothrow @nogc
    {
        import core.exception : onOutOfMemoryError;
        import core.lifetime : emplace;
        import core.memory : pureMalloc;

        auto memory = cast(Box*) pureMalloc(Box.sizeof);
        if (memory is null)
            onOutOfMemoryError();
        emplace(memory);
        memory.refs = 1;
        SharedPool result;
        result.box = memory;
        return result;
    }

    this(ref scope const SharedPool other) @trusted pure nothrow @nogc
    {
        import core.atomic : atomicOp;

        box = cast(Box*) cast(size_t) other.box;
        if (box !is null)
            atomicOp!"+="(box.refs, 1);
    }

    ~this() @trusted pure nothrow @nogc
    {
        import core.atomic : atomicOp;
        import core.memory : pureFree;

        if (box !is null && atomicOp!"-="(box.refs, 1) == 0)
            pureFree(box);
    }

    FieldTextPool* get() return @trusted pure nothrow @nogc => &box.pool;
}

///
@("editor.field.singleLine")
@safe pure nothrow
unittest
{
    import sparkles.input.events : Key, Mods;

    auto field = EditorField.singleLine("ab");
    assert(field.key(KeyEvent(Key.char_, 'c')).changed);
    assert(field.text == "abc");
    assert(field.key(KeyEvent(Key.char_, 'w', Mods(ctrl: true))).changed);
    assert(field.text == "");
    const yanked = field.key(KeyEvent(Key.char_, 'y', Mods(ctrl: true)));
    assert(yanked.changed && field.text == "abc");
    assert(field.key(KeyEvent(Key.enter)).submitted);
    assert(!field.key(KeyEvent(Key.char_, 'g', Mods(ctrl: true))).handled, "falls through");
    assert(!field.key(KeyEvent(Key.down)).handled, "a single line declines vertical motion");
    assert(field.insert("x\ny", true).changed && field.text == "abcx y");
    assert(field.key(KeyEvent(Key.escape)).cancelled);
}

/// Two fields sharing a session ring yank each other's kills (`EDY1`).
@("editor.field.sessionRing")
@safe pure nothrow
unittest
{
    import sparkles.input.events : Key, Mods;

    auto ring = new KillRing;
    auto a = EditorField.singleLine("hello");
    auto b = EditorField.singleLine();
    a.sessionRing = ring;
    b.sessionRing = ring;
    a.key(KeyEvent(Key.char_, 'u', Mods(ctrl: true)));
    b.key(KeyEvent(Key.char_, 'y', Mods(ctrl: true)));
    assert(a.text == "" && b.text == "hello");
}

/// EDI4: a paste longer than any key's text goes in whole.
@("editor.field.longPasteIsWhole")
@safe pure nothrow
unittest
{
    auto field = EditorField.make();
    auto big = new char[100_000];
    big[] = 'x';
    assert(field.insert(big, true).changed);
    assert(field.state.text.length == big.length);
}

/**
What a host's clipboard can do, for a host that reads it at once (`EDY5`).
Either member may be null; the field then reports that capability absent
(`EDI5`). `useClipboard` declares it to a field and `serveClipboard` does a
result's clipboard work.
*/
struct FieldClipboard(Write, Read)
{
    /// Puts text on the clipboard.
    Write write;
    /// Returns the clipboard's text.
    Read read;
}

/// ditto
FieldClipboard!(Write, Read) fieldClipboard(Write, Read)(Write write, Read read)
    => FieldClipboard!(Write, Read)(write, read);

/// Declare what `clipboard` can do to `field`, so paste, copy and cut are
/// offered only when the host carries them out.
void useClipboard(Clipboard)(ref EditorField field, in Clipboard clipboard)
{
    field.context.clipboardWrite = clipboard.write !is null;
    field.context.clipboardRead = clipboard.read !is null;
}

/**
Do `result`'s clipboard work: write the text it copied and answer the read
it asked for with the clipboard's text. Returns the result with the
answer's change folded in.
*/
FieldResult serveClipboard(Clipboard)(ref EditorField field, FieldResult result,
    in Clipboard clipboard)
{
    if (result.clipboardWrite.length && clipboard.write !is null)
    {
        auto bytes = new char[result.clipboardWrite.length];
        result.clipboardWrite.copyTo(0, bytes.length, bytes);
        clipboard.write(bytes);
    }
    if (result.clipboardRequest && clipboard.read !is null)
    {
        const answer = field.pasteAnswer(result.clipboardRequest, clipboard.read());
        result.changed = result.changed || answer.changed;
        result.clipboardRequest = 0;
    }
    return result;
}

/// A host serving a field's clipboard.
@("editor.field.serveClipboard")
@safe pure nothrow
unittest
{
    import sparkles.input.events : Key, Mods;
    import sparkles.ui.editor.keys : EditorTarget;

    string board = "pasted";
    auto clipboard = fieldClipboard((scope const(char)[] t) { board = t.idup; },
        () => board);
    auto field = EditorField.singleLine("abc", EditorTarget.window);
    assert(field.key(KeyEvent(Key.char_, 'v', Mods(ctrl: true))).effects.has(EffectKind.noop),
        "undeclared, paste is absent");

    useClipboard(field, clipboard);
    field.key(KeyEvent(Key.char_, 'a', Mods(ctrl: true))); // select all
    serveClipboard(field, field.key(KeyEvent(Key.char_, 'x', Mods(ctrl: true))), clipboard);
    assert(board == "abc" && field.empty, "cut puts the text on the board");
    const r = serveClipboard(field, field.key(KeyEvent(Key.char_, 'v', Mods(ctrl: true))), clipboard);
    assert(r.changed && field.text == "abc", "paste reads it back");
}
