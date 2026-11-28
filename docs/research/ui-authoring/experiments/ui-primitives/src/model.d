/// The model and messages both libraries' views share.
module model;

import std.sumtype : SumType;

struct MemberRow { string name; string value; }
struct Stats { bool hashOnEdit; int debounceMs; }
struct IdsView { bool computing; string query; const(MemberRow)[] rows; }

struct ToggleHash {}
struct SetDebounce { int ms; }
struct CopyName { string name; }
alias StatsMsg = SumType!(ToggleHash, SetDebounce, CopyName);

struct Settings
{
    bool[8] flags;
    int[8] numbers;
    string name;
}

struct ToggleFlag { int index; }
struct SetNumber { int index; int value; }
struct EditName {}
struct Press { int button; }
alias SettingsMsg = SumType!(ToggleFlag, SetNumber, EditName, Press, CopyName);
