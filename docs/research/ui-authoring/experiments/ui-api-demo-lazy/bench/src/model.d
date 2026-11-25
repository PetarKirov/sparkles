/// The model and messages the three builders' views share.
module model;

import std.sumtype : SumType;

struct MemberRow { string name; string value; }
struct Stats { bool hashOnEdit; int debounceMs; }
struct IdsView { bool computing; string query; const(MemberRow)[] rows; }

struct ToggleHash {}
struct SetDebounce { int ms; }
struct CopyName { string name; }
alias StatsMsg = SumType!(ToggleHash, SetDebounce, CopyName);
