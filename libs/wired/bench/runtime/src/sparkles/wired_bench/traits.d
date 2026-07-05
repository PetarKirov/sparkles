/**
Capability traits of benchmark engine adapters.

Centralized design-by-introspection detection (one expression-exact trait per
optional primitive, following the repo's DbI guidelines): the harness core
keys every op off these traits, so an engine that lacks a capability simply
has no row for it — never a compile error.
*/
module sparkles.wired_bench.traits;

import sparkles.wired_bench.fingerprint : Fingerprint;

/// The required engine surface: a display/filter name, a full parse of
/// immutable input (any engine-required copy or padding happens inside — the
/// honest immutable-input contract), and a structural fingerprint of the
/// engine's own parsed document (used for cross-engine verification only,
/// never timed).
enum bool isJsonEngine(E) = __traits(compiles, {
    E e;
    string n = E.name;
    e.parse((const(char)[]).init);
    Fingerprint f = e.fingerprint();
});

/// Optional one-time context creation, untimed (FFI engines allocate their
/// reusable parser state here).
enum bool hasSetup(E) = __traits(compiles, { E e; e.setup(); });

/// Optional deterministic context teardown, untimed.
enum bool hasTeardown(E) = __traits(compiles, { E e; e.teardown(); });

/// Optional document release, called untimed between parse iterations.
enum bool hasFreeDoc(E) = __traits(compiles, { E e; e.freeDoc(); });

/// Optional serialize: the held document rendered as minified JSON. The
/// returned buffer is engine-owned and valid until the next call.
enum bool hasSerialize(E) = __traits(compiles, {
    E e;
    const(char)[] s = e.serialize();
});

/// Optional destructive in-situ parse variant (the engine's scratch copy of
/// the input is made inside the timed region).
enum bool hasParseInsitu(E) = __traits(compiles, {
    E e;
    e.parseInsitu((const(char)[]).init);
});

/// Optional validate: full-input well-formedness check materializing nothing.
enum bool hasValidate(E) = __traits(compiles, {
    E e;
    e.validate((const(char)[]).init);
});

/// Optional caveat string shown in the report's notes column.
enum bool hasNotes(E) = __traits(compiles, { string s = E.notes; });

@("traits.isJsonEngine.detection")
@safe pure unittest
{
    static struct Good
    {
        enum name = "good";
        void parse(const(char)[]) {}
        Fingerprint fingerprint() => Fingerprint();
    }

    static struct NoFingerprint
    {
        enum name = "bad";
        void parse(const(char)[]) {}
    }

    static assert(isJsonEngine!Good);
    static assert(!isJsonEngine!NoFingerprint);
    static assert(!hasSerialize!Good && !hasParseInsitu!Good && !hasValidate!Good);
}

@("traits.optionalPrimitives.detection")
@safe pure unittest
{
    static struct Full
    {
        enum name = "full";
        enum notes = "a caveat";
        void setup() {}
        void teardown() {}
        void parse(const(char)[]) {}
        void parseInsitu(const(char)[]) {}
        void validate(const(char)[]) {}
        void freeDoc() {}
        const(char)[] serialize() => null;
        Fingerprint fingerprint() => Fingerprint();
    }

    static assert(isJsonEngine!Full);
    static assert(hasSetup!Full && hasTeardown!Full && hasFreeDoc!Full);
    static assert(hasSerialize!Full && hasParseInsitu!Full && hasValidate!Full);
    static assert(hasNotes!Full);
}
