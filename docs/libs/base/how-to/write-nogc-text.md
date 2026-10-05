# Write `@nogc` text

Use a `Buffer` plus `sparkles.base.text.writers` when a hot path needs
formatted text but must not allocate through the garbage collector.

## Format into an output range

The writers accept any output range. `UniqueBuffer!(char, N)` is the usual
choice for short-lived text:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_write_nogc_text"
    dependency "sparkles:base" version="*"
+/
import core.time : dur;
import std.stdio : writeln;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.writers : writeBytes, writeDuration, writeIntegerPadded;

@safe nothrow @nogc
void render(ref UniqueBuffer!(char, 128) out_)
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
    UniqueBuffer!(char, 128) buf;
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

## Keep Unicode storage explicit

Use `sparkles.base.text.utf.decodeToken` / `encodeScalar` for individual
tokens/scalars, and `decodePrefix` / `convertPrefix` for bounded prefix work.
`UtfMode.strict` rejects malformed input; replacement consumes Unicode maximal
subparts; UTF-8-only opaque mode preserves individual bytes as non-scalars.
`encodeToken` rejects opaque tokens: `reconstructToken` explicitly restores
their UTF-8 source bytes.

Prefix conversion commits only complete tokens and reports consumed/written
counts plus `needInput` or `outputFull`. Incomplete non-final suffixes remain
unconsumed. `UtfStream` instead owns carry state across chunks and reports
backpressure; do not discard unconsumed input or retry an already-consumed
prefix. Source-unit offsets are not universally byte offsets: UTF-16 and UTF-32
token spans count their corresponding code units.

For all-or-nothing conversion use `sparkles.base.text.utf16` bounded conversion
functions and `measureConversion`. Preflight rejects malformed input,
insufficient destination and prohibited overlap before publication; a failure
leaves the destination unchanged. NUL-terminated variants also reject embedded
NUL and reserve the terminator separately from reported payload counts.

Normalization, casing and source maps need caller-owned output, provenance,
epoch and scratch arenas. `@nogc` means no hidden allocation, not unlimited
caller storage. Check every result and preserve borrowed-view lifetimes; see
[Unicode analysis](../reference/unicode-analysis.md).
