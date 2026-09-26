# test-utils

`sparkles:test-utils` provides helpers used by unit tests and fixture-driven test code.

## Scope

- Temporary filesystem helpers
- Diff output helpers
- String helpers such as indentation stripping

## Package

Add the library as a `dub` dependency:

```sdl
dependency "sparkles:test-utils" version="*"
```

## Source Layout

- `libs/test-utils/src/sparkles/test_utils/package.d` - package exports
- `libs/test-utils/src/sparkles/test_utils/diff_tools.d` - diff tooling wrappers
- `libs/test-utils/src/sparkles/test_utils/tmpfs.d` - temporary filesystem support
- `libs/test-utils/src/sparkles/test_utils/string.d` - string helpers
