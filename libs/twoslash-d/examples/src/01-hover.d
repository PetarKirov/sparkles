module sample;
// ---cut---
/// Doubles a number — the ddoc travels into the hover popup.
int twice(int x) => x * 2;

auto answer = twice(21);
//     ^?
