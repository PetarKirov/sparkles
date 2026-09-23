# markdown

`sparkles:markdown` is the repository's Markdown parser and renderer subpackage.

## Scope

- Profile-aware parsing with a CommonMark-first baseline
- Feature flags for Markdown dialect extensions
- Rendering support
- Shared testing helpers in `sparkles.markdown.testing`

## Package

Add the library as a `dub` dependency:

```sdl
dependency "sparkles:markdown" version="*"
```

## Source Layout

- `libs/markdown/src/sparkles/markdown/package.d` - parser, renderer, options, and profiles
- `libs/markdown/src/sparkles/markdown/testing.d` - conformance and compatibility testing helpers
- `libs/markdown/examples/` - runnable examples
- `libs/markdown/tests/` - fixture corpora and test runners
- `docs/specs/markdown/` - parser and testing specs for this library

## Related Docs

- [Markdown specs](/specs/markdown/)
