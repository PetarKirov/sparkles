void g()
{
    mixin("#line 100 \"app.d\"\nstruct A3 {}");
    pragma(msg, "L3 #line100: ", __traits(getLocation, A3));
    mixin("#line 100 \"app.d\"\nstruct A4 {}");
    pragma(msg, "L5 #line100: ", __traits(getLocation, A4));



    mixin("#line 100 \"app.d\"\nstruct A5 {}");
    pragma(msg, "L10 #line100: ", __traits(getLocation, A5));
    mixin("#line 100 \"app.d\"\nstruct A6 {}\n#line 200\nstruct A7 {}");
    pragma(msg, "L12 #line100: ", __traits(getLocation, A6), __traits(getLocation, A7));
    mixin("\n#line 100 \"app.d\"\nstruct A8 {}");
    pragma(msg, "L14 nl #line100: ", __traits(getLocation, A8));
    mixin("int x = 1;\n#line 100 \"app.d\"\nint y = \"s\";");
}
