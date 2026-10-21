/**
The math library's tests, kept out of the modules they exercise.

`sparkles.math.vector` also compiles for a GPU, and a module that does may
hold no string literal, which a test's name is. So it carries no tests of its
own, and this host-only module carries them.
*/
module sparkles.math.testing;

import sparkles.math.vector;

private alias F2 = Vector!(float, 2, Layout.device);
private alias F3 = Vector!(float, 3, Layout.device);
private alias F4 = Vector!(float, 4, Layout.device);
private alias Cell = Vector!(ushort, 2, Layout.packed, ["col", "row"]);

/// A packed vector is its components back to back; a device vector is laid
/// out as a GPU lays it out.
@("Vector.layout")
@safe pure nothrow @nogc
unittest
{
    static assert(Vec3f.sizeof == 12 && Vec3f.alignof == 4);
    static assert(Cell.sizeof == 4 && Cell.alignof == 2);
    static assert(F2.sizeof == 8 && F2.alignof == 8);
    static assert(F3.sizeof == 16 && F3.alignof == 16);
    static assert(F4.sizeof == 16 && F4.alignof == 16);
    static assert(Vector!(int, 3, Layout.device).sizeof == 16);
    static assert(Vector!(ubyte, 4, Layout.device).sizeof == 4);
}

/// Every vector, of either layout, is a compile-time value too: its
/// components are read and written in CTFE.
@("Vector.ctfe")
@safe pure nothrow @nogc
unittest
{
    enum k = F4(1, 2, 3, 4) + F4(1);
    static assert(k.x == 2 && k.w == 5);
    static assert(k.array == [2f, 3, 4, 5]);
    enum s = () { Vec3f v; v.y = 7; v[2] = 9; return v; }();
    static assert(s == Vec3f(0, 7, 9));
    static immutable F3 table = F3(1, 2, 3) * 2;
    assert(table == F3(2, 4, 6));
}

/// A vector is constructed from every component, by position or by name,
/// from one broadcast value, or from a shorter vector and a last component.
@("Vector.construction")
@safe pure nothrow @nogc
unittest
{
    assert(Vec2f() == Vec2f(0, 0));
    assert(Vec3f(1, 2, 3).z == 3);
    assert(Cell(col: 3, row: 4).row == 4);
    assert(Cell(row: 4, col: 3) == Cell(3, 4));
    assert(F4(2) == F4(2, 2, 2, 2));
    assert(F4(F3(1, 2, 3), 9) == F4(1, 2, 3, 9));
    static assert(!__traits(compiles, Vec3f(1, 2)), "no zero-filled partial construction");
}

/// Components are read and written by name and by index.
@("Vector.components")
@safe pure nothrow @nogc
unittest
{
    auto v = Vec3f(1, 2, 3);
    v.x = 10;
    v[1] += 5;
    assert(v.x == 10 && v.y == 7 && v[$ - 1] == 3);
    assert(v.array == [10f, 7, 3]);

    auto size = ScreenSize!uint(1920, 1080);
    size.width -= 20;
    assert(size.width == 1900 && size.height == 1080);
}

/// Arithmetic is component-wise against a vector of the same length,
/// whatever its names or layout, and against a scalar on either side.
@("Vector.arithmetic")
@safe pure nothrow @nogc
unittest
{
    assert(Vec3f(1, 2, 3) + Vec3f(4, 5, 6) == Vec3f(5, 7, 9));
    assert(F4(4) - F4(1, 2, 3, 4) == F4(3, 2, 1, 0));
    assert(F2(2, 3) * F2(4, 5) == F2(8, 15));
    assert(Vec2f(1, 2) * 2 == Vec2f(2, 4));
    assert(2 / Vec2f(1, 2) == Vec2f(2, 1));
    assert(-F3(1, -2, 3) == F3(-1, 2, -3));

    alias Size = ScreenSize!int;
    assert(Size(2, 3) + Size(1, 1) == Size(3, 4), "two custom-named vectors add");
    assert((Vector!(int, 2)(1, 2) + Vec2f(0.5, 0.5)) == Vec2f(1.5, 2.5));

    auto acc = Cell(1, 2);
    acc += Cell(1, 1);
    acc *= 2;
    assert(acc == Cell(4, 6));
    assert(dot(Vec2f(1, 2), Vector!(int, 2)(3, 4)) == 11);
    assert(Vec2f(1, 2).dot(Vector!(int, 2)(3, 4)) == 11);
}

/// A swizzle reads, and writes, the components its letters name; `rgba`
/// spells `xyzw` for a vector with the default names.
@("Vector.swizzle")
@safe pure nothrow @nogc
unittest
{
    auto v = F4(1, 2, 3, 4);
    assert(v.zyx == F3(3, 2, 1));
    assert(v.xxyy == F4(1, 1, 2, 2));
    assert(v.rgb == F3(1, 2, 3) && v.a == 4);
    v.xy = F2(9, 8);
    v.ba = Vec2f(7, 6);
    assert(v == F4(9, 8, 7, 6));

    static assert(!__traits(compiles, v.xx = F2(1, 2)), "a written swizzle names each once");
    static assert(!__traits(compiles, v.xr), "a swizzle uses one spelling");
    static assert(!__traits(compiles, v.nope), "a name that is no swizzle is no member");
    static assert(!__traits(compiles, ScreenSize!int(1, 2).wh), "only one-letter names swizzle");
}

/// `==` is one `bool`, and equal vectors hash alike.
@("Vector.equalityAndHashing")
@safe pure nothrow
unittest
{
    assert(F4(1, 2, 3, 4) == F4(1, 2, 3, 4));
    assert(F4(1, 2, 3, 4) != F4(1, 2, 3, 5));
    assert(Vec2f(1, 2) == F2(1, 2), "the layout is not part of the value");
    int[Cell] cells = [Cell(1, 2): 5];
    assert(cells[Cell(1, 2)] == 5);
}

/// A packed vector's components are a slice of its storage.
@("Vector.slices")
@safe pure nothrow @nogc
unittest
{
    auto v = Vec3f(1, 2, 3);
    assert(v[] == [1f, 2, 3]);
    assert(v[1 .. $] == [2f, 3]);
}

/// A vector prints as a tuple.
@("Vector.toString")
@safe
unittest
{
    import sparkles.base.buffer : checkToString;
    import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;

    checkToString(Vector!(int, 1)(1), "(1)");
    checkToString(Vec3f(1, 2, 3), "(1, 2, 3)");
    checkToString(F4(1, 2, 3, 4), "(1, 2, 3, 4)");
    checkToString(prettyPrint(Vec2f(1, 2), PrettyPrintOptions!void.plainText), "(1, 2)");
    checkToString(prettyPrint(Vec2f(1, 2)), "(\x1b[34m1\x1b[39m, \x1b[34m2\x1b[39m)");
}

/// Floating-point vectors have an infinity.
@("Vector.infinity")
@safe pure nothrow @nogc
unittest
{
    static foreach (i; 0 .. 3)
        static assert(Vec3f.infinity[i] is float.infinity);
}
