# Declarations — hostile cases

The leading attribute run and the declaration head it modifies. Unpublished (`TST3`).

## Every UDA spelling keeps the declaration in its own column

<!-- fmt id=P22 -->

::: code-group

```d [Before]
@("n")
@safe
@nogc
void named()
{
    return;
}

@(SomeAttr)
struct WithExprUda
{
    int a;
}

@safe @nogc
@("both on one line, then a break")
void mixed()
{
    return;
}
```

```d [After]
@("n")
@safe
@nogc
void named()
{
    return;
}

@(SomeAttr)
struct WithExprUda
{
    int a;
}

@safe @nogc
@("both on one line, then a break")
void mixed()
{
    return;
}
```

:::

## Attribute keywords count as prefix, the head does not

<!-- fmt id=P22 -->

::: code-group

```d [Before]
static
private
void keywordPrefix()
{
    return;
}

void afterHead()
    @safe
{
    return;
}
```

```d [After]
static
private
void keywordPrefix()
{
    return;
}

void afterHead()
    @safe
{
    return;
}
```

:::

## A real continuation still indents

<!-- fmt id=P84 -->

::: code-group

```d [Before]
void f()
{
    auto x = aaa +
        bbb;
    auto y = foo(a)
        .bar(b);
}
```

```d [After]
void f()
{
    auto x = aaa +
        bbb;
    auto y = foo(a)
        .bar(b);
}
```

:::

## Empty bodies, every shape

<!-- fmt id=P34 -->

::: code-group

```d [Before]
void a() {}
void b()
{
}
struct C
{
}
void d()
{
    // only a comment
}
unittest
{
}
```

```d [After]
void a() {}
void b()
{
}
struct C
{
}
void d()
{
    // only a comment
}
unittest
{
}
```

:::

## Contracts and constraints still sit at the declaration's column

<!-- fmt id=P157 -->

::: code-group

```d [Before]
@safe
auto tr(T)(T a)
if (isX!T)
in (a > 0)
out (r; r > 0)
{
    return a;
}
```

```d [After]
@safe
auto tr(T)(T a)
if (isX!T)
in (a > 0)
out (r; r > 0)
{
    return a;
}
```

:::
