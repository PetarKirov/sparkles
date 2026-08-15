/**
SDL's out-of-band error channel, lifted into $(REF Expected, expected).

SDL3 reports failure by returning `false` or `NULL` and leaving a message in a
thread-local slot that the next SDL call may overwrite. The message is
therefore only valid immediately, and only if you remember to read it — which
makes it exactly the kind of error that gets dropped.

$(LREF sdlError) captures it at the point of failure, and the `check*` helpers
turn SDL's two failure shapes into an `Expected` the caller cannot ignore
silently.
*/
module sparkles.ui_sdl3.error;

import expected : Expected, err, ok;

import sparkles.ui_sdl3.c;

/// An operation that either produced a `T` or failed with SDL's message.
alias SdlExpected(T = void) = Expected!(T, string);

/**
SDL's current error message, copied out of its thread-local slot.

The copy matters: `SDL_GetError` returns a pointer SDL owns and may reuse on
the next call, so a borrowed slice would dangle exactly when it is finally
printed.
*/
string sdlError() @trusted nothrow
{
    import core.stdc.string : strlen;

    const msg = SDL_GetError();
    if (msg is null)
        return "unknown SDL error";

    const len = strlen(msg);
    if (len == 0)
        return "unknown SDL error";

    return msg[0 .. len].idup;
}

/// `ok` when `success`, otherwise SDL's message prefixed by `what`.
SdlExpected!() check(bool success, string what) @safe nothrow
    => success ? ok!string() : err!void(what ~ ": " ~ sdlError());

/// `ok(handle)` when non-null, otherwise SDL's message prefixed by `what`.
SdlExpected!T checkPtr(T)(T handle, string what) @safe nothrow
    => handle !is null ? ok!string(handle) : err!T(what ~ ": " ~ sdlError());

@("ui_sdl3.error.checkMapsBothOutcomes")
@safe nothrow unittest
{
    // SDL is not initialised here, so only the shape is asserted — the
    // message content belongs to whatever SDL last did on this thread.
    assert(!check(true, "open").hasError);

    const failed = check(false, "open");
    assert(failed.hasError);
    // The `what:` prefix is what makes an SDL message locatable at all; the
    // messages themselves say things like "Parameter 'window' is invalid".
    assert(failed.error.length > "open: ".length);
    assert(failed.error[0 .. 6] == "open: ");
}

@("ui_sdl3.error.checkPtrCarriesTheHandle")
@safe nothrow unittest
{
    int value = 7;
    auto held = checkPtr(&value, "create");
    assert(!held.hasError);
    assert(*held.value == 7);

    assert(checkPtr(cast(int*) null, "create").hasError);
}
