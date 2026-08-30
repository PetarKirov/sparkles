/**
Shared helpers for the DQL integration test modules: parse a query against a
reflected schema and evaluate it in one call, so every test spells the
common parse-assert-eval sequence the same way.
*/
module sparkles.dql.testing;

version (unittest):

import core.exception : AssertError;

import sparkles.base.lifetime : recycledErrorInstance;
import sparkles.dql.engine : DqlEngine;
import sparkles.dql.eval : evalDql;
import sparkles.dql.parser : parseDql;

/// Throws a recycled `AssertError`. `@trusted` because
/// `recycledErrorInstance` is `@system` (it parks the Error in a static
/// buffer) — the same seam `sparkles.versions.testing` uses.
private void throwAssert(in char[] msg) @trusted pure nothrow @nogc
{
    throw recycledErrorInstance!AssertError(msg);
}

/// Parses `query` against `Schema` — throwing the parse error as an
/// `AssertError` — and evaluates it against `subject`.
bool parseAndEvalDql(Schema)(ref DqlEngine engine, scope const(char)[] query,
    ref const Schema.Subject subject) @safe
{
    auto parsed = parseDql!Schema(engine, query);
    if (parsed.hasError)
        throwAssert(parsed.error.message);
    return evalDql!Schema(engine, parsed.value, subject);
}
