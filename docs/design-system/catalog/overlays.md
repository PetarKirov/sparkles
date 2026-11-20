# Overlays

_anchored, out of flow, on top._ The `ui-gallery` page **Overlays**, painted with no terminal and no window
at each of the [documented profiles](../index.md#profiles):

```bash
ui-gallery --render --page overlays --profile full|enhanced|baseline
```

::: code-group

<<< @/../apps/ui-gallery/test/data/profiles/overlays/full.ansi{ansi} [full]

<<< @/../apps/ui-gallery/test/data/profiles/overlays/enhanced.ansi{ansi} [enhanced]

<<< @/../apps/ui-gallery/test/data/profiles/overlays/baseline.ansi{ansi} [baseline]

:::

## What each profile gives up

The frame's [degradation report](../index.md#the-degradation-report): one line
per substitution, and the capability the target lacked. `full` is empty when
the page asks for nothing a terminal cannot do.

::: code-group

<<< @/../apps/ui-gallery/test/data/profiles/overlays/full.report{text} [full]

<<< @/../apps/ui-gallery/test/data/profiles/overlays/enhanced.report{text} [enhanced]

<<< @/../apps/ui-gallery/test/data/profiles/overlays/baseline.report{text} [baseline]

:::

These are the files `dub test :ui-gallery` compares every render against, so
a change to this page that is not re-blessed fails CI.

## A click past the pane

The files pane's menu is wider than the pane and hangs over the divider into
the preview. The page tells the dock where the menu painted, so a click on the
part over the preview goes to the files pane and the item under it
([anchored overlays](../../specs/ui/popup.md) `LYR5`). This is that frame
after one click on `duplicate`, right of the divider:

```bash
ui-gallery --render-plain --page overlays --window-width 100 --window-height 34 --clicks 42,15
```

<<< @/../apps/ui-gallery/test/data/profiles/overlays/click-past-the-pane.txt{text}
