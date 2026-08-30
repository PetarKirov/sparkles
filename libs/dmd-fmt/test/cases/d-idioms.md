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

## A braced body sits at the column of the header that opens it

<!-- fmt id=D10 -->

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
