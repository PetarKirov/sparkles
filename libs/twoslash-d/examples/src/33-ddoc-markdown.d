module sample;
// ---cut---
/++
# Retry policy

Retries happen on:

- connection resets
- *transient* DNS failures

Escalate to **operations** after three attempts, per the
[backoff guide](https://dlang.org).

The backoff schedule, in order:

1. wait one second
2. wait four seconds
    - jittered, so a fleet does not retry in lockstep
3. give up

| Attempt | Delay | Outcome |
| :------ | ----: | :-----: |
| first | 1s | retry |
| second | 4s | retry |
| third | — | fail |
+/
enum maxAttempts = 3;
//   ^?
