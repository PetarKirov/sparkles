# Run a chunked, paginated search

Freeze candidates in a `CandidateSnapshot`, configure one
`SearchAccumulator`, and carry the returned cursor between calls:

```d
CandidateView[100] candidates;
CandidateSnapshot corpus;
corpus.id.low = 7;
corpus.candidates = candidates[];

auto query = parseQuery("controller").value;
SearchAccumulator!32 results;
auto cursor = results.begin(corpus.id, 1, 1, 10, 20).value;
MatcherWorkspace!() matcher;
ConstraintWorkspace!() constraints;

SearchLimits work = SearchLimits(64, 16_384);
for (;;)
{
    auto step = searchChunk(query, corpus, cursor, work,
        results, matcher, constraints);
    assert(step.hasValue);
    cursor = step.value.cursor;
    if (step.value.stop == SearchStop.exhausted)
        break;
}

RankedResult[20] page;
auto count = results.page(page);
```

The accumulator keeps the global best `offset + limit`, so partial pages never
depend on chunk boundaries. Do not synthesize cursors: corpus ID, query
generation, sink epoch, offset, and accumulator revision are all validated.

For a frame budget, call `searchChunk` with one candidate at a time and compare
the host's monotonic clock between calls. Cancellation is also a host concern;
publish a new generation and discard any result whose generation is stale.

`newQuery.refines(oldQuery)` is only permission to reuse a **complete** retained
survivor set. If the host did not retain every admitted row from the examined
prefix—or its bounded survivor buffer filled—restart at corpus offset zero.
That fallback is required for global ranking correctness.
