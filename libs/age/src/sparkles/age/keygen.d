/**
Key-pair generation for the `age-keygen` workflow: $(LREF generateKey) and
$(LREF formatRecipient).

This is the small text layer that `age-keygen` and `age -y`-style tooling build
on. It does not introduce any new cryptography — it draws a fresh
$(REF X25519Identity, sparkles,age,recipients,x25519) from the OS CSPRNG and
renders it (and its public recipient) in the canonical, human-readable identity
file format that every age implementation agrees on:

```
# created: <RFC 3339 timestamp, seconds precision>
# public key: age1…
AGE-SECRET-KEY-1…
```

$(UL
    $(LI $(LREF generateKey) writes a complete three-line identity file: a
        `# created:` comment carrying the current local time
        ([std.datetime.systime.Clock.currTime] rendered with
        [std.datetime.systime.SysTime.toISOExtString], truncated to whole
        seconds), a `# public key:` comment carrying the `age1…` recipient, and
        the secret `AGE-SECRET-KEY-1…` line itself.)
    $(LI $(LREF formatRecipient) writes just the bare `age1…` recipient string for
        a given $(REF X25519Recipient, sparkles,age,recipients,x25519) — the
        building block used both for the `# public key:` comment line above and
        for emitting a stand-alone recipients file.)
)

This is a faithful port of rage's `rage-keygen` `generate` path
(`rage/src/bin/rage-keygen/main.rs`): `Identity::generate()`, then
`writeln!("# created: {}", Local::now().to_rfc3339_opts(Secs, true))`,
`writeln!("# public key: {}", pk)`, `writeln!("{}", sk)`.

Conventions: `@safe`; this layer MAY use the GC (the timestamp string from
`toISOExtString`). Output goes to a caller-provided text output range, so the
caller chooses the sink (an `Appender!string`, a
[smallbuffer.SmallBuffer]`!(char, …)`, a file writer, …).

See `docs/specs/age/SPEC.md` §8 and `https://c2sp.org/age`.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
*/
module sparkles.age.keygen;

import std.range.primitives : isOutputRange, put;

import sparkles.age.recipients.x25519 : X25519Identity, X25519Recipient;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// Identity-file labels (rage's localized `identity-file-created` /
// `identity-file-pubkey` strings, en-US)
// ─────────────────────────────────────────────────────────────────────────────

/// The `# created: …` comment prefix that opens a generated identity file.
private enum string CREATED_PREFIX = "# created: ";

/// The `# public key: …` comment prefix carrying the file's `age1…` recipient.
private enum string PUBLIC_KEY_PREFIX = "# public key: ";

// ─────────────────────────────────────────────────────────────────────────────
// generateKey
// ─────────────────────────────────────────────────────────────────────────────

/**
Generates a fresh X25519 key pair and writes a complete age identity file into
the text output range `w`.

Draws a new $(REF X25519Identity, sparkles,age,recipients,x25519) from the OS
CSPRNG, then writes exactly three newline-terminated lines:

```
# created: <RFC 3339, seconds precision>
# public key: age1…
AGE-SECRET-KEY-1…
```

The `# created:` timestamp is the current local time
([std.datetime.systime.Clock.currTime]) rendered via
[std.datetime.systime.SysTime.toISOExtString] with its fractional-seconds
component cleared, so the value has whole-second precision (e.g.
`2026-06-02T20:10:23+02:00`) — matching rage's
`Local::now().to_rfc3339_opts(SecondsFormat::Secs, true)`.

Faithful port of rage's `rage-keygen` `generate`.

Params:
    w = a text output range (accepts `const(char)[]` / `char`) that receives the
        three identity-file lines
*/
void generateKey(W)(ref W w)
if (isOutputRange!(W, const(char)[]))
{
    import std.datetime.systime : Clock, SysTime;
    import core.time : Duration;

    const identity = X25519Identity.generate();

    // 1) "# created: <RFC 3339 timestamp, seconds precision>\n"
    SysTime now = Clock.currTime();
    now.fracSecs = Duration.zero; // truncate to whole seconds (rage: Secs)
    put(w, CREATED_PREFIX);
    put(w, now.toISOExtString());
    put(w, '\n');

    // 2) "# public key: age1…\n"
    put(w, PUBLIC_KEY_PREFIX);
    formatRecipient(w, identity.toPublic());
    put(w, '\n');

    // 3) "AGE-SECRET-KEY-1…\n"
    identity.toString(w);
    put(w, '\n');
}

