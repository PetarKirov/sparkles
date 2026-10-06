# Borrowing, checking once, and leniency

## Faces borrow

A `Face` holds a slice of the caller's bytes and a few integers. Opening
copies nothing, and every table, name or glyph name the library returns is a
slice of those bytes, of storage the caller passed in, or of a static
standard table. That makes a memory-mapped file or an Android asset usable
without a copy, and it puts the lifetime in one place: the buffer outlives
everything read from it. `-preview=dip1000` checks this in `@safe` code.

## Checking happens once, in a value

A face never caches. Anything whose checking costs time proportional to a
table — a character map, a glyph-name index — is a separate value built by
an explicit call. Building it checks the data; using it does not check
again. That keeps every operation's cost visible at the call site and the
face itself immutable, so several threads can share it.

## Lenient where real fonts are wrong, never silent

Fonts in the wild are often slightly wrong, and HarfBuzz and FreeType
tolerate the common mistakes. So does this library: a `cmap` subtable runs to
the end of `cmap` whatever its `length` says, overlapping segments take
disjoint effective spans, and a broken subtable is skipped for the next
candidate. What it tolerates it reports: rejected subtables, mappings to
missing glyphs and unreadable list entries are counted or returned as errors,
because a font inspector exists to show exactly that damage.

## Hostile input

Every read is bounds-checked before it happens, and offset arithmetic cannot
wrap. A malformed font yields a `FontError`; it never reaches an assertion.
A seeded mutation corpus runs every public operation over thousands of
damaged fonts in the debug build and under AddressSanitizer.

## Independent checks

The library's answers are compared with HarfBuzz's over every bundled font by
the test-only `sparkles:font-oracle` package, which links HarfBuzz so that
`sparkles:font` itself never does. Where the library deliberately differs —
reading Mac Roman names that HarfBuzz reads as ASCII, for example — the
[parsing contracts](../../../specs/font/parsing.md#_7-oracles) list the
difference and what checks it instead.
