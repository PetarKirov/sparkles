#!/usr/bin/env dub
/+ dub.sdl:
    name "tui_demo"
    dependency "sparkles:tui" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
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

    // motion: true → DEC 1003 any-event tracking so the marker follows bare
    // pointer moves (default is drag-only 1002).
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
                g.putText(1, cast(ushort)(sz.height - 1), " q/Esc quit · arrows · move/click/drag/wheel", footer);
            }
        },
        // handle — return false to quit (events are the shared sparkles:input
        // vocabulary; positions arrive already 0-based).
        (in Event e) => e.match!(
            (in KeyEvent k) {
                if (k.key == Key.escape || (k.key == Key.char_ && k.ch == 'q'))
                    return false;
                status = describeKey(k);
                return true;
            },
            (in PointerEvent p) {
                mouse.col = cast(ushort) p.pos.x;
                mouse.row = cast(ushort) p.pos.y;
                status = text("mouse ", p.action, " ", p.button,
                    " @ ", p.pos.x, ",", p.pos.y);
                return true;
            },
            (in WheelEvent w) {
                status = text("wheel ", w.dy < 0 ? "up" : "down");
                return true;
            },
            _ => true,
        ),
        TerminalOptions(motion: true),
    );
}

string sizeText(TermSize sz) @safe => text(sz.width, "×", sz.height, " cells");

string describeKey(in KeyEvent e) @safe
{
    string m;
    if (e.mods.ctrl) m ~= "Ctrl+";
    if (e.mods.alt) m ~= "Alt+";
    if (e.mods.shift) m ~= "Shift+";
    if (e.key == Key.char_)
        return text("key ", m, "'", e.ch, "'");
    return text("key ", m, e.key);
}
