module sample;
// ---cut---
/// Adds a `bytes` accessor scaled by `unit`.
mixin template SizeAccessor(string unit)
{
    static if (unit == "KiB")
        size_t bytes() const => count * 1024;
    else
        size_t bytes() const => count;
}

struct Buffer { size_t count; mixin SizeAccessor!"KiB"; }

auto total = Buffer(4).bytes;
//   ^?
//                     ^?
