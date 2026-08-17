# Handle parse failures

Every entry point returns
[`ParseExpected`](https://tchaloupka.github.io/expected/expected.Expected.html)
— the repository's parse-error vocabulary from
`sparkles.base.text.errors` — rather than an empty report. That is what lets
a caller tell four different situations apart:

| Situation                          | Result                                      |
| ---------------------------------- | ------------------------------------------- |
| Not a coverage format at all       | `error.code == ParseErrorCode.unknownValue` |
| Malformed record                   | `unexpectedCharacter` / `unexpectedEnd`     |
| A count too large for `ulong`      | `numericOverflow`                           |
| A valid report describing no files | success, with an empty `files`              |

The last row is the reason this matters: an empty report is a legitimate
answer, so it cannot double as the failure signal.

## Degrade, do not fail

A coverage overlay is a decoration. If the artifact is stale, truncated or
simply not what the user thought it was, the right response is to say so and
render the file plainly — never to take the view down with it:

```d
auto parsed = loadCoverage(path, contents, source);
if (!parsed)
{
    warning(i"coverage artifact $(path) did not parse at byte "
        ~ i"$(parsed.error.offset): $(parsed.error.context)");
    return;                     // the document renders without a gutter
}
```

`error.offset` is a byte offset into the artifact you passed in, pointing at
the offending character rather than at the record containing it — so
`DA:1,3,f1ab29d0` reports the `f`, not the `D`.

## Untrusted offsets

The V8 format carries byte offsets into a source file the report does not
contain. If you hand `parseV8Coverage` a source that has since been rebuilt,
the offsets will not match. Those ranges are skipped rather than trusted, so
a mismatched pair degrades to "no span" instead of an out-of-range read.

If you construct a `TextSpan` from offsets you did not produce yourself, use
`TextSpan.of`, which yields the invalid sentinel for an inverted range
instead of a value whose `invariant` fires at some later accessor.

## What is not an error

Unknown record types are skipped, not rejected. LCOV's `TN`, `LF`, `LH`,
`BRF`, `BRH`, `FNF` and `FNH` are all derived totals that this library
recomputes, and gcov's `function …` and `call …` annotations carry nothing
the model represents. A future record type appearing in a tracefile will not
break an existing parse.
