module sample;
// ---cut---
// NB: manifest constants, not globals — a module-scope initializer is CTFE'd,
// and reading a mutable global there is an error ("cannot be read at compile
// time"), which would bury the completion list under a diagnostic.
/// Alpha channel opacity, 0 through 255.
enum ubyte alpha = 255;
/// The Latin alphabet, lowercase.
enum string alphabet = "abcdefghijklmnopqrstuvwxyz";

auto opacity = alpha;
//                  ^|
//   ^?
