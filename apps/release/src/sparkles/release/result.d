/++
A tiny `Expected`-based result type for the tool's IO layer: either a value or a
human-readable error message. The pure-logic modules use plain returns/`Nullable`;
the IO modules (`git.d`, `agents.d`, `notes.d`, `preflight.d`) report failures as
`Result!T` so `app.d` can render the message and choose an exit code.
+/
module sparkles.release.result;

import expected : Expected, ok, err;

/// Either a `T` or an error message.
alias Result(T) = Expected!(T, string);

/// A successful result carrying `value`.
Result!T success(T)(T value) => ok!string(value);

/// ditto — success with no payload. (Explicitly attributed: as a non-template it
/// cannot infer them.)
Result!void success() @safe pure nothrow => ok!string();

/// A failed result carrying `message`.
Result!T failure(T)(string message) => err!T(message);

@("result.successAndFailure")
@safe unittest
{
    auto good = success(42);
    assert(good.hasValue);
    assert(good.value == 42);

    auto bad = failure!int("nope");
    assert(bad.hasError);
    assert(bad.error == "nope");
}
