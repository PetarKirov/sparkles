#!/usr/bin/env dub

/+ dub.sdl:
name "vga"
dependency "sparkles:math" version="*"
targetPath "build"
+/

import std.stdio : writefln;

import sparkles.core_cli.prettyprint : prettyPrint;
import sparkles.math.vga;

void main()
{
    gradeBladeMasks!(4, 1).writefln!"[%(0b%04b, %)]";
}
