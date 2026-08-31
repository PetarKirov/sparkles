/**
`sparkles:wired` — format-aware (de)serialization.

Importing `sparkles.wired` pulls in the public policy surface (the `@Wire*`
attributes and their vocabulary). Concrete format backends — e.g.
`sparkles.wired.json` — are imported separately or re-exported here as they land.

See `docs/specs/wired/SPEC.md` for the normative specification.
*/
module sparkles.wired;

public import sparkles.wired.policy;
public import sparkles.wired.schema;
public import sparkles.wired.overlay;
public import sparkles.wired.walk;
public import sparkles.wired.json;
public import sparkles.wired.sdl;
