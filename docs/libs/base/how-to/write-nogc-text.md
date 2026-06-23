# Write `@nogc` text

Use `SmallBuffer` plus `sparkles.base.text.writers` when a hot path needs
formatted text but must not allocate through the garbage collector.

## Format into an output range

The writers accept any output range. `SmallBuffer!(char, N)` is the usual
choice for short-lived text:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_write_nogc_text"
    dependency "sparkles:base" version="*"
+/
import core.time : dur;
import std.stdio : writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.writers : writeBytes, writeDuration, writeIntegerPadded;

@safe nothrow @nogc
void render(ref SmallBuffer!(char, 128) out_)
{
    out_ ~= "job=";
    writeIntegerPadded(out_, 42, 4);
    out_ ~= " rss=";
    writeBytes(out_, 1536);
    out_ ~= " elapsed=";
    writeDuration(out_, dur!"msecs"(90_000));
}

void main()
{
    SmallBuffer!(char, 128) buf;
    render(buf);
    writeln(buf[]);
}
```

```ansi
job=0042 rss=1.5KiB elapsed=1.5m
```

## Keep fallbacks explicit

`writeValue` supports primitive values and user types with `@nogc`
`toString` hooks. Unsupported types fall back to allocating conversion, so
prefer direct writer functions in code that must stay `@nogc`.
