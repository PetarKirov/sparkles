/**
Vector Geometric Algebra primitives for Euclidean vector spaces.

This module starts a sibling implementation to `sparkles.math.vector` rather
than extending it directly. The core representation uses compile-time basis
blade bitmasks and grade-restricted multivector storage so common entities
such as vectors, bivectors, and rotors can be expressed as aliases over the
same generic kernel.
*/
module sparkles.math.vga;

import core.bitop : popcnt;

import std.math : PI, abs, cos, sin, sqrt;
import std.traits : CommonType, isNumeric, isSigned;

@safe pure nothrow @nogc:

public enum maxSupportedBasisVectors = size_t.sizeof * 8 - 1;

/// A basis blade is encoded as a subset of basis vectors in a single word:
/// `0b001` -> `e1`, `0b011` -> `e12`, `0b111` -> `e123`.
public enum bladeCount(size_t dimensions) =
    cast(size_t) 1 << dimensions;

public enum bool hasNoBitsOutsideDimensions(size_t mask, size_t dimensions) =
    (mask >> dimensions) == 0;

/// Number of bits needed to encode one blade mask for `R^dimensions`.
///
/// `R^0` still needs one bit to encode the scalar blade `0b0`.
public enum bladeMaskBitWidth(size_t dimensions) =
    dimensions == 0 ? cast(size_t) 1 : dimensions;

/// Number of blade masks packed into one machine word.
///
/// We pack into `size_t` words rather than narrower integers because the goal
/// here is compile-time throughput: fewer template-value words means smaller
/// type signatures and less template churn.
public enum packedBladeMasksPerWord(size_t dimensions) =
    size_t.sizeof * 8 / bladeMaskBitWidth!dimensions;

/// Number of packed words required to store `maskCount` blade masks.
public enum packedBladeMaskWordCount(size_t dimensions, size_t maskCount) =
    maskCount == 0 ? cast(size_t) 0 :
        (maskCount + packedBladeMasksPerWord!dimensions - 1) /
        packedBladeMasksPerWord!dimensions;

/// Low-bit mask for one packed blade-mask field.
public enum bladeMaskFieldMask(size_t dimensions) =
    ((cast(size_t) 1) << bladeMaskBitWidth!dimensions) - 1;

public enum choose(size_t n, size_t k) = {
    if (k > n)
        return cast(size_t) 0;

    size_t reducedK = k;
    if (reducedK > n - reducedK)
        reducedK = n - reducedK;

    size_t result = 1;
    foreach (i; 0 .. reducedK)
        result = result * (n - i) / (i + 1);

    return result;
}();

public enum evenBladeCount(size_t dimensions) =
    dimensions == 0 ? cast(size_t) 1 : bladeCount!dimensions / 2;

public enum oddBladeCount(size_t dimensions) =
    dimensions == 0 ? cast(size_t) 0 : bladeCount!dimensions / 2;

public size_t[bladeCount!dimensions] makeAllBladeMasks(size_t dimensions)()
in (dimensions <= maxSupportedBasisVectors)
{
    size_t[bladeCount!dimensions] result = void;

    foreach (i; 0 .. result.length)
        result[i] = i;

    return result;
}

public enum size_t[] allBladeMasks(size_t dimensions) =
    makeAllBladeMasks!dimensions();

/// Dense mask-to-index table for the full blade support of `R^dimensions`.
public ptrdiff_t[bladeCount!dimensions] makeAllBladeMaskIndexTable(
    size_t dimensions,
)()
in (dimensions <= maxSupportedBasisVectors)
{
    ptrdiff_t[bladeCount!dimensions] result = void;

    foreach (i; 0 .. result.length)
        result[i] = cast(ptrdiff_t) i;

    return result;
}

/// Dense mask-to-index table for a support set.
///
/// Entries are coefficient indices in support order, or `-1` when the blade
/// is absent from the support.
public ptrdiff_t[bladeCount!dimensions] makeBladeMaskIndexTable(
    size_t dimensions,
    size_t[] masks,
)()
in (dimensions <= maxSupportedBasisVectors)
{
    ptrdiff_t[bladeCount!dimensions] result;
    result[] = -1;

    foreach (i, mask; masks)
        result[mask] = cast(ptrdiff_t) i;

    return result;
}

/// Dense mask-to-index table recovered from a support list.
public enum bladeMaskIndexTable(size_t dimensions, size_t[] masks) =
    makeBladeMaskIndexTable!(dimensions, masks)();

/// Dense mask-to-index table for the full blade support of `R^dimensions`.
public enum allBladeMaskIndexTable(size_t dimensions) =
    makeAllBladeMaskIndexTable!dimensions();

@safe pure nothrow:

/// Packs an ascending blade-mask list into dense `size_t` words.
///
/// Masks are stored in ascending support order, low field to high field. For
/// example, in `R^3`, `[0b001, 0b010, 0b100]` becomes one packed word
/// `0b100_010_001`.
public size_t[packedBladeMaskWordCount!(dimensions, masks.length)] makePackedBladeMasks(
    size_t dimensions,
    size_t[] masks,
)()
in (dimensions <= maxSupportedBasisVectors)
{
    static foreach (mask; masks)
    {
        static assert(
            hasNoBitsOutsideDimensions!(mask, dimensions),
            "blade mask has bits set outside the algebra dimensions"
        );
    }

    enum bitWidth = bladeMaskBitWidth!dimensions;
    enum masksPerWord = packedBladeMasksPerWord!dimensions;

    size_t[packedBladeMaskWordCount!(dimensions, masks.length)] result = 0;

    foreach (i, mask; masks)
    {
        immutable wordIndex = i / masksPerWord;
        immutable shift = (i % masksPerWord) * bitWidth;
        result[wordIndex] |= mask << shift;
    }

    return result;
}

/// Packed `size_t`-word representation of a blade-mask support list.
public enum size_t[] packBladeMasks(size_t dimensions, size_t[] masks) =
    makePackedBladeMasks!(dimensions, masks)();

/// Unpacks dense `size_t` words back into one blade-mask list.
public size_t[maskCount] makeUnpackedBladeMasks(
    size_t dimensions,
    size_t maskCount,
    size_t[] packedMasks,
)()
in (
    dimensions <= maxSupportedBasisVectors &&
    packedMasks.length == packedBladeMaskWordCount!(dimensions, maskCount)
)
{
    enum bitWidth = bladeMaskBitWidth!dimensions;
    enum masksPerWord = packedBladeMasksPerWord!dimensions;
    enum fieldMask = bladeMaskFieldMask!dimensions;

    size_t[maskCount] result = 0;

    static foreach (i; 0 .. maskCount)
    {{
        enum wordIndex = i / masksPerWord;
        enum shift = (i % masksPerWord) * bitWidth;
        result[i] = (packedMasks[wordIndex] >> shift) & fieldMask;
    }}

    return result;
}

/// Unpacked blade-mask list recovered from [packBladeMasks].
public enum size_t[] unpackBladeMasks(
    size_t dimensions,
    size_t maskCount,
    size_t[] packedMasks,
) = makeUnpackedBladeMasks!(dimensions, maskCount, packedMasks)();

@safe pure nothrow @nogc:

public size_t bladeGrade(size_t mask)
    => cast(size_t) popcnt(mask);

public ptrdiff_t indexOfMask(scope const size_t[] masks, size_t mask)
{
    foreach (i, current; masks)
    {
        if (current == mask)
            return cast(ptrdiff_t) i;
    }

    return -1;
}

