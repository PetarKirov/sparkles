// Which call-site tricks compile, and which resolve to the *caller's* location?
module site_probe;
import std.stdio : writeln;

struct Site { string file; size_t line; size_t col; }

// P1: plain default args.
Site p1(string file = __FILE__, size_t line = __LINE__) => Site(file, line, 0);

// P2: special tokens nested in a default-argument expression.
Site p2(Site s = Site(__FILE__, __LINE__, 0)) => s;

// P3: default *template* alias argument holding a lambda; getLocation of it.
Site p3(alias tag = () {})() {
    enum loc = __traits(getLocation, tag);
    return Site(loc[0], loc[1], loc[2]);
}

// P4: explicit lambda passed as a `!` argument.
Site p4(alias tag)() {
    enum loc = __traits(getLocation, tag);
    return Site(loc[0], loc[1], loc[2]);
}

// P5: getLocation of a lambda inside a default (runtime) argument.
Site p5(Site s = () { enum loc = __traits(getLocation, __traits(parent, {})); return Site(loc[0], loc[1], loc[2]); }()) => s;

// P6: default template value parameter.
Site p6(size_t line = __LINE__, string file = __FILE__)() => Site(file, line, 0);

// P7: __traits(getLocation, __traits(parent, {})) in the callee.
Site p7() {
    enum loc = __traits(getLocation, __traits(parent, {}));
    return Site(loc[0], loc[1], loc[2]);
}

// P8: __FUNCTION__ / __MODULE__ default args.
string p8(string fn = __FUNCTION__, string mod = __MODULE__) => mod ~ " / " ~ fn;

// P9: struct static "here" factory with default args, used as a default argument.
struct Here { string file; size_t line; static Here make(string f = __FILE__, size_t l = __LINE__) => Here(f, l); }
Here p9(Here h = Here.make()) => h;

// P10: getLocation on a lambda declared at the call site as a *runtime* argument.
Site p10(T)(T tag) {
    enum loc = __traits(getLocation, T);   // a lambda's type is a function/delegate type, not a symbol
    return Site(loc[0], loc[1], loc[2]);
}

// P11: alias template arg + IFTI of a local struct type declared in a mixin
// (mixin-template site): `mixin(site)` string.
enum string here = q{Site(__traits(getLocation, __traits(parent, {}))[0], __LINE__, 0)};

void main()
{
    writeln("P1 ", p1());                                   // line 54
    writeln("P2 ", p2());                                   // line 55
    static if (__traits(compiles, p3())) writeln("P3 ", p3()); else writeln("P3 does not compile");
    writeln("P4 ", p4!(() {})());  writeln("P4b ", p4!({})());
    static if (__traits(compiles, p5())) writeln("P5 ", p5());
    writeln("P6 ", p6());
    writeln("P7 ", p7());
    writeln("P8 ", p8());
    writeln("P9 ", p9());
    static if (__traits(compiles, p10(() {}))) writeln("P10 ", p10(() {})); else writeln("P10 does not compile");
    writeln("P11 ", mixin(here));
    // two P3 calls on one line: distinct?
    static if (__traits(compiles, p3())) { writeln("P3 x2 ", p3(), p3()); }
    writeln("P4 x2 ", p4!({})(), " ", p4!({})());
}
// P12: column of a lambda written inside a string mixin at the call site.
enum string siteHere = q{(){ enum l = __traits(getLocation, __traits(parent, {})); return Site(l[0], l[1], l[2]); }()};
void p12main() { writeln("P12 ", mixin(siteHere), " ", mixin(siteHere)); }
static this() { p12main(); }
