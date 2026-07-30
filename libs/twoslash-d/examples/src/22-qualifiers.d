module sample;
// ---cut---
immutable int limit = 100;
//            ^?
immutable label = "alpha";
const(char)[] view = label;
//            ^?
shared int counter;
//         ^?

/// inout propagates the argument mutability through to the result.
inout(char)[] firstHalf(inout(char)[] text) => text[0 .. $ / 2];

auto half = firstHalf(label);
//   ^?
//          ^?
