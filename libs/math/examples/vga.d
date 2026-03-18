#!/usr/bin/env dub

/+ dub.sdl:
name "vga"
dependency "sparkles:math" version="*"
targetPath "build"
+/

import std.stdio : writeln, writefln;

import sparkles.core_cli.prettyprint : prettyPrint;
import sparkles.math.vga;

void main()
{
    gradeBladeMasks!(4, 1).writefln!"[%(0b%04b, %)]";

    alias Vec3 = GAVector!(double, 3);
    alias E3 = Basis!(double, 3);

    auto v = Vec3(1, 2, 3);
    // v.prettyPrint().writeln;
    // typeof(v.coeffs).stringof.writeln;

    choose!(3, 3).prettyPrint.writeln;
}
