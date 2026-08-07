/**
Platform backend selection (SPEC §3.5): `DefaultBackend` is the completion
backend the loop uses by default on each platform — `UringBackend` on Linux,
`KqueueBackend` on macOS/BSD, `IocpBackend` on Windows.

The `EventHorizonLibkqueue` version override forces the kqueue backend on
Linux, on top of [mheily/libkqueue](https://github.com/mheily/libkqueue) — a
Linux compatibility shim over epoll. It exists so the kqueue backend and the
full `EventLoop!KqueueBackend` integration can be built and tested on Linux
CI without a Mac; select it with `-version=EventHorizonLibkqueue` and link
`-lkqueue`.
*/
module sparkles.event_horizon.backend.select;

version (EventHorizonLibkqueue)
{
    public import sparkles.event_horizon.backend.kqueue : DefaultBackend = KqueueBackend;
}
else version (Android)
{
    // Android is Linux, but the app seccomp policy denies io_uring_setup —
    // and there is no epoll fallback in this library by design (SPEC §3.4).
    // The port is the kqueue PEER backend over mheily/libkqueue (an epoll
    // shim the Android build links statically): the same backend + shim
    // combination Linux CI already exercises via EventHorizonLibkqueue.
    public import sparkles.event_horizon.backend.kqueue : DefaultBackend = KqueueBackend;
}
else version (linux)
{
    public import sparkles.event_horizon.backend.uring : DefaultBackend = UringBackend;
}
else version (OSX)
{
    public import sparkles.event_horizon.backend.kqueue : DefaultBackend = KqueueBackend;
}
else version (Windows)
{
    public import sparkles.event_horizon.backend.iocp : DefaultBackend = IocpBackend;
}
