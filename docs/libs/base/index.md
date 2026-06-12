# `sparkles:base`

`sparkles:base` is the shared foundation for Sparkles libraries: small
allocation-conscious buffers, recycled `Error` storage for `@nogc` code,
text readers/writers, terminal styling, styled Interpolated Expression
Sequences, and the core logging interface.

Use it when a package needs low-level building blocks without depending on
the higher-level `sparkles:core-cli` UI and argument-parsing modules.

```d
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.writers : writeIntegerPadded;

SmallBuffer!(char, 16) buf;
writeIntegerPadded(buf, 7, 3);
assert(buf[] == "007");
```

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
- [Test `@nogc` code with check helpers](./how-to/test-with-check-helpers.md)

### Reference

_Information-oriented._ Lookup material for modules and symbols.

- [API index](./reference/api.md)

### Explanation

_Understanding-oriented._ Why `base` exists as a separate package.

- [The design](./explanation/design.md)