public enum bool allMasksHaveGrade(size_t[] masks, size_t wantGrade) = ()
{
    foreach (mask; masks)
    {
        if (bladeGrade(mask) != wantGrade)
            return false;
    }

    return true;
}();

public enum bool allMasksHaveParity(size_t[] masks, bool wantEven) = ()
{
    foreach (mask; masks)
    {
        if ((bladeGrade(mask) % 2 == 0) != wantEven)
            return false;
    }

    return true;
}();

public enum bool sameBladeMasks(size_t[] lhsMasks, size_t[] rhsMasks) = ()
{
    if (lhsMasks.length != rhsMasks.length)
        return false;

    foreach (i, lhsMask; lhsMasks)
    {
        if (lhsMask != rhsMasks[i])
            return false;
    }

    return true;
}();

public bool areStrictlyAscending(scope const size_t[] masks)
{
    foreach (i; 1 .. masks.length)
    {
        if (masks[i - 1] >= masks[i])
            return false;
    }

    return true;
}

public enum unionBladeMaskCount(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
) = ()
{
    bool[bladeCount!dimensions] seen = false;

    foreach (mask; lhsMasks)
        seen[mask] = true;

    foreach (mask; rhsMasks)
        seen[mask] = true;

    size_t count;
    foreach (present; seen)
    {
        if (present)
            ++count;
    }

    return count;
}();

public size_t[unionBladeMaskCount!(dimensions, lhsMasks, rhsMasks)] makeUnionBladeMasks(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
)()
{
    bool[bladeCount!dimensions] seen = false;
    foreach (mask; lhsMasks)
        seen[mask] = true;

    foreach (mask; rhsMasks)
        seen[mask] = true;

    size_t[unionBladeMaskCount!(dimensions, lhsMasks, rhsMasks)] result = void;
    size_t index;

    foreach (mask, present; seen)
    {
        if (present)
            result[index++] = mask;
    }

    return result;
}

public enum unionBladeMasks(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
) = makeUnionBladeMasks!(dimensions, lhsMasks, rhsMasks)();

/// Advances `mask` to the next larger bit pattern with the same popcount.
///
/// This is Gosper's hack. Starting from the lowest canonical `k`-blade mask
/// such as `0b00111`, it moves the rightmost movable `1` bit left, then packs
/// the remaining trailing `1`s back to the far right:
/// `0b00111 -> 0b01011 -> 0b01101 -> ...`.
///
/// Returns `false` when there is no larger same-popcount mask left in the
/// current machine word.
bool advanceFixedPopcountMask(ref size_t mask)
{
    if (mask == 0)
        return false;

    immutable smallest = mask & (~mask + 1);
    immutable ripple = mask + smallest;

    if (ripple == 0)
        return false;

    immutable ones = ((mask ^ ripple) >> 2) / smallest;
    mask = ripple | ones;
    return true;
}

public size_t[choose!(dimensions, targetGrade)] makeGradeBladeMasks(
    size_t dimensions,
    size_t targetGrade,
)()
in (dimensions <= maxSupportedBasisVectors)
{
    size_t[choose!(dimensions, targetGrade)] result = void;
    static if (targetGrade > dimensions)
        return result;

    static if (targetGrade == 0)
    {
        result[0] = 0;
        return result;
    }

    size_t index = 0;
    size_t mask = (cast(size_t) 1 << targetGrade) - 1;
    immutable limit = cast(size_t) 1 << dimensions;

    while (mask < limit)
    {
        result[index++] = mask;

        if (!advanceFixedPopcountMask(mask))
            break;
    }

    assert(index == result.length);

    return result;
}

public enum size_t[] gradeBladeMasks(size_t dimensions, size_t targetGrade) =
    makeGradeBladeMasks!(dimensions, targetGrade)();

public size_t[
    wantEven ? evenBladeCount!dimensions : oddBladeCount!dimensions
] makeParityBladeMasks(size_t dimensions, bool wantEven)()
in (dimensions <= maxSupportedBasisVectors)
{
    size_t[
        wantEven ? evenBladeCount!dimensions : oddBladeCount!dimensions
    ] result = void;
    size_t index;

    foreach (mask; 0 .. bladeCount!dimensions)
    {
        if ((bladeGrade(mask) % 2 == 0) == wantEven)
            result[index++] = mask;
    }

    return result;
}

public enum size_t[] evenBladeMasks(size_t dimensions) =
    makeParityBladeMasks!(dimensions, true)();

public enum size_t[] oddBladeMasks(size_t dimensions) =
    makeParityBladeMasks!(dimensions, false)();

/// Returns the sign needed to reorder `lhsMask * rhsMask` into canonical blade order.
///
/// The resulting blade itself is just `lhsMask ^ rhsMask`; this counts the swaps
/// needed to move the right-hand basis vectors past the left-hand ones.
public int geometricProductSign(size_t lhsMask, size_t rhsMask, size_t dimensions)
{
    int sign = 1;

    foreach (i; 0 .. dimensions)
    {
        immutable bit = cast(size_t) 1 << i;

        if ((lhsMask & bit) == 0)
            continue;

        if (popcnt(rhsMask & (bit - 1)) % 2 != 0)
            sign = -sign;
    }

    return sign;
}

public enum geometricProductMaskCount(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
) = ()
{
    bool[bladeCount!dimensions] seen = false;

    foreach (lhsMask; lhsMasks)
    {
        foreach (rhsMask; rhsMasks)
            seen[lhsMask ^ rhsMask] = true;
    }

    size_t count;
    foreach (present; seen)
    {
        if (present)
            ++count;
    }

    return count;
}();

public size_t[geometricProductMaskCount!(dimensions, lhsMasks, rhsMasks)] makeGeometricProductMasks(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
)()
in (dimensions <= maxSupportedBasisVectors)
{
    bool[bladeCount!dimensions] seen = false;

    foreach (lhsMask; lhsMasks)
    {
        foreach (rhsMask; rhsMasks)
            seen[lhsMask ^ rhsMask] = true;
    }

    size_t[geometricProductMaskCount!(dimensions, lhsMasks, rhsMasks)] result = void;
    size_t index;
    foreach (mask, present; seen)
    {
        if (present)
            result[index++] = mask;
    }

    return result;
}

public enum size_t[] geometricProductMasks(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
) = makeGeometricProductMasks!(dimensions, lhsMasks, rhsMasks)();

public enum outerProductMaskCount(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
) = ()
{
    bool[bladeCount!dimensions] seen = false;

    foreach (lhsMask; lhsMasks)
    {
        foreach (rhsMask; rhsMasks)
        {
            if ((lhsMask & rhsMask) != 0)
                continue;

            seen[lhsMask ^ rhsMask] = true;
        }
    }

    size_t count;
    foreach (present; seen)
    {
        if (present)
            ++count;
    }

    return count;
}();

public size_t[outerProductMaskCount!(dimensions, lhsMasks, rhsMasks)] makeOuterProductMasks(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
)()
in (dimensions <= maxSupportedBasisVectors)
{
    bool[bladeCount!dimensions] seen = false;

    foreach (lhsMask; lhsMasks)
    {
        foreach (rhsMask; rhsMasks)
        {
            if ((lhsMask & rhsMask) != 0)
                continue;

            seen[lhsMask ^ rhsMask] = true;
        }
    }

    size_t[outerProductMaskCount!(dimensions, lhsMasks, rhsMasks)] result = void;
    size_t index;
    foreach (mask, present; seen)
    {
        if (present)
            result[index++] = mask;
    }

    return result;
}

