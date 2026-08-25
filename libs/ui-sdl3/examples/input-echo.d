#!/usr/bin/env dub
/+ dub.sdl:
    name "input_echo"
    dependency "sparkles:ui-sdl3" path="../../.."
    dependency "sparkles:input" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "expected" version="~>0.4.1"
    stringImportPaths "../../vulkan-wsi/src/shaders"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
 * Prints every event `sparkles:ui-sdl3` synthesizes, one per line.
 *
 * The unit tests in `sparkles.ui_sdl3.events` prove the translation — given
 * this `SDL_Event`, that toolkit event — and they run with no display at all.
 * What they cannot prove is the half that belongs to SDL: that a keystroke is
 * really followed by its text event, that a resize really arrives as
 * `PIXEL_SIZE_CHANGED`, that a trackpad really reports fractional notches.
 * This is where that is checked, against a real window.
 *
 * It is also the tool to reach for when a key does not do what a keymap says
 * it should: run it, press the key, and read what the toolkit actually saw.
 *
 * Both keyboard grades are selectable, because they are the thing most worth
 * seeing side by side:
 *
 * ---
 * ./build/input_echo                # named keys and typed characters
 * ./build/input_echo --full         # every physical key, with press/repeat/release
 * ---
 *
 * Driving it without a keyboard, for a scripted check:
 *
 * ---
 * Xvfb :90 -screen 0 800x600x24 &
 * env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 DISPLAY=:90 ./build/input_echo &
 * DISPLAY=:90 xdotool search --name "sparkles" key --window %1 a Left
 * ---
 *
 * `-u WAYLAND_DISPLAY` is load-bearing: SDL prefers Wayland whenever that is
 * set and ignores `DISPLAY` entirely, so without it the window opens on the
 * real session and the injected keys go to whatever else is focused.
 */
module input_echo_example;

import std.format : format;
import std.stdio : writeln;

import expected : Expected, err, ok;

import sparkles.core_cli.args;
import sparkles.input;
import sparkles.ui_sdl3;

int main(string[] args) => runCli!InputEcho(args);

@(Command("input-echo",
    shortDescription: "Print the sparkles:input events an SDL3 window produces",
))
struct InputEcho
{
    @(Option(`W|width`, description: "Window width in logical units"))
    int width = 640;

    @(Option(`H|height`, description: "Window height in logical units"))
    int height = 360;

    @(Option("full",
        description: "Use the full-keyboard grade: every key, with releases and repeats"))
    bool full;

    @(Option(`c|cell`, description: "Cell size in pixels, for the pixels-to-cells mapping"))
    int cell = 10;

    @(Option(`f|frames`,
        description: "Poll N times then exit (0 = run until the window closes)"))
    int frames = 300;

    Expected!(void, string) run()
    {
        Window window;
        auto opened = Window.open(window, WindowRequest(
            title: "sparkles — input echo",
            width: width,
            height: height,
        ));
        if (opened.hasError)
        {
            // No display is a degraded environment, not a failure.
            writeln("SKIP: cannot open a window — ", opened.error);
            return ok();
        }

        // Without this SDL sends no text events at all, and the failure looks
        // like a broken keymap rather than a missing call.
        auto text = window.textInput(true);
        if (text.hasError)
            return err!void(text.error);

        Sdl3Events events;
        if (full)
            events.capabilities.keyRelease = true;

        writeln("grade: ", full ? "full keyboard" : "named keys + text",
            "; cell: ", cell, "px. Close the window or press Escape to stop.");

        bool quit;
        for (int i = 0; !quit && (frames == 0 || i < frames); i++)
        {
            // `poll` drains SDL's queue, so the quit check reads whatever is
            // left after it — SDL_EVENT_QUIT has no toolkit spelling.
            events.poll((Event e) { writeln(describe(e)); quit |= isEscape(e); },
                cell, cell);

            SDL_Event raw;
            while (SDL_PollEvent(&raw))
                if (raw.type == SDL_EventType.SDL_EVENT_QUIT)
                    quit = true;

            SDL_Delay(16);
        }

        return ok();
    }
}

/// Escape quits, so a scripted run has a way to stop that is not a signal.
bool isEscape(in Event e) @safe
    => e.match!(
        (KeyEvent k) => k.key == Key.escape && k.action != KeyAction.release,
        _ => false);

/// One event as one line — the format is for reading, not for parsing.
string describe(in Event e) @safe
    => e.match!(
        (KeyEvent k) => format("key    %-9s %s%s%s%s%s",
            k.key, actionOf(k.action), modsOf(k.mods),
            k.ch ? format(" ch=%s", cast(char) k.ch) : "",
            k.unshifted ? format(" unshifted=%s", cast(char) k.unshifted) : "",
            k.text.length ? format(" text=%(%s%)", [k.text]) : ""),
        (PointerEvent p) => format("ptr    %-9s %s at %d,%d%s",
            p.action, p.button, p.pos.x, p.pos.y, modsOf(p.mods)),
        (WheelEvent w) => format("wheel  dx=%d dy=%d at %d,%d%s%s",
            w.dx, w.dy, w.pos.x, w.pos.y, modsOf(w.mods),
            w.precise ? " precise" : ""),
        (FocusEvent f) => format("focus  %s", f.focused ? "gained" : "lost"),
        (ResizeEvent r) => "resize (re-query the window)",
        // Not produced by this backend yet: `GestureEvent` needs the touch arm
        // (`SDL_EVENT_FINGER_*` fed to `sparkles:input`'s recogniser), and
        // `EndOfInput` is the terminal reader's end-of-stream. Handled so the
        // match stays exhaustive and a future arm shows up here first.
        (GestureEvent g) => format("gesture %s", g),
        (NoEvent _) => "(none)",
        (EndOfInput _) => "end of input",
    );

string actionOf(KeyAction a) @safe pure nothrow @nogc
{
    final switch (a)
    {
        case KeyAction.press:   return "press  ";
        case KeyAction.repeat:  return "repeat ";
        case KeyAction.release: return "release";
    }
}

string modsOf(in Mods m) @safe
{
    const s = formatMods(m, false);
    return s.length ? " " ~ s : "";
}
