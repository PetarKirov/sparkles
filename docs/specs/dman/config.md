# `sparkles:dman` — Configuration

_The settings model ([D14](./DECISIONS.md)). dman ships configuration in v1
because the prior art's single biggest recurring pain was hardcoded policy (a
fixed protected-branch set, an assumed `origin`, no overrides). The guiding rules:
**policy is data**, and **every auto-detected assumption has an explicit
override**._

## Layered resolution

Each setting resolves in a fixed precedence: **CLI flag → environment variable →
config file → auto-detected default**. So a scan can run entirely on defaults,
while any layer can pin a value for a repo, a session, or a machine.

## Policy as data

- **Protected-branch glob patterns**, evaluated as policy — not a hardcoded
  `main`/`master`/`develop` list. A pattern set decides which branches the
  protected-branch write guard ([VCS backend](./vcs-backend.md)) refuses to mutate.

## Overrides for auto-detected assumptions

Every value dman would otherwise infer is overridable:

- **trunk** revision (overrides the detection ladder),
- **remote name** (not assumed `origin`),
- **scan roots** + exclude globs + max depth,
- **worktree naming template** ([D9](./DECISIONS.md)),
- **staleness threshold** (the age at which a branch is flagged stale).

## Configurable UI & cache

- **cache TTL** (and a disable/refresh switch — see
  [CLI surface](./cli-surface.md)),
- **theme** — the semantic color roles (accent / warning / danger / current /
  selected / success) the TUI renders through ([TUI shell](./tui-shell.md)),
- **keymap** overrides.

## Location & format

The config file lives under `core-cli`'s `configDir` ([Architecture §
config](./architecture.md#config--state)); it is a `wired`-decodable settings
struct, so its fields, naming, and validation follow the same policy vocabulary as
the rest of dman ([Command schema](./command-schema.md)).
