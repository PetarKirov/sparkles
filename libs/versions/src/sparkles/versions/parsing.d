/**
Parsing vocabulary for the version schemes.

The error vocabulary is generic and lives in
$(REF_MOD sparkles,core_cli,text,errors) — it is reused by every core_cli
text parser, not just versions. This module re-exports those types and adds
the versions-specific $(LREF ParseMode) selector.

See `docs/specs/versions/SPEC.md` §7.
*/
module sparkles.versions.parsing;

public import sparkles.base.text.errors :
    NoGcHook,
    ParseError,
    ParseErrorCode,
    ParseExpected,
    parseErr,
    parseOk;

/**
Strict / loose selector for schemes that route both behaviours through one
entry point.

Most schemes expose the discoverable, capability-gated `parseLoose` form
instead; `ParseMode` is for internal parsers that share one code path
between the two behaviours.
*/
enum ParseMode
{
    /// Accept only the scheme's canonical syntax.
    strict,

    /// Additionally accept common compatibility forms: a leading `v`,
    /// missing trailing components (zero-filled), and leading zeroes where
    /// the strict grammar would otherwise reject them.
    loose,
}

@("parsing.ParseMode.members")
@safe pure nothrow @nogc
unittest
{
    static assert(ParseMode.strict != ParseMode.loose);
}

@("parsing.reexports.available")
@safe pure nothrow @nogc
unittest
{
    // The re-exported parse vocabulary is usable directly from this module.
    ParseExpected!int good = parseOk(7);
    assert(good.hasValue);
    assert(good.value == 7);

    ParseExpected!int bad = parseErr!int(ParseErrorCode.emptyInput, 0);
    assert(!bad.hasValue);
    assert(bad.error.code == ParseErrorCode.emptyInput);
}
