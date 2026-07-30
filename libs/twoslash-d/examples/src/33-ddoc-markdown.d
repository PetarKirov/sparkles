module sample;
// ---cut---
// NB: a GFM table does not survive the translator (delimiter row dropped,
// body rows blank-line separated), so this stops at the constructs below.
/++
# Retry policy

Retries happen on:

- connection resets
- *transient* DNS failures

Escalate to **operations** after three attempts, per the
[backoff guide](https://dlang.org).
+/
enum maxAttempts = 3;
//   ^?
