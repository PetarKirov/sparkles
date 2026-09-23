# Components

_the application chrome._ The `ui-gallery` page **Components**, painted with no terminal and no window
at each of the [documented profiles](../index.md#profiles):

```bash
ui-gallery --render --page components --profile full|enhanced|baseline
```

::: code-group

<<< @/../apps/ui-gallery/test/data/profiles/components/full.ansi{ansi} [full]

<<< @/../apps/ui-gallery/test/data/profiles/components/enhanced.ansi{ansi} [enhanced]

<<< @/../apps/ui-gallery/test/data/profiles/components/baseline.ansi{ansi} [baseline]

:::

## What each profile gives up

The frame's [degradation report](../index.md#the-degradation-report): one line
per substitution, and the capability the target lacked. `full` is empty when
the page asks for nothing a terminal cannot do.

::: code-group

<<< @/../apps/ui-gallery/test/data/profiles/components/full.report{text} [full]

<<< @/../apps/ui-gallery/test/data/profiles/components/enhanced.report{text} [enhanced]

<<< @/../apps/ui-gallery/test/data/profiles/components/baseline.report{text} [baseline]

:::

These are the files `dub test :ui-gallery` compares every render against, so
a change to this page that is not re-blessed fails CI.
