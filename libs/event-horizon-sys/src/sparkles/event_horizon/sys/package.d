/**
The loop-free system-call layer of `sparkles:event-horizon`.

It holds the capability VFS's blocking backend, `BlockingVfs`, so code that
must not depend on the event loop, such as test fixtures in every package's
test build, can reach the file system through directory capabilities. It also
classifies native error codes into the shared `ErrorKind`.
*/
module sparkles.event_horizon.sys;

public import sparkles.event_horizon.sys.descriptor;
public import sparkles.event_horizon.sys.error_kinds;

version (Windows)
    public import sparkles.event_horizon.sys.vfs_nt;
else
    public import sparkles.event_horizon.sys.vfs;