public enum size_t[] outerProductMasks(
    size_t dimensions,
    size_t[] lhsMasks,
    size_t[] rhsMasks,
) = makeOuterProductMasks!(dimensions, lhsMasks, rhsMasks)();

public enum size_t[] singletonBladeMask(size_t mask) = [mask];

public bool isDigit(char c)
    => c >= '0' && c <= '9';

public bool isNonZeroDigit(char c)
    => c >= '1' && c <= '9';

public enum bool isBasisWord(string name, size_t dimensions) = ()
{
    BasisWordSpec ignored;
    return tryParseCompactBasisWord(name, dimensions, ignored) ||
        tryParseUnderscoreBasisWord(name, dimensions, ignored) ||
        tryParseDelimitedBasisWord(name, dimensions, '(', ')', ',', ignored) ||
        tryParseDelimitedBasisWord(name, dimensions, '[', ']', ',', ignored);
}();

public struct BasisWordSpec
{
    int sign;
    size_t mask;
}

public void applyBasisIndex(ref BasisWordSpec spec, size_t oneBasedIndex, size_t dimensions)
{
    immutable bit = cast(size_t) 1 << (oneBasedIndex - 1);
    spec.sign *= geometricProductSign(spec.mask, bit, dimensions);
    spec.mask ^= bit;
}

public bool parseBasisIndex(
    string name,
    ref size_t position,
    size_t dimensions,
    out size_t oneBasedIndex,
)
{
    if (position >= name.length || !isNonZeroDigit(name[position]))
        return false;

    size_t value;
    while (position < name.length && isDigit(name[position]))
    {
        value = value * 10 + cast(size_t) (name[position] - '0');
        ++position;
    }

    if (value == 0 || value > dimensions)
        return false;

    oneBasedIndex = value;
    return true;
}

// Basis-word syntax cluster:
// - compact identifier form: `e12`
// - underscore identifier forms: `e1_2`, `e_1_2`
// - delimited list forms: `basis!"e(1,2)"`, `basis!"e[1,2]"`
//
// The compact form always tokenizes one digit at a time, so `e12` means
// `e1 e2`. Use a leading underscore when you need a multi-digit basis index,
// for example `e_12` for the single vector `e12` or `e_10_2` for `e10 e2`.

public bool tryParseCompactBasisWord(string name, size_t dimensions, out BasisWordSpec spec)
{
    if (name.length < 2 || name[0] != 'e')
        return false;

    spec = BasisWordSpec(sign: 1, mask: 0b0);

    foreach (c; name[1 .. $])
    {
        if (!isNonZeroDigit(c))
            return false;

        immutable oneBasedIndex = cast(size_t) (c - '0');
        if (oneBasedIndex > dimensions)
            return false;

        applyBasisIndex(spec, oneBasedIndex, dimensions);
    }

    return true;
}

public bool tryParseUnderscoreBasisWord(string name, size_t dimensions, out BasisWordSpec spec)
{
    if (name.length < 3 || name[0] != 'e')
        return false;

    spec = BasisWordSpec(sign: 1, mask: 0b0);

    size_t position = 1;
    if (name[position] == '_')
        ++position;

    size_t oneBasedIndex;
    if (!parseBasisIndex(name, position, dimensions, oneBasedIndex))
        return false;

    applyBasisIndex(spec, oneBasedIndex, dimensions);

    while (position < name.length)
    {
        if (name[position] != '_')
            return false;

        ++position;
        if (!parseBasisIndex(name, position, dimensions, oneBasedIndex))
            return false;

        applyBasisIndex(spec, oneBasedIndex, dimensions);
    }

    return true;
}

public bool tryParseDelimitedBasisWord(
    string name,
    size_t dimensions,
    char open,
    char close,
    char separator,
    out BasisWordSpec spec,
)
{
    if (name.length < 5 || name[0] != 'e' || name[1] != open || name[$ - 1] != close)
        return false;

    spec = BasisWordSpec(sign: 1, mask: 0b0);

    immutable end = name.length - 1;
    size_t position = 2;
    size_t oneBasedIndex;

    while (true)
    {
        if (!parseBasisIndex(name, position, dimensions, oneBasedIndex))
            return false;

        applyBasisIndex(spec, oneBasedIndex, dimensions);

        if (position == end)
            return true;

        if (name[position] != separator)
            return false;

        ++position;
        if (position == end)
            return false;
    }
}

public BasisWordSpec basisWordSpec(string name, size_t dimensions)()
in (isBasisWord!(name, dimensions))
{
    BasisWordSpec result;

    if (tryParseCompactBasisWord(name, dimensions, result))
        return result;

    if (tryParseUnderscoreBasisWord(name, dimensions, result))
        return result;

    if (tryParseDelimitedBasisWord(name, dimensions, '(', ')', ',', result))
        return result;

    if (tryParseDelimitedBasisWord(name, dimensions, '[', ']', ',', result))
        return result;

    assert(0, "unreachable: invalid basis word");
}

public auto basisWord(T = double, size_t N, string name)()
if (isNumeric!T && N <= maxSupportedBasisVectors && isBasisWord!(name, N))
{
    enum spec = basisWordSpec!(name, N);

    static if (spec.sign < 0)
    {
        static assert(
            isSigned!T || __traits(isFloating, T),
            "Negative-oriented basis words require a signed or floating-point coefficient type"
        );
    }

    auto result = basisBlade!(T, N, spec.mask);
    result.coeffs[0] = cast(T) spec.sign;
    return result;
}

private alias FullSupportMultivector(T, size_t N) =
    MultivectorImpl!(T, N, allBladeMasks!N.length, packBladeMasks!(N, allBladeMasks!N));

/// Runtime-index counterpart to [basisWord], used by the widened `.e[...]` proxy.
public FullSupportMultivector!(T, N) fullBasisWordFromIndices(T, size_t N)(
    scope const size_t[] indices,
)
if (isNumeric!T && N <= maxSupportedBasisVectors)
{
    static assert(
        isSigned!T || __traits(isFloating, T),
        "Basis index proxy requires a signed or floating-point coefficient type"
    );

    BasisWordSpec spec = BasisWordSpec(
        sign: 1,
        mask: 0b0,
    );

    foreach (oneBasedIndex; indices)
    {
        assert(oneBasedIndex >= 1 && oneBasedIndex <= N, "Basis index out of range");
        applyBasisIndex(spec, oneBasedIndex, N);
    }

    FullSupportMultivector!(T, N) result;
    result.coeffs[spec.mask] = cast(T) spec.sign;
    return result;
}

/// Convenience proxy for widened basis-word construction via `.e[...]`.
///
/// This proxy intentionally returns [FullMultivector] instead of a compact
/// one-blade type because index arguments are runtime values. Use
/// `Basis!(T, N).e12`, `Basis!(T, N).e_10_2`, or `Basis!(T, N).basis!"e(10,2)"()`
/// when you want compile-time exact support.
///
/// D syntax note:
/// `Basis!(T, N).e[10, 2]` works through [opIndex].
/// `Basis!(T, N).e(10, 2)` does not parse as a proxy call in D, but storing the
/// proxy first does work:
/// ---
/// auto e = Basis!(double, 12).e;
/// auto blade = e(10, 2);
/// ---
struct BasisProxy(T, size_t N)
if (isNumeric!T && N <= maxSupportedBasisVectors)
{
    /// Returns a widened full multivector for basis indices like `.e[10, 2]`.
    FullSupportMultivector!(T, N) opIndex(size_t[] indices...) const
        => fullBasisWordFromIndices!(T, N)(indices);

    /// Callable form for stored proxies, e.g. `auto e = Basis!(T, N).e; e(10, 2)`.
    FullSupportMultivector!(T, N) opCall(size_t[] indices...) const
        => fullBasisWordFromIndices!(T, N)(indices);
}

