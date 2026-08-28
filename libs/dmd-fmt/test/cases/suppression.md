# Suppression and verbatim regions — hostile cases

The M3 do-no-harm valve, pushed into the corners. Unpublished (`TST3`).

## `// dfmt off` inside a bracket keeps its own line

<!-- fmt id=D5 -->

::: code-group

```d [Before]
enum t = [
    // dfmt off
    [1,   0,  0],
    [0, 1,    0],
    // dfmt on
];
```

```d [After]
enum t = [
    // dfmt off
    [1,   0,  0],
    [0, 1,    0],
    // dfmt on
];
```

:::

## Suppression survives an unformatted neighbourhood

<!-- fmt id=D5 -->

::: code-group

```d [Before]
int a;
// dfmt off
int    weird   =    1;
// dfmt on
int      b;
```

```d [After]
int a;
// dfmt off
int    weird   =    1;
// dfmt on
int b;
```

:::

## An `asm` body is verbatim

<!-- fmt id=D5 -->

::: code-group

```d [Before]
void f()
{
        asm {  mov  EAX,  1 ;  }
}
```

```d [After]
void f()
{
    asm {  mov  EAX,  1 ;  }
}
```

:::

## Multi-line literals and comments are never reflowed

<!-- fmt id=P28 width=40 -->

::: code-group

```d [Before]
enum sample = q{
int add(int a, int b)
{
    return a + b;
}
};
/* a block comment
   whose  interior  spacing
   is the author's */
int    x;
```

```d [After]
enum sample = q{
int add(int a, int b)
{
    return a + b;
}
};
/* a block comment
   whose  interior  spacing
   is the author's */
int x;
```

:::
