# Brackets — hostile cases

Not a published page: this is the unpublished half of `TST3`, where the cases are as hostile as the
engine deserves. The presentable case for each decision lives in
`docs/libs/dmd-fmt/reference/decisions/`.

## An author break after the opener survives

<!-- fmt id=P55 -->

::: code-group

```d [Before]
auto x = foo(
a + b);
auto y = [
        1, 2,
    3, 4];
auto z = foo(
            // note
  a);
```

```d [After]
auto x = foo(
    a + b);
auto y = [
    1, 2,
    3, 4];
auto z = foo(
    // note
    a);
```

:::

## Blank lines at a container's edge are dropped

<!-- fmt id=P20 -->

::: code-group

```d [Before]
auto w = [

    1, 2];
auto v = foo(

    a);
```

```d [After]
auto w = [
    1, 2];
auto v = foo(
    a);
```

:::

## Nested containers each keep their own author breaks

<!-- fmt id=P55 -->

::: code-group

```d [Before]
auto grid = [
[
    1, 2],
        [3,
  4],
];
```

```d [After]
auto grid = [
    [
        1, 2],
    [3,
        4],
];
```

:::

## A single-line list is laid out by the engine, not pinned

<!-- fmt id=P55 width=40 -->

::: code-group

```d [Before]
auto v = foo(alpha, beta, gamma, delta, epsilon);
```

```d [After]
auto v = foo(
    alpha,
    beta,
    gamma,
    delta,
    epsilon
);
```

:::

## An unclosed bracket invents nothing

<!-- fmt id=P56 -->

::: code-group

```d [Before]
auto broken = foo(
a,
        b
```

```d [After]
auto broken = foo(
    a,
    b
```

:::

## The trailing comma explodes a flat list and preserves a broken one

`M4` in both directions at once, plus the shapes that sit between them: a table packed several
values to a row, a list broken at every element, and one broken irregularly. All three already
have a shape, so all three keep it — only the flat list is exploded.

<!-- fmt id=M4 -->

::: code-group

```d [Before]
immutable flat = [1, 2, 3,];
immutable packed = [
      1, 2, 1,
    2, 4, 2,
        1, 2, 1,
];
immutable perLine = [
alpha,
        beta,
  gamma,
];
immutable ragged = [
    a, b,
            c,
    d, e, f,
];
```

```d [After]
immutable flat = [
    1,
    2,
    3,
];
immutable packed = [
    1, 2, 1,
    2, 4, 2,
    1, 2, 1,
];
immutable perLine = [
    alpha,
    beta,
    gamma,
];
immutable ragged = [
    a, b,
    c,
    d, e, f,
];
```

:::

## A broken call argument list keeps its rows too

The same rule where the list is a call rather than a literal — and where the trailing comma is
absent, so nothing pins the shape but the author's own breaks.

<!-- fmt id=M4 -->

::: code-group

```d [Before]
void f()
{
    configure(width, height,
    visible, resizable,);
    measure(width, height,
        visible);
}
```

```d [After]
void f()
{
    configure(width, height,
        visible, resizable,);
    measure(width, height,
        visible);
}
```

:::