/// Public multivector spelling with an unpacked support list.
///
/// The implementation type stores the support list in packed machine words to
/// keep template argument payloads compact. Use `.support` when you need the
/// unpacked blade masks and `.packedSupport` when you want the compressed form.
template Multivector(T, size_t N, size_t[] bladeMasks)
if (isNumeric!T && N <= maxSupportedBasisVectors)
{
    static assert(
        areStrictlyAscending(bladeMasks),
        "bladeMasks must be strictly ascending and unique"
    );

    static foreach (mask; bladeMasks)
    {
        static assert(
            hasNoBitsOutsideDimensions!(mask, N),
            "blade mask has bits set outside the algebra dimensions"
        );
    }

    alias Multivector = MultivectorImpl!(
        T,
        N,
        bladeMasks.length,
        packBladeMasks!(N, bladeMasks)
    );
}

/// Generic multivector over an `N`-dimensional Euclidean vector space.
struct MultivectorImpl(
    T,
    size_t N,
    size_t maskCount,
    size_t[] packedBladeMasks,
)
if (isNumeric!T && N <= maxSupportedBasisVectors)
{
    static assert(
        packedBladeMasks.length == packedBladeMaskWordCount!(N, maskCount),
        "packed support word count does not match the declared support length"
    );

    alias Self = MultivectorImpl!(T, N, maskCount, packedBladeMasks);
    alias CoefficientType = T;

    enum size_t dimensions = N;
    enum size_t supportCount = maskCount;
    enum size_t[] packedSupport = packedBladeMasks;
    enum size_t[] support = unpackBladeMasks!(N, maskCount, packedBladeMasks);
    enum bool hasFullSupport = maskCount == bladeCount!N;
    enum ptrdiff_t[bladeCount!N] supportIndexByMask = hasFullSupport ?
        allBladeMaskIndexTable!N :
        bladeMaskIndexTable!(N, support);

    static assert(
        areStrictlyAscending(support),
        "decoded blade masks must be strictly ascending and unique"
    );

    static foreach (mask; support)
    {
        static assert(
            hasNoBitsOutsideDimensions!(mask, N),
            "decoded blade mask has bits set outside the algebra dimensions"
        );
    }

    static assert(
        makePackedBladeMasks!(N, support) == packedBladeMasks,
        "packed blade-mask words must be canonical"
    );

    /// Coefficients ordered by ascending blade mask.
    T[maskCount] coeffs = 0;

    public alias CommonScalar(U) = CommonType!(T, U);

    /// Static basis-word lookup like `Type.e1`, `Type.e12`, `Type.e21`, or `Type.e_12`.
    ///
    /// Compact names always parse one digit at a time, so `Type.e12` means
    /// `Type.basis!"e12"()` and therefore `e1 e2`. Use a leading underscore to
    /// start a multi-digit index, such as `Type.e_12` for the single vector
    /// `e12` or `Type.e_10_2` for the ordered product `e10 e2`.
    static auto opDispatch(string name)()
        => basis!name();

    /// Convenience proxy for widened basis access like `Type.e[10, 2]`.
    ///
    /// This is ergonomic sugar over [BasisProxy] and intentionally widens to
    /// [FullMultivector]. Keep using [basis] or [opDispatch] when you want the
    /// exact one-blade support set in the return type.
    @property static BasisProxy!(T, N) e()
        => BasisProxy!(T, N).init;

    /// Static basis-word lookup for punctuated forms like `basis!"e(10,2)"`.
    ///
    /// Supported forms stay close to the parser cluster:
    /// `e12`, `e1_2`, `e_12`, `e_10_2`, `e(10,2)`, and `e[10,2]`.
    static auto basis(string name)()
    {
        static assert(
            isBasisWord!(name, N),
            "Invalid basis word `" ~ name ~ "` for this algebra"
        );

        return basisWord!(T, N, name);
    }

    static foreach (i; 1 .. maskCount + 1)
    {
        /// Initializes the first `i` coefficients in blade-mask order.
        this(T[i] values...)
        {
            coeffs[0 .. i] = values[0 .. i];
        }
    }

    /// Compile-time coefficient lookup for the requested basis blade.
    ///
    /// Use `mv.coefficient!0b011` for the native coefficient type or
    /// `mv.coefficient!(0b011, double)` to widen the result.
    CommonScalar!U coefficient(size_t mask, U = T)() const
    if (mask < bladeCount!N)
    {
        static if (hasFullSupport)
        {
            return cast(CommonScalar!U) coeffs[mask];
        }
        else
        {
            enum index = supportIndexByMask[mask];

            static if (index >= 0)
            {
                return cast(CommonScalar!U) coeffs[index];
            }
            else
            {
                return cast(CommonScalar!U) 0;
            }
        }
    }

    /// Short alias for [coefficient], so `mv.coeff!0b011` also works.
    alias coeff = coefficient;

    /// Runtime coefficient lookup by blade mask, e.g. `mv[0b011]`.
    T opIndex(size_t mask) const
    {
        assert(mask < bladeCount!N, "Blade mask outside the algebra dimensions");

        static if (hasFullSupport)
            return coeffs[mask];

        immutable index = supportIndexByMask[mask];
        return index >= 0 ? coeffs[cast(size_t) index] : 0;
    }

    /// Unary plus and minus preserve support and negate coefficients when needed.
    Self opUnary(string op)() const
    if (op == "+" || op == "-")
    {
        Self result;

        static if (op == "+")
        {
            result.coeffs[] = coeffs[];
        }
        else
        {
            foreach (i, ref coeff; result.coeffs)
                coeff = -coeffs[i];
        }

        return result;
    }

    /// Adds or subtracts multivectors and returns the smallest union support.
    auto opBinary(string op, Rhs)(
        in Rhs rhs
    ) const
    if (
        (op == "+" || op == "-") &&
        isMultivector!Rhs &&
        multivectorDimensions!Rhs == N &&
        isNumeric!(MultivectorCoefficient!Rhs)
    )
    {
        alias RhsScalar = MultivectorCoefficient!Rhs;
        alias Result = Multivector!(
            CommonScalar!RhsScalar,
            N,
            unionBladeMasks!(N, support, multivectorSupport!Rhs)
        );

        Result result;

        static foreach (i, mask; Result.support)
        {{
            enum lhsIndex = supportIndexByMask[mask];
            enum rhsIndex = multivectorSupportIndexByMask!Rhs[mask];

            CommonScalar!RhsScalar lhsValue = 0;
            CommonScalar!RhsScalar rhsValue = 0;

            static if (lhsIndex >= 0)
                lhsValue = cast(CommonScalar!RhsScalar) coeffs[lhsIndex];

            static if (rhsIndex >= 0)
                rhsValue = cast(CommonScalar!RhsScalar) rhs.coeffs[rhsIndex];

            result.coeffs[i] = mixin("lhsValue " ~ op ~ " rhsValue");
        }}

        return result;
    }

    /// In-place addition and subtraction for the same support set.
    ref Self opOpAssign(string op)(in Self rhs)
    if (op == "+" || op == "-")
    {
        foreach (i, ref coeff; coeffs)
            coeff = mixin("coeff " ~ op ~ " rhs.coeffs[i]");

        return this;
    }

    /// Scalar multiplication and division.
    auto opBinary(string op, U)(U rhs) const
    if ((op == "*" || op == "/") && isNumeric!U)
    {
        alias Result = Multivector!(CommonScalar!U, N, support);

        Result result;
        foreach (i, ref coeff; result.coeffs)
            coeff = mixin("this.coeffs[i] " ~ op ~ " rhs");

        return result;
    }

    /// Left scalar multiplication.
    auto opBinaryRight(string op, U)(U lhs) const
    if (op == "*" && isNumeric!U)
        => this * lhs;

    /// Geometric product.
    auto opBinary(string op, Rhs)(
        in Rhs rhs
    ) const
    if (
        op == "*" &&
        isMultivector!Rhs &&
        multivectorDimensions!Rhs == N &&
        isNumeric!(MultivectorCoefficient!Rhs)
    )
    {
        alias RhsScalar = MultivectorCoefficient!Rhs;
        alias Result = Multivector!(
            CommonScalar!RhsScalar,
            N,
            geometricProductMasks!(N, support, multivectorSupport!Rhs)
        );

        Result result;

        static foreach (lhsIndex, lhsMask; support)
        {{
            static foreach (rhsIndex, rhsMask; multivectorSupport!Rhs)
            {{
                enum resultMask = lhsMask ^ rhsMask;
                enum resultIndex = Result.supportIndexByMask[resultMask];
                enum sign = geometricProductSign(lhsMask, rhsMask, N);

                static if (resultIndex >= 0)
                {
                    result.coeffs[resultIndex] +=
                        cast(CommonScalar!RhsScalar) coeffs[lhsIndex] *
                        cast(CommonScalar!RhsScalar) rhs.coeffs[rhsIndex] *
                        sign;
                }
            }}
        }}

        return result;
    }

    /// Outer product.
    auto opBinary(string op, Rhs)(
        in Rhs rhs
    ) const
    if (
        op == "^" &&
        isMultivector!Rhs &&
        multivectorDimensions!Rhs == N &&
        isNumeric!(MultivectorCoefficient!Rhs)
    )
    {
        alias RhsScalar = MultivectorCoefficient!Rhs;
        alias Result = Multivector!(
            CommonScalar!RhsScalar,
            N,
            outerProductMasks!(N, support, multivectorSupport!Rhs)
        );

        Result result;

        static foreach (lhsIndex, lhsMask; support)
        {{
            static foreach (rhsIndex, rhsMask; multivectorSupport!Rhs)
            {{
                static if ((lhsMask & rhsMask) == 0)
                {
                    enum resultMask = lhsMask ^ rhsMask;
                    enum resultIndex = Result.supportIndexByMask[resultMask];
                    enum sign = geometricProductSign(lhsMask, rhsMask, N);

                    static if (resultIndex >= 0)
                    {
                        result.coeffs[resultIndex] +=
                            cast(CommonScalar!RhsScalar) coeffs[lhsIndex] *
                            cast(CommonScalar!RhsScalar) rhs.coeffs[rhsIndex] *
                            sign;
                    }
                }
            }}
        }}

        return result;
    }

    /// Scalar product, defined as the grade-0 part of the geometric product.
    CommonScalar!(MultivectorCoefficient!Rhs) scalarProduct(Rhs)(
        in Rhs rhs
    ) const
    if (
        isMultivector!Rhs &&
        multivectorDimensions!Rhs == N &&
        isNumeric!(MultivectorCoefficient!Rhs)
    )
    {
        alias RhsScalar = MultivectorCoefficient!Rhs;
        CommonScalar!RhsScalar result = 0;

        static foreach (lhsIndex, lhsMask; support)
        {{
            enum rhsIndex = multivectorSupportIndexByMask!Rhs[lhsMask];

            static if (rhsIndex >= 0)
            {
                result +=
                    cast(CommonScalar!RhsScalar) coeffs[lhsIndex] *
                    cast(CommonScalar!RhsScalar) rhs.coeffs[rhsIndex] *
                    geometricProductSign(lhsMask, lhsMask, N);
            }
        }}

        return result;
    }

    /// Grade-0 coefficient if present.
    @property T scalarPart() const
    {
        static if (hasFullSupport)
        {
            return coeffs[0];
        }
        else
        {
            enum index = supportIndexByMask[0b0];

            static if (index >= 0)
            {
                return coeffs[index];
            }
            else
            {
                return 0;
            }
        }
    }

    /// Equality compares coefficients blade-by-blade, even across different support sets.
    bool opEquals(Rhs)(
        in Rhs rhs
    ) const
    if (
        isMultivector!Rhs &&
        multivectorDimensions!Rhs == N &&
        isNumeric!(MultivectorCoefficient!Rhs)
    )
    {
        alias RhsScalar = MultivectorCoefficient!Rhs;

        static if (sameBladeMasks!(support, multivectorSupport!Rhs))
        {
            foreach (i, lhsCoeff; coeffs)
            {
                if (cast(CommonScalar!RhsScalar) lhsCoeff != cast(CommonScalar!RhsScalar) rhs.coeffs[i])
                    return false;
            }
        }
        else
        {
            static foreach (mask; unionBladeMasks!(N, support, multivectorSupport!Rhs))
            {{
                enum lhsIndex = supportIndexByMask[mask];
                enum rhsIndex = multivectorSupportIndexByMask!Rhs[mask];

                CommonScalar!RhsScalar lhsValue = 0;
                CommonScalar!RhsScalar rhsValue = 0;

                static if (lhsIndex >= 0)
                    lhsValue = cast(CommonScalar!RhsScalar) coeffs[lhsIndex];

                static if (rhsIndex >= 0)
                    rhsValue = cast(CommonScalar!RhsScalar) rhs.coeffs[rhsIndex];

                if (lhsValue != rhsValue)
                    return false;
            }}
        }

        return true;
    }

    /// Reversion involution.
    Self reverse() const
    {
        Self result;

        static foreach (i, mask; support)
        {{
            enum grade = bladeGrade(mask);
            enum sign = ((grade * (grade - 1) / 2) % 2 == 0) ? 1 : -1;
            result.coeffs[i] = coeffs[i] * sign;
        }}

        return result;
    }

    /// Grade involution.
    Self gradeInvolution() const
    {
        Self result;

        static foreach (i, mask; support)
        {{
            enum sign = (bladeGrade(mask) % 2 == 0) ? 1 : -1;
            result.coeffs[i] = coeffs[i] * sign;
        }}

        return result;
    }

    /// Clifford conjugation.
    Self cliffordConjugate() const
        => gradeInvolution().reverse();

    /// Extracts the grade-`targetGrade` part into a grade-restricted type.
    auto gradePart(size_t targetGrade)() const
    if (targetGrade <= N)
    {
        alias Result = Multivector!(T, N, gradeBladeMasks!(N, targetGrade));

        Result result;

        static foreach (i, mask; support)
        {{
            static if (bladeGrade(mask) == targetGrade)
            {
                enum resultIndex = Result.supportIndexByMask[mask];
                static if (resultIndex >= 0)
                    result.coeffs[resultIndex] = coeffs[i];
            }
        }}

        return result;
    }

    /// Writes coefficients as `a + b*e1 + c*e12`.
    void toString(W)(scope ref W writer) const
    {
        import sparkles.core_cli.text_writers : writeValue;
        import std.range.primitives : put;

        bool wroteTerm;

        static foreach (i, mask; support)
        {
            auto coeff = coeffs[i];

            if (coeff != 0)
            {
                if (wroteTerm)
                    put(writer, " + ");

                writeValue(writer, coeff);

                static if (mask != 0b0)
                {
                    put(writer, "*e");
                    writeBladeIndices(writer, mask);
                }

                wroteTerm = true;
            }
        }

        if (!wroteTerm)
            put(writer, '0');
    }
}

