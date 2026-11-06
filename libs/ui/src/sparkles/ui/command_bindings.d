/** Effective shortcut discovery for command catalogs and their views. */
module sparkles.ui.command_bindings;

import sparkles.input.events : ChordPath, KeyEvent, Mods, ShiftReq;
import sparkles.ui.command_palette : PaletteCommand;
import sparkles.ui.keymap : Binding, normalise, resolve, ResolveKind;

/// A concrete shortcut that actually resolves to this operation and argument, or depth zero.
ChordPath effectiveCommandShortcut(Cmd, Scope, Context)(scope const(Binding!(Cmd, Scope))[] table,
    PaletteCommand!Cmd command, in Context context)
{
    foreach (binding; table)
    {
        if (binding.cmd != command.operation || binding.group.length || binding.reveal
            || binding.depth == 0 || binding.depth > ChordPath.init.path.length) continue;
        ChordPath path;
        path.path = binding.path;
        path.depth = binding.depth;
        const last = binding.depth - 1;
        const end = path.path[last].chEnd;
        if (end)
        {
            if (command.argument > ubyte.max || end < path.path[last].ch) continue;
            const offset = (command.argument + 256 - binding.arg) % 256;
            if (offset > end - path.path[last].ch) continue;
            path.path[last].ch += cast(dchar) offset;
        }
        else if (command.argument != binding.arg) continue;
        bool effective = true;
        foreach (i; 0 .. binding.depth)
        {
            path.path[i].chEnd = 0;
            const chord = path.path[i];
            const event = KeyEvent(key: chord.key, ch: chord.ch,
                mods: Mods(ctrl: chord.ctrl, alt: chord.alt, super_: chord.super_,
                    shift: chord.shift == ShiftReq.yes));
            const result = resolve(table, path.path[0 .. i], event, context);
            const typed = normalise(event);
            path.path[i].key = typed.key;
            path.path[i].ch = typed.ch;
            path.path[i].ctrl = typed.mods.ctrl;
            path.path[i].alt = typed.mods.alt;
            path.path[i].super_ = typed.mods.super_;
            path.path[i].shift = typed.mods.shift ? ShiftReq.yes : ShiftReq.no;
            if (i == last)
                effective &= result.kind == ResolveKind.command && !result.reveal
                    && result.cmd == command.operation && result.arg == command.argument;
            else effective &= result.kind == ResolveKind.group;
            if (!effective) break;
        }
        if (effective) return path;
    }
    return ChordPath(depth: 0);
}

/// Discovery uses actual resolution, including shadows and concrete ranged arguments.
@("ui.command_bindings.effectiveShadowAndRange")
@safe pure nothrow @nogc unittest
{
    import sparkles.input.events : chord, chordRange;
    import sparkles.ui.keymap : bind;
    enum Command { none, save, open, tab }
    enum Scope { always, document }
    struct Context {}
    alias B = Binding!(Command, Scope);
    auto save = chord('s'); save.ctrl = true;
    auto leader = chord(' '); leader.ctrl = true;
    B[3] table = [bind(Scope.always, save, Command.open, "Open"),
        bind(Scope.document, save, Command.save, "Save"),
        bind(Scope.document, leader, chordRange('1', '3'), Command.tab, "Tab", arg: 1)];
    assert(effectiveCommandShortcut(table[], PaletteCommand!Command(Command.save), Context.init).depth == 0);
    const open = effectiveCommandShortcut(table[], PaletteCommand!Command(Command.open), Context.init);
    assert(open.depth == 1 && open.path[0].ch == 's' && open.path[0].ctrl);
    const second = effectiveCommandShortcut(table[], PaletteCommand!Command(Command.tab, 2), Context.init);
    assert(second.depth == 2 && second.path[0].ctrl && second.path[1].ch == '2');
}

/// Shortcut discovery tests concrete typed prefixes, including Shift shadows.
@("ui.command_bindings.concretePrefixShadow")
@safe pure nothrow @nogc unittest
{
    import sparkles.input.events : chord, ShiftReq;
    import sparkles.ui.keymap : bind;
    enum Command { none, first, shadowed }
    enum Scope { always }
    struct Context {}
    alias B = Binding!(Command, Scope);
    auto first = chord('x'); first.shift = ShiftReq.no;
    auto second = chord('x');
    B[2] table = [bind(Scope.always, first, chord('s'), Command.first, "First"),
        bind(Scope.always, second, chord('s'), Command.shadowed, "Shadowed")];
    const result = effectiveCommandShortcut(table[], PaletteCommand!Command(Command.shadowed), Context.init);
    assert(result.depth == 0);
}
