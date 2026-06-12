# Getting started with `sparkles:base`

This tutorial builds one tiny program that uses the most common `base`
building blocks: `SmallBuffer`, the `@nogc` text writers, styled IES
rendering, and `CoreLogger`.

## What you need

- A D compiler and `dub`.
- Five minutes.

## Step 1 — a single-file program

Create `base_tour.d` with this header:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_tour"
    dependency "sparkles:base" version="*"
+/
```

Everything below goes into the same file.

## Step 2 — write text without the GC

`SmallBuffer` is an output range with inline storage. The text writers
write directly into it:

```d
import core.time : dur;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.writers : writeDuration, writeIntegerPadded;

SmallBuffer!(char, 64) line;
writeIntegerPadded(line, 7, 3);
line ~= ' ';
writeDuration(line, dur!"msecs"(1_500));
```

## Step 3 — render styled IES

The styled-template parser accepts D Interpolated Expression Sequences and
can either emit ANSI styles or strip markup:

```d
import sparkles.base.styled_template : plainText;

auto status = plainText(i"{green ready} after $(line[])");
```

## Step 4 — install a logger

`initLogger` installs a `DeltaTimeLogger` for both Phobos and Sparkles
logging globals. The output includes live timestamps, so this tutorial
does not print a log line in the verified output; see
[Log through `CoreLogger`](../how-to/log-with-core-logger.md) for a
deterministic logger example.

```d
import sparkles.base.logger : LogLevel, initLogger;

initLogger(LogLevel.info);
```

## The whole program

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_tour"
    dependency "sparkles:base" version="*"
+/
import core.time : dur;
import std.stdio : writeln;

import sparkles.base.logger : LogLevel, initLogger;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.styled_template : plainText;
import sparkles.base.text.writers : writeDuration, writeIntegerPadded;

void main()
{
    SmallBuffer!(char, 64) line;
    writeIntegerPadded(line, 7, 3);
    line ~= ' ';
    writeDuration(line, dur!"msecs"(1_500));

    auto status = plainText(i"{green ready} after $(line[])");

    initLogger(LogLevel.info);

    writeln(line[]);
    writeln(status);
}
```

```[Output]
007 1.5s
ready after 007 1.5s
```

## What you learned

You wrote into stack-first storage, formatted numbers and durations
without GC allocation, stripped styled IES markup, and installed the
Sparkles logger.

## Where to go next

- [Write `@nogc` text](../how-to/write-nogc-text.md) for focused text
  writer patterns.
- [Log through `CoreLogger`](../how-to/log-with-core-logger.md) for the
  new logging interface.
- [API index](../reference/api.md) for module-level lookup.
