# Collect every decode error

By default `fromSDL` stops at the first problem. When a person edits a
configuration file, it is kinder to report every mistake at once. Pass an
_error sink_, any output range of `SdlError`, and the decoder keeps going
past each independent failure.

## Accumulate into any output range

```d
auto sink = appender!(SdlError[]);
auto result = fromSDL!Config(text, sink);
```

The result still fails, carrying the first error; the sink receives all of
them, each with its own source span and paths. A field that fails is left
at its default so its siblings can still be checked. An aggregate whose
fields failed skips its own `@WireCheck`s, because they would judge
defaults the input never contained.

## Bound the number of errors

`FixedWireErrors!(SdlError, capacity)` from `sparkles.wired.walk` is a sink
that never allocates. It keeps the first `capacity` errors, then appends a
single `errorSinkOverflow` marker, so a report says that more errors
existed. `overflowed` tells you whether that happened.

## Read the two paths

Every error names its site twice:

- `rolePath` is the place in the SDL text: `.worker[1]@threads` is the
  `threads` attribute of the second `worker` tag.
- `valuePath` is the place in your D value: `.workers[1].threads`.

`toString` prints both, with the source name and line and column first.

## Example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_collect_errors"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.array : appender;
import std.stdio : writeln;

import sparkles.wired : WireName, WireOptional;
import sparkles.wired.sdl : Sdl, SdlAttribute, SdlError, SdlTagValue, fromSDL;
import sparkles.wired.walk : FixedWireErrors;

struct Worker
{
    @SdlTagValue(0) string name;
    @WireOptional() @SdlAttribute() int threads = 1;
}

struct Service
{
    int port;
    @WireName!Sdl("worker") Worker[] workers;
}

enum text = `port "eighty"
worker "a" threads="x"
worker 7
worker "c" threads=2
`;

void main()
{
    auto sink = appender!(SdlError[]);
    const result = fromSDL!Service(text, sink, "service.sdl");
    assert(result.hasError);
    foreach (error; sink[])
        writeln(error.toString);

    FixedWireErrors!(SdlError, 2) bounded;
    const again = fromSDL!Service(text, bounded);
    assert(again.hasError);
    foreach (error; bounded[])
        writeln(error.code);
    writeln("overflowed: ", bounded.overflowed);
}
```

```ansi
service.sdl(1:6): Cannot decode int at $.port[0] (value $.port): expected an SDL integer
service.sdl(2:20): Cannot decode int at $.worker[0]@threads (value $.workers[0].threads): expected an SDL integer
service.sdl(3:8): Cannot decode string at $.worker[1]<value[0]> (value $.workers[1].name): expected an SDL string
unexpectedKind
unexpectedKind
errorSinkOverflow
overflowed: true
```
