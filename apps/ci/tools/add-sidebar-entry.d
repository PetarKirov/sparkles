#!/usr/bin/env dub
/+ dub.sdl:
    name "add_sidebar_entry"
+/
/**
Inserts one page link into a named group of the VitePress sidebar data.

Text-level insertion rather than a JSON round-trip: `sidebar.json` is
prettier-formatted, and re-serialising it would reformat the whole file for a
two-line change.
*/
module add_sidebar_entry;

import std.algorithm : canFind;
import std.file : readText, write;
import std.stdio : writeln;
import std.string : indexOf, lastIndexOf;

int main(string[] args)
{
    if (args.length != 5)
    {
        writeln("usage: add-sidebar.d <sidebar.json> <group-link> <text> <link>");
        return 2;
    }
    const path = args[1], groupLink = args[2], text = args[3], link = args[4];
    auto src = readText(path);

    if (src.canFind(`"link": "` ~ link ~ `"`))
    {
        writeln("already present: ", link);
        return 0;
    }

    // Find the group by its own link, then the last entry before its closing
    // bracket — the anchor we append after.
    const g = src.indexOf(`"link": "` ~ groupLink ~ `"`);
    if (g < 0)
    {
        writeln("group not found: ", groupLink);
        return 1;
    }
    const itemsAt = src.indexOf(`"items": [`, g);
    if (itemsAt < 0)
    {
        writeln("group has no items array");
        return 1;
    }

    // Walk to the matching close bracket, tracking depth.
    size_t i = cast(size_t)(itemsAt + `"items": [`.length);
    int depth = 1;
    for (; i < src.length && depth > 0; ++i)
    {
        if (src[i] == '[')
            ++depth;
        else if (src[i] == ']')
            --depth;
    }
    const closeAt = i - 1;
    const lastBrace = src[0 .. closeAt].lastIndexOf('}');

    const entry = ",\n          {\n            \"text\": \"" ~ text
        ~ "\",\n            \"link\": \"" ~ link ~ "\"\n          }";
    write(path, src[0 .. lastBrace + 1] ~ entry ~ src[lastBrace + 1 .. $]);
    writeln("inserted ", link);
    return 0;
}
