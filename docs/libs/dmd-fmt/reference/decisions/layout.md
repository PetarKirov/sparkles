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

If you leave a trailing comma after the last element of a list you wrote on one line, the list is
exploded — one element per line — even though it would fit. It is the one-bit instruction you give
the formatter about a list you intend to keep editing.

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

### On a list you already broke, the comma means _stay_ broken {#m4-authored}

<!-- fmt id=M4 -->

One element per line is what a flat list becomes, not what every list becomes. Where you have
already broken the list yourself, that shape _is_ the answer to the question the trailing comma
asks, so the formatter keeps it: a table packed several values to the row stays packed, and the
comma still pins it against being folded back onto one line.

::: code-group

```d [Before]
immutable kernel = [
    1, 2, 1,
        2, 4, 2,
  1, 2, 1,
];
```

```d [After]
immutable kernel = [
    1, 2, 1,
    2, 4, 2,
    1, 2, 1,
];
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

## Orphans

### A stray `;`, `,` or closer rejoins what it belongs to {#d10}

<!-- fmt id=D10 -->

Your line breaks are yours, with three exceptions.

A `;` or `,` that starts a line **moves up to the end of the line above** — both terminate what
precedes them, and D writes the comma at the end of an element rather than the start of the next.
The break moves with it, so a list written one-per-line stays one-per-line; only the commas change
ends.

A closing `)`, `]` or struct-initializer `}` **under contents that never broke** rejoins them: the
break there is a leftover, not a shape.

When the contents _do_ break, the closer on its own line is the exploded shape and stays exactly
where you put it — that is the next case. A statement block's `}` is never an orphan: a block
spread over more than one line gets its closer on a line of its own, even where you left it beside
a statement.

::: code-group

```d [Before]
void save(Config config)
{
    write(config.path
        )
        ;
    auto flags = [
          readable
        , writable
    ];
}
```

```d [After]
void save(Config config)
{
    write(config.path);
    auto flags = [
        readable,
        writable
    ];
}
```

:::

### …but a closer under contents that broke keeps its line {#d10-exploded}

<!-- fmt id=D10 -->

The same `]` in the exploded shape is not an orphan: the contents broke, so the closer at the
construct's own column is the point of the layout. This is the pair to read together — one rule,
and the thing that decides which side of it you are on is whether the contents broke.

::: code-group

```d [Before]
auto flags = [
readable,
writable,
];
S defaults = {
retries: 3,
timeout: 30,
};
```

```d [After]
auto flags = [
    readable,
    writable,
];
S defaults = {
    retries: 3,
    timeout: 30,
};
```

:::

---

## D idioms

### `static foreach`'s double braces stay touching {#d11}

<!-- fmt id=D11 -->

<div v-pre>

`{{ … }}` gives each iteration of a `static foreach` its own scope, and the two braces touch. The
formatter leaves them touching, because it never inserts a space you did not write — the same rule
that leaves `a+b` alone, and that keeps a hand-aligned table literal aligned.

</div>

Runs of spaces still collapse to one, and indentation is still recomputed. What is preserved is the
_absence_ of a space, which in D is often the shape of an idiom rather than an oversight.

::: code-group

```d [Before]
void describe(Args...)(Args args)
{
static foreach (arg; args)
{{
alias T = typeof(arg);
enum name = __traits(identifier, T);
record(name);
}}
}
```

```d [After]
void describe(Args...)(Args args)
{
    static foreach (arg; args)
    {{
        alias T = typeof(arg);
        enum name = __traits(identifier, T);
        record(name);
    }}
}
```

:::

---

### One-line headers stay on one line {#d12}

<!-- fmt id=D12 -->

`switch (kind) with (TOK)` is how D gets `case` labels without the enum prefix, and the whole
point of it is that the two headers share a line. The formatter leaves them there — along with
`with (E) final switch (…)`, `foreach (…) with (x)`, `with (a) with (b)`, and a one-line
`with (e) stmt;`.

That is not a special case in the engine so much as the author's-breaks policy doing its job: a
survey of ~460 `with` statements across dmd, phobos, ldc, mir and arsd found 155 written as a
joined header and 3 split across lines. The shape you write is the shape you get back.

When sibling `with`s _are_ split over a block they share one level, which is what the real-world
instances do — they scope the same block rather than nesting inside one another. Every other chain
indents per header, because there the inner one really is the outer one's body.

::: code-group

```d [Before]
void render(TOK kind)
{
switch (kind) with (TOK)
{
case identifier:
emit();
break;
default:
}

with (config)
with (theme)
{
apply();
}
}
```

```d [After]
void render(TOK kind)
{
    switch (kind) with (TOK)
    {
        case identifier:
            emit();
            break;
        default:
    }

    with (config)
    with (theme)
    {
        apply();
    }
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