/// Detects multivector implementation types produced by [Multivector].
public enum bool isMultivector(T) =
    __traits(compiles, T.dimensions) &&
    __traits(compiles, T.support) &&
    __traits(compiles, T.packedSupport) &&
    __traits(compiles, T.CoefficientType) &&
    __traits(compiles, T.init.coeffs);

/// Coefficient scalar type of a multivector.
template MultivectorCoefficient(T)
if (isMultivector!T)
{
    alias MultivectorCoefficient = T.CoefficientType;
}

/// Vector-space dimension of a multivector.
template multivectorDimensions(T)
if (isMultivector!T)
{
    enum size_t multivectorDimensions = T.dimensions;
}

/// Unpacked blade-mask support list of a multivector.
template multivectorSupport(T)
if (isMultivector!T)
{
    enum size_t[] multivectorSupport = T.support;
}

/// Dense blade-mask lookup table of a multivector.
template multivectorSupportIndexByMask(T)
if (isMultivector!T)
{
    enum multivectorSupportIndexByMask = T.supportIndexByMask;
}

/// Serializes a blade mask like `0b101` as the index sequence `13`.
public void writeBladeIndices(Writer)(ref Writer w, size_t mask)
{
    import sparkles.core_cli.text_writers : writeInteger;

    size_t currentMask = mask;
    size_t basisIndex = 0;

    while (currentMask != 0)
    {
        if ((currentMask & 1) != 0)
            writeInteger(w, basisIndex + 1);

        currentMask >>= 1;
        ++basisIndex;
    }
}

