# The DSV sample corpus

Real numbers about this repository, one file per feature axis of the DSV
preview / data browser ([spec](../../../../docs/specs/hue/dsv-preview.md)) —
dialects, typed columns, quoting, synthetic headers, width, scale, and the
tolerated defects. Generated **and verified** (sniff → parse → type
inference, read back through `sparkles:dsv`) by
[`tools/gen-dsv-corpus.d`](../../tools/gen-dsv-corpus.d):

```sh
dub run --single apps/hue/tools/gen-dsv-corpus.d
```

Try `hue view apps/hue/samples/dsv/files.csv`, then `/ext:d` to filter,
header clicks to sort, `Shift-C` for the columns palette.

The numbers are a snapshot of the tree that generated them; regenerate
whenever freshness matters.
