# Layout decisions

The formatting decisions the **layout tier** makes — the tier that is always on, changes no tokens,
and is verified by token equality. Each section states one decision and shows it happening.

> [!NOTE]
> **These examples are executed.** Every "After" block on this page is the output `dmd-fmt`
> actually produces for the "Before" block beside it — the page is a test fixture that the suite
> runs, so an example here cannot drift from the implementation. The mechanism is
> [the testing spec](../../../../specs/dmd-fmt/testing.md); the catalogue every `P`-number refers
> to is [the decision inventory](../../../../research/code-formatting/prettier-decisions.md).

The governing policy is **author's-breaks-preserved with structural reindentation**: where you put
your line breaks is yours, what happens horizontally is the formatter's.

---

## Vertical rhythm

### Blank-line runs collapse {#p19}

<!-- fmt id=P19 -->

A run of blank lines collapses to at most `max_blank_lines` (default **2**). Blank lines are never
inserted and a paragraph break is never removed entirely — your paragraphing survives, bounded.

::: code-group

```d [Before]
void a() {}




void b() {}
```

```d [After]
void a() {}


void b() {}
```

:::

### Blank lines at the edges of a block are dropped {#p20}

<!-- fmt id=P20 -->

A blank line immediately after `{` or immediately before `}` is removed. Blank lines _between_
statements are preserved (bounded by the rule above), so the separation you meant survives and the
padding you did not mean does not.

::: code-group

```d [Before]
void f()
{

    auto x = 1;

    return;

}
```

```d [After]
void f()
{
    auto x = 1;

    return;
}
```

:::

---

## Indentation

### Indentation is recomputed structurally {#p32}

<!-- fmt id=P32 variants=indent_size -->

Indentation is never preserved — it is derived from brace nesting, at `indent_size` columns per
level (default **4**, per [DStyle](../../../../guidelines/dstyle.md)). This is the one dimension
where the formatter overrules you completely, and it is why misindented code cannot survive a
format.

::: code-group

```d [Before]
void outer()
{
if (ready)
{
run();
}
}
```

```d [indent_size=4]
void outer()
{
    if (ready)
    {
        run();
    }
}
```

```d [indent_size=2]
void outer()
{
  if (ready)
  {
    run();
  }
}
```

:::

---

## Breaking long lines

### A call too wide for the print width breaks one argument per line {#p55}

<!-- fmt id=P55 width=60 -->

A line that exceeds `dfmt_soft_max_line_length` is broken by the greedy engine: the argument list
indents one level and takes one element per line. Lines that already fit are left exactly as you
wrote them — the formatter reflows what is too long, not what is merely long.

_At a print width of 60:_

::: code-group

```d [Before]
void f()
{
    auto widget = createWidget(width, height, visible, resizable, title);
}
```

```d [After]
void f()
{
    auto widget = createWidget(
        width,
        height,
        visible,
        resizable,
        title
    );
}
```

:::

### The magic trailing comma pins a list open {#m4}

<!-- fmt id=M4 width=60 -->

If you leave a trailing comma after the last element, the list stays exploded — one element per
line — even when it would fit on one. It is the one-bit instruction you give the formatter about a
list you intend to keep editing.

The comma is **read, never written**: v1 will not add one for you (that is the default-on rewrite
scheduled by [`D9`](../../../../specs/dmd-fmt/index.md)), so removing it returns the list to
automatic layout.

_At a print width of 60:_

::: code-group

```d [Before]
void f()
{
    auto small = createWidget(width, height,);
}
```

```d [After]
void f()
{
    auto small = createWidget(
        width,
        height,
    );
}
```

:::

---

## Opting out

### `// dfmt off` … `// dfmt on` is emitted byte-for-byte {#d5}

<!-- fmt id=D5 -->

Everything between the two markers is copied through untouched, including alignment the formatter
would otherwise collapse. dfmt's spelling is honoured as-is, so an existing project's suppression
markers keep working. Outside the range, formatting resumes normally — note `apply(  kernel )`
losing its padding below.

::: code-group

```d [Before]
void draw()
{
    // dfmt off
    immutable kernel = [
        1, 2, 1,
        2, 4, 2,
        1, 2, 1,
    ];
    // dfmt on
    apply(  kernel );
}
```

```d [After]
void draw()
{
    // dfmt off
    immutable kernel = [
        1, 2, 1,
        2, 4, 2,
        1, 2, 1,
    ];
    // dfmt on
    apply(kernel);
}
```

:::

---

## Declarations

### A UDA on its own line stays at its declaration's column {#p22}

<!-- fmt id=P22 -->

Attributes you put on their own line are a heading for the declaration below them, not a wrapped
continuation of it, so both sit in the same column. A break _after_ the declaration's head has
started is a genuine continuation and still indents one level.

::: code-group

```d [Before]
@("module.symbol.case")
    @safe unittest
{
        assert(1 + 1 == 2);
}
```

```d [After]
@("module.symbol.case")
@safe unittest
{
    assert(1 + 1 == 2);
}
```

:::

### An empty body keeps the shape the author gave it {#p34}

<!-- fmt id=P34 -->

`{}` written on one line stays on one line; braces the author put on separate lines stay on
separate lines, with nothing between them. The formatter has no opinion here — but it will not
insert a blank line into a body that has no statements.

::: code-group

```d [Before]
void inline() {}

    void spread()
{
        }
```

```d [After]
void inline() {}

void spread()
{
}
```

:::

---

## Statements

### A braceless body is indented, and nested ones step once each {#p38}

<!-- fmt id=P38 -->

A clause whose body you wrote on the next line without braces gets one level of indentation —
and a clause inside that body gets another. The steps follow the nesting you wrote, so a body two
clauses deep reads as two clauses deep.

This is the one place where the "one continuation level" rule does _not_ apply, and the distinction
is worth stating: a wrapped **expression** steps right once no matter how many lines it takes,
because every line is the same expression continuing. A nested **clause** steps right each time,
because each line is a different statement.

::: code-group

```d [Before]
bool anyMatch(int[] values)
{
    foreach (value; values)
    if (value == 3)
    return true;
    return false;
}
```

```d [After]
bool anyMatch(int[] values)
{
    foreach (value; values)
        if (value == 3)
            return true;
    return false;
}
```

:::

### A comment on its own line sits with what it annotates {#p41}

<!-- fmt id=P41 -->

A comment that starts its own line is a sibling of the statement below it, not a wrapped
continuation of the line above — so it takes that statement's indentation, and the statement does
not move to make room for it.

::: code-group

```d [Before]
void f()
{
    if (ready)
// Why this call, and not the obvious one.
    prepare();
}
```

```d [After]
void f()
{
    if (ready)
        // Why this call, and not the obvious one.
        prepare();
}
```

:::

---

## What this page does not cover yet

The layout tier is one of two. Token-changing rules — trailing-comma insertion, import sorting,
brace style, literal-form selection — are the **rewrite tier**, specified in
[`D9`](../../../../specs/dmd-fmt/index.md) and not yet implemented; their pages appear here as they
land, in this same executed form. Transformations that need resolved types are
[codemods](../../../../specs/dmd-fmt/codemods.md), a separate tool.
