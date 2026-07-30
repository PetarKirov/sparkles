module sample;
// ---cut---
enum greeting = "Hello, D twoslash";
// @annotate: computed at compile time — a manifest constant
enum shouted = greeting ~ "!";