/// Full multivector over `R^N`.
alias FullMultivector(T, size_t N) = Multivector!(T, N, allBladeMasks!N);

/// Grade-`K` multivector over `R^N`.
alias KVector(T, size_t N, size_t K) = Multivector!(T, N, gradeBladeMasks!(N, K));

/// Even-grade multivector over `R^N`.
alias EvenMultivector(T, size_t N) = Multivector!(T, N, evenBladeMasks!N);

/// Odd-grade multivector over `R^N`.
alias OddMultivector(T, size_t N) = Multivector!(T, N, oddBladeMasks!N);

/// Scalar over `R^N`.
alias Scalar(T, size_t N) = KVector!(T, N, 0);

/// Grade-1 vector over `R^N`.
alias GAVector(T, size_t N) = KVector!(T, N, 1);

/// Grade-2 bivector over `R^N`.
alias Bivector(T, size_t N) = KVector!(T, N, 2);

/// Grade-3 trivector over `R^N`.
alias Trivector(T, size_t N) = KVector!(T, N, 3);

/// Pseudoscalar over `R^N`.
alias Pseudoscalar(T, size_t N) = KVector!(T, N, N);

/// Even multivector used as the rotor carrier type.
alias Rotor(T, size_t N) = EvenMultivector!(T, N);

/// Static basis-word namespace like `Basis!(float, 2).e12`.
///
/// The naming rules intentionally keep the parsing logic clustered:
/// `e12` means `e1 e2`, while `e_12` means the single vector `e12`.
/// For larger indices you can use either identifier-safe forms like `e_10_2`
/// or punctuated forms through [basis], such as `basis!"e(10,2)"()`.
struct Basis(T, size_t N)
if (isNumeric!T && N <= maxSupportedBasisVectors)
{
    static auto opDispatch(string name)()
        => basis!name();

    /// Convenience proxy for widened basis access like `Basis!(T, N).e[10, 2]`.
    @property static BasisProxy!(T, N) e()
        => BasisProxy!(T, N).init;

    /// Static basis-word lookup for forms like `basis!"e(10,2)"()`.
    static auto basis(string name)()
    {
        static assert(
            isBasisWord!(name, N),
            "Invalid basis word `" ~ name ~ "` for this algebra"
        );

        return basisWord!(T, N, name);
    }
}

/// Basis blade with coefficient `1`.
auto basisBlade(T = double, size_t N, size_t mask)()
if (isNumeric!T && N <= maxSupportedBasisVectors && mask < bladeCount!N)
{
    Multivector!(T, N, singletonBladeMask!mask) result;
    result.coeffs[0] = 1;
    return result;
}

/// Basis vector `e_{index + 1}`.
auto basisVector(T = double, size_t N, size_t index)()
if (isNumeric!T && N <= maxSupportedBasisVectors && index < N)
    => basisBlade!(T, N, cast(size_t) 1 << index);

public enum size_t e12Mask2D = 0b11;

/// Converts degrees to radians for the 2D rotor helpers.
auto radiansFromDegrees(T)(T angleDegrees)
if (isNumeric!T)
    => cast(CommonType!(T, double)) angleDegrees * (cast(CommonType!(T, double)) PI / 180);

/// Squared Euclidean norm of a grade-1 vector.
auto normSquared(Mv)(in Mv vector)
if (
    isMultivector!Mv &&
    isNumeric!(MultivectorCoefficient!Mv) &&
    allMasksHaveGrade!(multivectorSupport!Mv, 1)
)
    => vector.scalarProduct(vector);

/// Euclidean norm of a grade-1 vector.
auto norm(Mv)(in Mv vector)
if (
    isMultivector!Mv &&
    isNumeric!(MultivectorCoefficient!Mv) &&
    allMasksHaveGrade!(multivectorSupport!Mv, 1)
)
    => sqrt(cast(CommonType!(MultivectorCoefficient!Mv, double)) normSquared(vector));

/// Returns a unit vector in the same direction.
auto normalized(Mv)(in Mv vector)
if (
    isMultivector!Mv &&
    isNumeric!(MultivectorCoefficient!Mv) &&
    allMasksHaveGrade!(multivectorSupport!Mv, 1)
)
{
    immutable magnitude = norm(vector);

    assert(magnitude != 0, "Cannot normalize the zero vector");
    return vector / magnitude;
}

/// Numeric comparison helper used by debug-only invariant checks.
public bool nearlyEqual(T, U, V = CommonType!(T, U))(
    T lhs,
    U rhs,
    V epsilon = cast(V) 1e-12,
)
if (isNumeric!T && isNumeric!U && isNumeric!V)
{
    alias Result = CommonType!(CommonType!(T, U), V);

    static if (__traits(isFloating, Result))
    {
        return abs(cast(Result) lhs - cast(Result) rhs) <= cast(Result) epsilon;
    }
    else
    {
        return lhs == rhs;
    }
}

/// Debug-only invariant check for normalized rotors.
///
/// With the current `alias Rotor = EvenMultivector`, we cannot enforce this for
/// every value of the carrier type. We can, however, check the values produced
/// by rotor constructors and the values consumed by rotor-based APIs.
public void debugAssertRotor(Mv)(
    in Mv rotor,
    CommonType!(MultivectorCoefficient!Mv, double) epsilon =
        cast(CommonType!(MultivectorCoefficient!Mv, double)) 1e-12,
)
if (
    isMultivector!Mv &&
    isNumeric!(MultivectorCoefficient!Mv) &&
    allMasksHaveParity!(multivectorSupport!Mv, true)
)
{
    debug
    {
        alias ScalarType = CommonType!(MultivectorCoefficient!Mv, double);
        immutable identity = rotor * rotor.reverse();

        static foreach (mask; typeof(identity).support)
        {{
            immutable coeffValue = identity.coefficient!(mask, ScalarType);

            static if (mask == 0b0)
                assert(
                    nearlyEqual(coeffValue, cast(ScalarType) 1, epsilon),
                    "Rotor must satisfy R * reverse(R) == 1"
                );
            else
                assert(
                    nearlyEqual(coeffValue, cast(ScalarType) 0, epsilon),
                    "Rotor must satisfy R * reverse(R) == 1"
                );
        }}
    }
}

