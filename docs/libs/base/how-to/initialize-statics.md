# Initialize globals at run time, on the declaration

Use `staticVar` for one global, or `StaticBlock` for several, when the value
can only be computed at run time but should read like an ordinary declaration:

```d
import sparkles.base.static_init : staticVar, StaticBlock;

mixin(staticVar!q{ immutable uint[256] crcTable = buildCrcTable(); });

mixin StaticBlock!q{
    immutable size_t nonZero = countNonZero(crcTable[]); // reads the line above
    string[] threadLog = ["started"];                    // one per thread
    __gshared Registry registry = new Registry;
};
```

The mixin turns each declaration into the bare declaration plus a module
constructor that assigns it. Because of that:

- **The variable keeps its type.** `crcTable` is an `immutable uint[256]`, not
  a wrapper, so passing it around needs no unwrapping.
- **Access costs nothing.** No flag is checked when the variable is read. Rust's
  `LazyLock<T>` checks an atomic on every access.
- **D's module-constructor guarantees apply.** The value is set before any
  code can read it, once per process or once per thread, in import order. A
  constructor cycle between modules aborts at startup instead of reading
  `.init`.

## Which constructor runs

| Declaration                        | Runs in                  | How often             |
| ---------------------------------- | ------------------------ | --------------------- |
| mutable thread-local (`T x`)       | `static this`            | at every thread start |
| `immutable`, `shared`, `__gshared` | `shared static this`     | once                  |
| thread-local `const`               | rejected at compile time | —                     |

A thread-local `const` would be set on the main thread only, so the mixin asks
for `immutable` or `shared const` instead.

## Ordering

Each declaration gets its own constructor, emitted in source order. D runs all
of a module's shared constructors first, then its thread-local ones, each
group in lexical order. So an initializer can read the variables of its own
group that are declared above it. A shared initializer that reads a
thread-local variable sees `.init`.

## Leave out the type

`immutable x = f();` and `auto y = g();` work. The type becomes
`typeof(<initializer>)`.

## Static members

Inside a struct or class, the variables must be `static`:

```d
struct Config
{
    mixin StaticBlock!q{ static immutable string name = loadName(); };
}
```

## Limits

- One declarator per declaration (`int a = 1, b = 2;` is rejected), and
  variables only. `enum`, `alias` and `import` lines, and declarations without
  `=`, pass through unchanged.
- The value is assigned in the constructor, so a type with `@disable this()`
  cannot be used. An `immutable` target needs the initializer to convert
  implicitly, as in a normal declaration; a `pure` factory does.
- An exception thrown by an initializer aborts startup.
- DDoc does not see doc comments inside the string.
- A nested `/+ … +/` comment ends at its first `+/`.
- A compile error in a `staticVar` is reported on your own line. In a
  `StaticBlock`, it points into `static_init.d`, followed by a
  "parent scope from here" note that gives your line.

The runnable version is `libs/base/examples/static-init.d`.
