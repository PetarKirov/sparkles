/** One command policy for keyboard resolution, Lantern and the command palette. */
module commands;

import sparkles.input.events : chord, Key, KeyEvent, unparseChordPath;
import sparkles.ui.command_bindings : effectiveCommandShortcut;
import sparkles.ui.command_palette : PaletteCommand, PaletteEntry;
import sparkles.ui.editor.keys : EditorAction, EditorTarget, editorBindings;
/// The find bar's switches, as `findOption` arguments.
public import sparkles.ui.editor.search : FindOption;
import sparkles.ui.keymap : Binding, bind, terminalScope;
import examples : Example;
import settings : IndentChoice, label, PresentationToggle;

/// App operations; shared editing operations carry an EditorAction argument.
enum Command : ubyte { none, palette, guide, newTab, nextTab, previousTab, inspector,
    example, themes, selectTheme, toggleTheme, edit, quit, open, save, saveAs, confirm, cancel,
    closeTab, discard, restoreSession, languages, selectLanguage, presentation, indentation,
    find, replace, findNext, findPrevious, closeFind, findOption, findFocus, replaceOne, replaceAll, selectMatches,
    settings, fonts, allFonts, selectFont }
enum Scope : ubyte { @terminalScope modalModifiers, application, document, dialog, closing, recovery, find }
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
    // Find and replace (EAP5, EAP7). A terminal keeps Ctrl-F and Ctrl-H for
    // Readline, so its bar opens through the leader there.
    auto settingsKey = chord(','); settingsKey.ctrl = true;
    result ~= target == EditorTarget.terminal
        ? bind(Scope.application, leader, chord(','), Command.settings, "Settings")
        : bind(Scope.application, settingsKey, Command.settings, "Settings");
    if (target == EditorTarget.terminal)
        result ~= [bind(Scope.application, leader, chord('f'), Command.find, "Find"),
            bind(Scope.application, leader, chord('h'), Command.replace, "Find and replace")];
    else
    {
        auto find = chord('f'); find.ctrl = true;
        auto replace = chord('h'); replace.ctrl = true;
        result ~= [bind(Scope.application, find, Command.find, "Find"),
            bind(Scope.application, replace, Command.replace, "Find and replace")];
    }
    auto backwards = chord(Key.f3); backwards.shift = typeof(backwards.shift).yes;
    auto forwards = chord(Key.f3); forwards.shift = typeof(forwards.shift).no;
    auto enter = chord(Key.enter); enter.shift = typeof(enter.shift).no;
    auto shiftEnter = chord(Key.enter); shiftEnter.shift = typeof(shiftEnter.shift).yes;
    auto all = chord(Key.enter); all.alt = true;
    auto replaceAll = chord(Key.enter); replaceAll.ctrl = true; replaceAll.alt = true;
    auto regex = chord('r'); regex.alt = true;
    auto matchCase = chord('c'); matchCase.alt = true;
    auto word = chord('w'); word.alt = true;
    auto focus = chord(Key.tab); focus.shift = typeof(focus.shift).ignore;
    result ~= [bind(Scope.application, forwards, Command.findNext, "Find next"),
        bind(Scope.application, backwards, Command.findPrevious, "Find previous"),
        bind(Scope.find, replaceAll, Command.replaceAll, "Replace all"),
        bind(Scope.find, all, Command.selectMatches, "Select all matches"),
        bind(Scope.find, enter, Command.findNext, "Find next"),
        bind(Scope.find, shiftEnter, Command.findPrevious, "Find previous"),
        bind(Scope.find, chord(Key.escape), Command.closeFind, "Close find"),
        bind(Scope.find, focus, Command.findFocus, "Switch find/replace field"),
        bind(Scope.find, regex, Command.findOption, "Toggle regular expression", arg: FindOption.regex),
        bind(Scope.find, matchCase, Command.findOption, "Toggle match case", arg: FindOption.caseSensitive),
        bind(Scope.find, word, Command.findOption, "Toggle whole word", arg: FindOption.wholeWord)];
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
    foreach (i; 0 .. IndentChoice.max + 1)
    {
        const choice = cast(IndentChoice) i;
        result ~= PaletteEntry!Command(CommandId(Command.indentation, choice), label(choice), "Editing");
    }
    result ~= PaletteEntry!Command(CommandId(Command.replaceOne), "Replace this match", "Find");
    result ~= PaletteEntry!Command(CommandId(Command.fonts), "Choose document font", "View");
    result ~= PaletteEntry!Command(CommandId(Command.allFonts), "Choose document font (all families)", "View");
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
    /// The find bar holds the keyboard: its scope is live, the document's keys are not.
    bool finding;

    bool available(CommandId command, ulong target) const scope @safe pure nothrow @nogc
    {
        if (command.operation == Command.none) return false;
        if (command.operation == Command.restoreSession) return !modal && recoveryAvailable;
        if (command.operation == Command.discard) return closing;
        const dialogCommand = command.operation == Command.confirm || command.operation == Command.cancel;
        if (modal != dialogCommand) return false;
        const findCommand = command.operation == Command.closeFind || command.operation == Command.findOption
            || command.operation == Command.findFocus || command.operation == Command.replaceOne
            || command.operation == Command.replaceAll || command.operation == Command.selectMatches;
        if (findCommand && !finding) return false;
        const documentCommand = command.operation == Command.edit || command.operation == Command.save
            || command.operation == Command.saveAs || command.operation == Command.closeTab
            || command.operation == Command.languages || command.operation == Command.selectLanguage
            || command.operation == Command.indentation || command.operation == Command.find
            || command.operation == Command.replace || command.operation == Command.findNext
            || command.operation == Command.findPrevious || findCommand;
        return !documentCommand || (target == document && document != 0);
    }

    bool reachable(Scope scope_) const scope @safe pure nothrow @nogc
        => scope_ == Scope.modalModifiers ? false : scope_ == Scope.closing ? closing
            : scope_ == Scope.recovery ? !modal && recoveryAvailable
            : scope_ == Scope.dialog ? modal : scope_ == Scope.find ? !modal && finding && document != 0
            : scope_ == Scope.document ? !modal && !finding && document != 0
            : !modal && (scope_ == Scope.application || document != 0);

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
