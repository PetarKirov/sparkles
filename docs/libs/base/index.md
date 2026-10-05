# `sparkles:base`

`sparkles:base` is the shared foundation for Sparkles libraries: small
allocation-conscious buffers, recycled `Error` storage for `@nogc` code,
text readers/writers, owned Unicode 18 codecs and text algorithms, terminal
styling, styled Interpolated Expression Sequences, and the core logging interface.

Use it when a package needs low-level building blocks without depending on
the higher-level `sparkles:core-cli` UI and argument-parsing modules.

```d
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.writers : writeIntegerPadded;

UniqueBuffer!(char, 16) buf;
writeIntegerPadded(buf, 7, 3);
assert(buf[] == "007");
```

Owned text APIs include unlimited whole-grapheme segmentation, explicit terminal
cell policy, word/sentence/line boundaries, whole-paragraph bidi, normalization,
contextual casing and typed source maps. Their `@nogc` cores use caller-owned
arenas with explicit capacity failures and borrowed-view lifetimes; unlimited
Unicode context does not mean unlimited caller storage. Import specialized
modules directly as described in the [API index](./reference/api.md).

## How this documentation is organised

These docs follow the [Diátaxis](https://diataxis.fr/) framework.

### [Tutorial](./tutorial/getting-started.md)

_Learning-oriented._ Build one small program using the buffer, text writer,
styled text, and logger primitives.

- [Getting started](./tutorial/getting-started.md)

### How-to guides

_Task-oriented._ Short recipes for common jobs.

- [Log through `CoreLogger`](./how-to/log-with-core-logger.md)
- [Write `@nogc` text](./how-to/write-nogc-text.md)
- [Style templates with IES](./how-to/style-text-templates.md)
- [Pretty-print values](./how-to/prettyprint-values.md)
- [Parse text with readers](./how-to/parse-text-readers.md)
- [Analyze Unicode text without allocation](./how-to/analyze-unicode-text.md)
- [Own a heap value without the collector](./how-to/own-heap-values.md)
- [Test `@nogc` code with check helpers](./how-to/test-with-check-helpers.md)

### Reference

_Information-oriented._ Lookup material for modules and symbols.

- [API index](./reference/api.md)
- [Base codecs](./reference/base-codecs.md)
- [Percent-encoding](./reference/percent-encoding.md)
- [Unicode analysis](./reference/unicode-analysis.md)

### Explanation

_Understanding-oriented._ Why `base` exists as a separate package.

- [The design](./explanation/design.md)
- [Buffers: storage as capabilities](./explanation/buffer.md)
- [Base codecs: design notes](./explanation/base-codecs.md)