/// Counterclockwise 2D rotor for the given angle in radians.
///
/// With [rotated], positive angles follow the usual `e1 -> e2` orientation.
auto planarRotor(T)(T angleRadians)
if (isNumeric!T)
{
    alias ResultScalar = CommonType!(T, double);

    immutable halfAngle = cast(ResultScalar) angleRadians / 2;
    immutable rotor = Rotor!(ResultScalar, 2)(
        cast(ResultScalar) cos(halfAngle),
        -cast(ResultScalar) sin(halfAngle),
    );
    debugAssertRotor(rotor);
    return rotor;
}

/// Unit 2D rotor that maps `from` onto `to`.
///
/// This normalizes both inputs first, so only direction matters.
auto rotorFromTo(From, To)(
    in From from,
    in To to,
)
if (
    isMultivector!From &&
    isMultivector!To &&
    multivectorDimensions!From == 2 &&
    multivectorDimensions!To == 2 &&
    isNumeric!(MultivectorCoefficient!From) &&
    isNumeric!(MultivectorCoefficient!To) &&
    allMasksHaveGrade!(multivectorSupport!From, 1) &&
    allMasksHaveGrade!(multivectorSupport!To, 1)
)
{
    alias ResultScalar = CommonType!(
        CommonType!(MultivectorCoefficient!From, MultivectorCoefficient!To),
        double
    );

    immutable fromUnit = normalized(from);
    immutable toUnit = normalized(to);
    immutable raw = Scalar!(ResultScalar, 2)(1) + toUnit * fromUnit;
    immutable scalar = raw.scalarPart;
    immutable bivector = raw.coefficient!(e12Mask2D, ResultScalar);
    immutable magnitude = sqrt(scalar * scalar + bivector * bivector);

    assert(magnitude != 0, "Cannot build a rotor between opposite vectors");
    immutable rotor = Rotor!(ResultScalar, 2)(scalar / magnitude, bivector / magnitude);
    debugAssertRotor(rotor);
    return rotor;
}

/// Rotates a 2D vector by a unit rotor through sandwiching.
auto rotated(Vector, RotorMv)(
    in Vector vector,
    in RotorMv rotor,
)
if (
    isMultivector!Vector &&
    isMultivector!RotorMv &&
    multivectorDimensions!Vector == 2 &&
    multivectorDimensions!RotorMv == 2 &&
    isNumeric!(MultivectorCoefficient!Vector) &&
    isNumeric!(MultivectorCoefficient!RotorMv) &&
    allMasksHaveGrade!(multivectorSupport!Vector, 1) &&
    allMasksHaveParity!(multivectorSupport!RotorMv, true)
)
{
    debugAssertRotor(rotor);
    return (rotor * vector * rotor.reverse()).gradePart!1;
}

/// Rotates a 2D vector by an angle in radians.
auto rotated(Vector, U)(
    in Vector vector,
    U angleRadians,
)
if (
    isMultivector!Vector &&
    multivectorDimensions!Vector == 2 &&
    isNumeric!(MultivectorCoefficient!Vector) &&
    isNumeric!U &&
    allMasksHaveGrade!(multivectorSupport!Vector, 1)
)
    => rotated(vector, planarRotor(angleRadians));

/// Basic blade-mask metadata and type aliases.
@("VGA.aliasesAndMasks")
@safe pure nothrow @nogc
unittest
{
    static assert(allBladeMasks!3 == [0b000, 0b001, 0b010, 0b011, 0b100, 0b101, 0b110, 0b111]);
    static assert(gradeBladeMasks!(3, 1) == [0b001, 0b010, 0b100]);
    static assert(gradeBladeMasks!(3, 2) == [0b011, 0b101, 0b110]);
    static assert(gradeBladeMasks!(4, 2) == [0b0011, 0b0101, 0b0110, 0b1001, 0b1010, 0b1100]);
    static assert(evenBladeMasks!3 == [0b000, 0b011, 0b101, 0b110]);
    static assert(oddBladeMasks!3 == [0b001, 0b010, 0b100, 0b111]);
    static assert(bladeMaskBitWidth!3 == 3);
    static assert(packedBladeMasksPerWord!4 == size_t.sizeof * 2);
    static assert(
        packBladeMasks!(3, [0b001, 0b010, 0b100]) ==
        [cast(size_t) 0b100_010_001]
    );
    static assert(
        unpackBladeMasks!(3, 3, [cast(size_t) 0b100_010_001]) ==
        [0b001, 0b010, 0b100]
    );
    assert(Basis!(int, 2).e1.gradePart!1 == GAVector!(int, 2)(1, 0));
    assert(Basis!(int, 2).e2.gradePart!1 == GAVector!(int, 2)(0, 1));
    assert(Basis!(int, 2).e12 == Bivector!(int, 2)(1));
    assert(Basis!(int, 2).e1_2 == Bivector!(int, 2)(1));
    assert(Basis!(int, 2).e_1_2 == Bivector!(int, 2)(1));
    assert(Basis!(int, 2).e21 == Bivector!(int, 2)(-1));
    assert(Basis!(int, 2).e11 == Scalar!(int, 2)(1));
    assert(FullMultivector!(int, 2).e12 == Basis!(int, 2).e12);
    static assert(GAVector!(float, 3).support == [0b001, 0b010, 0b100]);
    static assert(GAVector!(float, 3).packedSupport == [cast(size_t) 0b100_010_001]);
    static assert(Rotor!(double, 3).support == [0b000, 0b011, 0b101, 0b110]);
    static assert(Rotor!(double, 3).packedSupport == [cast(size_t) 0b110_101_011_000]);
}

version (VGAHeavyCompileTests)
{
    /// Compile-expensive higher-dimensional basis-word and proxy coverage.
    ///
    /// This stays behind `version (VGAHeavyCompileTests)` so the default math
    /// unittest configuration avoids instantiating the 12D full-support cases.
    /// Enable it with the dedicated `unittest-heavy` dub configuration.
    @("VGA.heavy.aliasesAndMasks12D")
    @safe pure nothrow @nogc
    unittest
    {
        assert(Basis!(int, 12).basis!"e(10,2)"() == Basis!(int, 12).e_10_2);
        assert(Basis!(int, 12).basis!"e[10,2]"() == Basis!(int, 12).e_10_2);
        assert(Basis!(int, 12).basis!"e(2,10)"() == Basis!(int, 12).e_2_10);
        assert(Basis!(int, 12).e_2_10 == -Basis!(int, 12).e_10_2);
        assert(FullMultivector!(int, 12).basis!"e[10,2]"() == Basis!(int, 12).e_10_2);

        enum e10e2Mask = (cast(size_t) 1 << 9) ^ (cast(size_t) 1 << 1);

        auto widened10_2 = Basis!(int, 12).e[10, 2];
        assert(widened10_2.coefficient!e10e2Mask == -1);
        assert(widened10_2.coeff!e10e2Mask == -1);
        assert(widened10_2[e10e2Mask] == -1);
        assert(FullMultivector!(int, 12).e[10, 2].coefficient!e10e2Mask == -1);

        auto widened2_10 = Basis!(int, 12).e[2, 10];
        assert(widened2_10[e10e2Mask] == 1);
        assert(widened2_10 == -widened10_2);

        auto e = Basis!(int, 12).e;
        assert(e(10, 2) == widened10_2);
    }
}

