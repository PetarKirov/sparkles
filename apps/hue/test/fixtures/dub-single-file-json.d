#!/usr/bin/env dub
/+ dub.json:
{
    "name": "hue-dub-single-file-json-fixture",
    "dependencies": {
        "vibe-d": "~>0.9.0"
    }
}
+/
/// Visual fixture: `/+ dub.json: … +/` injects as JSON inside a D file.
import std.stdio : writeln;

void main()
{
    writeln("hello from a dub.json single-file package");
}
