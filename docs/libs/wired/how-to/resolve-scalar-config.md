# Resolve scalar configuration with retained definitions

Import `sparkles.wired.config` to resolve scalar preferences without discarding
where their values came from. The schema supplies compiled defaults; each source
supplies sparse definitions with numerical priorities. Smaller priorities win.
Two equally preferred scalar definitions conflict, even when their values agree.

This interface handles supported scalars, strings, enums, nullable scalar payloads,
and explicitly marked finite sections. It rejects collection/custom-owner fields
rather than silently reporting a partial application schema. Collection composition,
app source discovery, settings persistence, and `config show` rendering are separate
contracts, not features of this scalar interface.

## Load and resolve

The runnable [scalar example](../../../../libs/wired/examples/scalar-config.d)
creates a builder, registers a user-file source, decodes a renamed setting using
its original wire policy, transfers the input into the builder, resolves, and
copies the effective configuration.

Start with `ConfigBuilder!T.create`. The result owns a builder on success; use
`takeValue()` to transfer it. Register sources with stable byte identities,
a source kind, diagnostic detail, priority, and order. Kind is a description,
not a hidden precedence rule. The reserved `$builtin` source and its field-
initializer definitions are created automatically.

Decode a text or parsed JSON root with `decodeConfigInput!T`. Missing members
supply no definition. Explicit `false`, zero, empty strings, and values equal to
defaults remain supplied. A nullable payload retains three states: missing,
supplied null, and supplied value. `WireName`, `WireCase`, and enum representation
come from the original schema site, not a rewritten nullable overlay.

Use `submitOwned` to transfer a successful decoded capsule, or `submitBorrowed`
to capture a typed `ConfigInput!T`. Rejected submission leaves both owners and
logical state unchanged. A successful owned submission consumes its capsule,
including an empty capsule. Definition metadata overrides priority/order/local
identity/location; a section priority supplies inheritance only to present
children, with explicit leaf priority taking precedence.

## Handle outcomes without replacing intent

`resolve` distinguishes operational failure from a complete semantic result:

- Allocation, overflow, or budget failure leaves the builder collecting. Adjust
  positive limits with `setLimits` or destroy the builder.
- A successful resolution consumes the builder and returns a snapshot, including
  every accepted definition and every conflict/selected-validation failure.
- Failed options have no effective value. Successfully resolved siblings remain
  inspectable in the same snapshot.
- `copyConfig` returns an independent configuration only if every option resolves.
  It does not repair conflicts with defaults or a last writer.

JSON parse/member/value failures and operational capture failures are distinct
in the decoder result. Unknown members reject by default; explicit ignore can
skip unknown fields but cannot hide duplicates of known fields. `WireStrict`
always requires rejection. Invalid enum domains reject admission even if their
definitions would later lose priority; `ConfigCheck` runs only for the sole
selected scalar, not conflicting or overridden values.

## Inspect and retain lifetimes

Use typed `visitOption`, `visitDefinition`, `visitOptions`, `visitDefinitions`,
`visitSource`, and `visitSources` calls. The callbacks borrow read-only records
for their call; they are not independently owned copies. Keep the snapshot alive
for provenance, and use `copyConfig` for independently owned settings. Do not
move or destroy an owner during its active callback.
The visit functions are free typed templates called with UFCS, for example
`snapshot.visitOption!sink("tabWidth")`; include the corresponding function names
when using selective imports. This keeps a captured sink and snapshot parameter
from requiring a deprecated dual-context member template.
Views keep the original schema type parameter but use opaque `ConfigValueView`
records with `hasValue` and scoped `get`; they expose no raw payload pointer.
Strings read as `const(char)[]`, and nullable values use a scoped nullable view
with `isNull`/`get`. Use `copyConfig` or an explicit copy when retaining text.

Sources enumerate by unsigned identity bytes, definitions by priority/order/source/
local identity, and options in schema declaration order. Failed-address diagnostics
use canonical byte order. Canonical option paths use original D member names;
wire renames affect document spelling, not option identity.

A source handle saved from registration remains valid after moving its builder,
resolving into a snapshot, and moving that snapshot. A wrong-owner or stale handle
is a structured lookup error, never a dereference of a retired owner.

## Keep limits explicit

Limits count sources, definitions, logical payload bytes, declared options, and
member depth. They include compiled defaults, overridden values and retained
validation text. Equal limits fit; one excess fails atomically. Payload accounting
is independent of allocator capacity or internal immutable sharing and is not an
RSS guarantee. Detached capsules count supplied values and schema paths, not
registered sources or built-in definitions.

For the exact supported policy/type matrix, ownership transitions, budget formulas,
and acceptance obligations, see the
[scalar contract](../../../specs/wired/config/scalar-resolution.md).
