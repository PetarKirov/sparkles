# D idioms — hostile cases

Shapes D writes that a formatter can quietly destroy. Unpublished (`TST3`).

## `static foreach` double braces stay touching

<!-- fmt id=D11 -->

::: code-group

```d [Before]
void f(Args...)(Args args)
{
static foreach (arg; args)
{{
alias T = typeof(arg);
enum name = __traits(identifier, T);
useName(name);
}}
}
```

```d [After]
void f(Args...)(Args args)
{
    static foreach (arg; args)
    {{
        alias T = typeof(arg);
        enum name = __traits(identifier, T);
        useName(name);
    }}
}
```

:::

## Nested double braces, and a padded block beside them

<!-- fmt id=D11 -->

::: code-group

```d [Before]
void f(Args...)(Args args)
{
    static foreach (i, arg; args)
        {{
        static foreach (j, other; args)
                {{
            pair(i, j);
                }}
        }}
    if (ready) { done(); }
    if (later) {done();}
}
```

```d [After]
void f(Args...)(Args args)
{
    static foreach (i, arg; args)
    {{
        static foreach (j, other; args)
        {{
            pair(i, j);
        }}
    }}
    if (ready) { done(); }
    if (later) {done();}
}
```

:::

## Sibling `with`s share a level; every other chain nests

`with (a)` over `with (b)` is a set of scopes over one block, and D writes the siblings at equal
indent. `if` over `if` — or over a `while` — is a nesting, and says so.

<!-- fmt id=D12 -->

::: code-group

```d [Before]
void f()
{
with (A)
with (B)
{
g();
}

if (a)
if (b)
{
h();
}

if (c)
{
plain();
}
}
```

```d [After]
void f()
{
    with (A)
    with (B)
    {
        g();
    }

    if (a)
        if (b)
        {
            h();
        }

    if (c)
    {
        plain();
    }
}
```

:::

## The one-line header shapes D actually writes

<!-- fmt id=D12 -->

::: code-group

```d [Before]
void f(ClockType clockType, TOK kind)
{
switch (kind) with (TOK)
{
case identifier:
break;
default:
}

with (ClockType) final switch (clockType)
{
case normal:
break;
}

foreach (triplet; data.triplets) with (triplet)
{
use(a, b);
}

with (yearMonth) this(year, month, day(assumePeriod));
}
```

```d [After]
void f(ClockType clockType, TOK kind)
{
    switch (kind) with (TOK)
    {
        case identifier:
            break;
        default:
    }

    with (ClockType) final switch (clockType)
    {
        case normal:
            break;
    }

    foreach (triplet; data.triplets) with (triplet)
    {
        use(a, b);
    }

    with (yearMonth) this(year, month, day(assumePeriod));
}
```

:::
