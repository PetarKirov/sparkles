#!/usr/bin/env dub
/+ dub.sdl:
    name "tui_demo"
    dependency "sparkles:tui" path="../../.."
    targetPath "build"
+/
// ci: build-only
/++
A tiny full-screen `sparkles:tui` demo: a colored header, a body that echoes the
last key / mouse event, a block that follows the mouse, and a footer. Quit with
`q` or `Esc`.

    dub run --single libs/tui/examples/demo.d

It exercises the whole stack — the cell grid + diff renderer, the terminal
backend (raw mode / alt-screen / mouse / sync frames), and the input decoder —
in an immediate-mode `runApp` loop.
+/
import sparkles.tui;
import std.conv : text;

void main() @system
{
    string status = "move the mouse, press keys — q or Esc to quit";
    TermPosition mouse;

    const header = CellStyle(fg: Color.fromRgb(20, 22, 30), bg: Color.fromRgb(130, 170, 255),
        attrs: TextAttr.bold);
    const body = CellStyle(fg: Color.fromRgb(220, 223, 235));
    const accent = CellStyle(fg: Color.fromRgb(130, 220, 160), attrs: TextAttr.bold);
    const footer = CellStyle(fg: Color.fromRgb(150, 155, 170), attrs: TextAttr.italic);
    const marker = CellStyle(fg: Color.fromRgb(20, 22, 30), bg: Color.fromRgb(240, 200, 120));

    runApp(
        // present — immediate mode: paint the whole frame from current state.
        (ref Grid g, TermSize sz) {
            g.fill(0, 0, sz.width, header);
            g.putText(1, 0, " sparkles:tui demo", header);

            g.putText(2, 2, "last event:", accent);
            g.putText(14, 2, status, body);
            g.putText(2, 4, "terminal:", accent);
            g.putText(12, 4, sizeText(sz), body);

            // A block that follows the mouse.
            if (mouse.row > 0 && mouse.row < sz.height - 1 && mouse.col < sz.width)
                g.putText(mouse.col, mouse.row, "█", marker);

            if (sz.height >= 1)
            {
                g.fill(0, cast(ushort)(sz.height - 1), sz.width, footer);
                g.putText(1, cast(ushort)(sz.height - 1), " q/Esc quit · arrows · click/drag/wheel", footer);
            }
        },
        // handle — return false to quit.
        (in Event e) {
            if (e.kind == EventKind.key)
            {
                if (e.key == Key.escape || (e.key == Key.char_ && e.ch == 'q'))
                    return false;
                status = describeKey(e);
            }
            else if (e.kind == EventKind.mouse)
            {
                mouse.col = e.mouse.col ? cast(ushort)(e.mouse.col - 1) : 0;
                mouse.row = e.mouse.row ? cast(ushort)(e.mouse.row - 1) : 0;
                status = describeMouse(e);
            }
            return true;
        },
    );
}

string sizeText(TermSize sz) @safe => text(sz.width, "×", sz.height, " cells");

string describeKey(in Event e) @safe
{
    string m;
    if (e.mods.ctrl) m ~= "Ctrl+";
    if (e.mods.alt) m ~= "Alt+";
    if (e.mods.shift) m ~= "Shift+";
    if (e.key == Key.char_)
        return text("key ", m, "'", e.ch, "'");
    return text("key ", m, e.key);
}

string describeMouse(in Event e) @safe
    => text("mouse ", e.action, " ", e.button, " @ ", e.mouse.col, ",", e.mouse.row);
