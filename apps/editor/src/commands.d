/** One command policy for keyboard resolution, Lantern and the command palette. */
module commands;

import sparkles.input.events : chord, Key, KeyEvent, unparseChordPath;
import sparkles.ui.command_bindings : effectiveCommandShortcut;
import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
import sparkles.ui.editor.keys : EditorAction, EditorTarget, editorBindings;
import sparkles.ui.keymap : Binding, bind, terminalScope;
import examples : Example;
import settings : label, PresentationToggle;

/// App operations; shared editing operations carry an EditorAction argument.
enum Command : ubyte { none, palette, guide, newTab, nextTab, previousTab, inspector,
    example, themes, selectTheme, toggleTheme, edit, quit, open, save, saveAs, confirm, cancel,
    closeTab, discard, restoreSession, languages, selectLanguage, presentation }
enum Scope : ubyte { @terminalScope modalModifiers, application, document, dialog, closing, recovery }
alias CommandId = PaletteCommand!Command;
alias CommandBinding = Binding!(Command, Scope);

/// Effective policy is chosen once per host's editor target.
CommandBinding[] commandBindings(EditorTarget target) @safe pure nothrow
{
    auto palette = chord('p'); palette.ctrl = true; palette.shift = typeof(palette.shift).yes;
    auto next = chord(Key.tab); next.ctrl = true;
    auto previous = next; previous.shift = typeof(previous.shift).yes;
    auto create = chord('n'); create.ctrl = true;
    auto quit = chord('q'); quit.ctrl = true;
    auto open = chord('o'); open.ctrl = true;
    auto save = chord('s'); save.ctrl = true;
    auto saveAs = save; saveAs.shift = typeof(save.shift).yes;
    auto close = chord('w'); close.ctrl = true;
    close.shift = target == EditorTarget.terminal ? typeof(close.shift).yes : typeof(close.shift).no;
    auto leader = chord(Key.f4);
    CommandBinding[] result = [bind(Scope.application, palette, Command.palette, "Commands"),
        bind(Scope.application, chord(Key.f1), Command.guide, "Key guide", reveal: true),
        bind(Scope.application, create, Command.newTab, "New tab"),
        bind(Scope.application, previous, Command.previousTab, "Previous tab"),
        bind(Scope.application, next, Command.nextTab, "Next tab"),
        bind(Scope.application, chord(Key.f12), Command.inspector, "Toggle inspector"),
        bind(Scope.application, leader, chord('t'), Command.themes, "Choose theme"),
        bind(Scope.application, leader, chord('d'), Command.toggleTheme, "Toggle dark/light theme"),
        bind(Scope.document, leader, chord('l'), Command.languages, "Choose language"),
        bind(Scope.recovery, leader, chord('r'), Command.restoreSession, "Restore previous session"),
        bind(Scope.application, open, Command.open, "Open file"),
        bind(Scope.application, saveAs, Command.saveAs, "Save as"),
        bind(Scope.application, save, Command.save, "Save"),
        bind(Scope.application, close, Command.closeTab, "Close tab"),
        bind(Scope.application, quit, Command.quit, "Quit"),
        bind(Scope.dialog, chord(Key.enter), Command.confirm, "Confirm"),
        bind(Scope.dialog, chord(Key.escape), Command.cancel, "Cancel"),
        bind(Scope.dialog, chord(Key.back), Command.cancel, "Cancel"),
        bind(Scope.closing, chord('s'), Command.confirm, "Save and close"),
        bind(Scope.closing, chord('d'), Command.discard, "Discard changes"),
        bind(Scope.closing, chord('c'), Command.cancel, "Cancel close")];
    foreach (original; editorBindings(target))
    {
        if (original.cmd == EditorAction.none) continue;
        CommandBinding binding;
        binding.path = original.path;
        binding.depth = original.depth;
        binding.scope_ = Scope.document;
        binding.cmd = Command.edit;
        binding.arg = cast(ubyte) original.cmd;
        binding.desc = original.desc;
        result ~= binding;
    }
    return result;
}

/// Palette metadata comes from the same table, plus intentionally unbound actions.
PaletteEntry!Command[] commandCatalog(scope const(CommandBinding)[] bindings) @safe pure nothrow
{
    PaletteEntry!Command[] result;
    foreach (binding; bindings)
    {
        if (binding.cmd == Command.none || binding.reveal) continue;
        const id = CommandId(binding.cmd, binding.arg);
        bool seen;
        foreach (entry; result) seen |= entry.command == id;
        if (!seen) result ~= PaletteEntry!Command(id, binding.desc,
            binding.cmd == Command.edit ? "Editing" : "Application");
    }
    result ~= PaletteEntry!Command(CommandId(Command.example, Example.code), "Open code example", "Examples");
    result ~= PaletteEntry!Command(CommandId(Command.example, Example.unicode), "Open Unicode example", "Examples");
    result ~= PaletteEntry!Command(CommandId(Command.example, Example.protectedText), "Open protected text example", "Examples");
    foreach (i; 0 .. PresentationToggle.max + 1)
    {
        const which = cast(PresentationToggle) i;
        result ~= PaletteEntry!Command(CommandId(Command.presentation, which), label(which), "View");
    }
    return result;
}

/// The captured document identity and live policy, shared by discovery and dispatch.
struct CommandContext
{
    ulong document;
    const(CommandBinding)[] bindings;
    bool modal;
    bool closing;
    bool recoveryAvailable;

    bool available(CommandId command, ulong target) const scope @safe pure nothrow @nogc
    {
        if (command.operation == Command.none) return false;
        if (command.operation == Command.restoreSession) return !modal && recoveryAvailable;
        if (command.operation == Command.discard) return closing;
        const dialogCommand = command.operation == Command.confirm || command.operation == Command.cancel;
        if (modal != dialogCommand) return false;
        const documentCommand = command.operation == Command.edit || command.operation == Command.save
            || command.operation == Command.saveAs || command.operation == Command.closeTab
            || command.operation == Command.languages || command.operation == Command.selectLanguage;
        return !documentCommand || (target == document && document != 0);
    }

    bool reachable(Scope scope_) const scope @safe pure nothrow @nogc
        => scope_ == Scope.modalModifiers ? false : scope_ == Scope.closing ? closing
            : scope_ == Scope.recovery ? !modal && recoveryAvailable
            : scope_ == Scope.dialog ? modal : !modal && (scope_ == Scope.application || document != 0);

    /// Modified input belongs to the focused field, never to plain decision letters.
    bool scopeActive(Scope scope_, in KeyEvent key) const scope @safe pure nothrow @nogc
        => scope_ == Scope.modalModifiers
            ? modal && (key.mods.ctrl || key.mods.alt || key.mods.super_ || key.mods.shift)
            : reachable(scope_);

    string shortcut(CommandId command, ulong target) const scope @safe pure
    {
        if (!available(command, target)) return null;
        const path = effectiveCommandShortcut(bindings, command, this);
        return path.depth ? unparseChordPath(path) : null;
    }
}
