#!/usr/bin/env dub

/+ dub.sdl:
name "term-caps"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/
// ci: build-only

module term_caps_example;

import sparkles.core_cli.term_caps :
    detectTermCaps, isTerminal, setTermWindowSizeHandler, StdStream, terminalSize;
import sparkles.math : ScreenSize;
import core.stdc.stdio : fflush, printf, stdout;
import std.stdio : readln, writefln;

@nogc nothrow
string formatSmallSize(ushort w, ushort h)
{
    alias enc = (ushort w, ushort h) => (w << 4) | h;

    final switch (enc(w, h))
    {
        case enc(4, 1): return "➃";
        case enc(3, 1): return "➂";
        case enc(2, 1): return "➁";
        case enc(1, 1): return "➀";

        case enc(4, 2): return "4\n2";
        case enc(3, 2): return "3\n2";
        case enc(2, 2): return "2\n2";
        case enc(1, 2): return "1\n2";

        case enc(4, 3): return "4\n/\n3";
        case enc(3, 3): return "3\n/\n3";
        case enc(2, 3): return "2\n/\n3";
        case enc(1, 3): return "1\n/\n3";
    }
}

void main()
{
    // The one-shot capability snapshot: tty-ness, the color decision
    // ($NO_COLOR / TERM=dumb / CLICOLOR_FORCE aware), unicode, and size —
    // the single place an app decides what its terminal can do.
    const caps = detectTermCaps();
    writefln!"caps: tty=%s colors=%s unicode=%s size=%sx%s"(
        caps.tty, caps.colors, caps.unicode, caps.size.width, caps.size.height);
    writefln!"stdin is a terminal: %s"(isTerminal(StdStream.stdin));

    // The synchronous query seeds the display; SIGWINCH keeps it fresh (the
    // signal never fires at startup).
    const initial = terminalSize();
    printf("%d/%d", initial.width, initial.height);
    fflush(stdout);

    setTermWindowSizeHandler((ScreenSize!ushort size)
    {
        printf("\r         \r");
        if (size.width < 5 && size.height < 4)
            printf("%s", formatSmallSize(size.width, size.height).ptr);
        else
            printf("%d/%d", size.width, size.height);
        fflush(stdout);
    });

    readln;
}
