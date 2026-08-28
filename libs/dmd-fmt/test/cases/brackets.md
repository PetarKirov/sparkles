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
