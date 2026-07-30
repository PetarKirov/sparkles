module sample;
import std.traits : ReturnType;
// ---cut---
/// Connection settings.
struct Config
{
    string host; /// Hostname or IP.
    ushort port; /// TCP port.
}

enum fields = [__traits(allMembers, Config)];
//   ^?

int connect(Config c) => c.port;
alias Status = ReturnType!connect;

Status code = 200;
//     ^?
