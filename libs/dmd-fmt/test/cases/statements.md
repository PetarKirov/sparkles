# Statements — hostile cases

Clause nesting, and the boundary between a nested clause and a wrapped expression. Unpublished
(`TST3`).

## Braceless bodies nest one level per clause

<!-- fmt id=P38 -->

::: code-group

```d [Before]
void f()
{
version (X)
foreach (i; 0 .. n)
if (c)
g();

        foreach (i; 0 .. n)
    if (c)
            return;

  while (c)
      with (obj)
   use();
}
```

```d [After]
void f()
{
    version (X)
        foreach (i; 0 .. n)
            if (c)
                g();

    foreach (i; 0 .. n)
        if (c)
            return;

    while (c)
        with (obj)
            use();
}
```

:::

## A wrapped expression steps once, however many lines it takes

<!-- fmt id=P84 -->

::: code-group

```d [Before]
void f()
{
    auto x = aaa +
bbb +
            ccc +
  ddd;
    auto y = foo(a)
.bar(b)
                .baz(c);
}
```

```d [After]
void f()
{
    auto x = aaa +
        bbb +
        ccc +
        ddd;
    auto y = foo(a)
        .bar(b)
        .baz(c);
}
```

:::

## A clause header followed by a wrapped body: both steps happen

<!-- fmt id=P38 -->

::: code-group

```d [Before]
void f()
{
    if (c)
x = a +
b;
    foreach (e; es)
            sink(e,
    other);
}
```

```d [After]
void f()
{
    if (c)
        x = a +
            b;
    foreach (e; es)
        sink(e,
            other);
}
```

:::

## `else`, `do` and `try` are clause headers with no parentheses

<!-- fmt id=P39 -->

::: code-group

```d [Before]
void f()
{
    if (a)
x();
    else
            y();

    if (a)
  x();
    else if (b)
            y();
    else
z();
}
```

```d [After]
void f()
{
    if (a)
        x();
    else
        y();

    if (a)
        x();
    else if (b)
        y();
    else
        z();
}
```

:::

## A call is not a clause, even though it also ends in `)`

<!-- fmt id=P84 -->

::: code-group

```d [Before]
void f()
{
    foo(a)
.bar();
    receive(handler)
            .then(next);
}
```

```d [After]
void f()
{
    foo(a)
        .bar();
    receive(handler)
        .then(next);
}
```

:::

## Own-line comments are siblings; a trailing comment is a wrap

<!-- fmt id=P41 -->

::: code-group

```d [Before]
void f()
{
    if (ready)
// why
        // and why again
prepare();

    auto x = a + // note
b;
}
```

```d [After]
void f()
{
    if (ready)
        // why
        // and why again
        prepare();

    auto x = a + // note
        b;
}
```

:::

## A comma inside a statement is not a statement boundary

`P84` where the wrap point is a comma. A selective import, a run of declarators and a call's
argument list all wrap at one, and none of them starts a new statement there — so the tail keeps
the continuation level instead of returning to the statement's own column.

<!-- fmt id=P84 -->

::: code-group

```d [Before]
import sparkles.raylib_text : FontSet, drawGrapheme,
drawText, TextStyle;
import sparkles.base.text : Reader,
            Writer;

void f()
{
    int first = 1,
second = 2,
        third = 3;
    sink(alpha, beta,
gamma);
}
```

```d [After]
import sparkles.raylib_text : FontSet, drawGrapheme,
    drawText, TextStyle;
import sparkles.base.text : Reader,
    Writer;

void f()
{
    int first = 1,
        second = 2,
        third = 3;
    sink(alpha, beta,
        gamma);
}
```

:::

## A comma-separated body still gives each member its own statement

The mirror: an `enum` body and a struct initializer have no `;` to separate anything, so there the
comma _is_ the separator and each member is a statement of its own.

<!-- fmt id=P84 -->

::: code-group

```d [Before]
enum Colour
{
red,
        green,
  blue,
}

void f()
{
    Point p = {
x: 1,
            y: 2,
    };
}
```

```d [After]
enum Colour
{
    red,
    green,
    blue,
}

void f()
{
    Point p = {
        x: 1,
        y: 2,
    };
}
```

:::
