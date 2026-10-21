/**
The project's one vector type: `Vector!(T, N, layout, names)`.

$(B Named components, no union.) A vector is one private array of its
components, and each name (`x`, `y`; or `width`, `height`; or `col`, `row`)
is a `ref` accessor to one of them. So a vector constructed at compile time
can be read at compile time, and reflection sees one field, not two views of
the same bytes.

$(B Two layouts.) `Layout.packed`, the default, is `T[N]`, aligned as one
`T`: dense storage for geometry, sizes and cells. `Layout.device` is how a
GPU lays a vector out: two components take twice a component's size and
alignment, three and four take four times (a `float3` is 16 bytes). The
shader vocabulary's `float2`–`float4` are device vectors, so a value, a
struct field or an array element holding one means the same bytes on the
host as on the device.

$(B Storage follows the compiler.) A device vector of `float`, `int` or
`uint` stores a `__vector` where that is what the compiler wants and handles
correctly: always in a dcompute device build, where it is what a shader's
interface must be, and on the host under an LDC whose CTFE evaluates vector
operations, for two and four components. Everywhere else, DMD always, it
stores a `T[N]`. The layout, the operations and their results are the same
either way; only the code the compiler generates differs.

$(B Operations.) Component-wise `+ - * /` against a vector of the same
length (whatever its names or layout) or a scalar on either side, their
assignment forms, unary `-`, `==` meaning every component is equal,
`v[i]`, `v.array`, construction from every component (by name too), from
one broadcast value, or from a shorter vector and a last component, and
swizzles: `v.yx`, `v.xxz`, `v.rgb`, read and written.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.math.vector;

import std.traits : CommonType, isFloatingPoint, isNumeric;

import sparkles.math.device : compute, CompileFor, vectorType;

/// How a vector is laid out in memory.
enum Layout
{
    /// The components back to back, aligned as one component: `T[N]`.
    packed,
    /// As a GPU lays a vector out: two components take twice a component's
    /// size and alignment, three and four take four times.
    device,
}

/// The size, and alignment, of a device-layout vector of `N` `T`s.
enum size_t deviceVectorSize(T, size_t N) = (N == 1 ? 1 : N == 2 ? 2 : 4) * T.sizeof;

/// Whether `V` is a $(LREF Vector).
enum bool isVector(V) = is(V : Vector!(U, M, L, nm), U, size_t M, Layout L, string[] nm);

// Whether this compiler's CTFE evaluates operations on `__vector`s
// (dlang/dmd#21823). Where it does not, a vector that stores one could not be
// a compile-time constant.
version (LDC)
    private enum bool vectorCtfe = __traits(compiles, {
        enum r = () { __vector(float[4]) a = 1; a = a + a; return a[0]; }();
        static assert(r == 2);
    });
else
    private enum bool vectorCtfe = false;

private enum bool isLane(T) = is(T == float) || is(T == int) || is(T == uint);

// Whether a vector stores a `__vector`: a device vector of 32-bit lanes, on
// the device always, on the host where CTFE handles it and for the widths a
// released LDC lays out like LLVM does (a three-wide `__vector` is 12 bytes
// to it, 16 to LLVM).
version (LDC_DCompute)
    private enum bool nativeStorage(T, size_t N, Layout layout) =
        layout == Layout.device && isLane!T && N >= 2 && N <= 4;
else
    private enum bool nativeStorage(T, size_t N, Layout layout) =
        layout == Layout.device && isLane!T && vectorCtfe && (N == 2 || N == 4);

private template decimal(size_t i)
{
    static if (i < 10)
        enum string decimal = "0123456789"[i .. i + 1];
    else
        enum string decimal = decimal!(i / 10) ~ decimal!(i % 10);
}

private template generatedNames(size_t N)
{
    static if (N == 0)
        enum string[] generatedNames = [];
    else
        enum string[] generatedNames = generatedNames!(N - 1) ~ ("v" ~ decimal!(N - 1));
}

/// The component names a vector of `N` gets by default: `x`, `y`, `z`, `w`,
/// or `v0`, `v1`, … beyond four.
template defaultNames(size_t N)
{
    static if (N <= 4)
        enum string[] defaultNames = ["x", "y", "z", "w"][0 .. N];
    else
        enum string[] defaultNames = generatedNames!N;
}

// The component a swizzle letter names: one of the vector's own one-letter
// names, or, for a vector with the default names, `rgba` for `xyzw`; -1 for
// none. `set` is which spelling it is, since a swizzle may not mix them.
private template swizzleComponent(string[] names, char c)
{
    enum int own = () {
        foreach (i, n; names)
            if (n.length == 1 && n[0] == c)
                return cast(int) i;
        return -1;
    }();
    enum int colour = () {
        if (names != defaultNames!(names.length) || names.length > 4)
            return -1;
        foreach (i, n; "rgba"[0 .. names.length])
            if (n == c)
                return cast(int) i;
        return -1;
    }();
    enum int index = own >= 0 ? own : colour;
    enum int set = own >= 0 ? 0 : colour >= 0 ? 1 : -1;
}

private template swizzleIndices(string[] names, string s)
{
    enum size_t[s.length] swizzleIndices = () {
        size_t[s.length] r;
        static foreach (k; 0 .. s.length)
            r[k] = swizzleComponent!(names, s[k]).index;
        return r;
    }();
}

// Whether `s` is a swizzle of a vector named `names`: one to four letters,
// each naming a component, all from one spelling.
private template isSwizzle(string[] names, string s)
{
    enum bool isSwizzle = () {
        if (s.length < 1 || s.length > 4)
            return false;
        int set = -2;
        static foreach (k; 0 .. s.length)
        {{
            alias c = swizzleComponent!(names, s[k]);
            if (c.index < 0 || (set != -2 && c.set != set))
                return false;
            set = c.set;
        }}
        return true;
    }();
}

private template hasRepeats(string[] names, string s)
{
    enum bool hasRepeats = () {
        enum idx = swizzleIndices!(names, s);
        foreach (i; 0 .. idx.length)
            foreach (j; i + 1 .. idx.length)
                if (idx[i] == idx[j])
                    return true;
        return false;
    }();
}

private template join(string[] parts, string sep)
{
    static if (parts.length == 0)
        enum string join = "";
    else static if (parts.length == 1)
        enum string join = parts[0];
    else
        enum string join = parts[0] ~ sep ~ join!(parts[1 .. $], sep);
}

private template parameters(string[] names)
{
    static if (names.length == 0)
        enum string[] parameters = [];
    else
        enum string[] parameters = parameters!(names[0 .. $ - 1]) ~ ("T " ~ names[$ - 1]);
}

private template assignments(string[] names)
{
    static if (names.length == 0)
        enum string assignments = "";
    else
        enum string assignments = assignments!(names[0 .. $ - 1])
            ~ "_c[" ~ decimal!(names.length - 1) ~ "] = " ~ names[$ - 1] ~ "; ";
}

private enum bool isArithmetic(string op) = op == "+" || op == "-" || op == "*" || op == "/";

// The UDA a vector carries: `@vectorType` where it stores a `__vector`.
private template marker(bool native)
{
    import std.meta : AliasSeq;

    static if (native)
        alias marker = vectorType;
    else
        alias marker = AliasSeq!();
}

/**
A vector of `N` components of type `T`, laid out as `layout`, with the
components named `names`.
*/
template Vector(T, size_t N, Layout layout = Layout.packed, string[] names = defaultNames!N)
if (isNumeric!T && N > 0)
{
    @(marker!(nativeStorage!(T, N, layout)))
    struct Vector
    {
        static assert(names.length == N, "a vector names each of its components");
        static assert(layout == Layout.packed || N <= 4, "a device vector has one to four components");

        /// The component type, the count, the layout and the names.
        alias Component = T;
        /// ditto
        enum size_t dimension = N;
        /// ditto
        enum Layout memoryLayout = layout;
        /// ditto
        enum string[] componentNames = names;

        private enum bool native = nativeStorage!(T, N, layout);

        static if (native)
            private alias Storage = __vector(T[N]);
        else
            private alias Storage = T[N];

        // The components. One field, so reflection sees one, and no union, so
        // CTFE reads it; the names below are accessors.
        align(layout == Layout.device ? deviceVectorSize!(T, N) : T.alignof)
        private Storage _c = 0;

        static foreach (i, name; names)
            mixin("@property ref inout(T) ", name, "() inout return => _c[", decimal!i, "];");

        /// Constructs a vector from every component, which may be passed by
        /// name: `Vector!(int, 2, Layout.packed, ["col", "row"])(col: 3, row: 4)`.
        mixin("this(" ~ join!(parameters!names, ", ") ~ ") { " ~ assignments!names ~ "}");

        static if (N > 1)
        {
            /// Constructs a vector with every component `value`.
            this(T value)
            {
                static foreach (i; 0 .. N)
                    _c[i] = value;
            }

            /// Constructs a vector from a vector of the first `N - 1`
            /// components and the last one: GLSL's `vec4(rgb, a)`.
            this(V)(const V head, T last)
            if (isVector!V && V.dimension == N - 1)
            {
                static foreach (i; 0 .. N - 1)
                    _c[i] = cast(T) head._c[i];
                _c[N - 1] = last;
            }
        }

        /// Component `i`; out of range, a bounds error on the host. (No
        /// contract: device code has no assertions.)
        ref inout(T) opIndex(size_t i) inout return => _c[i];

        /// ditto
        enum size_t opDollar = N;

        /// Whether this vector stores a `__vector`, and that vector: what an
        /// LLVM intrinsic over vectors takes, so that a function of a vector
        /// can be one vector instruction where the storage is one.
        enum bool storesNative = native;

        static if (native)
        {
            /// ditto
            alias NativeVector = Storage;

            /// ditto
            ref inout(Storage) nativeVector() inout return => _c;
        }

        /// The components, as a static array.
        T[N] array() const
        {
            static if (native)
                return _c.array;
            else
                return _c;
        }

        static if (!native)
        {
            /// The components as a slice of this vector's own storage (`v[]`).
            inout(T)[] opIndex() inout return => _c[];

            /// ditto (`v[1 .. 3]`)
            inout(T)[] opSlice(size_t i, size_t j) inout return => _c[i .. j];
        }

        // The operands are `const` values, not `in`: under `-preview=in` an
        // `in` struct of more than 8 bytes is a reference on Win64, and LDC
        // 1.42's CTFE crashes evaluating such a call in a function's `enum`.

        /// Component-wise arithmetic against a vector of the same length,
        /// whatever its names or layout. The result has this vector's names and
        /// layout and the common component type.
        auto opBinary(string op, V)(const V rhs) const
        if (isArithmetic!op && isVector!V && V.dimension == N)
        {
            alias R = CommonType!(T, V.Component);
            .Vector!(R, N, layout, names) r;
            static if (native && is(R == T) && is(V.Storage == Storage))
                r._c = mixin("_c " ~ op ~ " rhs._c");
            else
                static foreach (i; 0 .. N)
                    r._c[i] = cast(R) mixin("_c[i] " ~ op ~ " rhs._c[i]");
            return r;
        }

        /// Component-wise arithmetic against one value, on either side.
        auto opBinary(string op, U)(const U rhs) const
        if (isArithmetic!op && isNumeric!U)
        {
            alias R = CommonType!(T, U);
            .Vector!(R, N, layout, names) r;
            static if (native && is(R == T))
            {
                Storage b = rhs;
                r._c = mixin("_c " ~ op ~ " b");
            }
            else
                static foreach (i; 0 .. N)
                    r._c[i] = cast(R) mixin("_c[i] " ~ op ~ " rhs");
            return r;
        }

        /// ditto
        auto opBinaryRight(string op, U)(const U lhs) const
        if (isArithmetic!op && isNumeric!U)
        {
            alias R = CommonType!(T, U);
            .Vector!(R, N, layout, names) r;
            static if (native && is(R == T))
            {
                Storage b = lhs;
                r._c = mixin("b " ~ op ~ " _c");
            }
            else
                static foreach (i; 0 .. N)
                    r._c[i] = cast(R) mixin("lhs " ~ op ~ " _c[i]");
            return r;
        }

        /// In-place component-wise arithmetic, against a vector or a value.
        ref Vector opOpAssign(string op, V)(const V rhs) return
        if (isArithmetic!op && (isVector!V && V.dimension == N || isNumeric!V))
        {
            static if (isVector!V)
            {
                static if (native && is(V.Storage == Storage))
                    mixin("_c " ~ op ~ "= rhs._c;");
                else
                    static foreach (i; 0 .. N)
                        _c[i] = cast(T) mixin("_c[i] " ~ op ~ " rhs._c[i]");
            }
            else
            {
                static if (native)
                {
                    Storage b = cast(T) rhs;
                    mixin("_c " ~ op ~ "= b;");
                }
                else
                    static foreach (i; 0 .. N)
                        _c[i] = cast(T) mixin("_c[i] " ~ op ~ " rhs");
            }
            return this;
        }

        /// Negation, and its identity.
        Vector opUnary(string op)() const
        if (op == "-" || op == "+")
        {
            static if (op == "+")
                return this;
            else
            {
                Vector r;
                static if (native)
                    r._c = -_c;
                else
                    static foreach (i; 0 .. N)
                        r._c[i] = cast(T) -_c[i];
                return r;
            }
        }

        /// Whether every component equals the one of `rhs`: one `bool`, GLSL's
        /// `==` on vectors (D's `==` on a `__vector` is a mask).
        bool opEquals(V)(const V rhs) const
        if (isVector!V && V.dimension == N)
        {
            bool same = true;
            static foreach (i; 0 .. N)
                same = same & (_c[i] == rhs._c[i]);
            return same;
        }

        /// The dot product with a vector of the same length, as the free
        /// $(LREF dot) computes it: `a.dot(b)`.
        auto dot(V)(const V rhs) const
        if (isVector!V && V.dimension == N)
            => .dot(this, rhs);

        version (LDC_DCompute) {} else
        {
            /// The hash of the components, so a vector can key an associative
            /// array.
            size_t toHash() const @safe pure nothrow @nogc
            {
                const T[N] a = array;
                return hashOf(a);
            }
        }

        /// A swizzle: the components named by the letters of `s`, in order and
        /// repeating as they like (`v.yx`, `v.xxz`; `v.rgb` where the names are
        /// the default ones), as a vector. A name that is not a swizzle is not a
        /// member.
        auto opDispatch(string s)() const
        if (isSwizzle!(names, s))
        {
            enum idx = swizzleIndices!(names, s);
            static if (s.length == 1)
                return _c[idx[0]]; // one letter is the component, as in GLSL
            else
            {
                .Vector!(T, s.length, layout) r;
                static foreach (k; 0 .. s.length)
                    r._c[k] = _c[idx[k]];
                return r;
            }
        }

        /// ditto: writes the component one letter names.
        void opDispatch(string s, U)(const U rhs)
        if (isSwizzle!(names, s) && s.length == 1 && isNumeric!U)
        {
            enum idx = swizzleIndices!(names, s);
            _c[idx[0]] = cast(T) rhs;
        }

        /// Writes the components a swizzle names, which must not repeat.
        void opDispatch(string s, V)(const V rhs)
        if (isSwizzle!(names, s) && isVector!V && V.dimension == s.length)
        {
            static assert(!hasRepeats!(names, s),
                "a swizzle that is written names each component once");
            enum idx = swizzleIndices!(names, s);
            static foreach (k; 0 .. s.length)
                _c[idx[k]] = cast(T) rhs._c[k];
        }

        /// The components as an unnamed `std.typecons.Tuple`.
        auto asTuple() const
        {
            import std.meta : Repeat;
            import std.typecons : Tuple;

            Tuple!(Repeat!(N, T)) t;
            static foreach (i; 0 .. N)
                t[i] = _c[i];
            return t;
        }

        /// Formats the vector using the Sparkles pretty-printing protocol.
        void writePretty(Writer, Opts)(ref Writer writer, in Opts opts, ushort depth = 0) const
        {
            import sparkles.base.prettyprint : prettyPrintTuple;

            prettyPrintTuple(writer, this.asTuple, opts, depth);
        }

        /// Writes the vector as `(1, 2, ...)`.
        void toString(Writer)(ref Writer w) const
        {
            import sparkles.base.prettyprint : PrettyPrintOptions;

            this.writePretty(w, PrettyPrintOptions!void.plainText, 0);
        }

        static if (isFloatingPoint!T)
        {
            /// The vector with every component infinity.
            enum Vector infinity = () {
                Vector r;
                static foreach (i; 0 .. N)
                    r._c[i] = T.infinity;
                return r;
            }();
        }
    }
}

/// The vector of type `V` whose storage is `v`, for a `V` that stores a
/// `__vector`: the inverse of `nativeVector`.
V fromNative(V)(V.NativeVector v)
if (isVector!V && V.storesNative)
{
    V r;
    r.nativeVector = v;
    return r;
}

/// The dot product of two vectors of the same length.
auto dot(V, W)(const V a, const W b)
if (isVector!V && isVector!W && V.dimension == W.dimension)
{
    alias R = CommonType!(V.Component, W.Component);
    R r = 0;
    static foreach (i; 0 .. V.dimension)
        r += cast(R) a[i] * cast(R) b[i];
    return r;
}

/// 2D float vector.
alias Vec2f = Vector!(float, 2);

/// 3D float vector.
alias Vec3f = Vector!(float, 3);

/// 4D float vector.
alias Vec4f = Vector!(float, 4);

/// Named 2D vector for pixel dimensions.
alias ScreenSize(T) = Vector!(T, 2, Layout.packed, ["width", "height"]);

/// 2D vector for a position / coordinate (fields `x`, `y`). The companion of
/// $(LREF ScreenSize) for absolute points (mouse cell, cursor cell) rather than
/// extents.
alias ScreenPosition(T) = Vector!(T, 2);
