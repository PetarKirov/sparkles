module sample;
// ---cut---
// NB: exactly one instantiation on purpose. With two (say `clamped(12, 0, 9)`
// as well), the oracle picks an arbitrary instance for *every* tip in this
// file — including the template's own declaration — and the choice flips from
// run to run, so the fixture would never verify twice in a row.
/// Clamps value into the range lo .. hi; T is inferred from the arguments.
T clamped(T)(T value, T lo, T hi)
    => value < lo ? lo : (value > hi ? hi : value);

auto ratio = clamped(1.75, 0.0, 1.0);
//   ^?
//           ^?
