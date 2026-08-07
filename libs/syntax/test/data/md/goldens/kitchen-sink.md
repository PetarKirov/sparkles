# Kitchen sink — everything composed

Audience: a fixture composing every feature the preview renders, modelled on
the repo's real specs. It has **bold**, *italic*, `inline code`, a
[link](https://example.com), and ~~struck~~ prose in one paragraph.

## Tables inside a section

| Module    | Role                                                  |
| --------- | ----------------------------------------------------- |
| `model.d` | the structural markdown model (`extractMarkdown`)     |
| `wrap.d`  | greedy line wrapping in cells — a *sparkles* extension |

> [!NOTE]
> A note directly under a table, holding `code`, **bold**, and a nested list:
>
> - one thing
> - another thing

## Lists, deeply composed

1. An ordered item with a nested fence:

   ```d
   auto x = 1;
   ```

2. An item with a nested table? No — but a nested quote:

   > quoted inside an ordered item

3. An item with nested mixed lists:
   - bullet child
     1. ordinal grandchild
     2. with a [link](https://example.com)
   - [x] a checked task child

---

## Code, grouped and labelled

::: code-group

```d [main.d]
void main()
{
    import std.stdio : writeln;
    writeln("composed");
}
```

```console [run]
$ dub run
composed
```

:::

### Trailing callout

> [!WARNING]
> The last block is a callout with a trailing fence:
>
> ```sh
> echo done
> ```
