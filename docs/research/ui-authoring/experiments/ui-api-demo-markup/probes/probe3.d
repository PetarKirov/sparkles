void g()
{
    mixin("#line 100\nstruct A3 {}");
    pragma(msg, "L3 #line100 nofile: ", __traits(getLocation, A3));
    mixin("#line 100 \"probe3.d\"\nstruct A4 {}");
    pragma(msg, "L5 #line100 samefile: ", __traits(getLocation, A4));
    mixin("#line 100 \"zz.d\"\nstruct A5 {}\nstruct A6 {}");
    pragma(msg, "L7 #line100 : ", __traits(getLocation, A5), __traits(getLocation, A6));
    mixin("#line 1 \"zz.d\"\nstruct A9 {}");
    pragma(msg, "L9 #line1 : ", __traits(getLocation, A9));
}
#line 50 "qq.d"
struct B {}
pragma(msg, "file-level: ", __traits(getLocation, B));
