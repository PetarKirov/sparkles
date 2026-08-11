#!/usr/bin/env dub
/+ dub.sdl:
    name "hue-dub-single-file-fixture"
    dependency "vibe-d" version="~>0.9.0"
    dependency "mir-algorithm" version="~>3.0"
    configuration "application" {
        targetType "executable"
    }
+/
/**
A visual fixture for DUB single-file package recipe injection in hue.

The `/+ dub.sdl: … +/` nesting comment should highlight as SDLang (tag names,
strings, versions), while the D body below uses the ordinary D grammar. Open
with `hue apps/hue/test/fixtures/dub-single-file.d` (or the equivalent path
from the repo root) to check the injection by eye.

A JSON recipe form is in `dub-single-file-json.d`.
*/
import std.stdio : writeln;

void main(string[] args)
{
    writeln("hello from a dub single-file package");
    if (args.length > 1)
        writeln("args: ", args[1 .. $]);
}
