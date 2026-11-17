# `sparkles:recovery`

`sparkles:recovery` keeps an application's unsaved state safe across a crash.
Each running instance owns a private archive: a directory leased with
`flock`, so no second instance writes to it and a crashed instance's archive
can be claimed by the next one. The archive holds numbered generation files
that are never replaced. A background writer appends the latest observed
state and acknowledges a revision only once its generation is durable, so a
caller can tell its user which edits are safe.

Payloads are opaque: the library stores bytes a snapshot encodes, and the
application owns the schema, the restore user interface and what counts as a
valid record. Files are written through the capability VFS
([VFO9](../../specs/base/vfs/SPEC.md#vfo9-atomic-write)): create-only, synced
before commit, and with the directory synced after. The editor
(`apps/editor`) is its first user.

## Documentation

- [Reference: leases, generations, the writer and maintenance](./reference/api.md)

The fault-injection and process-kill probes in `libs/recovery/tools` check
the storage against real system calls; the editor's
[testing ledger](../../specs/editor/testing.md) records their runs.
