/** Shared query editing and keyboard routing for the command palette. */
module sparkles.ui.command_palette_input;

import core.time : MonoTime;
import sparkles.input.events : Key, KeyAction, KeyEvent;
import sparkles.ui.command_palette : CommandPalette, PaletteEffect, PaletteEffectKind,
    PaletteInvocation, PaletteStatus;
import sparkles.ui.editor.field : EditorField, FieldResult;

/// A palette and its single-line query field, independent of the rendering host.
struct PaletteInput(Cmd, size_t Capacity = 512, size_t QueryBytes = 256)
{
    CommandPalette!(Cmd, Capacity, QueryBytes) palette;
    EditorField query;
    /// Effects of the most recent query edit, including clipboard and IME cancellation asks.
    FieldResult lastEdit;

    /// Open with a fresh query and the invocation's captured target/focus.
    PaletteEffect!Cmd open(Context)(PaletteInvocation invocation, in Context context)
    {
        auto result = palette.open(invocation);
        if (result.kind == PaletteEffectKind.opened)
        {
            query = EditorField.singleLine();
            lastEdit = FieldResult.init;
            result.status = palette.search(result.ticket, "", context);
        }
        return result;
    }

    /// Route a key to navigation, acceptance, dismissal or the shared text editor.
    PaletteEffect!Cmd key(Context)(in KeyEvent event, in Context context,
        MonoTime now = MonoTime.init)
    {
        lastEdit = FieldResult.init;
        if (!palette.active || event.action == KeyAction.release) return PaletteEffect!Cmd.init;
        const ticket = palette.snapshot.ticket;
        if (!query.state.composition.active && !event.mods.ctrl && !event.mods.alt && !event.mods.super_)
        {
            if (event.key == Key.escape || event.key == Key.back) return palette.cancel(ticket);
            if (event.key == Key.enter) return palette.accept(ticket, context);
            if (event.key == Key.up || event.key == Key.down)
            {
                palette.move(ticket, event.key == Key.up ? -1 : 1);
                return PaletteEffect!Cmd.init;
            }
        }
        auto before = query;
        lastEdit = query.key(event, now);
        if (!lastEdit.changed) return PaletteEffect!Cmd.init;
        const status = palette.search(ticket, query.text, context);
        if (status != PaletteStatus.ok)
        {
            query = before;
            lastEdit = FieldResult.init;
        }
        return PaletteEffect!Cmd(status: status);
    }

    /// Insert a complete typed/pasted string; a refused query preserves both field and results.
    PaletteEffect!Cmd insert(Context)(scope const(char)[] text, in Context context,
        bool paste = true, MonoTime now = MonoTime.init)
        => editText(text, context, paste, 0, now);

    /// Serve a complete paste, preserving the query field's clipboard-request generation.
    PaletteEffect!Cmd paste(Context)(scope const(char)[] text, uint request, in Context context,
        MonoTime now = MonoTime.init)
        => editText(text, context, true, request, now);

    private PaletteEffect!Cmd editText(Context)(scope const(char)[] text, in Context context,
        bool pasted, uint request, MonoTime now)
    {
        lastEdit = FieldResult.init;
        if (!palette.active) return PaletteEffect!Cmd.init;
        if (text.length > QueryBytes) return PaletteEffect!Cmd(status: PaletteStatus.capacityExceeded);
        auto before = query;
        lastEdit = pasted ? query.paste(text, request, now) : query.insert(text, false, now);
        if (!lastEdit.changed) return PaletteEffect!Cmd.init;
        const status = palette.search(palette.snapshot.ticket, query.text, context);
        if (status != PaletteStatus.ok)
        {
            query = before;
            lastEdit = FieldResult.init;
        }
        return PaletteEffect!Cmd(status: status);
    }
}

/// Enter resolves preedit into the query; Escape cancels preedit before dismissing the palette.
@("ui.command_palette_input.compositionDoesNotExecute")
@safe unittest
{
    import sparkles.input.events : CompositionEvent;
    import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    PaletteInput!(Command, 4) input;
    PaletteEntry!Command[1] catalog = [PaletteEntry!Command(Id(Command.save), "Save")];
    assert(input.palette.catalog(catalog[]) == PaletteStatus.ok);
    input.open(PaletteInvocation(42, 17), Context.init);
    input.query.compose(CompositionEvent.init, "save");
    const result = input.key(KeyEvent(Key.enter), Context.init);
    assert(result.kind == PaletteEffectKind.none && input.palette.active);
    assert(!input.query.state.composition.active && input.query.text == "save");
    assert(input.palette.query == "save");
    input.query.compose(CompositionEvent.init, "copy");
    input.key(KeyEvent(Key.escape), Context.init);
    assert(input.palette.active && !input.query.state.composition.active);
    assert(input.query.text == "save");
    assert(input.key(KeyEvent(Key.escape), Context.init).kind == PaletteEffectKind.cancelled);
}

