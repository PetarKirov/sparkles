# `sparkles:recovery` reference

Every function is `@safe nothrow` and reports failure as an `Expected` whose
error is a user-facing message. Leases need Linux (`flock`); generation files
need the POSIX VFS backend. Elsewhere the calls report that recovery is
unavailable.

## Leased directories — `sparkles.recovery.directory`

| Symbol                                 | Meaning                                                                                                                                                              |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LeasedDirectory.create(base, root)`   | creates a private (`0700`) archive with a random name under `base`, syncs it up to the durable namespace root `root`, and holds its lease; `base` must lie in `root` |
| `LeasedDirectory.claim(path)`          | takes the lease of an abandoned archive; `busy` while another process holds it, `missing` once it is gone                                                            |
| `path`, `owned`, `close()`             | the archive's path, whether the lease is held, and releasing it                                                                                                      |
| `DirectoryIssue`, `DirectoryIssueKind` | a refused lease: `busy`, `missing` or `unavailable`, with its message                                                                                                |

Creation and claiming lock the base directory, so a half-created archive is
never claimed. Initialization opens nothing above `root`, as an Android
application sandbox requires.

## Generations — `sparkles.recovery.archive`

| Symbol                                                     | Meaning                                                                                                  |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `ArchiveLayout`                                            | the file suffix, the retirement marker's prefix and tag, and the largest payload (512 MiB)               |
| `generationName(layout, g)`, `generationOf(layout, name)`  | the canonical name, 20 digits and the suffix; zero for any other name                                    |
| `appendGeneration(dir, g, bytes, layout)`                  | a create-only atomic write that syncs the directory; a `WriteReceipt` says whether the commit is durable |
| `readGeneration(dir, g, layout)`                           | the payload, from a regular file only, never through a link                                              |
| `listGenerations(dir, layout)`                             | the canonical generations, newest first, links skipped                                                   |
| `pruneArchive(lease, through, layout, validate, keep)`     | keeps the `keep` newest valid generations at or below `through`; damaged, linked and newer files stay    |
| `retire(lease, g, layout)`, `retirementOf(dir, g, layout)` | a marker that `g` was adopted elsewhere: `none`, `retired`, or `damaged` (kept and reported)             |
| `claimArchives(base, layout)`                              | claims every abandoned archive under `base` with its generations; the caller closes each lease           |

## The writer — `sparkles.recovery.writer`

`CheckpointWriter!Snapshot` keeps one write running and one snapshot waiting.
A snapshot is a class with `ulong revision() const` and
`Expected!string encode(ulong generation) const`, which runs on the worker.

| Member                                          | Meaning                                                                                          |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `this(lease, layout, lastGeneration, interval)` | takes over the lease; `interval` (at most 500 ms) spaces submissions                             |
| `request(snapshot, now)`                        | retains the newest snapshot; continuous requests never postpone the first deadline               |
| `poll(now)`, `flush(now)`, `nextPoll(now)`      | publish receipts and submit due state; submit now; when to poll next                             |
| `durableRevision`, `durableGeneration`          | the newest revision acknowledged durable, and its file                                           |
| `pending`, `busy`, `overdue(now)`               | unacknowledged state exists; a write is running; pending state is a second old                   |
| `error`, `notice`                               | the latest failure (retried a second later under a new generation), the latest success's warning |
| `shutdown()`                                    | finishes accepted writes, publishes them, then releases the lease                                |

## Maintenance — `sparkles.recovery.maintenance`

`MaintenanceTask` is a job with `run()` and an `error`; `MaintenanceQueue`
runs one at a time on a `sparkles.event_horizon.job_queue.JobQueue`.
`InitializeTask(base, root)` creates the archive and `PruneTask(lease,
through, layout, validate)` prunes it. An application adds its own kinds,
such as discovering archives to offer and retiring adopted ones, as
subclasses.
