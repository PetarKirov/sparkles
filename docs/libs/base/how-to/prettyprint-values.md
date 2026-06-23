# Pretty-print values

Use `prettyPrint` to format nested structures, arrays, associative arrays, pointers, and tuples into structured, easy-to-read text with customizable styling and indentation.

## Print to string

To quickly convert any type to a formatted string, use the convenience overload of `prettyPrint` that returns a `string`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_prettyprint_string"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.prettyprint : prettyPrint;

struct User
{
    string name;
    int age;
    string[] roles;
}

void main()
{
    auto user = User("Alice", 30, ["admin", "developer"]);
    writeln(prettyPrint(user));
}
```

```ansi
[35mUser[39m([96mname[39m: [32m"Alice"[39m, [96mage[39m: [34m30[39m, [96mroles[39m: [[32m"admin"[39m, [32m"developer"[39m])
```

## Print into custom buffers

For memory-conscious or `@nogc` code, pass a `Writer` reference (such as `SmallBuffer`) to `writePretty` to write the output directly into the buffer without allocating memory:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_prettyprint_buffer"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.prettyprint : writePretty;

void main()
{
    auto ages = ["Alice": 30, "Bob": 25];

    SmallBuffer!(char, 1024) buf;
    writePretty(buf, ages);

    writeln(buf[]);
}
```

```ansi
[[32m"Alice"[39m: [34m30[39m, [32m"Bob"[39m: [34m25[39m]
```

## Configure options

You can customize the indentation, maximum recursion depth, soft max width (which allows single-line layouts for small values), coloring, and OSC 8 source links using `PrettyPrintOptions`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_prettyprint_options"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;

struct Point { int x; int y; }

void main()
{
    auto points = [Point(1, 2), Point(3, 4)];

    // Disable coloring and use single-line formatting if possible
    auto opt = PrettyPrintOptions!void(
        indentStep: 4,
        softMaxWidth: 120, // fits single-line easily
        useColors: false
    );

    writeln(prettyPrint(points, opt));
}
```

```ansi
[Point(x: 1, y: 2), Point(x: 3, y: 4)]
```
