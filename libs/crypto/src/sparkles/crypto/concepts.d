/**
 * Compile-time cryptographic algorithm concepts and size aliases.
 *
 * Algorithm "tag" structs (e.g. a `ChaCha20Poly1305` or `Sha256` marker type)
 * expose their fixed sizes as compile-time `size_t` enum constants
 * (`KEY_SIZE`, `NONCE_SIZE`, `TAG_SIZE`, `OUTPUT_SIZE`). This module turns
 * those constants into fixed-size `ubyte[]` array aliases via $(D Key),
 * $(D Nonce), $(D Tag) and $(D Output), and provides the concept predicates
 * $(D isDigest), $(D isMac) and $(D isAead) standing in for RustCrypto's
 * `Digest`/`Mac`/`Aead` traits.
 *
 * Sizes are pure compile-time constants, not runtime values, so a caller can
 * stack-allocate exactly the right buffer and the type system enforces that a
 * key/nonce/tag is the correct length for its algorithm.
 *
 * See `docs/specs/age/SPEC.md` §4.2 for the normative definition.
 */
module sparkles.crypto.concepts;

@safe nothrow @nogc pure:

/**
 * Fixed-size key type for algorithm tag `T`: `ubyte[T.KEY_SIZE]`.
 *
 * Params:
 *   T = an algorithm tag struct exposing an `enum size_t KEY_SIZE`.
 */
template Key(T)
{
    alias Key = ubyte[T.KEY_SIZE];
}

/**
 * Fixed-size nonce type for algorithm tag `T`: `ubyte[T.NONCE_SIZE]`.
 *
 * Params:
 *   T = an algorithm tag struct exposing an `enum size_t NONCE_SIZE`.
 */
template Nonce(T)
{
    alias Nonce = ubyte[T.NONCE_SIZE];
}

/**
 * Fixed-size authentication-tag type for algorithm tag `T`: `ubyte[T.TAG_SIZE]`.
 *
 * Params:
 *   T = an algorithm tag struct exposing an `enum size_t TAG_SIZE`.
 */
template Tag(T)
{
    alias Tag = ubyte[T.TAG_SIZE];
}

/**
 * Fixed-size output (digest) type for algorithm tag `T`: `ubyte[T.OUTPUT_SIZE]`.
 *
 * Params:
 *   T = an algorithm tag struct exposing an `enum size_t OUTPUT_SIZE`.
 */
template Output(T)
{
    alias Output = ubyte[T.OUTPUT_SIZE];
}

///
@("crypto.concepts.sizeAliases")
@safe pure nothrow @nogc
unittest
{
    static struct MockAead
    {
        enum size_t KEY_SIZE = 32;
        enum size_t NONCE_SIZE = 12;
        enum size_t TAG_SIZE = 16;
    }

    static assert(is(Key!MockAead == ubyte[32]));
    static assert(is(Nonce!MockAead == ubyte[12]));
    static assert(is(Tag!MockAead == ubyte[16]));

    static struct MockDigest
    {
        enum size_t OUTPUT_SIZE = 32;
    }

    static assert(is(Output!MockDigest == ubyte[32]));
}

/**
 * `true` iff `T` is a digest algorithm tag: it exposes a fixed output size as
 * a compile-time `size_t` (`enum OUTPUT_SIZE`).
 *
 * This is the structural analogue of RustCrypto's `Digest` trait; the
 * buffering/closure machinery RustCrypto needs for monomorphization is
 * unnecessary in D and is collapsed away.
 */
enum bool isDigest(T) = is(typeof(T.OUTPUT_SIZE) : size_t);

///
@("crypto.concepts.isDigest")
@safe pure nothrow @nogc
unittest
{
    static struct MockDigest
    {
        enum size_t OUTPUT_SIZE = 32;
    }

    static assert(isDigest!MockDigest);
    static assert(!isDigest!int);

    // A tag with no OUTPUT_SIZE is not a digest.
    static struct NotADigest
    {
        enum size_t KEY_SIZE = 32;
    }

    static assert(!isDigest!NotADigest);
}

/**
 * `true` iff `T` is a keyed MAC algorithm tag: it exposes both a fixed output
 * size (`OUTPUT_SIZE`) and a fixed key size (`KEY_SIZE`), each a compile-time
 * `size_t`.
 *
 * Structural analogue of RustCrypto's `Mac` trait.
 */
enum bool isMac(T) = is(typeof(T.OUTPUT_SIZE) : size_t)
    && is(typeof(T.KEY_SIZE) : size_t);

///
@("crypto.concepts.isMac")
@safe pure nothrow @nogc
unittest
{
    static struct MockMac
    {
        enum size_t KEY_SIZE = 32;
        enum size_t OUTPUT_SIZE = 32;
    }

    static assert(isMac!MockMac);
    static assert(!isMac!int);

    // A digest without a key is not a MAC.
    static struct MockDigest
    {
        enum size_t OUTPUT_SIZE = 32;
    }

    static assert(isDigest!MockDigest);
    static assert(!isMac!MockDigest);
}

/**
 * `true` iff `T` is an AEAD algorithm tag: it exposes fixed key, nonce and tag
 * sizes (`KEY_SIZE`, `NONCE_SIZE`, `TAG_SIZE`), each a compile-time `size_t`.
 *
 * Structural analogue of RustCrypto's `Aead` trait. With this predicate
 * satisfied, $(D Key)`!T`, $(D Nonce)`!T` and $(D Tag)`!T` are all well-formed.
 */
enum bool isAead(T) = is(typeof(T.KEY_SIZE) : size_t)
    && is(typeof(T.NONCE_SIZE) : size_t)
    && is(typeof(T.TAG_SIZE) : size_t);

///
@("crypto.concepts.isAead")
@safe pure nothrow @nogc
unittest
{
    static struct MockAead
    {
        enum size_t KEY_SIZE = 32;
        enum size_t NONCE_SIZE = 12;
        enum size_t TAG_SIZE = 16;
    }

    static assert(isAead!MockAead);
    static assert(!isAead!int);

    // A digest is not an AEAD (no key/nonce/tag).
    static struct MockDigest
    {
        enum size_t OUTPUT_SIZE = 32;
    }

    static assert(!isAead!MockDigest);

    // The size aliases are well-formed for an AEAD tag.
    static assert(is(Key!MockAead == ubyte[32]));
    static assert(is(Nonce!MockAead == ubyte[12]));
    static assert(is(Tag!MockAead == ubyte[16]));
}
