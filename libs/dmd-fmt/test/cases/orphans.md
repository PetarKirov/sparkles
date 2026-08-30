# Orphaned separators and closers — hostile cases

`D10`: the three shapes where a break carries nothing to preserve, and the neighbouring shapes
where it carries everything. Unpublished (`TST3`).

## A line holding only `;` or `,` rejoins

<!-- fmt id=D10 -->

::: code-group

```d [Before]
void f()
{
    check(value)
        ;
    auto xs = [
        1
        ,
        2,
    ];
}
```

```d [After]
void f()
{
    check(value);
    auto xs = [
        1,
        2,
    ];
}
```

:::

## A comma leading its line moves up, and takes the break with it

<!-- fmt id=D10 -->

::: code-group

```d [Before]
auto xs = [
      1
    , 2
    , 3];
```

```d [After]
auto xs = [
    1,
    2,
    3];
```

:::

## A closer under contents that never broke rejoins them

<!-- fmt id=D10 -->

::: code-group

```d [Before]
auto a = [1, 2, 3
];
auto b = foo(x + y
);
auto c = arr[i
];
S s = { a: 1, b: 2
};
```

```d [After]
auto a = [1, 2, 3];
auto b = foo(x + y);
auto c = arr[i];
S s = { a: 1, b: 2 };
```

:::

## A closer under contents that did break keeps its line

<!-- fmt id=D10 -->

::: code-group

```d [Before]
auto a = [
1,
2,
];
auto b = foo(
x,
y
);
S s = {
a: 1,
b: 2,
};
```

```d [After]
auto a = [
    1,
    2,
];
auto b = foo(
    x,
    y
);
S s = {
    a: 1,
    b: 2,
};
```

:::

## A statement block's `}` earns its line even when left beside a statement

The mirror of the case above: same visual shape — a closer sharing a line with content — and the
opposite outcome, because a block is not a value.

<!-- fmt id=D10 -->

::: code-group

```d [Before]
void f()
{
    g(); }

void nested()
{
    if (ready)
    {
        prepare(); }
}

void alreadyOneLine() { done(); }
```

```d [After]
void f()
{
    g();
}

void nested()
{
    if (ready)
    {
        prepare();
    }
}

void alreadyOneLine() { done(); }
```

:::

## A token string's interior is untouched; its orphaned `;` is not

<!-- fmt id=D10 -->

::: code-group

```d [Before]
enum code = q{
int   add(int a, int b)
{
    return a + b;
}
}
;
```

```d [After]
enum code = q{
int   add(int a, int b)
{
    return a + b;
}
};
```

:::
