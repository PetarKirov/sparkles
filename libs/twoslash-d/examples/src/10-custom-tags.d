module sample;
// ---cut---
enum retries = 3;
// @annotate: tuned against the flaky CI runner
enum backoffMs = 250;
// @log: retry budget = 750 ms
enum budgetMs = retries * backoffMs;
//   ^?
// @warn: raising this delays the whole suite
enum ceilingMs = 5_000;
// @error: never ship a zero ceiling
