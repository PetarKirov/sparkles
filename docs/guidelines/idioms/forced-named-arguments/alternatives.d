/// Alternative techniques for forcing named arguments — none of them work.
/// Each section demonstrates one approach and why it fails.
///
/// This file is for reference only; it is NOT expected to compile as-is
/// (the failing lines are left uncommented to show the errors).

module alternatives;

import std.stdio : writefln;

// ---------------------------------------------------------------------------
// 1. @disable this(int, int, …) — blocks BOTH positional AND named
// ---------------------------------------------------------------------------

struct Opts1
{
    int x, y, width, height;
    @disable this(int, int, int, int);
}

void test1()
{
    // auto a = Opts1(10, 20, 100, 200);                    // ❌ blocked
    // auto b = Opts1(x: 10, y: 20, width: 100, height: 200); // ❌ also blocked!
}

// ---------------------------------------------------------------------------
// 2. Distinct wrapper types — type-safe, but doesn't force naming
// ---------------------------------------------------------------------------

struct X { int v; }
struct Y { int v; }
struct W { int v; }
struct H { int v; }

void draw2(X x, Y y, W w, H h)
{
    writefln("draw2(%d, %d, %d, %d)", x.v, y.v, w.v, h.v);
}

void test2()
{
    draw2(X(1), Y(2), W(3), H(4));             // compiles — positional
    draw2(x: X(1), y: Y(2), w: W(3), h: H(4)); // compiles — named
    // Both work — naming is not enforced.
}

// ---------------------------------------------------------------------------
// 3. All-default parameters — positional still works
// ---------------------------------------------------------------------------

void draw3(int x = 0, int y = 0, int width = 0, int height = 0)
{
    writefln("draw3(%d, %d, %d, %d)", x, y, width, height);
}

void test3()
{
    draw3(10, 20, 100, 200);                                  // ✅ positional
    draw3(x: 10, y: 20, width: 100, height: 200);             // ✅ named
    // Both work — naming is not enforced.
}

// ---------------------------------------------------------------------------
// 4. Struct parameter wrapper — positional struct literal still works
// ---------------------------------------------------------------------------

struct DrawOpts
{
    int x, y, width, height;
}

void draw4(DrawOpts o)
{
    writefln("draw4(%d, %d, %d, %d)", o.x, o.y, o.width, o.height);
}

void test4()
{
    draw4(DrawOpts(10, 20, 100, 200));                                  // ✅ positional
    draw4(DrawOpts(x: 10, y: 20, width: 100, height: 200));            // ✅ named
    // Both work — naming is not enforced.
}

// ---------------------------------------------------------------------------
// 5. static opCall with @disable this() — opCall is unreachable
// ---------------------------------------------------------------------------

struct Opts5
{
    private int _x, _y;

    @disable this();

    static Opts5 opCall(int x, int y)
    {
        Opts5 o = void;
        o._x = x;
        o._y = y;
        return o;
    }
}

void test5()
{
    // auto o = Opts5(x: 1, y: 2);  // ❌ Error: constructor is not callable
    // auto p = Opts5(1, 2);         // ❌ Error: expected 0 arguments, not 2
    // @disable this() blocks everything — opCall is never reached.
}
