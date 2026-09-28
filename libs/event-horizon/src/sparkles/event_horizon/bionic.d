/**
Declarations Bionic provides but druntime's `core.sys.posix` omits for
`CRuntime_Bionic` — the pty-allocation quartet (API 21+). Declared here, not
worked around, so the call sites stay the portable POSIX spelling.
*/
module sparkles.event_horizon.bionic;

version (CRuntime_Bionic):

extern (C) nothrow @nogc:

int posix_openpt(int flags);
int grantpt(int fd);
int unlockpt(int fd);
char* ptsname(int fd);
