#!/usr/bin/env dub

/+ dub.sdl:
    name "vga"
    dependency "sparkles:math" path="../../.."
    targetPath "build"

    // The build this repo ships nix artifacts with: optimised, assertions
    // live, `debug {}` blocks out. Neither `debug` (which turns those blocks
    // on) nor `release` (which deletes every assert expression).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

import std.stdio : writeln, writefln;

import sparkles.base.prettyprint : prettyPrint;
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