// ─────────────────────────────────────────────────────────────────────────────
// formatRecipient
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes the bare canonical `age1…` recipient string for `r` into the text output
range `w` (no trailing newline).

This is the building block both for the `# public key:` line in
$(LREF generateKey) and for emitting a stand-alone recipients file (one `age1…`
per line). It simply forwards to
$(REF X25519Recipient.toString, sparkles,age,recipients,x25519).

Params:
    w = a text output range (accepts `const(char)[]` / `char`)
    r = the recipient to render
*/
void formatRecipient(W)(ref W w, in X25519Recipient r)
if (isOutputRange!(W, const(char)[]))
{
    r.toString(w);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

/// $(LREF generateKey) writes the three expected lines: a `# created:` comment,
/// a `# public key: age1…` comment whose recipient parses back via
/// $(REF X25519Recipient.parse, sparkles,age,recipients,x25519), and an
/// `AGE-SECRET-KEY-1…` line whose identity parses back via
/// $(REF X25519Identity.parse, sparkles,age,recipients,x25519) — and the parsed
/// identity's `toPublic()` equals the parsed recipient.
@("age.keygen.generateKey.threeLinesRoundTrip")
@safe
unittest
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;
    import std.array : appender, array;

    auto w = appender!string;
    generateKey(w);

    // Three newline-terminated lines → splitting on '\n' yields the three lines
    // plus a trailing empty element (the text ends with '\n').
    auto lines = w[].splitter('\n').array;
    assert(lines.length == 4, "generateKey must write exactly three lines");
    assert(lines[3].length == 0, "the file must end with a trailing newline");

    // Line 0: the "# created: …" comment.
    assert(lines[0].startsWith(CREATED_PREFIX),
        "line 1 must be the '# created:' comment");
    assert(lines[0].length > CREATED_PREFIX.length,
        "the '# created:' comment must carry a timestamp");

    // Line 1: the "# public key: age1…" comment — strip the prefix and parse.
    assert(lines[1].startsWith(PUBLIC_KEY_PREFIX),
        "line 2 must be the '# public key:' comment");
    const pkString = lines[1][PUBLIC_KEY_PREFIX.length .. $];
    auto parsedRecipient = X25519Recipient.parse(pkString);
    assert(parsedRecipient.hasValue, "the '# public key:' line must parse as age1…");

    // Line 2: the bare "AGE-SECRET-KEY-1…" identity.
    X25519Identity parsedIdentity;
    auto idStatus = X25519Identity.parse(lines[2], parsedIdentity);
    assert(!idStatus.hasError, "the secret-key line must parse as AGE-SECRET-KEY-1…");

    // The parsed identity's public key must equal the parsed recipient.
    assert(parsedIdentity.toPublic().publicKey == parsedRecipient.value.publicKey,
        "the secret key's public key must equal the printed recipient");
}

/// $(LREF formatRecipient) writes exactly the recipient's canonical `age1…`
/// string (no newline), identical to the recipient's own `toString`.
@("age.keygen.formatRecipient.matchesToString")
@safe
unittest
{
    import std.array : appender;

    auto id = X25519Identity.generate();
    const recipient = id.toPublic();

    // formatRecipient and the recipient's toString must agree byte-for-byte.
    auto a = appender!string;
    formatRecipient(a, recipient);

    auto b = appender!string;
    recipient.toString(b);

    assert(a[] == b[], "formatRecipient must match X25519Recipient.toString");
    assert(a[].length > 0 && a[][0 .. 4] == "age1",
        "formatRecipient must emit a bare age1… string");
    // It must round-trip back through parse to the same public key.
    auto reparsed = X25519Recipient.parse(a[]);
    assert(reparsed.hasValue);
    assert(reparsed.value.publicKey == recipient.publicKey);
}
