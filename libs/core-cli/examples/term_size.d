#!/usr/bin/env dub

/+ dub.sdl:
name "term-size"
dependency "sparkles:core-cli" version="*"
targetPath "build"
+/

import sparkles.core_cli.term_size : setTermWindowSizeHandler;
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
    setTermWindowSizeHandler((ushort w, ushort h)
    {
        printf("\r         \r");
        if (w < 5 && h < 4)
            printf("%s", formatSmallSize(w, h).ptr);
        else
            printf("%d/%d", w, h);
        fflush(stdout);
    });

    readln;
}
