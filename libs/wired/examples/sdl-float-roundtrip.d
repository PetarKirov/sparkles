#!/usr/bin/env dub
/+ dub.sdl:
    name "sdl_float_roundtrip"
    dependency "sparkles:wired" path="../../.."
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Every floating-point kind through the SDL codec and back, bit for bit.

The document is written with the shortest spelling of each value at its own
width — `F`, `D` and `BD` — and read back through the text overload of
`fromSDL`, which is `@safe` for a consumer compiled with `-preview=dip1000`
too: this program is the regression for the lexer's error path, which once
failed that inference from outside the library's own build.
*/
module sdl_float_roundtrip;

import std.stdio : writefln;
import sparkles.wired.sdl : fromSDL, toSDL;

struct Readings
{
    float f;
    double d;
    real r;
}

bool sameBits(T)(T a, T b) @safe
{
    import sparkles.base.text.float_conv : decompose;

    return decompose!T(a) == decompose!T(b);
}

/// The text overload of `fromSDL`, from `@safe` code in a consumer.
auto decode(scope const(char)[] text) @safe => fromSDL!Readings(text);

void main()
{
    const original = Readings(0.1f, 1e-300, real.max);
    auto sdl = toSDL(original);
    if (sdl.hasError)
        assert(0, sdl.error.toString);
    // A named `const` copy of the document: `value` hands out the buffer by
    // value, and a slice taken straight off that temporary would dangle —
    // the mutable slice of a shared copy-on-write buffer clones the block,
    // and the clone dies with the temporary at the end of the statement.
    // real.max at binary128 is a BD token of about 4 900 digits; show the
    // shape, not the whole thing.
    const text = sdl.value;
    writefln("%s bytes of SDL, starting: %s", text.length,
        text.length > 60 ? text[][0 .. 60] ~ "…" : text[]);

    auto back = decode(text[]);
    if (back.hasError)
        assert(0, back.error.toString);
    writefln("float  round-trips: %s", sameBits(back.value.f, original.f));
    writefln("double round-trips: %s", sameBits(back.value.d, original.d));
    writefln("real   round-trips: %s", sameBits(back.value.r, original.r));
}
