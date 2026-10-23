# Getting started with SDL

This tutorial reads a small service configuration written in
[SDLang](https://sdlang.org) into a D struct, changes it, writes it back,
and then shows what a mistake in the file looks like. By the end you will
have one program that does all three, and you will have run it.

You do not need to know how the SDL backend works inside. The
[explanation](../explanation/sdl-design.md) and
[reference](../reference/sdl.md) pages are there for afterwards.

## What you need

- A D compiler and `dub` (the examples are tested with LDC).
- Five minutes.

## Step 1: the file

SDL is a list of _tags_. Each tag has a name, then optional positional
_values_, then optional `key=value` _attributes_, then an optional `{ … }`
block of child tags:

```sdl
name "billing"
listen "0.0.0.0" port=8080
worker "invoices" threads=4
worker "reports"
```

`listen` has one value and one attribute. `worker` appears twice: SDL
allows a tag to repeat, which is how it spells a list.

## Step 2: a struct for each tag

Each struct field says which part of a tag it reads. An unannotated field
is a child tag of the same name. `@SdlTagValue(0)` reads the first
positional value, and `@SdlAttribute()` reads an attribute:

```d
struct Listen
{
    @SdlTagValue(0) string host;
    @SdlAttribute() int port;
}

struct Worker
{
    @SdlTagValue(0) string name;
    @WireOptional() @SdlAttribute() int threads = 1;
}

struct Service
{
    string name;
    Listen listen;
    @WireName!Sdl("worker") Worker[] workers;
}
```

`name` holds a plain string, so the backend reads it from the first value
of the `name` tag. `listen` is a struct, so it reads the `listen` tag's
own values and attributes. `workers` is an array of structs, so every
`worker` tag becomes one element; `@WireName!Sdl("worker")` keeps the
D field plural while the tag stays singular.

The second `worker` tag has no `threads` attribute. Every field is
required unless you say otherwise; `@WireOptional()` lets `threads` be
absent, and an absent field keeps its declared initializer, `1`.

## Step 3: decode, change, encode

`fromSDL!Service` parses and decodes in one call. It never throws: it
returns a result that holds either the value or an error. `toSDL` turns a
value back into canonical SDL text.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_tutorial"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : write, writeln;

import sparkles.wired : WireName, WireOptional;
import sparkles.wired.sdl : Sdl, SdlAttribute, SdlTagValue, fromSDL, toSDL;

struct Listen
{
    @SdlTagValue(0) string host;
    @SdlAttribute() int port;
}

struct Worker
{
    @SdlTagValue(0) string name;
    @WireOptional() @SdlAttribute() int threads = 1;
}

struct Service
{
    string name;
    Listen listen;
    @WireName!Sdl("worker") Worker[] workers;
}

enum config = `name "billing"
listen "0.0.0.0" port=8080
worker "invoices" threads=4
worker "reports"
`;

void main()
{
    auto service = fromSDL!Service(config);
    assert(service.hasValue, service.error.toString);
    writeln(service.value.workers.length, " workers, the second with ",
        service.value.workers[1].threads, " thread");

    auto changed = service.value;
    changed.listen.port = 9090;
    changed.workers ~= Worker("audit", 2);
    write(toSDL(changed).value[]);

    const broken = fromSDL!Service(`name "billing"
listen "0.0.0.0" port=8080
worker "invoices" threads="four"
`);
    writeln(broken.error.toString);
}
```

```ansi
2 workers, the second with 1 thread
name "billing"
listen "0.0.0.0" port=9090
worker "invoices" threads=4
worker "reports" threads=1
worker "audit" threads=2
Cannot decode int at $.worker[0]@threads (value $.workers[0].threads): expected an SDL integer
```

Read the output from the top:

1. The decoded value has two workers, and the second kept its default.
2. The written text is _canonical_: values first, then attributes, one tag
   per line, LF newlines. Writing the same value always gives the same
   bytes, so the output is safe to diff and to commit.
3. The broken input fails with a message that names the exact place:
   `$.worker[0]@threads` is the `threads` attribute of the first `worker`
   tag, and `$.workers[0].threads` is the same place in your struct.

## What you learned

- One struct field per part of a tag: `@SdlTagValue`, `@SdlAttribute`,
  or (by default) a child tag.
- An array field reads a repeated tag; `@WireOptional()` lets a field be
  absent, keeping its initializer.
- `fromSDL` and `toSDL` return results instead of throwing, and errors
  carry both the SDL position and the D field path.

## Next steps

- [Map fields to SDL roles](../how-to/sdl-map-fields.md) covers namespaces,
  maps, positional arrays, and dynamic tag names.
- [Collect every decode error](../how-to/sdl-collect-errors.md) reports all
  mistakes in one pass instead of the first.
- [Read DUB recipes](../how-to/sdl-read-dub-recipes.md) picks the profile
  that matches `dub.sdl` exactly.
