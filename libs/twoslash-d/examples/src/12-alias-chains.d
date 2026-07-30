module sample;
// ---cut---
/// A one-field container.
struct Box(T) { T value; }

alias IntBox = Box!int;
alias Handle = IntBox;

Handle open() => Handle(42);

auto h = open();
//   ^?
//       ^?
