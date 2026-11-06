/** One command policy for keyboard resolution, Lantern and the command palette. */
module commands;

import sparkles.input.events : chord, Key, unparseChordPath;
import sparkles.ui.command_bindings : effectiveCommandShortcut;
import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
import sparkles.ui.editor.keys : EditorAction, EditorTarget, editorBindings;
import sparkles.ui.keymap : Binding, bind;

/// App operations; shared editing operations carry an EditorAction argument.
enum Command : ubyte { none, palette, guide, newTab, nextTab, previousTab, inspector, edit, quit }
enum Scope : ubyte { always, document }
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
    CommandBinding[] result = [bind(Scope.always, palette, Command.palette, "Commands"),
        bind(Scope.always, chord(Key.f1), Command.guide, "Key guide", reveal: true),
        bind(Scope.always, create, Command.newTab, "New tab"),
        bind(Scope.always, previous, Command.previousTab, "Previous tab"),
        bind(Scope.always, next, Command.nextTab, "Next tab"),
        bind(Scope.always, chord(Key.f12), Command.inspector, "Toggle inspector"),
        bind(Scope.always, quit, Command.quit, "Quit")];
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
    return result;
}

/// The captured document identity and live policy, shared by discovery and dispatch.
struct CommandContext
{
    ulong document;
    const(CommandBinding)[] bindings;

    bool available(CommandId command, ulong target) const scope @safe pure nothrow @nogc
        => command.operation != Command.none
            && (command.operation != Command.edit || (target == document && document != 0));

    bool reachable(Scope scope_) const scope @safe pure nothrow @nogc
        => scope_ == Scope.always || document != 0;

    string shortcut(CommandId command, ulong target) const scope @safe pure
    {
        if (!available(command, target)) return null;
        const path = effectiveCommandShortcut(bindings, command, this);
        return path.depth ? unparseChordPath(path) : null;
    }
}
