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
// resolveSource borrows each selected script's original immutable snapshot;
// selectScript optionally projects the artifact before source resolution.
auto parsed = loadCoverage(path, contents, resolveSource, selectScript);
if (!parsed)
{
    warning(i"coverage artifact $(path) could not be used: "
        ~ i"$(parsed.error.code) at offset $(parsed.error.offset): $(parsed.error.context)");
    return;                     // the document renders without a gutter
}
```

For textual record errors, `error.offset` is a byte offset into the artifact,
pointing at the offending character rather than the containing record —
`DA:1,3,f1ab29d0` reports the `f`, not the `D`. Do not assume every V8 error
uses that coordinate system: malformed snapshot errors identify a byte in
the original source, and invalid producer ranges use offset zero because
the JSON codec does not retain token positions. Their `error.context`
identifies the script and offending UTF-16 offset. Resolver errors are
propagated as supplied by the caller.

## Untrusted offsets

V8 carries **UTF-16 code-unit offsets**, not source byte offsets. Its artifact
does not contain the original source. Supply a resolver returning a borrowed
`const(char)[]` snapshot for each selected normalized script path; keep that
snapshot alive and unchanged throughout parsing. Use the optional selector
to exclude unrelated scripts **before** resolution, rather than returning
fake sources for them. Without a selector every script requires its own
snapshot; missing sources are errors, not empty-file fallbacks.

The parser maps exact scalar boundaries to original UTF-8 byte spans. In
`"A😀\n界B\n"`, the producer range `[4, 6)` becomes bytes `[6, 10)`.
Offset 2 lies inside `😀`'s surrogate pair and is rejected with
`invalidSurrogate`; offsets beyond the source reject with `unexpectedEnd`,
and inverted ranges with `unexpectedCharacter`. Malformed UTF-8 anywhere
in the snapshot (even an uncovered suffix) rejects with `invalidUtf8`;
mapping or `TextSpan` capacity overflow rejects with `numericOverflow`.
No invalid range is skipped or clamped.

A rebuilt snapshot is not a valid substitute: bounds checks cannot detect
every stale artifact whose offsets happen to remain valid. Preserve the
producer's original source identity yourself. See the
[API reference](../reference/api.md#v8-source-snapshots-and-script-selection)
for multi-script resolution and explicit single-script projection.

If you construct a `TextSpan` from offsets you did not produce yourself, use
`TextSpan.of`, which yields the invalid sentinel for an inverted range
instead of a value whose `invariant` fires at some later accessor.

## What is not an error

Unknown record types are skipped, not rejected. LCOV's `TN`, `LF`, `LH`,
`BRF`, `BRH`, `FNF` and `FNH` are all derived totals that this library
recomputes, and gcov's `function …` and `call …` annotations carry nothing
the model represents. A future record type appearing in a tracefile will not
break an existing parse.
