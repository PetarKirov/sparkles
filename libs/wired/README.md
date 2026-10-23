# `sparkles:wired`

Serialization with shared schema policies, JSON, and SDL. See the
[library documentation](../../docs/libs/wired/index.md) for the full API.

## SDL defaults, aliases, and presence

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_sdl_presence"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : write, writeln;
import sparkles.wired : Decoded, WireAlias, WireDefault, WireCheck, isBetween;
import sparkles.wired.sdl : Sdl, fromSDL, toSDL;

struct Settings
{
    @WireAlias!Sdl("oldPort") @WireDefault!Sdl(8080)
    @WireCheck!(isBetween!(1, 65535)) int port;
}

void main()
{
    const decoded = fromSDL!(Decoded!Settings)("oldPort 443\n");
    assert(decoded.hasValue);
    writeln(decoded.value.present.has!"port");
    const encoded = toSDL(decoded.value.value);
    assert(encoded.hasValue);
    write(encoded.value[]);
}
```

```ansi
true
port 443
```
