/**
`sparkles:event-horizon` — the completion-first event loop with a native
algebraic-effect layer. This package module re-exports the public surface
(SPEC §13); import `sparkles.event_horizon` for the whole API, or a specific
module for a narrower dependency.
*/
module sparkles.event_horizon;

public import sparkles.event_horizon.errors;
public import sparkles.event_horizon.cause;
public import sparkles.event_horizon.capability;
public import sparkles.event_horizon.scope_;
public import sparkles.event_horizon.schedule;
public import sparkles.event_horizon.clock;
public import sparkles.event_horizon.net;
public import sparkles.event_horizon.buffer;
public import sparkles.event_horizon.effect;
public import sparkles.event_horizon.op;

version (Windows)
{
    public import sparkles.event_horizon.backend.iocp;
}

version (linux)
{
    public import sparkles.event_horizon.backend.probe;
    public import sparkles.event_horizon.loop;
    public import sparkles.event_horizon.sched;
    public import sparkles.event_horizon.io;
    public import sparkles.event_horizon.live;
    public import sparkles.event_horizon.group;
    public import sparkles.event_horizon.pool;
    public import sparkles.event_horizon.fs;
    public import sparkles.event_horizon.proc;
    public import sparkles.event_horizon.signals;
    public import sparkles.event_horizon.watch;
}
