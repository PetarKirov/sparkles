/**
Vector primitives for linear algebra in game and graphics code.

Provides a fixed-size numeric vector type with optional named fields,
component-wise arithmetic, scalar operations, dot product, and aliases
for common vector sizes.
*/
module sparkles.math.vector;

import std.traits : CommonType, isNumeric;

@safe:

private enum baseFieldNames = ["x", "y", "z", "w"];

private string[] makeDefaultFieldNames(size_t N)()
{
    static if (N <= baseFieldNames.length)
    {
        return baseFieldNames[0 .. N];
    }
    else
    {
        import std.conv : to;

        string[N] generated = void;
        static foreach (i; 0 .. N)
            generated[i] = "v" ~ i.to!string;
        return generated[];
    }
}

/// Fixed-size numeric vector with optional named components.
struct Vector(T, size_t N, string[] fieldNames = makeDefaultFieldNames!N)
if (isNumeric!T && N > 0)
{
    static assert(
        fieldNames.length == N,
        "fieldNames must have exactly N entries"
    );

    union
    {
        T[N] data = 0;
        struct
        {
            static foreach (field; fieldNames)
                mixin("T " ~ field ~ ";");
        }
    }

    private alias CommonVector(U) = Vector!(CommonType!(T, U), N, fieldNames);

    static foreach (i; 1 .. N + 1)
    {
        /// Initializes the first `i` components from constructor arguments.
        this(T[i] values...)
        @safe pure nothrow @nogc
        {
            data[0 .. i] = values[0 .. i];
        }
    }

    /// Component-wise vector addition/subtraction.
    CommonVector!U opBinary(string op, U)(in Vector!(U, N) rhs) const
    if ((op == "+" || op == "-") && isNumeric!U)
    {
        CommonVector!U result;
        foreach (i, ref elem; result.data)
            elem = mixin("this.data[i] " ~ op ~ " rhs.data[i]");
        return result;
    }

    /// In-place component-wise vector addition/subtraction.
    ref Vector opOpAssign(string op)(in Vector rhs)
    if (op == "+" || op == "-")
    {
        foreach (i, ref elem; data)
            elem = mixin("elem " ~ op ~ " rhs.data[i]");
        return this;
    }

    /// Component-wise scalar multiplication/division.
    CommonVector!U opBinary(string op, U)(U rhs) const
    if ((op == "*" || op == "/") && isNumeric!U)
    {
        CommonVector!U result;
        foreach (i, ref elem; result.data)
            elem = mixin("this.data[i] " ~ op ~ " rhs");
        return result;
    }

    /// Scalar multiplication/division where scalar is on the left side.
    CommonVector!U opBinaryRight(string op, U)(U lhs) const
    if ((op == "*" || op == "/") && isNumeric!U)
    {
        static if (op == "*")
        {
            return this * lhs;
        }
        else
        {
            CommonVector!U result;
            foreach (i, ref elem; result.data)
                elem = lhs / data[i];
            return result;
        }
    }

    /// Dot product between two vectors.
    CommonType!(T, U) dot(U)(in Vector!(U, N) rhs) const
    if (isNumeric!U)
    {
        CommonType!(T, U) result = 0;
        foreach (i; 0 .. N)
            result += cast(CommonType!(T, U)) data[i] * rhs.data[i];
        return result;
    }

    /// Writes the vector as `(name0: value0, name1: value1, ...)`.
    void toString(W)(scope ref W writer) const
    {
        import std.format : formattedWrite;

        formattedWrite(writer, "(");
        static foreach (i; 0 .. N)
        {
            if (i != 0)
                formattedWrite(writer, ", ");
            formattedWrite(writer, "%s: %s", fieldNames[i], data[i]);
        }
        formattedWrite(writer, ")");
    }

    static if (__traits(isFloating, T))
    {
        /// Vector with all components set to floating-point infinity.
        enum infinity = ()
        {
            typeof(this) result;
            result.data[] = T.infinity;
            return result;
        }();
    }
}

/// 2D float vector.
alias Vec2f = Vector!(float, 2);

/// 3D float vector.
alias Vec3f = Vector!(float, 3);

/// 4D float vector.
alias Vec4f = Vector!(float, 4);

/// Named 2D vector for pixel dimensions.
alias ScreenSize(T) = Vector!(T, 2, ["width", "height"]);

/// Default initialization and partial constructors.
@("Vector.initialization")
@safe pure nothrow @nogc
unittest
{
    auto v2 = Vec2f();
    assert(v2.x == 0);
    assert(v2.y == 0);

    auto v0 = Vec3f();
    assert(v0 == Vec3f(0, 0, 0));

    auto v1 = Vec3f(1f);
    assert(v1 == Vec3f(1, 0, 0));

    auto v3 = Vec3f(1, 2, 3);
    assert(v3.x == 1);
    assert(v3.y == 2);
    assert(v3.z == 3);
}

/// Component-wise arithmetic and in-place updates.
@("Vector.arithmetic")
@safe pure nothrow @nogc
unittest
{
    assert(Vec3f(1, 2, 3) + Vec3f(4, 5, 6) == Vec3f(5, 7, 9));
    assert(Vec3f(4, 5, 6) - Vec3f(1, 2, 3) == Vec3f(3, 3, 3));

    Vec3f accum = Vec3f(1, 2, 3);
    accum += Vec3f(4, 5, 6);
    assert(accum == Vec3f(5, 7, 9));

    accum -= Vec3f(2, 2, 2);
    assert(accum == Vec3f(3, 5, 7));
}

/// Scalar operations with vectors on either side.
@("Vector.scalarArithmetic")
@safe pure nothrow @nogc
unittest
{
    assert(Vec3f(1, 2, 3) * 2 == Vec3f(2, 4, 6));
    assert(Vec3f(1, 2, 3) / 2 == Vec3f(0.5, 1, 1.5));
    assert(2 * Vec2f(1, 2) == Vec2f(2, 4));
    assert(2 / Vec2f(1, 2) == Vec2f(2, 1));
}

/// Dot product works for mixed numeric vector types.
@("Vector.dot")
@safe pure nothrow @nogc
unittest
{
    assert(Vec2f(1, 2).dot(Vector!(int, 2)(3, 4)) == 11);
    static assert(is(typeof(Vec2f(1, 2).dot(Vector!(int, 2)(3, 4))) == float));
}

/// Custom component names and aliases.
@("Vector.customFieldNames")
@safe pure nothrow @nogc
unittest
{
    alias Color = Vector!(ubyte, 3, ["r", "g", "b"]);
    auto pink = Color(255, 192, 203);
    assert(pink.r == 255);
    assert(pink.g == 192);
    assert(pink.b == 203);

    auto screen = ScreenSize!uint(1920, 1080);
    assert(screen.width == 1920);
    assert(screen.height == 1080);
}

/// String formatting for debugging and logging.
@("Vector.toString")
@safe
unittest
{
    import std.array : appender;

    auto buf = appender!string();
    Vec3f(1, 2, 3).toString(buf);
    assert(buf[] == "(x: 1, y: 2, z: 3)");
}

/// Floating-point vectors expose an infinity constant.
@("Vector.infinity")
@safe pure nothrow @nogc
unittest
{
    const inf = Vec3f.infinity;
    static foreach (i; 0 .. 3)
        static assert(inf.data[i] is float.infinity);
}
