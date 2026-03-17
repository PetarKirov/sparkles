# Forcing Named Arguments in D

## Problem

D's [named arguments (DIP1030)](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1030.md) are convenient but **optional** — callers can always fall back to positional arguments. For APIs with multiple parameters of the same type (e.g., `int x, int y, int width, int height`), positional calls are error-prone because swapping arguments compiles silently.

There is no built-in keyword-only parameter mechanism (unlike Python's `*` separator).

## Solution: Private Sentinel Type

Place a `private`-typed parameter with a default value as the **first** parameter. External callers cannot construct or match the private type positionally, so they must use named arguments for the remaining parameters.

### Functions

::: code-group

```d [mylib/drawing.d — definition]
module mylib.drawing;

/// Sentinel type — private to this module, impossible to name or
/// construct from the outside.
private struct NamedOnly {}

/// Draws a rectangle. External callers must use named arguments:
///     draw(x: 10, y: 20, width: 100, height: 200);
void draw(NamedOnly _ = NamedOnly.init, int x = 0, int y = 0, int width = 0, int height = 0)
{
    // ...
}
```

```d [caller.d — usage]
import mylib.drawing;

draw(x: 10, y: 20, width: 100, height: 200);  // ✅ compiles
draw(width: 50, height: 50);                    // ✅ partial — rest get defaults
draw(10, 20, 100, 200);                         // ❌ Error: cannot pass `int` to parameter `NamedOnly`
```

:::

### Structs

The same trick works for struct initialization — place the sentinel as the first field:

::: code-group

```d [mylib/config.d — definition]
module mylib.config;

struct ServerConfig
{
    private struct NamedOnly {}

    NamedOnly _ = NamedOnly.init;
    string host;
    ushort port;
    uint maxConnections = 100;
}
```

```d [caller.d — usage]
import mylib.config;

auto cfg = ServerConfig(host: "localhost", port: 8080);  // ✅ compiles
auto bad = ServerConfig("localhost", 8080);               // ❌ Error: cannot convert `string` to `NamedOnly`
```

:::

## Guidelines

- Name the sentinel `_` so it is clearly not a real parameter
- Always give it `= NamedOnly.init` so callers never need to mention it
- All real parameters should also have defaults when the sentinel is used, since
  named arguments allow skipping parameters (e.g., `draw(width: 50, height: 50)`)
- Use this idiom for APIs where positional argument confusion would be a source
  of bugs (e.g., multiple parameters of the same type like coordinates)
- **Prefer the function-parameter variant** over the struct-field variant for
  zero-overhead guarantees (see [ABI Impact](#abi-impact) below)

## ABI Impact

The sentinel is a zero-sized struct. Its impact depends on where it is used:

| Variant            | Overhead    | Why                                                                          |
| ------------------ | ----------- | ---------------------------------------------------------------------------- |
| Function parameter | **None**    | Zero-sized struct occupies no register and no stack slot — identical codegen |
| Struct field       | **4 bytes** | D structs have minimum `sizeof == 1`; alignment padding inflates the struct  |

### Compiler Output

With LDC at `-O2 -release`, the function-parameter variant produces **byte-identical** assembly to a plain function (full source: [`abi_comparison.d`](abi_comparison.d)):

::: code-group

```d [sentinel version]
export Rect withSentinel(
    NamedOnly _ = NamedOnly.init,
    int x = 0, int y = 0, int width = 0, int height = 0, int margin = 0,
)
{
    return Rect(x - margin, y - margin, width + 2 * margin, height + 2 * margin);
}
```

```d [baseline — no sentinel]
export Rect withoutSentinel(int x, int y, int width, int height, int margin)
{
    return Rect(x - margin, y - margin, width + 2 * margin, height + 2 * margin);
}
```

```asm [generated assembly (identical for both)]
subl    %r8d, %edi
subl    %r8d, %esi
leal    (%rdx,%r8,2), %edx
leal    (%rcx,%r8,2), %ecx
shlq    $32, %rsi
leaq    (%rdi,%rsi), %rax
shlq    $32, %rcx
orq     %rcx, %rdx
retq
```

:::

## Alternative Techniques Considered

None of the following enforce named-only arguments:

| Technique                                      | Idea                                                          | Why it doesn't work                                                                                                 |
| ---------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `@disable this(int, int, …)`                   | Disable the positional constructor on a struct                | Named args resolve to the **same** constructor signature, so `@disable` blocks both positional and named calls      |
| Distinct wrapper types (`struct X { int v; }`) | Each parameter gets its own type, preventing accidental swaps | Provides **type safety** but doesn't force naming — callers can still write `draw(X(10), Y(20))` positionally       |
| All-default parameters                         | Give every parameter a default so callers can skip freely     | Positional calls still compile — `draw(10, 20, 100, 200)` is accepted without names                                 |
| Struct parameter wrapper                       | `void draw(DrawOpts opts)`                                    | Encourages naming at the struct literal site, but `DrawOpts(10, 20, 100, 200)` still compiles positionally          |
| `static opCall` with `@disable this()`         | Disable default constructor and route through `static opCall` | `@disable this()` interferes with `opCall` — the compiler tries the disabled constructor first and rejects the call |

The experiments for each technique are in this directory — [`alternatives.d`](alternatives.d) collects all failing approaches, and [`abi_comparison.d`](abi_comparison.d) is the ABI snippet shown above. The multi-module enforcement test:

::: code-group

```d [lib.d — module with sentinel]
module lib;

private struct NamedOnly {}

struct Rect
{
    int x, y, width, height;
}

Rect inflateRect(NamedOnly _ = NamedOnly.init, int x = 0, int y = 0, int width = 0, int height = 0, int margin = 0)
{
    return Rect(x - margin, y - margin, width + 2 * margin, height + 2 * margin);
}

struct RectOpts
{
    private struct NamedOnly {}

    NamedOnly _ = NamedOnly.init;
    int x, y, width, height;
}

Rect makeRect(RectOpts o)
{
    return Rect(o.x, o.y, o.width, o.height);
}
```

```d [test_positive.d — named args ✅]
/// Run: dmd -i -run test_positive.d
import lib;

void main()
{
    import std.stdio : writefln;

    auto r1 = lib.inflateRect(x: 10, y: 20, width: 100, height: 200, margin: 5);
    assert(r1 == lib.Rect(5, 15, 110, 210));

    auto r2 = lib.inflateRect(width: 50, height: 50);
    assert(r2 == lib.Rect(0, 0, 50, 50));

    auto r3 = lib.makeRect(lib.RectOpts(x: 10, y: 20, width: 100, height: 200));
    assert(r3 == lib.Rect(10, 20, 100, 200));

    writefln("All positive tests passed.");
}
```

```d [test_negative.d — positional ❌]
/// Run: dmd -i -c test_negative.d
/// Expected: compilation errors for every call below.
import lib;

void main()
{
    auto r1 = lib.inflateRect(10, 20, 100, 200, 5);  // ❌ cannot pass `int` as `NamedOnly`
    auto r2 = lib.RectOpts(10, 20, 100, 200);         // ❌ cannot convert `int` to `NamedOnly`
}
```

:::