/// Basis vectors generate the Euclidean algebra relations.
@("VGA.basisProducts")
@safe pure nothrow @nogc
unittest
{
    alias Vec3 = GAVector!(float, 3);
    alias E3 = Basis!(float, 3);

    enum e1 = E3.e1;
    enum e2 = E3.e2;
    enum e3 = E3.e3;

    static assert(typeof(e1 * e2).support == [0b011]);
    static assert(typeof(e2 * e1).support == [0b011]);

    assert((e1 * e1).scalarPart == 1);
    assert((e2 * e2).scalarPart == 1);
    assert((e3 * e3).scalarPart == 1);

    assert((e1 ^ e2).gradePart!2 == Bivector!(float, 3)(1, 0, 0));
    assert((e2 ^ e1).gradePart!2 == Bivector!(float, 3)(-1, 0, 0));
    assert((e1 * e2).gradePart!2 == Bivector!(float, 3)(1, 0, 0));
    assert((e2 * e1).gradePart!2 == Bivector!(float, 3)(-1, 0, 0));

    Vec3 a = Vec3(2, -3, 5);
    Vec3 b = Vec3(7, 11, 13);

    assert(a.scalarProduct(b) == 2 * 7 + (-3) * 11 + 5 * 13);
}

/// Grade extraction and involutions preserve the expected signs.
@("VGA.gradePartsAndInvolutions")
@safe pure nothrow @nogc
unittest
{
    alias Mv3 = FullMultivector!(int, 3);

    auto mv = Mv3(1, 2, 3, 4, 5, 6, 7, 8);

    assert(mv.gradePart!0 == Scalar!(int, 3)(1));
    assert(mv.gradePart!1 == GAVector!(int, 3)(2, 3, 5));
    assert(mv.gradePart!2 == Bivector!(int, 3)(4, 6, 7));
    assert(mv.gradePart!3 == Trivector!(int, 3)(8));

    assert(mv.reverse() == Mv3(1, 2, 3, -4, 5, -6, -7, -8));
    assert(mv.gradeInvolution() == Mv3(1, -2, -3, 4, -5, 6, 7, -8));
    assert(mv.cliffordConjugate() == Mv3(1, -2, -3, -4, -5, -6, -7, 8));
}

/// Rotor aliases remain specialized to even-grade storage.
@("VGA.rotorAlias")
@safe pure nothrow @nogc
unittest
{
    alias Rotor3f = Rotor!(float, 3);

    auto rotor = Rotor3f(1, 2, 3, 4);
    assert(rotor.scalarPart == 1);
    assert(rotor.gradePart!2 == Bivector!(float, 3)(2, 3, 4));
}

/// Runtime arithmetic remains explicitly `@nogc`.
@("VGA.nogcArithmetic")
@safe pure nothrow @nogc
unittest
{
    alias Vec3 = GAVector!(float, 3);

    Vec3 a = Vec3(1, 2, 3);
    Vec3 b = Vec3(4, 5, 6);

    assert(a + b == Vec3(5, 7, 9));
    assert(a - b == Vec3(-3, -3, -3));
    assert(a * 2 == Vec3(2, 4, 6));
    assert(2 * a == Vec3(2, 4, 6));

    assert(a.coefficient!0b001 == 1);
    assert(a.coeff!0b010 == 2);
    assert(a[0b100] == 3);
    assert(a[0b011] == 0);
}

/// Sparkles writer utilities can render multivectors through `writeValue`.
@("VGA.sparklesWriterInterop")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import sparkles.core_cli.text_writers : writeValue;

    SmallBuffer!(char, 64) buf;

    auto mv = Basis!(int, 3).e12;
    // static assert(hasNogcOutputRangeToString!(typeof(mv)));

    writeValue(buf, mv);
    assert(buf[] == "1*e12");
}

/// Reproduces the six 2D `u v w` products from:
/// Source: `From Zero to Geo`, `https://youtu.be/KBmxE5XzW1E`,
/// section `01:43 Exercise from the previous video`.
@("VGA.fromZeroToGeo.uvwExamples2D")
@safe pure nothrow @nogc
unittest
{
    alias E2 = Basis!(int, 2);
    enum e1 = E2.e1;
    enum e2 = E2.e2;

    {
        auto u = -e1;
        auto v = e1;
        auto w = e2;

        assert(u * v * w == -e2);
    }

    {
        auto u = e2;
        auto v = e1;
        auto w = 2 * e1 + e2;

        assert(u * v * w == -e1 + 2 * e2);
    }

    {
        auto u = -e1 + e2;
        auto v = e1;
        auto w = 2 * e1 + e2;

        assert(u * v * w == -3 * e1 + e2);
    }

    {
        auto u = -e1 - 2 * e2;
        auto v = e1;
        auto w = 2 * e1 + e2;

        assert(u * v * w == -5 * e2);
    }

    {
        auto u = -e1 - e2;
        auto v = e1 + e2;
        auto w = e2;

        assert(u * v * w == -2 * e2);
    }

    {
        auto u = e1;
        auto v = e1 + e2;
        auto w = -e2;

        assert(u * v * w == -e1 - e2);
    }
}

/// Reproduces the 2D rotation exercise from:
/// Source: `From Zero to Geo`, `https://youtu.be/KBmxE5XzW1E`,
/// section `07:51 Rotating exercise`.
@("VGA.fromZeroToGeo.rotatingExercise2D")
@safe pure nothrow @nogc
unittest
{
    alias Vec2 = GAVector!(double, 2);
    alias E2 = Basis!(double, 2);

    bool nearlyEqual(double lhs, double rhs, double epsilon = 1e-12)
        => abs(lhs - rhs) <= epsilon;

    void assertVec2Near(Vec2 actual, Vec2 expected)
    {
        assert(nearlyEqual(actual.coeffs[0], expected.coeffs[0]));
        assert(nearlyEqual(actual.coeffs[1], expected.coeffs[1]));
    }

    Vec2 vec2(double x, double y)
        => Vec2(x, y);

    enum e1 = E2.e1;
    enum e2 = E2.e2;

    immutable ninetyDegrees = radiansFromDegrees(90.0);
    immutable fortyFiveDegrees = radiansFromDegrees(45.0);
    immutable diagonalRotor = rotorFromTo(e1 + 5 * e2, e2);
    immutable root2 = sqrt(2.0);
    immutable root26 = sqrt(26.0);

    immutable Vec2[3] vectors = [
        3 * e1 + 2 * e2,
        e1 - 2 * e2,
        -e1 + e2,
    ];

    immutable Vec2[3] expected90 = [
        vec2(-2, 3),
        vec2(2, 1),
        vec2(-1, -1),
    ];

    immutable Vec2[3] expected45 = [
        vec2(1 / root2, 5 / root2),
        vec2(3 / root2, -1 / root2),
        vec2(-root2, 0),
    ];

    immutable Vec2[3] expectedDiagonal = [
        vec2(13 / root26, 13 / root26),
        vec2(7 / root26, -9 / root26),
        vec2(-6 / root26, 4 / root26),
    ];

    foreach (i, vector; vectors)
    {
        assertVec2Near(rotated(vector, ninetyDegrees), expected90[i]);
        assertVec2Near(rotated(vector, fortyFiveDegrees), expected45[i]);
        assertVec2Near(rotated(vector, diagonalRotor), expectedDiagonal[i]);
    }
}