/// A refused paste reports its bound and preserves the accepted query/results.
@("ui.command_palette_input.oversizedPaste")
@safe unittest
{
    import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    PaletteInput!(Command, 4, 4) input;
    PaletteEntry!Command[1] catalog = [PaletteEntry!Command(Id(Command.save), "Save")];
    assert(input.palette.catalog(catalog[]) == PaletteStatus.ok);
    input.open(PaletteInvocation(42, 17), Context.init);
    const result = input.insert("12345", Context.init);
    assert(result.status == PaletteStatus.capacityExceeded);
    assert(input.query.empty && input.palette.query.length == 0 && input.palette.rowCount == 1);
}

/// A rolled-back query never publishes change effects for the discarded edit.
@("ui.command_palette_input.rejectedEditHasNoChangeEffects")
@safe unittest
{
    import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
    import sparkles.ui.editor.effect : EffectKind;
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    PaletteInput!(Command, 4, 4) input;
    PaletteEntry!Command[1] catalog = [PaletteEntry!Command(Id(Command.save), "Save")];
    assert(input.palette.catalog(catalog[]) == PaletteStatus.ok);
    input.open(PaletteInvocation(42, 17), Context.init);
    input.insert("save", Context.init);
    const rejected = input.key(KeyEvent(Key.char_, 'r'), Context.init);
    assert(rejected.status == PaletteStatus.capacityExceeded);
    assert(input.query.text == "save" && input.palette.query == "save");
    assert(!input.lastEdit.changed && !input.lastEdit.effects.has(EffectKind.changed));
}

/// Clipboard answers are accepted once and stale request IDs cannot change the query.
@("ui.command_palette_input.clipboardAnswerGeneration")
@safe unittest
{
    import sparkles.input.events : Mods;
    import sparkles.ui.editor.keys : EditorTarget;
    import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    PaletteInput!(Command, 4) input;
    PaletteEntry!Command[1] catalog = [PaletteEntry!Command(Id(Command.save), "Save")];
    assert(input.palette.catalog(catalog[]) == PaletteStatus.ok);
    input.open(PaletteInvocation(42, 17), Context.init);
    input.query.target = EditorTarget.window;
    input.query.context.clipboardRead = true;
    input.key(KeyEvent(Key.char_, 'v', Mods(ctrl: true)), Context.init);
    const request = input.lastEdit.clipboardRequest;
    assert(request != 0);
    input.paste("save", request, Context.init);
    assert(input.query.text == "save" && input.palette.query == "save");
    input.paste("late", request, Context.init);
    assert(input.query.text == "save" && input.palette.query == "save");
}

/// Typing, navigation and acceptance share one target; reopening drops the old query.
@("ui.command_palette_input.keyboardLifecycle")
@safe unittest
{
    import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
    enum Command { none, save, open }
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => target == 42;
    }
    PaletteInput!(Command, 4, 8) input;
    PaletteEntry!Command[2] catalog = [PaletteEntry!Command(Id(Command.save), "Save"),
        PaletteEntry!Command(Id(Command.open), "Open")];
    assert(input.palette.catalog(catalog[]) == PaletteStatus.ok);
    assert(input.open(PaletteInvocation(42, 17), Context.init).kind == PaletteEffectKind.opened);
    assert(input.key(KeyEvent(Key.char_, 's'), Context.init).status == PaletteStatus.ok);
    assert(input.query.text == "s", input.query.text);
    assert(input.palette.row(0).command == Id(Command.save));
    input.insert("ave", Context.init);
    assert(input.query.text == "save");
    assert(input.palette.rowCount == 1);
    input.key(KeyEvent(Key.enter), Context.init);
    // Closed input cannot emit a second invocation.
    assert(input.key(KeyEvent(Key.enter), Context.init).kind == PaletteEffectKind.none);
    input.open(PaletteInvocation(42, 17), Context.init);
    assert(input.query.empty && input.palette.rowCount == 2);
    input.key(KeyEvent(Key.down), Context.init);
    const accepted = input.key(KeyEvent(Key.enter), Context.init);
    assert(accepted.kind == PaletteEffectKind.execute && accepted.invocation.target == 42);
    assert(accepted.command == Id(Command.open));
    input.open(PaletteInvocation(42, 17), Context.init);
    const cancelled = input.key(KeyEvent(Key.escape), Context.init);
    assert(cancelled.kind == PaletteEffectKind.cancelled && cancelled.invocation.focus == 17);
}
