module sample;
import std.meta : AliasSeq;
// ---cut---
/// The field types every record in this module carries.
alias Ts = AliasSeq!(int, string, double);

struct Record { Ts fields; }

enum arity = Ts.length;
//   ^?

auto r = Record(1, "two", 3.0);
//   ^?
