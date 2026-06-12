# The design

`sparkles:base` exists to keep low-level, allocation-conscious utilities
available without pulling in the full `sparkles:core-cli` surface.

Before the split, version parsing, process utilities, pretty printing,
logging, terminal styling, and UI components all shared one package. That
made `sparkles:versions` depend on a CLI package just to reuse
`SmallBuffer` and text parsing primitives. `base` is the smaller layer:
mechanism without application-level policy.

## What belongs in `base`

The package holds utilities that are useful across Sparkles libraries and
do not need `core-cli` UI concepts:

- stack-first output storage via `SmallBuffer`;
- recycled object storage for rare `@nogc` throw paths;
- low-level text readers and writers;
- ANSI style values and styled IES rendering;
- the core logging interface.

Higher-level CLI concerns stay in `sparkles:core-cli`: argument parsing,
help formatting, terminal-size handling, pretty printing, source-URI
links, and UI components.

## Why logging is here

Logging is a cross-cutting primitive. `CoreLogger` derives from
`std.logger.Logger` so existing Phobos integrations still work, but the
Sparkles wrappers route through `sharedCoreLog` and write styled IES into
caller-owned buffers. That gives internal code a `@safe nothrow @nogc`
path without changing what `std.logger.log` means.

`fatal` uses a handler hook instead of hardcoding process termination.
The default throws a recycled `FatalLogError`; alternatives assert or
abort. This keeps the caller-side API `nothrow` while making fatal policy
explicit.

## Why styling moved too

The text writers expose style-aware rendering helpers, and the logger
needs styled IES rendering on its hot path. Moving only `SmallBuffer` and
text readers would either leave a package cycle or force duplicated style
logic. `term_style` and `styled_template` therefore move with the base
dependency closure.
