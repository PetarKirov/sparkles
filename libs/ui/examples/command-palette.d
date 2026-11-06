#!/usr/bin/env dub
/+ dub.sdl:
name "shared-command-palette"
targetPath "build"
dependency "sparkles:ui" path="../../.."
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
+/
/** A command palette's state can run without a window or terminal. */
module command_palette_example;

import std.stdio : writeln;
import sparkles.ui.command_palette : CommandPalette, PaletteCommand, PaletteEffectKind,
    PaletteEntry, PaletteInvocation, PaletteStatus;

enum Command { none, save, open }
alias Id = PaletteCommand!Command;

struct Context
{
    bool available(Id command, ulong target) const @safe pure nothrow @nogc
        => target == 42;
}

void main() @safe
{
    CommandPalette!(Command, 4) palette;
    PaletteEntry!Command[2] commands = [
        PaletteEntry!Command(Id(Command.save), "Save document", "File"),
        PaletteEntry!Command(Id(Command.open), "Open file", "File"),
    ];
    const installed = palette.catalog(commands[]);
    assert(installed == PaletteStatus.ok);
    const opening = palette.open(PaletteInvocation(42, 17));
    const searched = palette.search(opening.ticket, "save", Context.init);
    assert(searched == PaletteStatus.ok);
    const effect = palette.accept(opening.ticket, Context.init);
    assert(effect.kind == PaletteEffectKind.execute);
    writeln(effect.command.operation, " on target ", effect.invocation.target);
    assert(palette.accept(opening.ticket, Context.init).kind == PaletteEffectKind.none);
}
