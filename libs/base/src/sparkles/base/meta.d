/**
Compile-time metaprogramming helpers for Sparkles.
*/
module sparkles.base.meta;

/// Evaluates whether a version identifier is set at compile time.
template isVersion(string versionName)
{
    mixin("version (", versionName, ") { enum isVersion = true; } else { enum isVersion = false; }");
}

@("base.meta.isVersion")
@safe pure unittest
{
    static assert(isVersion!"unittest");
    static assert(!isVersion!"NonExistentVersionIdentifier_12345");
}
