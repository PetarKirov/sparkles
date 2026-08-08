# Callouts

> [!NOTE]
> A note callout with `inline code` and **bold** text.

> [!TIP]
> A tip callout.

> [!IMPORTANT]
> An important callout spanning
> two source lines.

> [!WARNING]
> A warning callout.

> [!CAUTION]
> A caution callout.

> [!NOTE]
> A callout with more structure:
>
> - a list inside
> - another item
>
> ```d
> auto x = 1; // a fence inside a callout
> ```

Plain quotes:

> A plain block quote with no marker — just prose with `inline code`,
> **bold**, *italic*, ~~struck~~, and a [link](https://example.com).

> Depth one
>
> > Depth two
> >
> > > Depth three
> > >
> > > > Depth four
> > > >
> > > > > Depth five
> > > > >
> > > > > > Depth six

> Outer quote — depth one, with structure throughout.
>
> - unordered at depth one
>   - nested bullet
>   - another nested bullet with `code`
> - back to depth one, **bold** item
>
> 1. ordered at depth one
> 2. second ordinal with *emphasis*
>    1. nested ordinal
>    2. deeper ordinal with ~~struck~~ text
>       - bullet under nested ordinal
>       - and another
>
> > Nested quote, depth two — holds mixed lists and a fence:
> >
> > - bullet inside depth-two quote
> >   1. ordinal under that bullet
> >   2. with **bold** and `inline`
> > - sibling bullet at depth two
> >
> > ```d
> > // fence at quote depth two
> > auto nested = true;
> > ```
> >
> > > Depth three — more structure still:
> > >
> > > 1. ordinal at depth three
> > >    - bullet under it
> > >      1. ordinal under the bullet
> > >    - sibling bullet with *italic*
> > > 2. second ordinal at depth three
> > >
> > > > Depth four — styles, a task list, and a code group:
> > > >
> > > > Prose at the deepest level: **bold**, *italic*, `code`,
> > > > ~~struck~~, and a [link](https://example.com/deep).
> > > >
> > > > - [ ] unchecked task at depth four
> > > > - [x] checked task at depth four
> > > >   - [ ] nested unchecked under a checked task
> > > >
> > > > ::: code-group
> > > >
> > > > ```d [quote.d]
> > > > void deep()
> > > > {
> > > >     import std.stdio : writeln;
> > > >     writeln("quoted");
> > > > }
> > > > ```
> > > >
> > > > ```console [run]
> > > > $ dub run
> > > > quoted
> > > > ```
> > > >
> > > > :::
>
> Closing paragraph back at depth one after the nest.
