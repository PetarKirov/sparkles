/**
The loop-free system-call layer of `sparkles:event-horizon`.

It holds the capability VFS's blocking backend, `BlockingVfs`, so code that
must not depend on the event loop, such as test fixtures in every package's
test build, can reach the file system through directory capabilities.
*/
module sparkles.event_horizon.sys;

public import sparkles.event_horizon.sys.vfs;
