/**
The Nix store path a tree would be copied to (CAP1, CAP2): the path
`builtins.path`, `nix-store --add` and `lib.fileset.toSource` give a tree
with no references, computed from its `NarHash` and a store name.

The path is `<store>/<hash>-<name>`, where `<hash>` is Nix's base-32 of a
20-byte digest: SHA-256 over `source:sha256:<NarHash in hex>:<store>:<name>`,
folded to 20 bytes by XOR. `nix-store --print-fixed-path --recursive` is
the oracle (`content_addressing.store_path.printFixedPath`).
*/
module sparkles.build_primitives.content_addressing.store_path;

import std.digest.sha : sha256Of;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.errors : NoGcHook;

/// Nix's default store directory.
enum string defaultStoreDir = "/nix/store";

/// The store name `lib.fileset.toSource` gives what it copies.
enum string defaultStoreName = "source";

/// The longest store name Nix accepts.
enum size_t maxStoreNameLength = 211;

/// Nix's base-32 alphabet: the digits and the letters but `e`, `o`, `u`, `t`.
enum string nix32Alphabet = "0123456789abcdfghijklmnpqrsvwxyz";

/// A store path, or why Nix would refuse its name.
alias StorePathExpected = Expected!(string, string, NoGcHook);

/**
The store path of a tree whose NAR has SHA-256 `narSha256`, under `name` in
the store `storeDir` (CAP1). Fails, saying why, for a name Nix refuses
(CAP2).
*/
StorePathExpected nixStorePath(in ubyte[32] narSha256, scope const(char)[] name,
    scope const(char)[] storeDir = defaultStoreDir) @safe pure
{
    import std.digest : LetterCase, toHexString;

    if (string why = storeNameProblem(name))
        return err!(string, NoGcHook)(why);
    const hex = toHexString!(LetterCase.lower)(narSha256);
    const digest = sha256Of("source:sha256:" ~ hex[] ~ ":" ~ storeDir ~ ":" ~ name);
    ubyte[20] folded;
    foreach (i, b; digest)
        folded[i % 20] ^= b;
    return ok!(string, NoGcHook)((storeDir ~ "/" ~ toNix32(folded)[] ~ "-" ~ name).idup);
}

/// Why Nix refuses `name` as a store name, or `null` (CAP2).
string storeNameProblem(scope const(char)[] name) @safe pure nothrow
{
    if (name.length == 0)
        return "a store name must not be empty";
    if (name.length > maxStoreNameLength)
        return "a store name is at most 211 bytes";
    if (name == "." || name == "..")
        return "a store name must not be `.` or `..`";
    foreach (c; name)
    {
        const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '+' || c == '-' || c == '.' || c == '_' || c == '?' || c == '=';
        if (!ok)
            return "a store name holds only letters, digits and `+-._?=`";
    }
    return null;
}

/**
`bytes` in Nix's base-32: 5-bit groups from the most significant of the
whole number, byte 0 being its least significant.
*/
char[(n * 8 - 1) / 5 + 1] toNix32(size_t n)(in ubyte[n] bytes) @safe pure nothrow @nogc
{
    enum len = (n * 8 - 1) / 5 + 1;
    char[len] s;
    foreach (k; 0 .. len)
    {
        const g = len - 1 - k; // the group, from the most significant
        const b = g * 5;
        const i = b / 8, j = b % 8;
        const lo = bytes[i] >> j;
        const hi = i + 1 < n ? bytes[i + 1] << (8 - j) : 0;
        s[k] = nix32Alphabet[(lo | hi) & 0x1f];
    }
    return s;
}

/// SHA-256 of nothing, as `nix hash convert --to nix32` prints it.
@("content_addressing.store_path.toNix32")
@safe pure nothrow @nogc unittest
{
    static immutable ubyte[32] empty = [
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    ];
    assert(toNix32(empty)[] == "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73");
    static immutable ubyte[20] zero;
    assert(toNix32(zero)[] == "00000000000000000000000000000000");
}

/// A directory holding one file `a` with `hi`, as `nix-store
/// --print-fixed-path --recursive sha256` names it.
@("content_addressing.store_path.CAP1.vector")
@safe pure unittest
{
    static immutable ubyte[32] nar = [
        0x9c, 0x8c, 0xe2, 0x1f, 0x90, 0x30, 0x58, 0x6f, 0x74, 0x4b, 0xac, 0x93, 0x23, 0x4e, 0x1d, 0x13,
        0x53, 0xc7, 0x18, 0xd1, 0x0e, 0xd1, 0x27, 0x6b, 0x20, 0x51, 0xe5, 0x7b, 0x3e, 0xe4, 0xdb, 0x87,
    ];
    const p = nixStorePath(nar, "source");
    assert(p.hasValue && p.value == "/nix/store/30hx62n8wkglnwb3050aazhzcjy1i0sw-source", p.value);
}

/// The names Nix refuses are refused, and the ones it accepts accepted (CAP2).
@("content_addressing.store_path.CAP2.names")
@safe pure unittest
{
    ubyte[32] nar;
    char[212] long_ = 'a';
    foreach (bad; ["", ".", "..", "a b", "a/b", "é", long_[].idup])
        assert(nixStorePath(nar, bad).hasError, bad);
    foreach (good; [".a", "source", "a+-._?=", long_[0 .. 211].idup])
        assert(nixStorePath(nar, good).hasValue, good);
}
